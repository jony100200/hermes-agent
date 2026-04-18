# Windows Native Port Log

This log tracks every direct modification touching upstream core files and all new compatibility additions.

## 2026-04-18 - Phase 1 Bootstrap

### Added Files

| File | Change Type | Reason | Conflict Risk | Notes |
| --- | --- | --- | --- | --- |
| scripts/setup.ps1 | new | Native Windows local setup flow for cloned repo | low | PowerShell 7+ primary for setup/test flow |
| scripts/run_tests.ps1 | new | Windows-native CI-parity test launcher | low | Mirrors hermetic env behavior from run_tests.sh |
| docs/migration/windows-port-log.md | new | Track portability edits and conflict rationale | low | Required for update-friendly architecture |
| docs/migration/windows-handoff.md | new | Continuation handoff doc for future agent sessions | low | Includes verification and next actions |

### Direct Core File Modifications

| File | Reason | Adapter-Only Alternative | Why Direct Edit Was Needed | Conflict Risk |
| --- | --- | --- | --- | --- |
| README.md | Surface native Windows setup/test commands | Keep docs unchanged and rely on external docs | Users need first-party Windows path in root readme | medium |

## 2026-04-18 - Phase 2 Runtime Adapter Integration

### Added Files

| File | Change Type | Reason | Conflict Risk | Notes |
| --- | --- | --- | --- | --- |
| tools/platform_runtime.py | new | Centralize shell/process/temp cross-platform behavior | low | Windows shell selection + POSIX compatibility wrappering |

### Direct Core File Modifications

| File | Reason | Adapter-Only Alternative | Why Direct Edit Was Needed | Conflict Risk |
| --- | --- | --- | --- | --- |
| tools/environments/local.py | Use adapter for shell command argv, temp dir, and process tree kill | Keep shell logic inline in local.py | Local execution is a primary Windows surface; adapter integration reduces repeated platform conditionals | medium |
| tools/process_registry.py | Use adapter for shell argv build, temp dir fallback, and PID tree termination | Keep existing SIGTERM/bash assumptions | Background process execution must be Windows-safe in core runtime path | medium |
| scripts/run_tests.ps1 | Add dependency bootstrap and robust import detection | Require pre-provisioned venv dependencies | First-run Windows workflow should work without manual pytest bootstrap | low |

### Verification

Command:

`pwsh -NoProfile -File .\\scripts\\run_tests.ps1 tests/tools/test_windows_compat.py`

Result:

- 12 passed
- 0 failed

## 2026-04-18 - Phase 3 Parity Hardening

### Direct Core File Modifications

| File | Reason | Adapter-Only Alternative | Why Direct Edit Was Needed | Conflict Risk |
| --- | --- | --- | --- | --- |
| cli.py | Replace `shell=True` quick-command execution with `build_shell_command()` + `find_preferred_shell()` | Keep inline shell execution | Quick commands must run consistently on Windows PowerShell/cmd/Git Bash and avoid shell injection edge behavior | medium |
| tui_gateway/server.py | Replace `shell=True` in slash quick commands and `shell.exec` with adapter-based shell argv | Leave legacy shell execution | TUI command execution path should share cross-platform shell behavior with core runtime | medium |
| gateway/run.py | Replace detached restart `bash/setsid` loop with cross-platform detached Python launcher | Keep Unix-only bash loop | Detached restart must work on native Windows without WSL/bash assumptions | medium |
| gateway/platforms/base.py | Add Windows absolute path detection for local media extraction | Keep POSIX-only local-path regex | Media file extraction behavior should be parity-safe for Windows-generated file paths | low |
| gateway/platforms/whatsapp.py | Resolve npm executable (`npm`/`npm.cmd`) before bridge dependency install | Keep bare `npm` invocation | Ensures npm invocation is robust on Windows PATH/PATHEXT setups | low |
| gateway/status.py | Use `terminate_pid_tree()` for Windows-aware process termination | Keep local `taskkill`/signal logic | Consolidates termination behavior under the shared cross-platform adapter | low |
| README.md | Add Windows run/test commands and known Git Bash limitation; align `.venv` path | Keep partial Windows docs | Reduces setup drift and clarifies real operational expectations on Windows | low |

### Verification

Command set:

`pwsh -NoProfile -File .\\scripts\\run_tests.ps1 tests\\tools\\test_windows_compat.py tests\\tools\\test_file_operations.py tests\\gateway\\test_extract_local_files.py tests\\tools\\test_process_registry.py`

`npm --version`

`npx --version`

`npx @openai/codex --help`

Expected outcome:
- Test suites pass
- npm/npx available on PATH
- Codex CLI help starts via npx (or returns a clear dependency/network error)

