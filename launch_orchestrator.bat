@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ============================================================================
:: launch_orchestrator.bat
:: One-click launcher for the Tiered Agent Orchestration pipeline.
:: Opens Hermes CLI pre-loaded with the tiered-orchestration skill and all
:: delegation toolsets active.
::
:: What gets wired up:
::   T1 — LM Studio local (http://127.0.0.1:1234/v1)
::   T2 — Groq / Together / Gemini Free / HuggingFace
::   T3 — Hermes memory (MEMORY.md) + Kendro context if running
::   T4 — Paid review (OpenRouter → Claude/GPT)
::   T5 — Cheap verify (Haiku / Gemini Flash)
:: ============================================================================

set "REPO_DIR=%~dp0"
if "%REPO_DIR:~-1%"=="\" set "REPO_DIR=%REPO_DIR:~0,-1%"

set "PYTHON_EXE=%REPO_DIR%\.venv\Scripts\python.exe"
set "HERMES_HOME=%REPO_DIR%\data\home"
set "TMP=%REPO_DIR%\data\tmp"
set "TEMP=%REPO_DIR%\data\tmp"

:: Create tmp dir if needed
if not exist "%REPO_DIR%\data\tmp" mkdir "%REPO_DIR%\data\tmp"

:: ── API Keys (merged from Kendro .env) ───────────────────────────────────
set "GROQ_API_KEY=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"
set "TOGETHER_API_KEY=tgp_v1_U7Jt3bB84SzZr_osyZfIPPQ_N2tIXGA4iYL8ZO-eRdw"
set "GEMINI_API_KEY=AIzaSyDPj6oGaFy5N6fPtnPIwaEL00_CERMVJj8"
set "HF_TOKEN=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"
set "GOOGLE_API_KEY=AIzaSyDPj6oGaFy5N6fPtnPIwaEL00_CERMVJj8"

:: ── Kendro Integration (auto-discover if running) ────────────────────────
set "KENDRO_DIR=O:\KS Apps\KS Kendro"
if exist "%KENDRO_DIR%\.runtime\kendro_bundle_state.json" (
  echo [Orchestrator] Kendro service detected at %KENDRO_DIR%
  set "KS_KENDRO_BUNDLE_ROOT=%KENDRO_DIR%"
  :: Try to extract base_url from state file
  for /f "tokens=2 delims=:, " %%A in ('findstr "base_url" "%KENDRO_DIR%\.runtime\kendro_bundle_state.json" 2^>nul') do (
    set "KS_KENDRO_BASE_URL=%%~A"
  )
) else (
  echo [Orchestrator] Kendro not running - T3 memory will use Hermes only
)

:: ── LM Studio check ──────────────────────────────────────────────────────
curl -s --max-time 2 http://127.0.0.1:1234/v1/models >nul 2>&1
if errorlevel 1 (
  echo [Orchestrator] WARNING: LM Studio not detected at http://127.0.0.1:1234
  echo [Orchestrator] T1 workers will fail - start LM Studio or change delegation.base_url
  echo [Orchestrator] Fallback chain: Groq free -^> Gemini free -^> OpenRouter
  echo.
) else (
  echo [Orchestrator] LM Studio T1 ready at http://127.0.0.1:1234/v1
)

if not exist "%PYTHON_EXE%" (
  echo ERROR: Python venv not found at %PYTHON_EXE%
  echo Run: python -m venv .venv ^&^& .venv\Scripts\pip install -e .
  pause
  exit /b 1
)

echo.
echo =====================================================================
echo  HERMES TIERED ORCHESTRATION PIPELINE
echo =====================================================================
echo  T1  LM Studio local   http://127.0.0.1:1234/v1
echo  T2  Groq free         llama-3.3-70b / qwq-32b
echo  T2  Together free     Llama-3.3-70B / DeepSeek-R1
echo  T2  Gemini free       gemini-2.0-flash (1M ctx)
echo  T3  Memory            HERMES_HOME\MEMORY.md + Kendro if running
echo  T4  Paid review       OpenRouter -^> claude-sonnet / gpt-4o
echo  T5  Cheap verify      claude-haiku / gemini-flash
echo =====================================================================
echo  Skill loaded: /skill tiered-orchestration
echo  Max parallel: 4 concurrent sub-agents
echo  Spawn depth:  2 (parent -^> orchestrator -^> workers)
echo =====================================================================
echo.
echo TIP: Ask any complex task naturally. Say "run in parallel" or
echo      "use tiered orchestration" to activate the full pipeline.
echo.
echo Press Ctrl+C to stop.
echo.

:: Launch Hermes CLI with delegation + all toolsets active
"%PYTHON_EXE%" "%REPO_DIR%\hermes" chat ^
  --toolsets hermes-cli ^
  --load-skill tiered-orchestration ^
  %*

set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo [Orchestrator] Session ended with code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%
