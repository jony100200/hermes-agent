"""Cross-platform runtime helpers for shell execution and process control."""

import os
import platform
import shutil
import signal
import subprocess
import tempfile

_IS_WINDOWS = platform.system() == "Windows"


def is_windows() -> bool:
    return _IS_WINDOWS


def find_preferred_shell() -> str:
    """Resolve the preferred local shell executable for the current platform."""
    if not _IS_WINDOWS:
        return (
            shutil.which("bash")
            or ("/usr/bin/bash" if os.path.isfile("/usr/bin/bash") else None)
            or ("/bin/bash" if os.path.isfile("/bin/bash") else None)
            or os.environ.get("SHELL")
            or "/bin/sh"
        )

    preference = (os.environ.get("HERMES_WINDOWS_SHELL") or "").strip().lower()
    if preference in {"pwsh", "powershell", "cmd", "bash"}:
        ordered = [preference]
    else:
        ordered = ["pwsh", "powershell", "bash", "cmd"]

    bash_candidates = [
        os.environ.get("HERMES_GIT_BASH_PATH"),
        shutil.which("bash"),
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "Git", "bin", "bash.exe"),
        os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"), "Git", "bin", "bash.exe"),
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Git", "bin", "bash.exe"),
    ]

    for candidate in ordered:
        if candidate == "pwsh":
            pwsh = shutil.which("pwsh")
            if pwsh:
                return pwsh
        elif candidate == "powershell":
            ps = shutil.which("powershell")
            if ps:
                return ps
        elif candidate == "bash":
            for bash in bash_candidates:
                if bash and os.path.isfile(bash):
                    return bash
        elif candidate == "cmd":
            comspec = os.environ.get("ComSpec")
            if comspec and os.path.isfile(comspec):
                return comspec
            cmd = shutil.which("cmd")
            if cmd:
                return cmd

    raise RuntimeError(
        "No usable Windows shell found. Install PowerShell 7 (pwsh), "
        "Windows PowerShell, Git Bash, or ensure cmd.exe is available."
    )


def build_shell_command(shell: str, command: str, *, login: bool = False, interactive: bool = False) -> list[str]:
    """Build argv for shell execution in a platform-aware way."""
    shell_name = os.path.basename(shell).lower()

    if _IS_WINDOWS and (shell_name in {"pwsh", "pwsh.exe", "powershell", "powershell.exe"}):
        return [
            shell,
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            command,
        ]

    if _IS_WINDOWS and (shell_name in {"cmd", "cmd.exe"}):
        return [shell, "/d", "/s", "/c", command]

    if interactive:
        return [shell, "-lic", f"set +m; {command}"]
    if login:
        return [shell, "-lc", command]
    return [shell, "-c", command]


def default_temp_dir() -> str:
    """Return a safe default temp directory path for the current host."""
    if _IS_WINDOWS:
        return tempfile.gettempdir()
    return "/tmp"


def terminate_pid_tree(pid: int, *, force: bool = False) -> None:
    """Terminate a process and its children with platform-specific behavior."""
    if _IS_WINDOWS:
        cmd = ["taskkill", "/PID", str(pid), "/T"]
        if force:
            cmd.append("/F")
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        return

    sig = getattr(signal, "SIGKILL", signal.SIGTERM) if force else signal.SIGTERM
    try:
        os.killpg(os.getpgid(pid), sig)
    except (OSError, ProcessLookupError, PermissionError):
        os.kill(pid, sig)
