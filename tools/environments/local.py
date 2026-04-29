"""Local execution environment — spawn-per-call with session snapshot."""

import os
import platform
import shutil
import signal
import subprocess
import tempfile

from tools.environments.base import BaseEnvironment, _pipe_stdin
from tools.platform_runtime import (
    build_shell_command,
    default_temp_dir,
    find_preferred_shell,
    terminate_pid_tree,
)

_IS_WINDOWS = platform.system() == "Windows"


# Hermes-internal env vars that should NOT leak into terminal subprocesses.
_HERMES_PROVIDER_ENV_FORCE_PREFIX = "_HERMES_FORCE_"


def _build_provider_env_blocklist() -> frozenset:
    """Derive the blocklist from provider, tool, and gateway config."""
    blocked: set[str] = set()

    try:
        from hermes_cli.auth import PROVIDER_REGISTRY
        for pconfig in PROVIDER_REGISTRY.values():
            blocked.update(pconfig.api_key_env_vars)
            if pconfig.base_url_env_var:
                blocked.add(pconfig.base_url_env_var)
    except ImportError:
        pass

    try:
        from hermes_cli.config import OPTIONAL_ENV_VARS
        for name, metadata in OPTIONAL_ENV_VARS.items():
            category = metadata.get("category")
            if category in {"tool", "messaging"}:
                blocked.add(name)
            elif category == "setting" and metadata.get("password"):
                blocked.add(name)
    except ImportError:
        pass

    blocked.update({
        "OPENAI_BASE_URL",
        "OPENAI_API_KEY",
        "OPENAI_API_BASE",
        "OPENAI_ORG_ID",
        "OPENAI_ORGANIZATION",
        "OPENROUTER_API_KEY",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "LLM_MODEL",
        "GOOGLE_API_KEY",
        "DEEPSEEK_API_KEY",
        "MISTRAL_API_KEY",
        "GROQ_API_KEY",
        "TOGETHER_API_KEY",
        "PERPLEXITY_API_KEY",
        "COHERE_API_KEY",
        "FIREWORKS_API_KEY",
        "XAI_API_KEY",
        "HELICONE_API_KEY",
        "PARALLEL_API_KEY",
        "FIRECRAWL_API_KEY",
        "FIRECRAWL_API_URL",
        "TELEGRAM_HOME_CHANNEL",
        "TELEGRAM_HOME_CHANNEL_NAME",
        "DISCORD_HOME_CHANNEL",
        "DISCORD_HOME_CHANNEL_NAME",
        "DISCORD_REQUIRE_MENTION",
        "DISCORD_FREE_RESPONSE_CHANNELS",
        "DISCORD_AUTO_THREAD",
        "SLACK_HOME_CHANNEL",
        "SLACK_HOME_CHANNEL_NAME",
        "SLACK_ALLOWED_USERS",
        "WHATSAPP_ENABLED",
        "WHATSAPP_MODE",
        "WHATSAPP_ALLOWED_USERS",
        "SIGNAL_HTTP_URL",
        "SIGNAL_ACCOUNT",
        "SIGNAL_ALLOWED_USERS",
        "SIGNAL_GROUP_ALLOWED_USERS",
        "SIGNAL_HOME_CHANNEL",
        "SIGNAL_HOME_CHANNEL_NAME",
        "SIGNAL_IGNORE_STORIES",
        "HASS_TOKEN",
        "HASS_URL",
        "EMAIL_ADDRESS",
        "EMAIL_PASSWORD",
        "EMAIL_IMAP_HOST",
        "EMAIL_SMTP_HOST",
        "EMAIL_HOME_ADDRESS",
        "EMAIL_HOME_ADDRESS_NAME",
        "GATEWAY_ALLOWED_USERS",
        "GH_TOKEN",
        "GITHUB_APP_ID",
        "GITHUB_APP_PRIVATE_KEY_PATH",
        "GITHUB_APP_INSTALLATION_ID",
        "MODAL_TOKEN_ID",
        "MODAL_TOKEN_SECRET",
        "DAYTONA_API_KEY",
        "VERCEL_OIDC_TOKEN",
        "VERCEL_TOKEN",
        "VERCEL_PROJECT_ID",
        "VERCEL_TEAM_ID",
    })
    return frozenset(blocked)


_HERMES_PROVIDER_ENV_BLOCKLIST = _build_provider_env_blocklist()


