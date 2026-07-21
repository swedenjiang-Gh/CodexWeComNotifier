[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$WebhookReminder = '可以先建两个机器人，然后和机器人拉个群聊，然后点群聊右上方的三个点···，找到消息推送，点“添加”即可提取webhook地址。'
$HookTrustReminder = '在codex设置的钩子/hooks里可以找到新的hook，设置信任即可。'

function Get-CodexHomePath {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [IO.Path]::GetFullPath($env:CODEX_HOME)
    }

    Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.codex'
}

function Test-WeComWebhookFormat {
    param(
        [Parameter(Mandatory)]
        [string]$Webhook
    )

    $uri = $null
    if (-not [uri]::TryCreate($Webhook.Trim(), [UriKind]::Absolute, [ref]$uri)) {
        return $false
    }

    if ($uri.Scheme -ne 'https' -or
        $uri.Host -ne 'qyapi.weixin.qq.com' -or
        $uri.AbsolutePath -ne '/cgi-bin/webhook/send' -or
        (-not $uri.IsDefaultPort -and $uri.Port -ne 443) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        return $false
    }

    foreach ($part in $uri.Query.TrimStart('?').Split('&', [StringSplitOptions]::RemoveEmptyEntries)) {
        $pair = $part.Split('=', 2)
        if ($pair.Count -eq 2 -and $pair[0] -eq 'key' -and -not [string]::IsNullOrWhiteSpace([uri]::UnescapeDataString($pair[1]))) {
            return $true
        }
    }

    $false
}

function Save-WeComSecret {
    param(
        [Parameter(Mandatory)]
        [string]$Webhook,

        [Parameter(Mandatory)]
        [string]$SecretPath
    )

    $secretDirectory = Split-Path -Parent $SecretPath
    if (-not (Test-Path -LiteralPath $secretDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $secretDirectory | Out-Null
    }

    $secureWebhook = ConvertTo-SecureString -String $Webhook -AsPlainText -Force
    $encryptedWebhook = ConvertFrom-SecureString -SecureString $secureWebhook
    [IO.File]::WriteAllText($SecretPath, $encryptedWebhook, [Text.UTF8Encoding]::new($false))
}

function Get-WeComHookCommand {
    param(
        [Parameter(Mandatory)]
        [string]$NotificationScriptPath
    )

    'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $NotificationScriptPath + '"'
}

function Read-HooksRoot {
    param(
        [Parameter(Mandatory)]
        [string]$HooksPath
    )

    if (-not (Test-Path -LiteralPath $HooksPath -PathType Leaf)) {
        return [pscustomobject]@{}
    }

    $json = Get-Content -LiteralPath $HooksPath -Raw
    if ([string]::IsNullOrWhiteSpace($json)) {
        return [pscustomobject]@{}
    }

    $root = $json | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $root) {
        throw 'hooks.json root must be an object.'
    }
    $root
}

function Write-HooksRoot {
    param(
        [Parameter(Mandatory)]
        [string]$HooksPath,

        [Parameter(Mandatory)]
        [object]$Root
    )

    $directory = Split-Path -Parent $HooksPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $temporaryPath = $HooksPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    $backupPath = $HooksPath + '.bak-' + [guid]::NewGuid().ToString('N')
    try {
        $json = $Root | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $HooksPath -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $HooksPath, $backupPath)
        } else {
            [IO.File]::Move($temporaryPath, $HooksPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath
        }
    }
}

function Add-WeComStopHook {
    param(
        [Parameter(Mandatory)]
        [string]$HooksPath,

        [Parameter(Mandatory)]
        [string]$NotificationScriptPath
    )

    $root = Read-HooksRoot -HooksPath $HooksPath
    if ($null -eq $root.PSObject.Properties['hooks']) {
        $root | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
    }

    $hookCommand = Get-WeComHookCommand -NotificationScriptPath $NotificationScriptPath
    $stopGroups = @()
    if ($null -ne $root.hooks.PSObject.Properties['Stop']) {
        $stopGroups = @($root.hooks.Stop)
    }

    foreach ($group in $stopGroups) {
        foreach ($hook in @($group.hooks)) {
            if ([string]$hook.command -eq $hookCommand) {
                return
            }
        }
    }

    $stopGroups += [pscustomobject]@{
        hooks = @(
            [pscustomobject]@{
                type = 'command'
                command = $hookCommand
                timeout = 15
                statusMessage = 'Sending enterprise WeChat notification'
            }
        )
    }

    if ($null -eq $root.hooks.PSObject.Properties['Stop']) {
        $root.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue $stopGroups
    } else {
        $root.hooks.Stop = $stopGroups
    }

    Write-HooksRoot -HooksPath $HooksPath -Root $root
}

