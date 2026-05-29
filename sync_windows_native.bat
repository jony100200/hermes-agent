@echo off
setlocal enabledelayedexpansion

:: Change directory to the folder containing this batch file
cd /d "%~dp0"

echo ========================================================
echo   Hermes Agent Fork Sync Script (windows-native branch)
echo ========================================================
echo.

:: Ensure we are in a git repository
git rev-parse --is-inside-work-tree >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Error: Not a git repository or git is not installed.
    goto error
)

:: Get current branch name so we can switch back at the end
for /f "tokens=*" %%i in ('git branch --show-current') do set "START_BRANCH=%%i"
echo Current active branch: !START_BRANCH!

echo.
echo Fetching latest commits from upstream (NousResearch/hermes-agent)...
git fetch upstream
if %ERRORLEVEL% neq 0 (
    echo.
    echo Warning: Failed to fetch from 'upstream'. Make sure you have internet access
    echo and 'upstream' remote is configured correctly.
    goto error
)

echo.
echo Stashing any uncommitted changes...
git stash -m "Auto-stash before sync_windows_native" >nul 2>&1
set "STASHED=%ERRORLEVEL%"

echo.
echo Checking out windows-native branch...
git checkout windows-native
if %ERRORLEVEL% neq 0 (
    echo.
    echo Error: Could not checkout windows-native branch.
    goto restore
)

echo.
echo Merging upstream/main into windows-native branch...
echo (Keeping your custom improvements intact)
git merge upstream/main -m "Merge upstream/main into windows-native"
if %ERRORLEVEL% neq 0 (
    echo.
    echo ========================================================
    echo   CONFLICTS DETECTED!
    echo   Please resolve the merge conflicts manually in your editor.
    echo   Once resolved, commit the changes to finish the merge.
    echo ========================================================
    :: Since there is a merge conflict, we don't switch back automatically
    :: to avoid confusing the user while they are in the middle of a merge.
    pause
    exit /b 1
)

echo.
echo Pushing updated windows-native to origin (jony100200/hermes-agent)...
git push origin windows-native
if %ERRORLEVEL% neq 0 (
    echo.
    echo Warning: Failed to push to origin. You might not have write permissions or internet access.
)

:restore
if "%START_BRANCH%" neq "" (
    if "%START_BRANCH%" neq "windows-native" (
        echo.
        echo Switching back to your original branch: !START_BRANCH!
        git checkout !START_BRANCH!
    )
)

:: If stash succeeded and created a stash entry, pop it
git stash list | findstr /c:"Auto-stash before sync_windows_native" >nul
if %ERRORLEVEL% equ 0 (
    echo.
    echo Restoring stashed changes...
    git stash pop >nul 2>&1
)

echo.
echo ========================================================
echo   Sync completed successfully!
echo ========================================================
pause
exit /b 0

:error
echo.
echo ========================================================
echo   Sync failed! Please review the output above.
echo ========================================================
pause
exit /b 1