def _sanitize_subprocess_env(base_env: dict | None, extra_env: dict | None = None) -> dict:
    """Filter Hermes-managed secrets from a subprocess environment."""
    try:
        from tools.env_passthrough import is_env_passthrough as _is_passthrough
    except Exception:
        _is_passthrough = lambda _: False  # noqa: E731

    sanitized: dict[str, str] = {}

    for key, value in (base_env or {}).items():
        if key.startswith(_HERMES_PROVIDER_ENV_FORCE_PREFIX):
            continue
        if key not in _HERMES_PROVIDER_ENV_BLOCKLIST or _is_passthrough(key):
            sanitized[key] = value

    for key, value in (extra_env or {}).items():
        if key.startswith(_HERMES_PROVIDER_ENV_FORCE_PREFIX):
            real_key = key[len(_HERMES_PROVIDER_ENV_FORCE_PREFIX):]
            sanitized[real_key] = value
        elif key not in _HERMES_PROVIDER_ENV_BLOCKLIST or _is_passthrough(key):
            sanitized[key] = value

    # Per-profile HOME isolation for background processes (same as _make_run_env).
    from hermes_constants import get_subprocess_home
    _profile_home = get_subprocess_home()
    if _profile_home:
        sanitized["HOME"] = _profile_home

    return sanitized


def _find_bash() -> str:
    """Find bash for command execution (required by BaseEnvironment semantics)."""
    return _find_legacy_bash()


def _find_shell() -> str:
    """Find the preferred local shell executable."""
    return find_preferred_shell()


def _find_legacy_bash() -> str:
    """Find Git Bash specifically for compatibility callers that require it."""
    if not _IS_WINDOWS:
        return (
            shutil.which("bash")
            or ("/usr/bin/bash" if os.path.isfile("/usr/bin/bash") else None)
            or ("/bin/bash" if os.path.isfile("/bin/bash") else None)
            or os.environ.get("SHELL")
            or "/bin/sh"
        )

    def _is_wsl_system_bash(path: str) -> bool:
        norm = os.path.normcase(os.path.abspath(path))
        wsl_bash = os.path.normcase(os.path.abspath(r"C:\Windows\System32\bash.exe"))
        return norm == wsl_bash

    def _looks_like_git_bash(path: str) -> bool:
        norm = os.path.normcase(path).replace("\\", "/")
        return norm.endswith("/git/bin/bash.exe")

    custom = os.environ.get("HERMES_GIT_BASH_PATH")
    if custom and os.path.isfile(custom):
        if _is_wsl_system_bash(custom):
            raise RuntimeError(
                "HERMES_GIT_BASH_PATH points to WSL bash.exe, which is unsupported for "
                "Hermes bash compatibility mode on Windows. Point it to Git Bash "
                "(...\\Git\\bin\\bash.exe) instead."
            )
        return custom

    for candidate in (
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "Git", "bin", "bash.exe"),
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "Git", "usr", "bin", "bash.exe"),
        os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"), "Git", "bin", "bash.exe"),
        os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"), "Git", "usr", "bin", "bash.exe"),
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Git", "bin", "bash.exe"),
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Git", "usr", "bin", "bash.exe"),
    ):
        if candidate and os.path.isfile(candidate):
            return candidate

    git_exe = shutil.which("git")
    if git_exe:
        git_root = os.path.dirname(os.path.dirname(git_exe))
        for candidate in (
            os.path.join(git_root, "bin", "bash.exe"),
            os.path.join(git_root, "usr", "bin", "bash.exe"),
        ):
            if os.path.isfile(candidate):
                return candidate

    found = shutil.which("bash")
    if found:
        if _is_wsl_system_bash(found):
            raise RuntimeError(
                "Found Windows WSL bash.exe on PATH, but Hermes bash compatibility mode "
                "requires Git Bash for correct exit-code behavior. "
                "Install Git for Windows and ensure ...\\Git\\bin\\bash.exe is on PATH."
            )
        if _looks_like_git_bash(found):
            return found

    raise RuntimeError(
        "Git Bash not found. Hermes Agent requires Git for Windows on Windows.\n"
        "Install it from: https://git-scm.com/download/win\n"
        "Or set HERMES_GIT_BASH_PATH to your bash.exe location."
    )


