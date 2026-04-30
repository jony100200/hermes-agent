@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "CHECK_ONLY="
if /I "%~1"=="--check" set "CHECK_ONLY=1"

rem Resolve paths relative to this launcher file
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "UI_DIR=%%~fI"
for %%I in ("%UI_DIR%\..") do set "REPO_DIR=%%~fI"

set "PYTHON_EXE=%REPO_DIR%\.venv\Scripts\python.exe"
set "HERMES_SCRIPT=%REPO_DIR%\hermes"
set "WORKSPACE_DIR=%REPO_DIR%"
set "KENDRO_STATE_FILE="
set "KENDRO_BUNDLE_ROOT="
set "KENDRO_BASE_URL="
set "KENDRO_WORKSPACE="

if defined HERMES_UI_WORKSPACE_PATH (
  if exist "%HERMES_UI_WORKSPACE_PATH%\" (
    set "WORKSPACE_DIR=%HERMES_UI_WORKSPACE_PATH%"
    echo NOTE: Using HERMES_UI_WORKSPACE_PATH override.
  ) else (
    echo NOTE: HERMES_UI_WORKSPACE_PATH not found: "%HERMES_UI_WORKSPACE_PATH%"
    echo NOTE: Trying Kendro runtime discovery from running service.
    call :resolve_kendro_runtime
    if defined KENDRO_WORKSPACE (
      set "WORKSPACE_DIR=!KENDRO_WORKSPACE!"
      echo NOTE: Using workspace from running Kendro service.
    ) else (
      echo NOTE: Falling back to repo directory workspace.
    )
  )
)

if not defined HERMES_UI_WORKSPACE_PATH (
  call :resolve_kendro_runtime
  if defined KENDRO_WORKSPACE (
    set "WORKSPACE_DIR=!KENDRO_WORKSPACE!"
    echo NOTE: Using workspace from running Kendro service.
  ) else (
    echo NOTE: Kendro runtime discovery unavailable.
    echo NOTE: Falling back to repo directory workspace.
  )
)

echo.
echo [Hermes Desktop UI Launcher]
echo UI directory   : %UI_DIR%
echo Repo directory : %REPO_DIR%
echo Workspace path : %WORKSPACE_DIR%
if defined KENDRO_BASE_URL echo Kendro base URL: %KENDRO_BASE_URL%
if defined KENDRO_STATE_FILE echo Kendro state   : %KENDRO_STATE_FILE%
echo.

where npm >nul 2>nul
if errorlevel 1 (
  echo ERROR: npm is not available in PATH.
  echo Install Node.js, reopen terminal, then run this launcher again.
  exit /b 1
)

if not exist "%PYTHON_EXE%" (
  echo WARNING: Python venv not found at "%PYTHON_EXE%".
  echo Local Hermes runtime may fail until a valid Python path is configured.
)

if not exist "%HERMES_SCRIPT%" (
  echo WARNING: Hermes script not found at "%HERMES_SCRIPT%".
)

pushd "%UI_DIR%" || (
  echo ERROR: Could not enter "%UI_DIR%".
  exit /b 1
)

if not exist "node_modules" (
  echo Installing desktop-ui dependencies...
  call npm install
  if errorlevel 1 (
    echo ERROR: npm install failed.
    popd
    exit /b 1
  )
)

set "HERMES_DESKTOP_REPO=%REPO_DIR%"
set "HERMES_DESKTOP_PYTHON=%PYTHON_EXE%"
set "HERMES_DESKTOP_SCRIPT=%HERMES_SCRIPT%"
set "HERMES_DESKTOP_WORKSPACE=%WORKSPACE_DIR%"
if defined KENDRO_BUNDLE_ROOT set "KS_KENDRO_BUNDLE_ROOT=%KENDRO_BUNDLE_ROOT%"
if defined KENDRO_BASE_URL set "KS_KENDRO_BASE_URL=%KENDRO_BASE_URL%"

if defined CHECK_ONLY (
  echo Preflight check passed.
  popd
  exit /b 0
)

echo Starting Hermes Desktop UI in development mode...
echo Press Ctrl+C in this window to stop it.
echo.

call npm run dev
set "EXIT_CODE=%ERRORLEVEL%"

popd
exit /b %EXIT_CODE%

:resolve_kendro_runtime
set "KENDRO_STATE_FILE="
set "KENDRO_BUNDLE_ROOT="
set "KENDRO_BASE_URL="
set "KENDRO_WORKSPACE="

if not exist "%SCRIPT_DIR%resolve-kendro-runtime.ps1" exit /b 0

for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%resolve-kendro-runtime.ps1"`) do (
  for /f "tokens=1,* delims==" %%A in ("%%I") do (
    if /I "%%A"=="KENDRO_STATE_FILE" set "KENDRO_STATE_FILE=%%B"
    if /I "%%A"=="KENDRO_BUNDLE_ROOT" set "KENDRO_BUNDLE_ROOT=%%B"
    if /I "%%A"=="KENDRO_BASE_URL" set "KENDRO_BASE_URL=%%B"
    if /I "%%A"=="KENDRO_WORKSPACE" set "KENDRO_WORKSPACE=%%B"
  )
)

exit /b 0
