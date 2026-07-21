[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
$wix = (Get-Command wix.exe -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($wix)) {
    $wix = Join-Path $env:USERPROFILE '.dotnet\tools\wix.exe'
}
$testProject = Join-Path $projectRoot 'tests\CodexWeComNotifier.Tests\CodexWeComNotifier.Tests.csproj'
$buildScript = Join-Path $projectRoot 'build.ps1'
$msiPath = Join-Path $projectRoot 'dist\CodexWeComNotifier-x64.msi'

& $dotnet run --project $testProject -c Release
if ($LASTEXITCODE -ne 0) {
    throw "Tests failed with exit code $LASTEXITCODE"
}

& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $buildScript
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

$extractDirectory = Join-Path $env:TEMP ('CodexWeComNotifierVerify-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $extractDirectory -Force | Out-Null
$msiArguments = @(
    '/a'
    $msiPath
    '/qn'
    "TARGETDIR=$extractDirectory"
)
$msiPathExecutable = (Get-Command msiexec.exe -ErrorAction Stop).Source
for ($attempt = 1; $attempt -le 10; $attempt++) {
    $msiProcessInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $msiProcessInfo.FileName = $msiPathExecutable
    $msiProcessInfo.UseShellExecute = $false
    foreach ($argument in $msiArguments) {
        $msiProcessInfo.ArgumentList.Add($argument)
    }
    $msiProcess = [System.Diagnostics.Process]::Start($msiProcessInfo)
    $msiProcess.WaitForExit()
    if ($msiProcess.ExitCode -ne 1618 -or $attempt -eq 10) {
        break
    }
    Start-Sleep -Seconds 1
}
if ($msiProcess.ExitCode -ne 0) {
    throw "Administrative extraction failed with exit code $($msiProcess.ExitCode)"
}

$extractedExecutables = @(Get-ChildItem -LiteralPath $extractDirectory -Filter 'CodexWeComNotifier.exe' -File -Recurse)
if ($extractedExecutables.Count -ne 1) {
    throw "Expected one extracted notifier executable, found $($extractedExecutables.Count)."
}

$sourcePatterns = @(
    [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    ('nt' + 'fy.sh')
    ('nt' + 'fy-topic')
    ('notify' + '-dual')
    ('wecom-webhook' + '.dpapi')
)
$sourceFiles = Get-ChildItem -LiteralPath $projectRoot -File -Recurse |
    Where-Object { $_.FullName -notmatch '[\\/](bin|obj|dist)[\\/]' }
foreach ($pattern in $sourcePatterns) {
    $match = Select-String -LiteralPath $sourceFiles.FullName -SimpleMatch $pattern -Quiet
    if ($match) {
        throw "Sensitive source marker found: $pattern"
    }
}

$binaryPatterns = @(
    [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    ('nt' + 'fy')
    ('notify' + '-dual')
    'test-key'
    'qyapi.weixin.qq.com/cgi-bin/webhook/send?key='
)
$binaryFiles = @($msiPath) + $extractedExecutables.FullName
foreach ($binaryFile in $binaryFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($binaryFile)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $unicode = [System.Text.Encoding]::Unicode.GetString($bytes)
    foreach ($pattern in $binaryPatterns) {
        if ($ascii.Contains($pattern) -or $unicode.Contains($pattern)) {
            throw "Sensitive binary marker found in $binaryFile"
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
    ExtractedExecutable  = $extractedExecutables[0].FullName
    Tests                = 'PASS'
    WixValidation        = 'PASS'
    SensitiveMarkerScan = 'PASS'
} | Format-List
