param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PytestArgs
)

$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "> $Message" -ForegroundColor Cyan
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir

$candidates = @(
    (Join-Path $repoRoot ".venv\Scripts\python.exe"),
    (Join-Path $repoRoot "venv\Scripts\python.exe"),
    (Join-Path $env:USERPROFILE ".hermes\hermes-agent\venv\Scripts\python.exe")
)

$python = $null
foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) {
        $python = $candidate
        break
    }
}

if (-not $python) {
    throw "No virtual environment python found. Expected one of: $($candidates -join ', ')"
}

Set-Location $repoRoot

# Hermetic environment parity with scripts/run_tests.sh
$credentialPatterns = @(
    '*_API_KEY', '*_TOKEN', '*_SECRET', '*_PASSWORD', '*_CREDENTIALS', '*_ACCESS_KEY',
    '*_SECRET_ACCESS_KEY', '*_PRIVATE_KEY', '*_OAUTH_TOKEN', '*_WEBHOOK_SECRET',
    '*_ENCRYPT_KEY', '*_APP_SECRET', '*_CLIENT_SECRET', '*_CORP_SECRET', '*_AES_KEY',
    'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'FAL_KEY',
    'GH_TOKEN', 'GITHUB_TOKEN'
)

Get-ChildItem Env: | ForEach-Object {
    $name = $_.Name
    foreach ($pattern in $credentialPatterns) {
        if ($name -like $pattern) {
            Remove-Item ("Env:" + $name) -ErrorAction SilentlyContinue
            break
        }
    }
}

$hermesVars = @(
    'HERMES_YOLO_MODE', 'HERMES_INTERACTIVE', 'HERMES_QUIET', 'HERMES_TOOL_PROGRESS',
    'HERMES_TOOL_PROGRESS_MODE', 'HERMES_MAX_ITERATIONS', 'HERMES_SESSION_PLATFORM',
    'HERMES_SESSION_CHAT_ID', 'HERMES_SESSION_CHAT_NAME', 'HERMES_SESSION_THREAD_ID',
    'HERMES_SESSION_SOURCE', 'HERMES_SESSION_KEY', 'HERMES_GATEWAY_SESSION',
    'HERMES_PLATFORM', 'HERMES_INFERENCE_PROVIDER', 'HERMES_MANAGED', 'HERMES_DEV',
    'HERMES_CONTAINER', 'HERMES_EPHEMERAL_SYSTEM_PROMPT', 'HERMES_TIMEZONE',
    'HERMES_REDACT_SECRETS', 'HERMES_BACKGROUND_NOTIFICATIONS', 'HERMES_EXEC_ASK',
    'HERMES_HOME_MODE'
)

foreach ($name in $hermesVars) {
    Remove-Item ("Env:" + $name) -ErrorAction SilentlyContinue
}

$env:TZ = 'UTC'
$env:LANG = 'C.UTF-8'
$env:LC_ALL = 'C.UTF-8'
$env:PYTHONHASHSEED = '0'

$workers = if ($env:HERMES_TEST_WORKERS) { $env:HERMES_TEST_WORKERS } else { '4' }

& $python -c "import pytest" *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Info "Installing pytest into active virtual environment"
    & $python -m pip install --quiet "pytest>=8,<9"
}

& $python -c "import xdist" *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Info "Installing pytest-xdist into active virtual environment"
    & $python -m pip install --quiet "pytest-xdist>=3,<4"
}

& $python -c "import pytest_split" *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Info "Installing pytest-split into active virtual environment"
    & $python -m pip install --quiet "pytest-split>=0.9,<1"
}

$pytestCmd = @(
    '-m', 'pytest',
    '-o', 'addopts=',
    '-n', $workers,
    '--ignore=tests/integration',
    '--ignore=tests/e2e',
    '-m', 'not integration'
)

if ($PytestArgs) {
    $pytestCmd += $PytestArgs
}

Write-Info "Running pytest in $repoRoot with $workers workers"
& $python @pytestCmd