def _windows_to_bash_path(path: str, bash_path: str | None = None) -> str:
    """Convert a Windows absolute path to a bash-compatible path."""
    if not _IS_WINDOWS:
        return path
    if not path or len(path) < 3 or path[1] != ":":
        return path

    drive = path[0].lower()
    rest = path[2:].replace("\\", "/").lstrip("/")
    bash_path = (bash_path or "").lower()

    # WSL bash.exe expects /mnt/<drive>/...; Git Bash expects /<drive>/...
    if "windows\\system32\\bash.exe" in bash_path:
        return f"/mnt/{drive}/{rest}"
    return f"/{drive}/{rest}"


# Standard PATH entries for environments with minimal PATH.
_SANE_PATH = (
    "/opt/homebrew/bin:/opt/homebrew/sbin:"
    "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
)


def _make_run_env(env: dict, *, posix_path_hint: bool = True) -> dict:
    """Build a run environment with provider-var stripping.

    Args:
        posix_path_hint: When True, append a POSIX fallback PATH segment used
            by bash-compat execution. Keep False for Windows-native shells so
            we don't inject mixed PATH separators.
    """
    try:
        from tools.env_passthrough import is_env_passthrough as _is_passthrough
    except Exception:
        _is_passthrough = lambda _: False  # noqa: E731

    merged = dict(os.environ | env)
    run_env = {}
    for k, v in merged.items():
        if k.startswith(_HERMES_PROVIDER_ENV_FORCE_PREFIX):
            real_key = k[len(_HERMES_PROVIDER_ENV_FORCE_PREFIX):]
            run_env[real_key] = v
        elif k not in _HERMES_PROVIDER_ENV_BLOCKLIST or _is_passthrough(k):
            run_env[k] = v
    existing_path = run_env.get("PATH", "")
    if posix_path_hint and "/usr/bin" not in existing_path.split(":"):
        run_env["PATH"] = f"{existing_path}:{_SANE_PATH}" if existing_path else _SANE_PATH

    # Per-profile HOME isolation: redirect system tool configs (git, ssh, gh,
    # npm …) into {HERMES_HOME}/home/ when that directory exists.  Only the
    # subprocess sees the override — the Python process keeps the real HOME.
    from hermes_constants import get_subprocess_home
    _profile_home = get_subprocess_home()
    if _profile_home:
        run_env["HOME"] = _profile_home

    return run_env


def _read_terminal_shell_init_config() -> tuple[list[str], bool]:
    """Return (shell_init_files, auto_source_bashrc) from config.yaml.

    Best-effort — returns sensible defaults on any failure so terminal
    execution never breaks because the config file is unreadable.
    """
    try:
        from hermes_cli.config import load_config

        cfg = load_config() or {}
        terminal_cfg = cfg.get("terminal") or {}
        files = terminal_cfg.get("shell_init_files") or []
        if not isinstance(files, list):
            files = []
        auto_bashrc = bool(terminal_cfg.get("auto_source_bashrc", True))
        return [str(f) for f in files if f], auto_bashrc
    except Exception:
        return [], True


def _resolve_shell_init_files() -> list[str]:
    """Resolve the list of files to source before the login-shell snapshot.

    Expands ``~`` and ``${VAR}`` references and drops anything that doesn't
    exist on disk, so a missing ``~/.bashrc`` never breaks the snapshot.
    The ``auto_source_bashrc`` path runs only when the user hasn't supplied
    an explicit list — once they have, Hermes trusts them.
    """
    explicit, auto_bashrc = _read_terminal_shell_init_config()

    candidates: list[str] = []
    if explicit:
        candidates.extend(explicit)
    elif auto_bashrc and not _IS_WINDOWS:
        # Build a login-shell-ish source list so tools like n / nvm / asdf /
        # pyenv that self-install into the user's shell rc land on PATH in
        # the captured snapshot.
        #
        # ~/.profile and ~/.bash_profile run first because they have no
        # interactivity guard — installers like ``n`` and ``nvm`` append
        # their PATH export there on most distros, and a non-interactive
        # ``. ~/.profile`` picks that up.
        #
        # ~/.bashrc runs last. On Debian/Ubuntu the default bashrc starts
        # with ``case $- in *i*) ;; *) return;; esac`` and exits early
        # when sourced non-interactively, which is why sourcing bashrc
        # alone misses nvm/n PATH additions placed below that guard. We
        # still include it so users who put PATH logic in bashrc (and
        # stripped the guard, or never had one) keep working.
        candidates.extend(["~/.profile", "~/.bash_profile", "~/.bashrc"])

    resolved: list[str] = []
    for raw in candidates:
        try:
            path = os.path.expandvars(os.path.expanduser(raw))
        except Exception:
            continue
        if path and os.path.isfile(path):
            resolved.append(path)
    return resolved


