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
$tokenSummaryScript = Join-Path $projectRoot 'scripts\task-token-summary.ps1'
$hookMetadataScript = Join-Path $projectRoot 'scripts\hook-event-metadata.ps1'

. $notifyScript
. $configureScript

$validWebhook = 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=00000000-0000-0000-0000-000000000000'
Assert-True (Test-WeComWebhookFormat -Webhook $validWebhook) 'A valid enterprise WeChat webhook must be accepted.'
Assert-True (-not (Test-WeComWebhookFormat -Webhook 'https://example.com/webhook')) 'A non-WeCom webhook must be rejected.'

$tokenSummary = '本轮任务总消耗（含子 Agent）：1,234 · 输入 1,000 · 输出 234'
$body = New-WeComNotificationBody -Workspace 'demo' -Timestamp '2026-07-21 20:00:00' -TokenSummaryText $tokenSummary
Assert-True ($body -eq "Codex 任务轮次已结束`n工作区：demo`n时间：2026-07-21 20:00:00`n`n$tokenSummary") 'Notification text must contain the existing detailed token summary.'
Assert-True ($body -notmatch 'ntfy') 'Notification text must not contain ntfy content.'

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
    Assert-True ([string]::Equals((Get-WeComSecret -SecretPath $secretPath), $validWebhook, [StringComparison]::Ordinal)) 'The DPAPI-protected webhook must round-trip for the current user.'

    $legacyPlainBytes = [Text.Encoding]::Unicode.GetBytes($validWebhook)
    try {
        $legacyProtectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $legacyPlainBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $legacyEncryptedWebhook = [BitConverter]::ToString($legacyProtectedBytes).Replace('-', '')
        [IO.File]::WriteAllText($secretPath, $legacyEncryptedWebhook, [Text.UTF8Encoding]::new($false))
    } finally {
        [Array]::Clear($legacyPlainBytes, 0, $legacyPlainBytes.Length)
    }
    Assert-True ([string]::Equals((Get-WeComSecret -SecretPath $secretPath), $validWebhook, [StringComparison]::Ordinal)) 'The notifier must read legacy Windows PowerShell DPAPI secrets.'

    $transcriptPath = Join-Path $temporaryRoot 'token-summary.jsonl'
    $transcriptEntries = @(
        [ordered]@{ timestamp = '2026-07-22T01:00:00Z'; type = 'event_msg'; payload = [ordered]@{ type = 'task_started'; turn_id = 'turn-test' } },
        [ordered]@{ timestamp = '2026-07-22T01:00:30Z'; type = 'event_msg'; payload = [ordered]@{ type = 'token_count'; info = [ordered]@{ total_token_usage = [ordered]@{ input_tokens = 100; cached_input_tokens = 20; output_tokens = 30; total_tokens = 130 }; last_token_usage = [ordered]@{ total_tokens = 130 }; model_context_window = 1000 } } },
        [ordered]@{ timestamp = '2026-07-22T01:00:31Z'; type = 'event_msg'; payload = [ordered]@{ type = 'task_complete'; turn_id = 'turn-test' } }
    ) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 }
    [IO.File]::WriteAllLines($transcriptPath, $transcriptEntries, [Text.UTF8Encoding]::new($false))
    $summaryEvent = [ordered]@{ session_id = 'session-test'; turn_id = 'turn-test'; transcript_path = $transcriptPath; hook_event_name = 'Stop' } | ConvertTo-Json -Compress
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $summaryOutput = @($summaryEvent | & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -File $tokenSummaryScript)
    Assert-True ($LASTEXITCODE -eq 0 -and $summaryOutput.Count -gt 0) 'The token summary must run under Windows PowerShell 5.1.'
    $summaryResult = ($summaryOutput -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ([string]$summaryResult.systemMessage -match '本轮任务总消耗（含子 Agent）：130') 'The Windows PowerShell token summary must preserve the existing detailed output.'

    Install-WeComNotificationScript -SourcePath $notifyScript -DestinationPath $notifyScript
} finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Get-ChildItem -LiteralPath $temporaryRoot -File | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName
        }
        Remove-Item -LiteralPath $temporaryRoot
    }
}

