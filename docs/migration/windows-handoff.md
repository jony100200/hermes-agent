# Windows Migration Handoff

Last updated: 2026-04-18
Branch: windows/phase1-repo-bootstrap

## Update 2026-04-18 (Critical CLI Input Rendering Fix)

### Completed Work

- Root-caused Windows typing instability in the classic CLI to output/render contention during active prompt sessions.
- Fixed prompt-safe output path in `cli.py`:
	- Added `_CPRINT_LOCK` to serialize concurrent output writes from worker/background threads.
	- Added `_ANSI_ESCAPE_RE` to strip ANSI escapes when writing through prompt-toolkit's `StdoutProxy`.
	- Updated `_cprint(...)` to detect active `patch_stdout` sessions and write via `sys.stdout` (`StdoutProxy`) instead of direct `print_formatted_text(...)`.
	- Added fallback path so output remains visible even if ANSI formatter errors.
- Added regression tests in `tests/cli/test_cprint_prompt_safety.py`:
	- Verifies `_cprint` uses stdout proxy path and preserves visible text.
	- Verifies fallback keeps text visible when formatter fails.
- Ran focused CLI regression suites and confirmed all pass.

### Current Status

- Input line rendering is now protected from background-output overwrite in prompt-toolkit sessions.
- The fix specifically targets the Windows interactive terminals where typed characters were intermittently invisible/disrupted.

### Exact Verification Commands

Run from repository root:

```powershell
pwsh -NoProfile -File .\scripts\run_tests.ps1 tests\cli\test_cprint_prompt_safety.py tests\cli\test_tool_progress_scrollback.py
pwsh -NoProfile -File .\scripts\run_tests.ps1 tests\cli\test_reasoning_command.py
pwsh -NoProfile -Command "& \"d:/DevTools/hermes-agent/.venv/Scripts/python.exe\" -c \"from cli import _cprint; from prompt_toolkit.patch_stdout import patch_stdout; import threading,time; print('start');\nwith patch_stdout():\n    def worker():\n        for i in range(5):\n            _cprint('\\x1b[31mline %d\\x1b[0m' % i); time.sleep(0.01)\n    t=threading.Thread(target=worker); t.start(); t.join();\nprint('done')\""
```

Observed results in this session:
- `tests/cli/test_cprint_prompt_safety.py tests/cli/test_tool_progress_scrollback.py`: `14 passed`
- `tests/cli/test_reasoning_command.py`: included in prior focused run; overall batch passed (`67 passed` with paired CLI suite)
- Patch stdout smoke run printed stable visible lines (`line 0` ... `line 4`) with no crash.

### Known Issues

- Full human interactive validation (rapid typing + backspace/arrow behavior while live agent output streams) is inherently manual; automated tests cover the output-path regression but not full keystroke ergonomics in every terminal emulator.

### Next Actions

1. Manual terminal validation pass in PowerShell, Windows Terminal, and CMD using a long-running prompt to confirm no flicker/disappearing text under real typing load.
2. If any residual flicker appears, route high-frequency streaming-only output to an in-layout widget (no scrollback writes during active typing).

## Update 2026-04-18 (Tools Setup WinError 2)

### Completed Work

- Root-caused setup wizard crash in `hermes setup` during tool provider post-setup (`subprocess.run(["npm", ...])` raised `FileNotFoundError: [WinError 2]`).
- Hardened post-setup process launches in `hermes_cli/tools_config.py`:
	- Added local `_safe_run(...)` wrapper that catches `OSError`/launch failures and returns a warning instead of crashing setup.
	- Resolved npm path once with `shutil.which("npm")` and executed the resolved path directly.
	- Applied same safe-run path to RL post-setup installs for consistency.
	- Corrected browser post-setup manual recovery message to point at `PROJECT_ROOT`.
- Verified no static errors in edited file.
- Reproduced the previous failure mode by forcing a bad npm path and confirmed setup now warns and continues.

### Current Status

- `hermes setup` post-setup hooks no longer crash on missing/unlaunchable npm binaries.
- Behavior is now graceful-degradation: warning + manual recovery instruction.

### Exact Verification Commands

Run from repository root:

```powershell
pwsh -NoProfile -Command "& \"d:/DevTools/hermes-agent/.venv/Scripts/python.exe\" -c \"import shutil; from hermes_cli.tools_config import _run_post_setup; orig=shutil.which; shutil.which=lambda n: r'C:\\\\definitely-missing\\\\npm.cmd' if n=='npm' else orig(n); _run_post_setup('agent_browser'); print('post-setup completed')\""
pwsh -NoProfile -Command "Get-Command hermes | Select-Object -ExpandProperty Source"
pwsh -NoProfile -Command "Push-Location D:\\; hermes --help | Select-Object -First 5; Pop-Location"
cmd /d /c "cd /d D:\\ && hermes --help"
```

Expected key lines:
- `Failed to launch '...npm.cmd install --silent': [WinError 2] ...`
- `npm install failed - run manually: cd D:\DevTools\hermes-agent && npm install`
- `post-setup completed`
- Hermes help output renders successfully from outside repo.

### Known Issues

- If npm is genuinely missing or broken, browser tool dependencies are not auto-installed; user must run manual install after fixing Node.js/npm.

### Next Actions

1. Optionally add a small unit test around `_run_post_setup` launch-failure handling (mock `subprocess.run` raising `OSError`).
2. Consider centralizing safe subprocess launch utility for other setup paths to keep behavior consistent.

## Completed Work