Observed results (current environment):
- `tests/tools/test_windows_compat.py` + `tests/tools/test_file_operations.py`: passed.
- `tests/gateway/test_extract_local_files.py`: passed after regex correction for Windows `\\` separators.
- `tests/tools/test_process_registry.py`: targeted regression cases pass in isolation; full-file runs intermittently abort with `KeyboardInterrupt` in this environment.
- `npm --version`: `10.9.2`
- `npx --version`: `10.9.2`
- `codex`: found on PATH (`codex.cmd`) and starts via `npx @openai/codex --help`.
- `npx @google/gemini-cli --help`: starts successfully.
- `kilocode` and `cloudcode`: not found on PATH in this environment.

## 2026-04-18 - Phase 4 Windows Hardening Follow-up

### Direct Core File Modifications

| File | Reason | Adapter-Only Alternative | Why Direct Edit Was Needed | Conflict Risk |
| --- | --- | --- | --- | --- |
| tools/process_registry.py | Normalize local background `cwd` for Windows native and bash-compat modes (`~`, relative paths, `/c/...`) | Keep foreground/background cwd handling divergent | Background process startup was less Windows-safe than foreground execution and could mis-handle workdirs | medium |
| tools/environments/local.py | Make `get_temp_dir()` return host temp dir in Windows native mode | Keep `/tmp` for all Windows modes | Native shell mode should not report POSIX temp paths on Windows | low |
| scripts/run_tests.ps1 | Fail loudly on dependency bootstrap errors and propagate pytest non-zero exit explicitly | Rely on implicit shell exit behavior | Windows test wrapper must not silently continue after failed bootstrap/install steps | low |
| scripts/setup.ps1 | Add explicit native command exit-code checks for venv creation/install/setup steps | Rely on default PowerShell behavior for native command failures | Setup script should fail clearly and consistently when subprocesses fail | low |
| hermes_cli/doctor.py | Make console output resilient to legacy Windows code pages (CP1252) by forcing replacement error handling | Require UTF-8 codepage only | `hermes doctor` crashed on default Windows console encoding | medium |
| README.md | Separate Linux and Windows setup/post-install contributor flows more clearly | Keep mixed platform snippets close together | Prevent Windows users from seeing Linux `source` commands in nearby setup flow | low |
| CONTRIBUTING.md | Split configure/run sections by platform with PowerShell-native commands | Keep Linux-only snippets with implied translation | Contributor setup steps must be copy-paste ready on Windows | low |
| AGENTS.md | Add explicit Windows virtualenv activation/testing snippets | Keep Linux-only activation examples | Assistant/developer guide should not prescribe `source` as universal | low |
| tests/tools/test_process_registry.py | Add regression coverage for Windows local background cwd normalization | Rely on manual verification only | Locks in path normalization behavior to prevent regressions | low |

### Verification

Command set:

`pwsh -NoProfile -File .\\scripts\\setup.ps1 -SkipSetupWizard`

`pwsh -NoProfile -File .\\scripts\\run_tests.ps1 tests\\tools\\test_windows_compat.py`

`pwsh -NoProfile -File .\\scripts\\run_tests.ps1 tests\\tools\\test_windows_compat.py::does_not_exist`

`pwsh -NoProfile -File .\\scripts\\run_tests.ps1 tests\\tools\\test_local_env_blocklist.py tests\\tools\\test_terminal_tool.py tests\\tools\\test_windows_compat.py tests\\tools\\test_file_operations.py tests\\tools\\test_modal_sandbox_fixes.py`

`pwsh -NoProfile -File .\\scripts\\run_tests.ps1 tests\\hermes_cli\\test_doctor.py tests\\hermes_cli\\test_doctor_command_install.py`

`pwsh -NoProfile -File .\\scripts\\run_tests.ps1 tests\\tools\\test_process_registry.py::TestSpawnEnvSanitization::test_normalize_local_cwd_expands_home tests\\tools\\test_process_registry.py::TestSpawnEnvSanitization::test_normalize_local_cwd_converts_bash_drive_prefix tests\\tools\\test_process_registry.py::TestSpawnEnvSanitization::test_spawn_local_normalizes_tilde_cwd`

Observed results:
- `scripts/setup.ps1 -SkipSetupWizard`: completed successfully on Windows PowerShell.
- `scripts/run_tests.ps1` returns `0` on passing suite and `1` on invalid test target (non-zero propagation verified).
- Targeted Windows-sensitive suites passed (`local_env_blocklist`, `terminal_tool`, `windows_compat`, `file_operations`, `modal_sandbox_fixes`, doctor tests).
- New process-registry normalization tests passed.
- Known environment flake persists: full `tests/tools/test_process_registry.py` can intermittently end in `KeyboardInterrupt` teardown; targeted regression cases remain stable and passing.
- `python -m hermes_cli.main doctor` no longer crashes under CP1252 console output.

