[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wix = (Get-Command wix.exe -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($wix)) {
    $wix = Join-Path $env:USERPROFILE '.dotnet\tools\wix.exe'
}
$testScript = Join-Path $projectRoot 'tests\test-powershell.ps1'
$buildScript = Join-Path $projectRoot 'build.ps1'
$msiPath = Join-Path $projectRoot 'dist\CodexWeComNotifier-x64.msi'

& $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $testScript
if ($LASTEXITCODE -ne 0) {
    throw "Tests failed with exit code $LASTEXITCODE"
}

& $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $buildScript
if ($LASTEXITCODE -ne 0) {
    throw "Build failed with exit code $LASTEXITCODE"
}

$distFiles = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'dist') -File)
if ($distFiles.Count -ne 1 -or $distFiles[0].FullName -ne $msiPath) {
    throw 'The dist directory must contain only CodexWeComNotifier-x64.msi.'
}

& $wix msi validate $msiPath
if ($LASTEXITCODE -ne 0) {
    throw "MSI validation failed with exit code $LASTEXITCODE"
}

$verificationDirectory = Join-Path $env:TEMP ('CodexWeComNotifierVerify-' + [guid]::NewGuid().ToString('N'))
$extractDirectory = Join-Path $verificationDirectory 'files'
$decompiledSource = Join-Path $verificationDirectory 'Package.wxs'
New-Item -ItemType Directory -Path $verificationDirectory | Out-Null
& $wix msi decompile $msiPath -x $extractDirectory -o $decompiledSource
if ($LASTEXITCODE -ne 0) {
    throw "MSI extraction failed with exit code $LASTEXITCODE"
}

$extractedConfigurationScripts = @(Get-Item -LiteralPath (Join-Path $extractDirectory 'File\ConfigureScript') -ErrorAction SilentlyContinue)
$extractedNotificationScripts = @(Get-Item -LiteralPath (Join-Path $extractDirectory 'File\NotificationScript') -ErrorAction SilentlyContinue)
$extractedTokenSummaryScripts = @(Get-Item -LiteralPath (Join-Path $extractDirectory 'File\TokenSummaryScript') -ErrorAction SilentlyContinue)
$extractedHookMetadataScripts = @(Get-Item -LiteralPath (Join-Path $extractDirectory 'File\HookMetadataScript') -ErrorAction SilentlyContinue)
if ($extractedConfigurationScripts.Count -ne 1 -or $extractedNotificationScripts.Count -ne 1 -or $extractedTokenSummaryScripts.Count -ne 1 -or $extractedHookMetadataScripts.Count -ne 1) {
    throw 'Expected the configuration, notification, token summary, and hook metadata scripts in the MSI.'
}
foreach ($scriptFile in @($extractedConfigurationScripts[0], $extractedNotificationScripts[0], $extractedTokenSummaryScripts[0], $extractedHookMetadataScripts[0])) {
    $scriptBytes = [IO.File]::ReadAllBytes($scriptFile.FullName)
    if ($scriptBytes.Length -lt 3 -or $scriptBytes[0] -ne 0xEF -or $scriptBytes[1] -ne 0xBB -or $scriptBytes[2] -ne 0xBF) {
        throw "Windows PowerShell script is not UTF-8 with BOM: $($scriptFile.FullName)"
    }
}
if (@(Get-ChildItem -LiteralPath $extractDirectory -Filter '*.exe' -File -Recurse).Count -ne 0) {
    throw 'The MSI must not contain executable files.'
}

$sourcePatterns = @(
    [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
)
$sourceFiles = Get-ChildItem -LiteralPath $projectRoot -File -Recurse |
    Where-Object { $_.FullName -notmatch '[\\/](bin|obj|dist)[\\/]' }
foreach ($pattern in $sourcePatterns) {
    $match = Select-String -LiteralPath $sourceFiles.FullName -SimpleMatch $pattern -Quiet
    if ($match) {
        throw "Sensitive source marker found: $pattern"
    }
}
$webhookPattern = 'qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key=([0-9a-fA-F-]{36})'
foreach ($sourceFile in $sourceFiles) {
    $sourceText = Get-Content -LiteralPath $sourceFile.FullName -Raw
    foreach ($match in [regex]::Matches($sourceText, $webhookPattern)) {
        if ($match.Groups[1].Value -ne '00000000-0000-0000-0000-000000000000') {
            throw "Webhook credential found in source: $($sourceFile.FullName)"
        }
    }
}

$binaryPatterns = @(
    [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    'test-key'
)
$binaryFiles = @($msiPath) + $extractedConfigurationScripts.FullName + $extractedNotificationScripts.FullName + $extractedTokenSummaryScripts.FullName + $extractedHookMetadataScripts.FullName
foreach ($binaryFile in $binaryFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($binaryFile)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $unicode = [System.Text.Encoding]::Unicode.GetString($bytes)
    foreach ($pattern in $binaryPatterns) {
        if ($ascii.Contains($pattern) -or $unicode.Contains($pattern)) {
            throw "Sensitive binary marker found in $binaryFile"
        }
    }
    foreach ($binaryText in @($ascii, $unicode)) {
        foreach ($match in [regex]::Matches($binaryText, $webhookPattern)) {
            if ($match.Groups[1].Value -ne '00000000-0000-0000-0000-000000000000') {
                throw "Webhook credential found in $binaryFile"
            }
        }
    }
}

$msi = Get-Item -LiteralPath $msiPath
$hash = Get-FileHash -LiteralPath $msiPath -Algorithm SHA256
$signature = Get-AuthenticodeSignature -LiteralPath $msiPath

[pscustomobject]@{
    MsiPath              = $msi.FullName
    SizeBytes            = $msi.Length
    Sha256               = $hash.Hash
    SignatureStatus      = $signature.Status
    ExtractDirectory     = $extractDirectory
    ConfigurationScript  = $extractedConfigurationScripts[0].FullName
    NotificationScript   = $extractedNotificationScripts[0].FullName
    TokenSummaryScript   = $extractedTokenSummaryScripts[0].FullName
    HookMetadataScript   = $extractedHookMetadataScripts[0].FullName
    Tests                = 'PASS'
    WixValidation        = 'PASS'
    SensitiveMarkerScan = 'PASS'
} | Format-List
