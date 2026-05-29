[CmdletBinding(PositionalBinding = $false)]
param(
  [Alias("list", "list-models")]
  [switch]$ListModels,
  [Alias("m")]
  [string]$Model,
  [string]$SettingsPath = "",
  [switch]$NoLaunch,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$QwenArgs
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$resolver = Join-Path $scriptDir "resolve-kendro-runtime.ps1"

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
  if (-not [string]::IsNullOrWhiteSpace($env:QWEN_SETTINGS_PATH)) {
    $SettingsPath = $env:QWEN_SETTINGS_PATH
  }
  elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $SettingsPath = Join-Path $env:USERPROFILE ".qwen\settings.json"
  }
  else {
    $SettingsPath = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".qwen\settings.json"
  }
}

if (-not (Test-Path $resolver)) {
  throw "Missing resolver script: $resolver"
}

function Parse-KeyValueLines {
  param([string[]]$Lines)
  $map = @{}
  foreach ($line in $Lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $idx = $line.IndexOf("=")
    if ($idx -lt 1) { continue }
    $key = $line.Substring(0, $idx).Trim()
    $value = $line.Substring($idx + 1).Trim()
    $map[$key] = $value
  }
  return $map
}

function Ensure-ObjectProperty {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if (-not $Object.PSObject.Properties[$Name] -or $null -eq $Object.$Name) {
    if ($Object.PSObject.Properties[$Name]) {
      $Object.$Name = [pscustomobject]@{}
    }
    else {
      $Object | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{})
    }
  }
  return $Object.$Name
}

function Set-ObjectPropertyValue {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    $Value
  )
  if ($Object.PSObject.Properties[$Name]) {
    $Object.$Name = $Value
  }
  else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function New-ProviderEntry {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$EnvKey,
    $GenerationConfig = $null,
    [string]$Description = ""
  )

  $entry = [ordered]@{
    id = $Id
    name = $Name
    baseUrl = $BaseUrl
    envKey = $EnvKey
  }

  if ($GenerationConfig) {
    $entry.generationConfig = $GenerationConfig
  }

  if (-not [string]::IsNullOrWhiteSpace($Description)) {
    $entry.description = $Description
  }

  return [pscustomobject]$entry
}

function Prepend-PathEntry {
  param([string]$PathEntry)
  if ([string]::IsNullOrWhiteSpace($PathEntry)) { return }
  if (-not (Test-Path $PathEntry)) { return }
  $parts = @($env:PATH -split ';')
  if ($parts -contains $PathEntry) { return }
  $env:PATH = "$PathEntry;$env:PATH"
}

$resolvedLines = & powershell -NoProfile -ExecutionPolicy Bypass -File $resolver 2>$null
$runtime = Parse-KeyValueLines -Lines $resolvedLines

$kendroBase = $runtime["KENDRO_BASE_URL"]
$kendroBundleRoot = $runtime["KENDRO_BUNDLE_ROOT"]
if (-not $kendroBase) {
  throw "Could not resolve running Kendro service. Start Kendro first (Bat Launchers\\start_kendro_serving_all.bat)."
}

$apiBase = $kendroBase.TrimEnd("/") + "/v1"

try {
  $modelsResponse = Invoke-RestMethod -Uri ($apiBase + "/models") -TimeoutSec 10
}
catch {
  throw "Kendro is running but /v1/models failed at $apiBase. $_"
}

$modelItems = @()
if ($modelsResponse -and $modelsResponse.data) {
  $modelItems = @($modelsResponse.data)
}

$dynamicIds = @()
$seen = @{}
foreach ($item in $modelItems) {
  $id = [string]$item.id
  if ([string]::IsNullOrWhiteSpace($id)) { continue }
  if (-not $seen.ContainsKey($id)) {
    $seen[$id] = $true
    $dynamicIds += $id
  }
}
$dynamicIds = @($dynamicIds | Sort-Object)

if (-not (Test-Path $SettingsPath)) {
  $settingsDir = Split-Path -Parent $SettingsPath
  if (-not (Test-Path $settingsDir)) {
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
  }
  $settings = [pscustomobject]@{}
}
else {
  $raw = Get-Content -Raw $SettingsPath
  if ([string]::IsNullOrWhiteSpace($raw)) {
    $settings = [pscustomobject]@{}
  }
  else {
    $settings = $raw | ConvertFrom-Json
  }
}

if (-not $settings) {
  $settings = [pscustomobject]@{}
}

$modelNode = Ensure-ObjectProperty -Object $settings -Name "model"
$providersNode = Ensure-ObjectProperty -Object $settings -Name "modelProviders"
$securityNode = Ensure-ObjectProperty -Object $settings -Name "security"
$authNode = Ensure-ObjectProperty -Object $securityNode -Name "auth"
$envNode = Ensure-ObjectProperty -Object $settings -Name "env"

$authNode.selectedType = "openai"
if (-not $settings.PSObject.Properties["`$version"] -or $null -eq $settings."$version") {
  $settings | Add-Member -NotePropertyName "`$version" -NotePropertyValue 3 -Force
}
else {
  $settings."$version" = 3
}

