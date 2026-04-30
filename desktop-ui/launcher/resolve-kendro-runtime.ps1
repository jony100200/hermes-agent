$ErrorActionPreference = "SilentlyContinue"

$stateCandidates = New-Object System.Collections.Generic.List[string]

if ($env:HERMES_UI_KENDRO_STATE_FILE) {
  $stateCandidates.Add($env:HERMES_UI_KENDRO_STATE_FILE)
}

$processes = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "run_kendro_bundle\.py" }
foreach ($proc in $processes) {
  $cmd = [string]$proc.CommandLine
  if (-not $cmd) {
    continue
  }

  $scriptPath = (($cmd -split [char]34) | Where-Object { $_ -match "run_kendro_bundle\.py$" } | Select-Object -First 1)
  if (-not $scriptPath) {
    $match = [regex]::Match($cmd, "([A-Za-z]:\\.*run_kendro_bundle\.py)")
    if ($match.Success) {
      $scriptPath = $match.Groups[1].Value
    }
  }

  if ($scriptPath) {
    $bundleRoot = Split-Path $scriptPath -Parent
    $statePath = Join-Path $bundleRoot ".runtime\kendro_bundle_state.json"
    $stateCandidates.Add($statePath)
  }
}

$stateCandidates = $stateCandidates | Where-Object { $_ } | Select-Object -Unique

foreach ($state in $stateCandidates) {
  if (-not (Test-Path $state)) {
    continue
  }

  try {
    $raw = Get-Content -Raw $state | ConvertFrom-Json
  }
  catch {
    continue
  }

  $bundle = [string]$raw.bundle_root
  $base = [string]$raw.base_url

  $pid = 0
  try {
    $pid = [int]$raw.pid
  }
  catch {
    $pid = 0
  }

  $pidOk = $false
  if ($pid -gt 0) {
    $pidOk = [bool](Get-Process -Id $pid)
  }

  $liveOk = $false
  if ($base) {
    try {
      $liveUrl = $base.TrimEnd("/") + "/live"
      $resp = Invoke-WebRequest -Uri $liveUrl -TimeoutSec 2
      $liveOk = $resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500
    }
    catch {
      $liveOk = $false
    }
  }

  if (-not $pidOk -and -not $liveOk) {
    continue
  }

  if (-not $bundle) {
    $bundle = Split-Path (Split-Path $state -Parent) -Parent
  }

  $workspace = Join-Path $bundle "services"
  if (-not (Test-Path $workspace)) {
    $workspace = $bundle
  }

  Write-Output "KENDRO_STATE_FILE=$state"
  if ($bundle) {
    Write-Output "KENDRO_BUNDLE_ROOT=$bundle"
  }
  if ($base) {
    Write-Output "KENDRO_BASE_URL=$base"
  }
  Write-Output "KENDRO_WORKSPACE=$workspace"
  break
}
