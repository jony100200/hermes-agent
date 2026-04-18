# Windows Migration Handoff

Last updated: 2026-04-18
Branch: windows/phase1-repo-bootstrap

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