- Verified remote model is correct (`origin` fork, `upstream` source).
- Created branch scaffolding: `windows-native` and `windows/phase1-repo-bootstrap`.
- Added Windows-native setup script: `scripts/setup.ps1`.
- Added Windows-native test runner: `scripts/run_tests.ps1`.
- Started migration logging with `docs/migration/windows-port-log.md`.
- Updated README with native Windows install/setup paths.
- Added runtime compatibility adapter: `tools/platform_runtime.py`.
- Integrated adapter behavior into `tools/environments/local.py`.
- Integrated adapter behavior into `tools/process_registry.py`.
- Integrated adapter behavior into `tools/tool_result_storage.py` and `tools/code_execution_tool.py` for temp-path safety.
- Hardened `tools/file_operations.py` for Windows absolute-path compatibility in shell-backed operations.
- Added shell-aware Windows path conversion (`/mnt/<drive>/...` for WSL bash, `/<drive>/...` for Git Bash) in local execution and file operations.
- Hardened gateway detached update spawn in `gateway/run.py` for native Windows command execution.
- Hardened profile alias/wrapper behavior in `hermes_cli/profiles.py` and `hermes_cli/main.py` (Windows wrapper dir and `.cmd` handling).
- Hardened `scripts/run_tests.ps1` to auto-install pytest, pytest-xdist, and pytest-split when missing.
- Updated developer/testing docs to include native Windows wrapper usage in `AGENTS.md`.
- Updated website docs for native Windows install/support messaging in `website/docs/getting-started/installation.md`, `website/docs/reference/faq.md`, and `website/docs/developer-guide/contributing.md`.
- Validated focused regression suites and fixed a mock-compat regression in `tools/file_operations.py`.
- Standardized CLI/TUI quick shell execution through `tools/platform_runtime.py` (`build_shell_command` + `find_preferred_shell`) in `cli.py` and `tui_gateway/server.py`.
- Replaced detached restart bash loop in `gateway/run.py` with a cross-platform detached Python launcher.
- Added Windows drive-path support to gateway local file extraction in `gateway/platforms/base.py` and tests in `tests/gateway/test_extract_local_files.py`.
- Hardened WhatsApp bridge npm bootstrap path resolution in `gateway/platforms/whatsapp.py`.
- Consolidated gateway PID termination through `tools/platform_runtime.terminate_pid_tree()` in `gateway/status.py`.
- Hardened `tools/process_registry.py` for Windows PID liveness edge cases and shell command normalization (`python3` -> `python` for native Windows shells).
- Added Phase 3 changelog entry to `docs/migration/windows-port-log.md`.

## Current Status

- Phase 1 bootstrap is complete.
- Phase 2 adapter integration is complete for high-impact local/runtime execution paths.
- Core Windows-native flow for setup, profile wrappers, gateway update detachment, and focused test execution is operational.
- File tool absolute Windows path handling now works under both WSL bash and Git Bash semantics.
- CLI/TUI shell command execution paths now use a unified cross-platform shell adapter.
- Remaining work is now concentrated in long-tail script/tool/docs parity and broader integration regression coverage.

## Exact Verification Commands

Run from repository root:

```powershell
git remote -v
git branch --show-current
d:\DevTools\hermes-agent\.venv\Scripts\python.exe -c "from run_agent import AIAgent; from model_tools import discover_builtin_tools; print('agent import ok', AIAgent is not None, len(discover_builtin_tools()))"
d:\DevTools\hermes-agent\.venv\Scripts\python.exe -c "from tools.process_registry import ProcessRegistry; import time; pr=ProcessRegistry(); s=pr.spawn_local('echo windows-bg-ok', cwd='.'); time.sleep(0.5); print(pr.poll(s.id))"
d:\DevTools\hermes-agent\.venv\Scripts\python.exe -c "from tools.file_tools import read_file_tool; print(read_file_tool('d:/DevTools/hermes-agent/README.md', 1, 2)[:80])"
pwsh -NoProfile -File .\scripts\run_tests.ps1 tests\tools\test_file_operations.py
pwsh -NoProfile -File .\scripts\run_tests.ps1 tests\tools\test_windows_compat.py tests\hermes_cli\test_profiles.py
pwsh -NoProfile -File .\scripts\run_tests.ps1 tests\gateway\test_extract_local_files.py
pwsh -NoProfile -File .\scripts\run_tests.ps1 tests\tools\test_process_registry.py::TestStdinHelpers::test_close_stdin_allows_eof_driven_process_to_finish tests\tools\test_process_registry.py::TestSpawnEnvSanitization::test_spawn_local_strips_blocked_vars_from_background_env tests\tools\test_process_registry.py::TestKillProcess::test_kill_detached_session_uses_host_pid
npm --version
npx --version
npx @openai/codex --help
npx @google/gemini-cli --help
```

Expected current result for tests:
- `tests/tools/test_file_operations.py`: `45 passed`
- `tests/tools/test_windows_compat.py tests/hermes_cli/test_profiles.py`: `99 passed`
- `tests/gateway/test_extract_local_files.py`: `37 passed`
- Targeted process registry regressions listed above: each passes in isolation

## Known Issues

- Full native Windows parity is not complete yet.
- Some optional skills/benchmark scripts and docs remain bash-first.
- Full `tests/tools/test_process_registry.py` intermittently aborts under this environment with `KeyboardInterrupt` before completion; targeted failing cases were re-run in isolation.
- `kilocode` and `cloudcode` CLIs were not present on PATH in this environment (Codex and Gemini CLI via npx were validated).

## Next Actions

1. Investigate and stabilize `KeyboardInterrupt` interruptions in full `test_process_registry.py` on Windows test runner.
2. Continue audit for remaining bash-only skill/dev scripts and add PowerShell counterparts for highest-impact paths.
3. Expand adapter usage review for remaining `shell=True` and direct shell invocation paths outside CLI/TUI quick-command surfaces.
4. Add/expand tests for shell-aware path normalization edge cases (spaces, mixed separators, UNC where supported).