function Remove-WeComStopHook {
    param(
        [Parameter(Mandatory)]
        [string]$HooksPath,

        [Parameter(Mandatory)]
        [string]$NotificationScriptPath
    )

    if (-not (Test-Path -LiteralPath $HooksPath -PathType Leaf)) {
        return
    }

    $root = Read-HooksRoot -HooksPath $HooksPath
    if ($null -eq $root.PSObject.Properties['hooks'] -or $null -eq $root.hooks.PSObject.Properties['Stop']) {
        return
    }

    $hookCommand = Get-WeComHookCommand -NotificationScriptPath $NotificationScriptPath
    $remainingGroups = @()
    foreach ($group in @($root.hooks.Stop)) {
        $remainingHooks = @($group.hooks | Where-Object { [string]$_.command -ne $hookCommand })
        if ($remainingHooks.Count -gt 0) {
            $group.hooks = $remainingHooks
            $remainingGroups += $group
        }
    }

    if ($remainingGroups.Count -eq 0) {
        $root.hooks.PSObject.Properties.Remove('Stop')
    } else {
        $root.hooks.Stop = $remainingGroups
    }

    Write-HooksRoot -HooksPath $HooksPath -Root $root
}

function Install-WeComNotificationScript {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $destinationDirectory = Split-Path -Parent $DestinationPath
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDirectory | Out-Null
    }
    if ([IO.Path]::GetFullPath($SourcePath) -eq [IO.Path]::GetFullPath($DestinationPath)) {
        return
    }
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
}

function Send-WeComTestMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Webhook
    )

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $payload = @{
        msgtype = 'text'
        text = @{
            content = "Codex 企业微信通知配置成功`n时间：$timestamp"
        }
    } | ConvertTo-Json -Depth 3

    $response = Invoke-RestMethod -Uri $Webhook -Method Post -Body $payload -ContentType 'application/json; charset=utf-8' -TimeoutSec 10
    if ([int]$response.errcode -ne 0) {
        throw "Enterprise WeChat rejected the test with errcode $($response.errcode)."
    }
}

