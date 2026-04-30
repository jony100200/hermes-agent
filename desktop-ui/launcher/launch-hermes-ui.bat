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

echo.
echo [Hermes Desktop UI Launcher]
echo UI directory   : %UI_DIR%
echo Repo directory : %REPO_DIR%
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
set "HERMES_DESKTOP_WORKSPACE=%REPO_DIR%"

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
