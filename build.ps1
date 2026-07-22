[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$configureScript = Join-Path $projectRoot 'scripts\configure-wecom.ps1'
$notificationScript = Join-Path $projectRoot 'scripts\notify-wecom.ps1'
$tokenSummaryScript = Join-Path $projectRoot 'scripts\task-token-summary.ps1'
$hookMetadataScript = Join-Path $projectRoot 'scripts\hook-event-metadata.ps1'
$wixSource = Join-Path $projectRoot 'installer\Package.wxs'
$distDirectory = Join-Path $projectRoot 'dist'
$msiPath = Join-Path $distDirectory 'CodexWeComNotifier-x64.msi'
$wix = (Get-Command wix.exe -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($wix)) {
    $wix = Join-Path $env:USERPROFILE '.dotnet\tools\wix.exe'
}

if (-not (Test-Path -LiteralPath $wix -PathType Leaf)) {
    throw 'WiX Toolset was not found.'
}

New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null

& $wix build $wixSource -arch x64 -d "ConfigureScriptSource=$configureScript" -d "NotificationScriptSource=$notificationScript" -d "TokenSummaryScriptSource=$tokenSummaryScript" -d "HookMetadataScriptSource=$hookMetadataScript" -pdbtype none -o $msiPath
if ($LASTEXITCODE -ne 0) {
    throw "WiX build failed with exit code $LASTEXITCODE"
}

Write-Host "Built: $msiPath"