function Show-WeComConfiguration {
    $codexHome = Get-CodexHomePath
    $hookDirectory = Join-Path $codexHome 'hooks'
    $notificationSource = Join-Path $PSScriptRoot 'notify-wecom.ps1'
    $notificationTarget = Join-Path $hookDirectory 'notify-wecom.ps1'
    $secretPath = Join-Path $hookDirectory 'wecom-webhook.dpapi'
    $hooksPath = Join-Path $codexHome 'hooks.json'

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object Windows.Forms.Form
    $form.Text = 'Codex 企业微信通知配置'
    $form.ClientSize = New-Object Drawing.Size(680, 320)
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

    $stepsLabel = New-Object Windows.Forms.Label
    $stepsLabel.Location = New-Object Drawing.Point(24, 20)
    $stepsLabel.Size = New-Object Drawing.Size(632, 64)
    $stepsLabel.Text = $WebhookReminder

    $inputLabel = New-Object Windows.Forms.Label
    $inputLabel.AutoSize = $true
    $inputLabel.Location = New-Object Drawing.Point(24, 94)
    $inputLabel.Text = '企业微信 Webhook 地址：'

    $webhookTextBox = New-Object Windows.Forms.TextBox
    $webhookTextBox.Location = New-Object Drawing.Point(24, 120)
    $webhookTextBox.Size = New-Object Drawing.Size(632, 27)
    $webhookTextBox.UseSystemPasswordChar = $true

    $showAddress = New-Object Windows.Forms.CheckBox
    $showAddress.AutoSize = $true
    $showAddress.Location = New-Object Drawing.Point(24, 158)
    $showAddress.Text = '显示地址'
    $showAddress.Add_CheckedChanged({
        $webhookTextBox.UseSystemPasswordChar = -not $showAddress.Checked
    })

    $statusLabel = New-Object Windows.Forms.Label
    $statusLabel.Location = New-Object Drawing.Point(24, 190)
    $statusLabel.Size = New-Object Drawing.Size(470, 48)
    $statusLabel.ForeColor = [Drawing.Color]::DimGray
    $statusLabel.Text = '请粘贴完整 Webhook 地址。'

    $saveButton = New-Object Windows.Forms.Button
    $saveButton.Location = New-Object Drawing.Point(516, 188)
    $saveButton.Size = New-Object Drawing.Size(140, 38)
    $saveButton.Text = '测试并保存'
    $saveButton.Add_Click({
        $webhook = $webhookTextBox.Text.Trim()
        if (-not (Test-WeComWebhookFormat -Webhook $webhook)) {
            $statusLabel.ForeColor = [Drawing.Color]::Firebrick
            $statusLabel.Text = '地址格式不正确，请粘贴完整的企业微信群机器人 Webhook。'
            return
        }

        $saveButton.Enabled = $false
        $webhookTextBox.Enabled = $false
        $statusLabel.ForeColor = [Drawing.Color]::DimGray
        $statusLabel.Text = '正在发送测试消息……'
        $form.Refresh()

        try {
            Send-WeComTestMessage -Webhook $webhook
            Install-WeComNotificationScript -SourcePath $notificationSource -DestinationPath $notificationTarget
            Save-WeComSecret -Webhook $webhook -SecretPath $secretPath
            Add-WeComStopHook -HooksPath $hooksPath -NotificationScriptPath $notificationTarget
            $statusLabel.ForeColor = [Drawing.Color]::DarkGreen
            $statusLabel.Text = '配置成功。'
            [Windows.Forms.MessageBox]::Show(
                "$HookTrustReminder`n`n请重启 Codex，使新 Hook 在新任务中生效。",
                '配置成功',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            $form.DialogResult = [Windows.Forms.DialogResult]::OK
            $form.Close()
        } catch {
            $statusLabel.ForeColor = [Drawing.Color]::Firebrick
            $statusLabel.Text = '配置失败。请检查网络、Webhook 是否有效以及 Codex 配置文件权限。'
            $saveButton.Enabled = $true
            $webhookTextBox.Enabled = $true
        }
    })

    $privacyLabel = New-Object Windows.Forms.Label
    $privacyLabel.Location = New-Object Drawing.Point(24, 252)
    $privacyLabel.Size = New-Object Drawing.Size(632, 44)
    $privacyLabel.ForeColor = [Drawing.Color]::DimGray
    $privacyLabel.Text = 'Webhook 只会在本机使用 Windows DPAPI 加密保存，不会写入安装包或日志。'

    $form.Controls.AddRange(@($stepsLabel, $inputLabel, $webhookTextBox, $showAddress, $statusLabel, $saveButton, $privacyLabel))
    $form.AcceptButton = $saveButton
    $result = $form.ShowDialog()
    $form.Dispose()
    if ($result -eq [Windows.Forms.DialogResult]::OK) { return 0 }
    1
}

function Uninstall-WeComConfiguration {
    $codexHome = Get-CodexHomePath
    $hookDirectory = Join-Path $codexHome 'hooks'
    $notificationTarget = Join-Path $hookDirectory 'notify-wecom.ps1'
    $secretPath = Join-Path $hookDirectory 'wecom-webhook.dpapi'
    $hooksPath = Join-Path $codexHome 'hooks.json'

    Remove-WeComStopHook -HooksPath $hooksPath -NotificationScriptPath $notificationTarget
    if (Test-Path -LiteralPath $secretPath -PathType Leaf) {
        Remove-Item -LiteralPath $secretPath
    }
    if (Test-Path -LiteralPath $notificationTarget -PathType Leaf) {
        Remove-Item -LiteralPath $notificationTarget
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Uninstall) {
        try { Uninstall-WeComConfiguration } catch { }
        exit 0
    }

    exit (Show-WeComConfiguration)
}
