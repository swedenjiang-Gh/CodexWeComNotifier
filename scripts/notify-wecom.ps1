[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Security

function Get-WeComSecret {
    param(
        [Parameter(Mandatory)]
        [string]$SecretPath
    )

    $encryptedValue = (Get-Content -LiteralPath $SecretPath -Raw).Trim()
    if ($encryptedValue.Length % 2 -ne 0 -or $encryptedValue -notmatch '^[0-9a-fA-F]+$') {
        throw 'The DPAPI secret has an invalid format.'
    }

    $protectedBytes = New-Object byte[] ($encryptedValue.Length / 2)
    for ($index = 0; $index -lt $protectedBytes.Length; $index++) {
        $protectedBytes[$index] = [Convert]::ToByte($encryptedValue.Substring($index * 2, 2), 16)
    }

    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    try {
        [Text.Encoding]::Unicode.GetString($plainBytes)
    } finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Get-WeComWorkspace {
    param(
        [AllowEmptyString()]
        [string]$EventJson
    )

    $currentPath = (Get-Location).Path
    $workspace = Split-Path -Leaf $currentPath
    if ([string]::IsNullOrWhiteSpace($workspace)) {
        $workspace = $currentPath
    }

    if ([string]::IsNullOrWhiteSpace($EventJson)) {
        return $workspace
    }

    try {
        $eventData = $EventJson | ConvertFrom-Json -ErrorAction Stop
        $eventPath = [string]$eventData.cwd
        if (-not [string]::IsNullOrWhiteSpace($eventPath)) {
            $eventWorkspace = Split-Path -Leaf $eventPath -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($eventWorkspace)) {
                return $eventPath
            }
            return $eventWorkspace
        }
    } catch {
    }

    $workspace
}

function New-WeComNotificationBody {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,

        [Parameter(Mandatory)]
        [string]$Timestamp,

        [AllowEmptyString()]
        [string]$TokenSummaryText
    )

    if ([string]::IsNullOrWhiteSpace($TokenSummaryText)) {
        $TokenSummaryText = 'Token 统计暂不可用'
    }

    "Codex 任务轮次已结束`n工作区：$Workspace`n时间：$Timestamp`n`n$TokenSummaryText"
}

function Get-WeComTokenSummary {
    param(
        [AllowEmptyString()]
        [string]$EventJson
    )

    if ([string]::IsNullOrWhiteSpace($EventJson)) {
        return $null
    }

    $summaryScript = Join-Path $PSScriptRoot 'task-token-summary.ps1'
    if (-not (Test-Path -LiteralPath $summaryScript -PathType Leaf)) {
        return $null
    }

    try {
        $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $summaryOutput = @($EventJson | & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $summaryScript)
        if ($LASTEXITCODE -ne 0 -or $summaryOutput.Count -eq 0) {
            return $null
        }

        $summaryJson = $summaryOutput -join [Environment]::NewLine
        $summary = $summaryJson | ConvertFrom-Json -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$summary.systemMessage)) {
            return $null
        }

        [pscustomobject]@{
            Json = $summaryJson
            Text = [string]$summary.systemMessage
        }
    } catch {
        $null
    }
}

function Send-WeComNotification {
    param(
        [Parameter(Mandatory)]
        [string]$Webhook,

        [Parameter(Mandatory)]
        [string]$Body
    )

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $payload = @{
        msgtype = 'text'
        text = @{
            content = $Body
        }
    } | ConvertTo-Json -Depth 3

    $response = Invoke-RestMethod -Uri $Webhook -Method Post -Body $payload -ContentType 'application/json; charset=utf-8' -TimeoutSec 8
    if ([int]$response.errcode -ne 0) {
        throw "Enterprise WeChat rejected the message with errcode $($response.errcode)."
    }
}

function Invoke-WeComStopHook {
    param(
        [AllowEmptyString()]
        [string]$EventJson
    )

    $secretPath = Join-Path $PSScriptRoot 'wecom-webhook.dpapi'
    if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
        return
    }

    $tokenSummary = Get-WeComTokenSummary -EventJson $EventJson
    $summaryText = if ($null -ne $tokenSummary) { $tokenSummary.Text } else { '' }
    $workspace = Get-WeComWorkspace -EventJson $EventJson
    $body = New-WeComNotificationBody -Workspace $workspace -Timestamp (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -TokenSummaryText $summaryText
    $webhook = Get-WeComSecret -SecretPath $secretPath
    Send-WeComNotification -Webhook $webhook -Body $body
    if ($null -ne $tokenSummary) {
        $tokenSummary.Json
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-WeComStopHook -EventJson ([Console]::In.ReadToEnd())
    } catch {
    }
    exit 0
}
