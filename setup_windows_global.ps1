param(
    [string]$InstallRoot = "D:\DevTools",
    [string]$RepoPath = "D:\DevTools\hermes-agent",
    [string]$VenvPath = "D:\DevTools\hermes-agent.venv",
    [string]$BinPath = "D:\DevTools\bin",
    [string]$DataPath = "D:\DevTools\hermes-agent\data",
    [string]$RepoUrl = "https://github.com/NousResearch/hermes-agent.git"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "[OK]   $Message" -ForegroundColor Green
}

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Add-UserPathEntry([string]$Entry) {
    $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($currentUserPath)) {
        $segments = @()
    }
    else {
        $segments = $currentUserPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
    }

    $alreadyPresent = $segments | Where-Object { $_.TrimEnd('\\') -ieq $Entry.TrimEnd('\\') }
    if (-not $alreadyPresent) {
        $newPath = if ($segments.Count -gt 0) {
            ($segments + $Entry) -join ';'
        }
        else {
            $Entry
        }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Ok "Added to user PATH: $Entry"
    }
    else {
        Write-Info "User PATH already contains: $Entry"
    }

    if (-not (($env:Path.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) | Where-Object {
        $_.TrimEnd('\\') -ieq $Entry.TrimEnd('\\')
    }))) {
        $env:Path = "$Entry;$env:Path"
        Write-Info "Updated current session PATH with: $Entry"
    }
}

Write-Info "Preparing Windows global Hermes installation"
Write-Info "InstallRoot: $InstallRoot"
Write-Info "RepoPath: $RepoPath"
Write-Info "VenvPath: $VenvPath"
Write-Info "BinPath: $BinPath"
Write-Info "DataPath: $DataPath"

Ensure-Dir -Path $InstallRoot
Ensure-Dir -Path $BinPath
Ensure-Dir -Path $DataPath
Ensure-Dir -Path (Join-Path $DataPath "home")
Ensure-Dir -Path (Join-Path $DataPath "tmp")
Ensure-Dir -Path (Join-Path $DataPath "cache")
Ensure-Dir -Path (Join-Path $DataPath "logs")
Ensure-Dir -Path (Join-Path $DataPath "pip-cache")

if (-not (Test-Path -LiteralPath (Join-Path $RepoPath ".git"))) {
    if (Test-Path -LiteralPath $RepoPath) {
        throw "RepoPath exists but is not a git repository: $RepoPath"
    }

    Write-Info "Cloning repository into $RepoPath"
    & git clone --recurse-submodules $RepoUrl $RepoPath
    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed with exit code $LASTEXITCODE"
    }
    Write-Ok "Repository cloned"
}
else {
    Write-Info "Repository already present at $RepoPath"
}

$pythonExe = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonExe) {
    throw "python executable not found on PATH. Install Python 3.11+ and re-run."
}

if (-not (Test-Path -LiteralPath $VenvPath)) {
    Write-Info "Creating virtual environment at $VenvPath"
    & python -m venv $VenvPath
    if ($LASTEXITCODE -ne 0) {
        throw "python -m venv failed with exit code $LASTEXITCODE"
    }
    Write-Ok "Virtual environment created"
}
else {
    Write-Info "Virtual environment already exists at $VenvPath"
}

$venvPython = Join-Path $VenvPath "Scripts\python.exe"
if (-not (Test-Path -LiteralPath $venvPython)) {
    throw "Virtual environment python not found: $venvPython"
}

$env:PIP_CACHE_DIR = Join-Path $DataPath "pip-cache"
Ensure-Dir -Path $env:PIP_CACHE_DIR

Write-Info "Upgrading pip/setuptools/wheel in venv"
& $venvPython -m pip install --upgrade pip setuptools wheel
if ($LASTEXITCODE -ne 0) {
    throw "pip bootstrap failed with exit code $LASTEXITCODE"
}

Write-Info "Installing Hermes into venv from repo"
& $venvPython -m pip install -e "$RepoPath[all]"
if ($LASTEXITCODE -ne 0) {
    throw "Hermes install failed with exit code $LASTEXITCODE"
}
Write-Ok "Hermes installed"

$homePath = Join-Path $DataPath "home"
$tmpPath = Join-Path $DataPath "tmp"
$cachePath = Join-Path $DataPath "cache"

$cmdWrapper = Join-Path $BinPath "hermes.cmd"
$psWrapper = Join-Path $BinPath "hermes.ps1"

$cmdContent = @"
@echo off
set "HERMES_HOME=$homePath"
set "TMP=$tmpPath"
set "TEMP=$tmpPath"
set "XDG_CACHE_HOME=$cachePath"
set "PIP_CACHE_DIR=$env:PIP_CACHE_DIR"
"$venvPython" -m hermes_cli.main %*
"@

$psContent = @"
`$ErrorActionPreference = "Stop"
`$env:HERMES_HOME = "$homePath"
`$env:TMP = "$tmpPath"
`$env:TEMP = "$tmpPath"
`$env:XDG_CACHE_HOME = "$cachePath"
`$env:PIP_CACHE_DIR = "$env:PIP_CACHE_DIR"
& "$venvPython" -m hermes_cli.main @args
"@

Set-Content -LiteralPath $cmdWrapper -Value $cmdContent -Encoding Ascii -NoNewline
Set-Content -LiteralPath $psWrapper -Value $psContent -Encoding Ascii -NoNewline
Write-Ok "Wrappers created: $cmdWrapper and $psWrapper"

Add-UserPathEntry -Entry $BinPath

Write-Info "Verifying hermes from non-repo directory"
Push-Location $InstallRoot
try {
    $resolvedHermes = (Get-Command hermes -ErrorAction Stop).Source
    Write-Info "Resolved hermes command: $resolvedHermes"

    $helpOutput = & hermes --help 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "hermes --help failed: $helpOutput"
    }
    Write-Ok "hermes --help succeeded"

    $cmdHelp = & $cmdWrapper --help 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "hermes.cmd --help failed: $cmdHelp"
    }
    Write-Ok "hermes.cmd --help succeeded"

    $pythonProbe = & $venvPython -c "import sys; print(sys.executable)" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Interpreter probe failed: $pythonProbe"
    }
    $pythonProbe = ($pythonProbe | Select-Object -Last 1).ToString().Trim()
    Write-Info "Interpreter probe: $pythonProbe"

    if ($pythonProbe.TrimEnd('\\') -ine $venvPython.TrimEnd('\\')) {
        throw "Interpreter mismatch. Expected $venvPython but got $pythonProbe"
    }
    Write-Ok "Verified expected interpreter path"
}
finally {
    Pop-Location
}

Write-Host ""
Write-Ok "Global setup complete"
Write-Host "Use from any new terminal: hermes --help"
Write-Host "Installed repo: $RepoPath"
Write-Host "Installed venv: $VenvPath"
Write-Host "Global bin: $BinPath"
Write-Host "Hermes data root: $DataPath"