def _prepend_shell_init(cmd_string: str, files: list[str]) -> str:
    """Prepend ``source <file>`` lines (guarded + silent) to a bash script.

    Each file is wrapped so a failing rc file doesn't abort the whole
    bootstrap: ``set +e`` keeps going on errors, ``2>/dev/null`` hides
    noisy prompts, and ``|| true`` neutralises the exit status.
    """
    if not files:
        return cmd_string

    prelude_parts = ["set +e"]
    for path in files:
        # shlex.quote isn't available here without an import; the files list
        # comes from os.path.expanduser output so it's a concrete absolute
        # path.  Escape single quotes defensively anyway.
        safe = path.replace("'", "'\\''")
        prelude_parts.append(f"[ -r '{safe}' ] && . '{safe}' 2>/dev/null || true")
    prelude = "\n".join(prelude_parts) + "\n"
    return prelude + cmd_string


class LocalEnvironment(BaseEnvironment):
    """Run commands directly on the host machine.

    On Unix and Windows bash-compat mode: spawn-per-call through bash with
    session snapshot semantics.

    On Windows native mode: execute directly in the preferred host shell
    (PowerShell/cmd/Git Bash), with explicit cwd handling and no bash snapshot
    wrapper. This keeps the primary Windows flow shell-native.
    """

    def __init__(self, cwd: str = "", timeout: int = 60, env: dict = None, shell_mode: str | None = None):
        requested_mode = (shell_mode or "").strip().lower()
        default_mode = "native" if _IS_WINDOWS else "bash_compat"
        self._shell_mode = requested_mode or default_mode
        if self._shell_mode not in {"native", "bash_compat"}:
            raise ValueError(f"Invalid LocalEnvironment shell_mode={shell_mode!r}. Use 'native' or 'bash_compat'.")
        self._native_shell = _find_shell() if (_IS_WINDOWS and self._shell_mode == "native") else None
        if cwd:
            cwd = os.path.expanduser(cwd)
        super().__init__(cwd=cwd or os.getcwd(), timeout=timeout, env=env)

        # In bash compatibility mode on Windows, convert host cwd up front so
        # the first wrapped command can cd successfully.
        if _IS_WINDOWS and self._shell_mode == "bash_compat":
            self.cwd = self.normalize_path_for_shell(self.cwd)

        if self._use_windows_native_shell():
            self._snapshot_ready = False
        else:
            self.init_session()

    def _use_windows_native_shell(self) -> bool:
        return _IS_WINDOWS and self._shell_mode == "native"

    def _resolve_windows_workdir(self, cwd: str | None) -> str:
        """Resolve cwd for Windows-native execution."""
        raw = (cwd or "").strip()
        if not raw:
            raw = self.cwd

        if raw in {"~", ""}:
            resolved = os.path.expanduser("~")
        elif raw.startswith("~/") or raw.startswith("~\\"):
            resolved = os.path.expanduser(raw)
        elif os.path.isabs(raw):
            resolved = raw
        else:
            resolved = os.path.join(self.cwd or os.getcwd(), raw)

        return os.path.abspath(os.path.expanduser(resolved))

    def get_temp_dir(self) -> str:
        """Return a shell-safe writable temp dir for local execution.

        Termux does not provide /tmp by default, but exposes a POSIX TMPDIR.
        Prefer POSIX-style env vars when available, keep using /tmp on regular
        Unix systems, and only fall back to tempfile.gettempdir() when it also
        resolves to a POSIX path.

        Check the environment configured for this backend first so callers can
        override the temp root explicitly (for example via terminal.env or a
        custom TMPDIR), then fall back to the host process environment.
        """
        if _IS_WINDOWS:
            # Windows native mode should use a real host temp directory.
            # Bash-compat mode keeps /tmp semantics for snapshot artifacts.
            if self._use_windows_native_shell():
                return default_temp_dir()
            return "/tmp"

        for env_var in ("TMPDIR", "TMP", "TEMP"):
            candidate = self.env.get(env_var) or os.environ.get(env_var)
            if candidate and os.path.isabs(candidate):
                return candidate.rstrip("/\\") or candidate

        if os.path.isdir("/tmp") and os.access("/tmp", os.W_OK | os.X_OK):
            return "/tmp"

        candidate = tempfile.gettempdir()
        if candidate.startswith("/"):
            return candidate.rstrip("/") or "/"

        return default_temp_dir()

    def _run_bash(self, cmd_string: str, *, login: bool = False,
                  timeout: int = 120,
                  stdin_data: str | None = None) -> subprocess.Popen:
        if self._use_windows_native_shell():
            raise RuntimeError("_run_bash called in Windows native shell mode")

        shell = _find_bash()
        # For login-shell invocations (used by init_session to build the
        # environment snapshot), prepend sources for the user's bashrc /
        # custom init files so tools registered outside bash_profile
        # (nvm, asdf, pyenv, …) end up on PATH in the captured snapshot.
        # Non-login invocations are already sourcing the snapshot and
        # don't need this.
        if login:
            init_files = _resolve_shell_init_files()
            if init_files:
                cmd_string = _prepend_shell_init(cmd_string, init_files)
        args = build_shell_command(shell, cmd_string, login=login)
        run_env = _make_run_env(self.env, posix_path_hint=True)

        proc = subprocess.Popen(
            args,
            text=True,
            env=run_env,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            preexec_fn=None if _IS_WINDOWS else os.setsid,
            cwd=self.cwd,
        )

        if stdin_data is not None:
            _pipe_stdin(proc, stdin_data)

        return proc

    def _run_windows_native_shell(
        self,
        command: str,
        *,
        cwd: str,
        timeout: int,
        stdin_data: str | None = None,
    ) -> dict:
        exec_command, sudo_stdin = self._prepare_command(command)
        if sudo_stdin is not None and stdin_data is not None:
            effective_stdin = sudo_stdin + stdin_data
        elif sudo_stdin is not None:
            effective_stdin = sudo_stdin
        else:
            effective_stdin = stdin_data

        shell = self._native_shell or _find_shell()
        argv = build_shell_command(shell, exec_command, login=False, interactive=False)
        run_env = _make_run_env(self.env, posix_path_hint=False)
        proc = subprocess.Popen(
            argv,
            cwd=cwd,
            text=True,
            env=run_env,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.PIPE if effective_stdin is not None else subprocess.DEVNULL,
            preexec_fn=None,
        )
        if effective_stdin is not None:
            _pipe_stdin(proc, effective_stdin)

        return self._wait_for_process(proc, timeout=timeout)

    def execute(
        self,
        command: str,
        cwd: str = "",
        *,
        timeout: int | None = None,
        stdin_data: str | None = None,
    ) -> dict:
        """Execute a command, preserving the BaseEnvironment API."""
        if self._use_windows_native_shell():
            effective_timeout = timeout or self.timeout
            effective_cwd = self._resolve_windows_workdir(cwd or self.cwd)
            result = self._run_windows_native_shell(
                command,
                cwd=effective_cwd,
                timeout=effective_timeout,
                stdin_data=stdin_data,
            )
            self.cwd = effective_cwd
            return result

        # Bash-compat path (Unix + explicit Windows compatibility mode)
        if _IS_WINDOWS and cwd:
            cwd = self.normalize_path_for_shell(cwd)
        return super().execute(command, cwd=cwd, timeout=timeout, stdin_data=stdin_data)

    def _kill_process(self, proc):
        """Kill the entire process group (all children)."""
        try:
            if _IS_WINDOWS:
                terminate_pid_tree(proc.pid, force=True)
            else:
                pgid = os.getpgid(proc.pid)
                os.killpg(pgid, signal.SIGTERM)
                try:
                    proc.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            try:
                proc.kill()
            except Exception:
                pass

    def _update_cwd(self, result: dict):
        """Read CWD from temp file (local-only, no round-trip needed)."""
        try:
            with open(self._cwd_file) as f:
                cwd_path = f.read().strip()
            if cwd_path:
                self.cwd = cwd_path
        except (OSError, FileNotFoundError):
            pass

        # Still strip the marker from output so it's not visible
        self._extract_cwd_from_output(result)

    def cleanup(self):
        """Clean up temp files."""
        for f in (self._snapshot_path, self._cwd_file):
            try:
                os.unlink(f)
            except OSError:
                pass

    def normalize_path_for_shell(self, path: str) -> str:
        """Normalize host paths for the configured bash runtime on Windows."""
        if self._use_windows_native_shell():
            return path
        return _windows_to_bash_path(path, _find_bash())
