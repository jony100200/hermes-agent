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
git stash push -m "Auto-stash before sync_windows_native" -- :!sync_windows_native.bat :!sync_upstream.bat >nul 2>&1
set "STASHED=%ERRORLEVEL%"

echo.
echo Checking out main branch...
git checkout main
if %ERRORLEVEL% neq 0 (
    echo.
    echo Error: Could not checkout main branch.
    goto restore
)

echo.
echo Updating local main branch from upstream/main (fast-forward)...
git merge upstream/main --ff-only
if %ERRORLEVEL% neq 0 (
    echo.
    echo Error: Fast-forward merge failed on main. Local main may have diverged.
    echo Attempting regular merge...
    git merge upstream/main -m "Merge upstream/main into main"
    if %ERRORLEVEL% neq 0 (
         echo.
         echo Error: Merge failed on main with conflicts. Please resolve manually.
         goto restore
    )
)

echo.
echo Pushing updated main to origin (jony100200/hermes-agent)...
git push origin main
if %ERRORLEVEL% neq 0 (
    echo.
    echo Warning: Failed to push main to origin.
)

echo.
echo Checking out windows-native branch...
git checkout windows-native
if %ERRORLEVEL% neq 0 (
    echo.
    echo Error: Could not checkout windows-native branch.
    goto restore
)

echo.
echo Merging main into windows-native branch...
echo (Keeping your custom improvements intact)
git merge main -m "Merge main into windows-native"
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
    echo Warning: Failed to push windows-native to origin.
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