if (-not $envNode.PSObject.Properties["LMSTUDIO_API_KEY"]) { $envNode | Add-Member -NotePropertyName "LMSTUDIO_API_KEY" -NotePropertyValue "lm-studio" }
if (-not $envNode.PSObject.Properties["OPENAI_API_KEY"]) { $envNode | Add-Member -NotePropertyName "OPENAI_API_KEY" -NotePropertyValue "ks-kendro" }
Set-ObjectPropertyValue -Object $envNode -Name "OPENAI_BASE_URL" -Value $apiBase
Set-ObjectPropertyValue -Object $envNode -Name "KS_KENDRO_BASE_URL" -Value $kendroBase
Set-ObjectPropertyValue -Object $envNode -Name "KS_AI_GATEWAY_BASE_URL" -Value $apiBase
if ($kendroBundleRoot) {
  if (-not $envNode.PSObject.Properties["KS_KENDRO_BUNDLE_ROOT"]) {
    $envNode | Add-Member -NotePropertyName "KS_KENDRO_BUNDLE_ROOT" -NotePropertyValue $kendroBundleRoot
  }
  else {
    $envNode.KS_KENDRO_BUNDLE_ROOT = $kendroBundleRoot
  }
}

$providerEntries = @()
$providerEntries += New-ProviderEntry -Id "ks-kendro-auto" -Name "KS Kendro Auto" -BaseUrl $apiBase -EnvKey "LMSTUDIO_API_KEY" -GenerationConfig ([pscustomobject]@{
    extra_body = [pscustomobject]@{ task_type = "general" }
    samplingParams = [pscustomobject]@{ max_tokens = 8192; temperature = 0.7 }
    contextWindowSize = 128000
    maxRetries = 3
    timeout = 300000
  }) -Description "Dynamic auto routing"
$providerEntries += New-ProviderEntry -Id "ks-kendro-coding" -Name "KS Kendro Coding" -BaseUrl $apiBase -EnvKey "LMSTUDIO_API_KEY" -GenerationConfig ([pscustomobject]@{
    extra_body = [pscustomobject]@{ task_type = "coding" }
    samplingParams = [pscustomobject]@{ max_tokens = 8192; temperature = 0.7 }
    contextWindowSize = 128000
    maxRetries = 3
    timeout = 300000
  }) -Description "Dynamic coding routing"

foreach ($id in $dynamicIds) {
  if ($id -in @("ks-kendro-auto", "ks-kendro-coding")) {
    continue
  }
  $providerEntries += New-ProviderEntry -Id $id -Name $id -BaseUrl $apiBase -EnvKey "LMSTUDIO_API_KEY"
}

Set-ObjectPropertyValue -Object $providersNode -Name "openai" -Value $providerEntries

$allIds = @("ks-kendro-auto", "ks-kendro-coding") + $dynamicIds
$currentModel = [string]$modelNode.name

$selectedModel = ""
if ($Model) {
  if ($allIds -contains $Model) {
    $selectedModel = $Model
  }
  else {
    throw "Requested model '$Model' is not in current Kendro catalog. Use -ListModels to inspect available models."
  }
}
elseif ($currentModel -and ($allIds -contains $currentModel)) {
  $selectedModel = $currentModel
}
else {
  $selectedModel = "ks-kendro-auto"
}

$modelNode.name = $selectedModel

$settings | ConvertTo-Json -Depth 40 | Set-Content -Encoding UTF8 $SettingsPath

if ($ListModels) {
  Write-Host "Kendro Base URL : $kendroBase"
  Write-Host "OpenAI API URL  : $apiBase"
  Write-Host "Selected Model  : $selectedModel"
  Write-Host "Total Models    : $($allIds.Count)"
  Write-Host ""
  $allIds | ForEach-Object { Write-Host $_ }
  exit 0
}

if ($NoLaunch) {
  Write-Host "Settings synced: $SettingsPath"
  Write-Host "Selected model : $selectedModel"
  exit 0
}

$toolsHome = ""
if (-not [string]::IsNullOrWhiteSpace($env:QWEN_TOOLS_HOME)) {
  $toolsHome = $env:QWEN_TOOLS_HOME
}
elseif (-not [string]::IsNullOrWhiteSpace($env:DEVTOOLS_HOME)) {
  $toolsHome = $env:DEVTOOLS_HOME
}
elseif (Test-Path "D:\DevTools") {
  $toolsHome = "D:\DevTools"
}

if ($toolsHome) {
  Prepend-PathEntry -PathEntry (Join-Path $toolsHome "npm-global")
  Prepend-PathEntry -PathEntry (Join-Path $toolsHome "nodejs")
  Prepend-PathEntry -PathEntry (Join-Path $toolsHome "bin")
  Prepend-PathEntry -PathEntry $toolsHome
}

$qwenCmd = Get-Command qwen.cmd -ErrorAction SilentlyContinue
if (-not $qwenCmd) {
  $qwenCmd = Get-Command qwen -ErrorAction SilentlyContinue
}
if (-not $qwenCmd) {
  throw "Qwen CLI not found in PATH. Install or add qwen to PATH first."
}

$env:OPENAI_BASE_URL = $apiBase
if ($envNode.OPENAI_API_KEY) { $env:OPENAI_API_KEY = [string]$envNode.OPENAI_API_KEY }
if ($envNode.LMSTUDIO_API_KEY) { $env:LMSTUDIO_API_KEY = [string]$envNode.LMSTUDIO_API_KEY }
$env:KS_KENDRO_BASE_URL = $kendroBase
$env:KS_AI_GATEWAY_BASE_URL = $apiBase
if ($kendroBundleRoot) { $env:KS_KENDRO_BUNDLE_ROOT = $kendroBundleRoot }

$openAiKey = [string]$envNode.OPENAI_API_KEY
if ([string]::IsNullOrWhiteSpace($openAiKey)) {
  $openAiKey = "ks-kendro"
}

$launchArgs = @(
  "--auth-type", "openai",
  "--openai-base-url", $apiBase,
  "--openai-api-key", $openAiKey,
  "--model", $selectedModel
) + $QwenArgs
$launchTarget = $qwenCmd.Source
& $launchTarget @launchArgs
exit $LASTEXITCODE
