@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ============================================================================
:: launch_orchestrator.bat
:: One-click launcher for the Tiered Agent Orchestration pipeline.
::
:: KEY DESIGN: No API keys are stored here or in the repo.
::   - Primary: Kendro service at O:\KS Apps\KS Kendro handles all keys
::     and routes to free models via its local OpenAI-compatible API.
::   - Fallback: If Kendro is running, we read its .env at launch time
::     (never stored in Hermes files). If neither available, graceful notice.
::
:: Tier routing:
::   T1  LM Studio local      (127.0.0.1:1234)
::   T2  Kendro free router   (127.0.0.1:8788/v1) — owns all cloud keys
::   T3  Hermes memory        MEMORY.md  +  Kendro context store
::   T4  Paid review          via Kendro paid route or OpenRouter key
::   T5  Cheap verify         via Kendro cheap route or OpenRouter key
:: ============================================================================

set "REPO_DIR=%~dp0"
if "%REPO_DIR:~-1%"=="\" set "REPO_DIR=%REPO_DIR:~0,-1%"

set "PYTHON_EXE=%REPO_DIR%\.venv\Scripts\python.exe"
set "HERMES_HOME=%REPO_DIR%\data\home"
set "TMP=%REPO_DIR%\data\tmp"
set "TEMP=%REPO_DIR%\data\tmp"
set "KENDRO_DIR=O:\KS Apps\KS Kendro"
set "KENDRO_ENV=%KENDRO_DIR%\.env"
set "KENDRO_STATE=%KENDRO_DIR%\.runtime\kendro_bundle_state.json"

if not exist "%REPO_DIR%\data\tmp" mkdir "%REPO_DIR%\data\tmp"

:: ── Step 1: Detect Kendro ─────────────────────────────────────────────────
set "KENDRO_LIVE=0"
set "KENDRO_BASE_URL="

if exist "%KENDRO_STATE%" (
  :: Parse base_url out of JSON (simple findstr approach)
  for /f "tokens=2 delims=:," %%A in ('findstr /i "base_url" "%KENDRO_STATE%" 2^>nul') do (
    set "RAW=%%~A"
    :: Strip quotes and spaces
    set "RAW=!RAW: =!"
    set "RAW=!RAW:"=!"
    if not "!RAW!"=="" (
      if not "!RAW!"=="null" (
        set "KENDRO_BASE_URL=http:!RAW!"
      )
    )
  )
)

:: Verify Kendro is actually alive
if defined KENDRO_BASE_URL (
  curl -s --max-time 3 "%KENDRO_BASE_URL%/live" >nul 2>&1
  if not errorlevel 1 set "KENDRO_LIVE=1"
)

:: ── Step 2: Load keys from Kendro .env at runtime (never stored in repo) ──
:: Keys are sourced from Kendro's own .env file - zero duplication.
:: This section only runs if Kendro is present; never hardcodes values.
if exist "%KENDRO_ENV%" (
  for /f "usebackq tokens=1,* delims==" %%K in ("%KENDRO_ENV%") do (
    set "LINE=%%K"
    if not "!LINE:~0,1!"=="#" (
      if not "%%L"=="" (
        set "%%K=%%L"
      )
    )
  )
  echo [Orchestrator] Keys loaded from Kendro .env ^(not stored in repo^)
) else (
  echo [Orchestrator] Kendro .env not found at %KENDRO_ENV%
  echo [Orchestrator] Only OpenRouter key ^(already in Hermes .env^) will be used
)

:: ── Step 3: Export Kendro vars for the UI ────────────────────────────────
if "%KENDRO_LIVE%"=="1" (
  set "KS_KENDRO_BUNDLE_ROOT=%KENDRO_DIR%"
  set "KS_KENDRO_BASE_URL=%KENDRO_BASE_URL%"
  echo [Orchestrator] Kendro router LIVE at %KENDRO_BASE_URL%
) else (
  echo [Orchestrator] Kendro not running - using direct provider keys from Kendro .env
  if defined GROQ_API_KEY (
    echo [Orchestrator] Groq free tier available via GROQ_API_KEY
  )
)

:: ── Step 4: LM Studio check ──────────────────────────────────────────────
curl -s --max-time 2 http://127.0.0.1:1234/v1/models >nul 2>&1
if errorlevel 1 (
  echo [Orchestrator] WARNING: LM Studio not at 127.0.0.1:1234
  echo [Orchestrator] T1 workers fall back to Kendro/Groq free
) else (
  echo [Orchestrator] LM Studio T1 ready
)

if not exist "%PYTHON_EXE%" (
  echo ERROR: Python venv not found at %PYTHON_EXE%
  pause
  exit /b 1
)

echo.
echo =====================================================================
echo  HERMES TIERED ORCHESTRATION
echo =====================================================================
echo  T1  LM Studio local    127.0.0.1:1234
if "%KENDRO_LIVE%"=="1" (
  echo  T2  Kendro router       %KENDRO_BASE_URL% [LIVE]
) else (
  echo  T2  Direct free APIs    Groq / Gemini via Kendro .env keys
)
echo  T3  Memory             MEMORY.md + Kendro context store
echo  T4  Paid review        OpenRouter ^(your key^)
echo  T5  Cheap verify       OpenRouter ^(your key^)
echo  Keys source            Kendro .env ^(not in git^)
echo =====================================================================
echo  Skill: /skill tiered-orchestration    Workers: 4    Depth: 2
echo =====================================================================
echo.

"%PYTHON_EXE%" "%REPO_DIR%\hermes" chat ^
  --toolsets hermes-cli ^
  --load-skill tiered-orchestration ^
  %*

set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo [Orchestrator] Session ended ^(code %EXIT_CODE%^).
pause
exit /b %EXIT_CODE%
