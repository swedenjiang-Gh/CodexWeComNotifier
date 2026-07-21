[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$projectPath = Join-Path $projectRoot 'src\CodexWeComNotifier\CodexWeComNotifier.csproj'
$sourceExe = Join-Path $projectRoot 'src\CodexWeComNotifier\bin\Release\net48\CodexWeComNotifier.exe'
$wixSource = Join-Path $projectRoot 'installer\Package.wxs'
$distDirectory = Join-Path $projectRoot 'dist'
$msiPath = Join-Path $distDirectory 'CodexWeComNotifier-x64.msi'
$dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
$wix = (Get-Command wix.exe -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($wix)) {
    $wix = Join-Path $env:USERPROFILE '.dotnet\tools\wix.exe'
}

if (-not (Test-Path -LiteralPath $dotnet -PathType Leaf)) {
    throw 'dotnet.exe was not found.'
}
if (-not (Test-Path -LiteralPath $wix -PathType Leaf)) {
    throw 'WiX Toolset was not found.'
}

New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null

& $dotnet build $projectPath -c Release
if ($LASTEXITCODE -ne 0) {
    throw "dotnet build failed with exit code $LASTEXITCODE"
}

& $wix build $wixSource -arch x64 -d "NotifierSource=$sourceExe" -pdbtype none -o $msiPath
if ($LASTEXITCODE -ne 0) {
    throw "WiX build failed with exit code $LASTEXITCODE"
}

Write-Host "Built: $msiPath"
