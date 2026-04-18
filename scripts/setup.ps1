param(
    [switch]$SkipSetupWizard,
    [string]$PythonVersion = "3.11"
)

$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[ok] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[warn] $Message" -ForegroundColor Yellow
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warn "PowerShell 7+ is recommended. Current version: $($PSVersionTable.PSVersion)"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$venvDir = Join-Path $repoRoot ".venv"
$venvPython = Join-Path $venvDir "Scripts\python.exe"

Write-Info "Repository root: $repoRoot"

Set-Location $repoRoot

$uvCmd = $null
if (Get-Command uv -ErrorAction SilentlyContinue) {
    $uvCmd = "uv"
}

if (Test-Path $venvDir) {
    Write-Info "Removing old virtual environment at $venvDir"
    Remove-Item -Recurse -Force $venvDir
}

if ($uvCmd) {
    Write-Info "Creating virtual environment with uv ($PythonVersion)"
    & $uvCmd venv $venvDir --python $PythonVersion
    if ($LASTEXITCODE -ne 0) {
        throw "uv venv failed (exit code $LASTEXITCODE)"
    }
} else {
    Write-Warn "uv not found. Falling back to py/python venv creation."
    if (Get-Command py -ErrorAction SilentlyContinue) {
        & py "-$PythonVersion" -m venv $venvDir
        if ($LASTEXITCODE -ne 0) {
            throw "py -$PythonVersion -m venv failed (exit code $LASTEXITCODE)"
        }
    } elseif (Get-Command python -ErrorAction SilentlyContinue) {
        & python -m venv $venvDir
        if ($LASTEXITCODE -ne 0) {
            throw "python -m venv failed (exit code $LASTEXITCODE)"
        }
    } else {
        throw "No Python launcher found. Install Python 3.11+ or uv first."
    }
}

if (-not (Test-Path $venvPython)) {
    throw "Virtual environment creation failed. Missing $venvPython"
}

Write-Info "Installing dependencies"
if ($uvCmd -and (Test-Path (Join-Path $repoRoot "uv.lock"))) {
    try {
        $env:UV_PROJECT_ENVIRONMENT = $venvDir
        & $uvCmd sync --all-extras --locked
        if ($LASTEXITCODE -ne 0) {
            throw "uv sync failed (exit code $LASTEXITCODE)"
        }
        Remove-Item Env:UV_PROJECT_ENVIRONMENT -ErrorAction SilentlyContinue
        Write-Success "Dependencies installed from uv.lock"
    } catch {
        Remove-Item Env:UV_PROJECT_ENVIRONMENT -ErrorAction SilentlyContinue
        Write-Warn "uv sync failed, falling back to pip editable install"
        & $venvPython -m pip install --upgrade pip setuptools wheel
        if ($LASTEXITCODE -ne 0) {
            throw "pip bootstrap failed (exit code $LASTEXITCODE)"
        }
        try {
            & $venvPython -m pip install -e ".[all]"
            if ($LASTEXITCODE -ne 0) {
                throw "pip install -e .[all] failed (exit code $LASTEXITCODE)"
            }
        } catch {
            & $venvPython -m pip install -e "."
            if ($LASTEXITCODE -ne 0) {
                throw "pip install -e . failed (exit code $LASTEXITCODE)"
            }
        }
    }
} else {
    & $venvPython -m pip install --upgrade pip setuptools wheel
    if ($LASTEXITCODE -ne 0) {
        throw "pip bootstrap failed (exit code $LASTEXITCODE)"
    }
    try {
        & $venvPython -m pip install -e ".[all]"
        if ($LASTEXITCODE -ne 0) {
            throw "pip install -e .[all] failed (exit code $LASTEXITCODE)"
        }
    } catch {
        & $venvPython -m pip install -e "."
        if ($LASTEXITCODE -ne 0) {
            throw "pip install -e . failed (exit code $LASTEXITCODE)"
        }
    }
    Write-Success "Dependencies installed with pip"
}

$envExample = Join-Path $repoRoot ".env.example"
$envFile = Join-Path $repoRoot ".env"
if ((Test-Path $envExample) -and (-not (Test-Path $envFile))) {
    Copy-Item $envExample $envFile
    Write-Success "Created .env from .env.example"
}

Write-Host ""
Write-Success "Windows setup complete"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1) $venvPython -m hermes_cli.main setup"
Write-Host "  2) $venvPython -m hermes_cli.main"
Write-Host ""

if (-not $SkipSetupWizard) {
    Write-Info "Launching setup wizard"
    & $venvPython -m hermes_cli.main setup
    if ($LASTEXITCODE -ne 0) {
        throw "setup wizard failed (exit code $LASTEXITCODE)"
    }
}