$combinedSource = (Get-Content -LiteralPath $notifyScript -Raw) + (Get-Content -LiteralPath $configureScript -Raw) + (Get-Content -LiteralPath $tokenSummaryScript -Raw) + (Get-Content -LiteralPath $hookMetadataScript -Raw)
Assert-True ($combinedSource -notmatch '(?i)ntfy') 'Installed scripts must not contain ntfy features.'
Assert-True ($combinedSource -notmatch '(?i)pwsh\.exe') 'Installed scripts must not require PowerShell 7.'
Assert-True (([regex]::Matches($combinedSource, '\[Console\]::InputEncoding\s*=\s*\[Text\.UTF8Encoding\]::new\(\$false\)')).Count -ge 2) 'The notification and token summary scripts must read UTF-8 Hook input.'
Assert-True (([regex]::Matches($combinedSource, '\[Console\]::OutputEncoding\s*=\s*\[Text\.UTF8Encoding\]::new\(\$false\)')).Count -ge 2) 'The notification and token summary scripts must emit UTF-8 Hook output.'
Assert-True ($combinedSource -notmatch 'ConvertTo-SecureString|ConvertFrom-SecureString|Microsoft\.PowerShell\.Security') 'Installed scripts must not depend on PowerShell Security module auto-loading.'
Assert-True ($combinedSource -match 'Security\.Cryptography\.ProtectedData') 'Installed scripts must use the .NET DPAPI implementation.'
Assert-True ($combinedSource -match '本轮任务总消耗（含子 Agent）') 'Installed scripts must preserve the existing detailed token summary.'
Assert-True ($combinedSource.Contains('可以先建两个机器人，然后和机器人拉个群聊，然后点群聊右上方的三个点···，找到消息推送，点“添加”即可提取webhook地址。')) 'The webhook extraction reminder must be preserved exactly.'
Assert-True ($combinedSource.Contains('在codex设置的钩子/hooks里可以找到新的hook，设置信任即可。')) 'The hook trust reminder must be preserved exactly.'

$packageSource = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Package.wxs') -Raw
$buildSource = Get-Content -LiteralPath (Join-Path $projectRoot 'build.ps1') -Raw
$installExecuteSequence = [regex]::Match($packageSource, '(?s)<InstallExecuteSequence>(.*?)</InstallExecuteSequence>').Groups[1].Value
$installUISequence = [regex]::Match($packageSource, '(?s)<InstallUISequence>(.*?)</InstallUISequence>').Groups[1].Value
Assert-True ($packageSource -match 'ConfigureScript') 'The MSI must install and launch the PowerShell configuration script.'
Assert-True ($packageSource -match 'NotificationScript') 'The MSI must contain the enterprise WeChat notification script.'
Assert-True ($packageSource -match 'TokenSummaryScript') 'The MSI must contain the token summary script.'
Assert-True ($packageSource -match 'HookMetadataScript') 'The MSI must contain the hook event metadata script.'
Assert-True ($installUISequence -match '<Custom Action="ConfigureProduct" After="ExecuteAction" Condition="[^"]*UILevel\s*&gt;=\s*4[^"]*"') 'The MSI must launch the configuration window from the interactive UI sequence after installation.'
Assert-True ($installUISequence -notmatch 'WIX_UPGRADE_DETECTED') 'An interactive upgrade must allow the user to configure the webhook.'
Assert-True ($installExecuteSequence -notmatch '<Custom Action="ConfigureProduct"') 'The MSI execute sequence must not launch the interactive configuration window.'
Assert-True ($packageSource -match '(?s)<CustomAction\s+Id="ConfigureProduct".*?Return="ignore"') 'Closing the configuration window must not make the completed MSI installation fail.'
Assert-True ($packageSource -notmatch 'NotifierExe|CodexWeComNotifier\.exe') 'The MSI must not install the old .NET executable.'
Assert-True ($buildSource -notmatch '(?i)dotnet build|net48|\.csproj|dotnet\.exe was not found') 'The MSI build must not require the .NET SDK or .NET Framework build output.'

Write-Output 'PASS: Windows PowerShell hook tests completed.'
