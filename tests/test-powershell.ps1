[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$notifyScript = Join-Path $projectRoot 'scripts\notify-wecom.ps1'
$configureScript = Join-Path $projectRoot 'scripts\configure-wecom.ps1'

. $notifyScript
. $configureScript

$validWebhook = 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=00000000-0000-0000-0000-000000000000'
Assert-True (Test-WeComWebhookFormat -Webhook $validWebhook) 'A valid enterprise WeChat webhook must be accepted.'
Assert-True (-not (Test-WeComWebhookFormat -Webhook 'https://example.com/webhook')) 'A non-WeCom webhook must be rejected.'

$body = New-WeComNotificationBody -Workspace 'demo' -Timestamp '2026-07-21 20:00:00'
Assert-True ($body -eq "Codex 任务已完成`n工作区：demo`n时间：2026-07-21 20:00:00") 'Notification text must contain only the task result, workspace, and timestamp.'
Assert-True ($body -notmatch 'token|ntfy') 'Notification text must not contain token or ntfy content.'

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexWeComNotifierTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $hooksPath = Join-Path $temporaryRoot 'hooks.json'
    $notificationPath = Join-Path $temporaryRoot 'notify-wecom.ps1'
    $existing = [ordered]@{
        hooks = [ordered]@{
            SessionStart = @(
                [ordered]@{
                    hooks = @(
                        [ordered]@{ type = 'command'; command = 'existing.exe' }
                    )
                }
            )
        }
    }
    [IO.File]::WriteAllText($hooksPath, ($existing | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

    Add-WeComStopHook -HooksPath $hooksPath -NotificationScriptPath $notificationPath
    Add-WeComStopHook -HooksPath $hooksPath -NotificationScriptPath $notificationPath

    $configured = Get-Content -LiteralPath $hooksPath -Raw | ConvertFrom-Json
    Assert-True ($configured.hooks.SessionStart[0].hooks[0].command -eq 'existing.exe') 'Existing hooks must be preserved.'
    Assert-True (@($configured.hooks.Stop).Count -eq 1) 'The enterprise WeChat Stop hook must not be duplicated.'
    $command = [string]$configured.hooks.Stop[0].hooks[0].command
    Assert-True ($command -match '^powershell\.exe ') 'The Stop hook must use Windows PowerShell.'
    Assert-True ($command -notmatch 'pwsh|ntfy|token') 'The Stop hook must not use PowerShell 7, ntfy, or token scripts.'

    Remove-WeComStopHook -HooksPath $hooksPath -NotificationScriptPath $notificationPath
    $removed = Get-Content -LiteralPath $hooksPath -Raw | ConvertFrom-Json
    Assert-True ($removed.hooks.SessionStart[0].hooks[0].command -eq 'existing.exe') 'Uninstall must preserve unrelated hooks.'
    Assert-True ($null -eq $removed.hooks.Stop) 'Uninstall must remove only the enterprise WeChat Stop hook.'

    $secretPath = Join-Path $temporaryRoot 'wecom-webhook.dpapi'
    Save-WeComSecret -Webhook $validWebhook -SecretPath $secretPath
    Assert-True ((Get-WeComSecret -SecretPath $secretPath) -eq $validWebhook) 'The DPAPI-protected webhook must round-trip for the current user.'

    Install-WeComNotificationScript -SourcePath $notifyScript -DestinationPath $notifyScript
} finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Get-ChildItem -LiteralPath $temporaryRoot -File | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName
        }
        Remove-Item -LiteralPath $temporaryRoot
    }
}

$combinedSource = (Get-Content -LiteralPath $notifyScript -Raw) + (Get-Content -LiteralPath $configureScript -Raw)
Assert-True ($combinedSource -notmatch '(?i)ntfy|token') 'Installed scripts must not contain ntfy or token features.'
Assert-True ($combinedSource -notmatch '(?i)pwsh\.exe') 'Installed scripts must not require PowerShell 7.'
Assert-True ($combinedSource.Contains('可以先建两个机器人，然后和机器人拉个群聊，然后点群聊右上方的三个点···，找到消息推送，点“添加”即可提取webhook地址。')) 'The webhook extraction reminder must be preserved exactly.'
Assert-True ($combinedSource.Contains('在codex设置的钩子/hooks里可以找到新的hook，设置信任即可。')) 'The hook trust reminder must be preserved exactly.'

$packageSource = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Package.wxs') -Raw
$buildSource = Get-Content -LiteralPath (Join-Path $projectRoot 'build.ps1') -Raw
Assert-True ($packageSource -match 'ConfigureScript') 'The MSI must install and launch the PowerShell configuration script.'
Assert-True ($packageSource -match 'NotificationScript') 'The MSI must contain the enterprise WeChat notification script.'
Assert-True ($packageSource -match 'Custom Action="ConfigureProduct"[^>]+Condition="[^"]*UILevel\s*&gt;=\s*4[^"]*"') 'The MSI must launch the configuration window only in full interactive UI mode.'
Assert-True ($packageSource -notmatch 'NotifierExe|CodexWeComNotifier\.exe') 'The MSI must not install the old .NET executable.'
Assert-True ($buildSource -notmatch '(?i)dotnet build|net48|\.csproj|dotnet\.exe was not found') 'The MSI build must not require the .NET SDK or .NET Framework build output.'

Write-Output 'PASS: Windows PowerShell hook tests completed.'
