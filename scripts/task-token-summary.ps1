$ErrorActionPreference = 'Stop'
$internalErrorPath = Join-Path $PSScriptRoot 'task-token-summary-internal-error.log'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
trap {
    try {
        $position = ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' ')
        Set-Content -LiteralPath $internalErrorPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $($_.Exception.Message) $position" -Encoding utf8
    } catch {
    }
    exit 1
}

. (Join-Path $PSScriptRoot 'hook-event-metadata.ps1')
$rawHookEvent = [Console]::In.ReadToEnd()
$hook = ConvertFrom-CodexHookEventMetadata -EventJson $rawHookEvent
if (-not $hook.transcript_path -or -not (Test-Path -LiteralPath $hook.transcript_path)) { exit 0 }

$eventTypePattern = '"type"\s*:\s*"(?:task_started|task_complete|token_count|sub_agent_activity)"'
$relevantEventTypes = @('task_started', 'task_complete', 'token_count', 'sub_agent_activity')
$entries = [Collections.Generic.List[object]]::new()
$relevantLines = @(Get-Content -LiteralPath $hook.transcript_path | Where-Object { $_ -match $eventTypePattern })
foreach ($line in $relevantLines) {
    try { $entry = $line | ConvertFrom-Json } catch { continue }
    if ($entry.type -ne 'event_msg' -or $entry.payload.type -notin $relevantEventTypes) { continue }
    $entries.Add($entry)
}

$sessionEvents = @($entries | Where-Object { $_.type -eq 'event_msg' -and $_.payload.type -eq 'token_count' })
if ($sessionEvents.Count -eq 0) { exit 0 }

$openTaskStartIndex = -1
$openTurnIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$matchingTurnStartIndex = -1
$matchingTurnEndIndex = -1
$lastTaskStartIndex = -1
$lastTaskEndIndex = -1
for ($i = 0; $i -lt $entries.Count; $i++) {
    $entry = $entries[$i]
    if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'task_started') {
        $lastTaskStartIndex = $i
        if ($openTaskStartIndex -lt 0) {
            $openTaskStartIndex = $i
            $openTurnIds.Clear()
        }
        if ($entry.payload.turn_id) { $null = $openTurnIds.Add([string]$entry.payload.turn_id) }
    }
    elseif ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'task_complete') {
        if ($openTaskStartIndex -ge 0) {
            $lastTaskStartIndex = $openTaskStartIndex
            $lastTaskEndIndex = $i
            if ($hook.turn_id -and $openTurnIds.Contains([string]$hook.turn_id)) {
                $matchingTurnStartIndex = $openTaskStartIndex
                $matchingTurnEndIndex = $i
            }
        }
        $openTaskStartIndex = -1
        $openTurnIds.Clear()
    }
}
$hookMatchesOpenTask = $hook.turn_id -and $openTaskStartIndex -ge 0 -and $openTurnIds.Contains([string]$hook.turn_id)
if ($hookMatchesOpenTask) {
    $turnStartIndex = $openTaskStartIndex
    $turnEndIndex = $entries.Count - 1
}
elseif ($matchingTurnStartIndex -ge 0) {
    $turnStartIndex = $matchingTurnStartIndex
    $turnEndIndex = $matchingTurnEndIndex
}
elseif ($openTaskStartIndex -ge 0) {
    $turnStartIndex = $openTaskStartIndex
    $turnEndIndex = $entries.Count - 1
}
else {
    $turnStartIndex = $lastTaskStartIndex
    $turnEndIndex = if ($lastTaskEndIndex -ge 0) { $lastTaskEndIndex } else { $entries.Count - 1 }
}
$turnEntries = if ($turnStartIndex -ge 0) { $entries[$turnStartIndex..$turnEndIndex] } else { $entries }
$events = @($turnEntries | Where-Object { $_.type -eq 'event_msg' -and $_.payload.type -eq 'token_count' })
if ($events.Count -eq 0) { exit 0 }

$priorMainUsage = $null
if ($turnStartIndex -gt 0) {
    for ($i = $turnStartIndex - 1; $i -ge 0; $i--) {
        $entry = $entries[$i]
        if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'token_count') {
            $priorMainUsage = $entry.payload.info.total_token_usage
            break
        }
    }
}

$latest = $events[-1]
$latestTotalUsage = $latest.payload.info.total_token_usage
$priorInputTokens = if ($priorMainUsage) { [int64]$priorMainUsage.input_tokens } else { [int64]0 }
$priorCachedInputTokens = if ($priorMainUsage) { [int64]$priorMainUsage.cached_input_tokens } else { [int64]0 }
$priorOutputTokens = if ($priorMainUsage) { [int64]$priorMainUsage.output_tokens } else { [int64]0 }
$priorTotalTokens = if ($priorMainUsage) { [int64]$priorMainUsage.total_tokens } else { [int64]0 }
$inputTokens = [int64]$latestTotalUsage.input_tokens - $priorInputTokens
$cachedInputTokens = [int64]$latestTotalUsage.cached_input_tokens - $priorCachedInputTokens
$outputTokens = [int64]$latestTotalUsage.output_tokens - $priorOutputTokens
$totalTokens = [int64]$latestTotalUsage.total_tokens - $priorTotalTokens
$mainCalls = 0
$previousMainTotal = $priorTotalTokens
foreach ($event in $events) {
    $currentMainTotal = [int64]$event.payload.info.total_token_usage.total_tokens
    if ($currentMainTotal -gt $previousMainTotal) {
        $mainCalls++
    }
    $previousMainTotal = $currentMainTotal
}

$latestUsage = $latest.payload.info.last_token_usage
$contextWindow = [int64]$latest.payload.info.model_context_window
$contextPercent = if ($contextWindow) { [double]$latestUsage.total_tokens / $contextWindow * 100 } else { 0 }
$turnStartTimestamp = if ($turnStartIndex -ge 0) { $entries[$turnStartIndex].timestamp } else { $events[0].timestamp }
$turnStart = [datetimeoffset]$turnStartTimestamp
$turnEnd = if ($matchingTurnEndIndex -ge 0 -and $turnEndIndex -eq $matchingTurnEndIndex) { [datetimeoffset]$entries[$turnEndIndex].timestamp } else { [datetimeoffset]::UtcNow }
$latestActivity = [datetimeoffset]$latest.timestamp

$childInputTokens = [int64]0
$childCachedInputTokens = [int64]0
$childOutputTokens = [int64]0
$childTotalTokens = [int64]0
$childCalls = 0
$childAgentCount = 0
$sessionChildTotalTokens = [int64]0
$transcriptPath = [IO.Path]::GetFullPath([string]$hook.transcript_path)
$sessionsMarker = [IO.Path]::DirectorySeparatorChar + 'sessions' + [IO.Path]::DirectorySeparatorChar
$sessionsIndex = $transcriptPath.IndexOf($sessionsMarker, [StringComparison]::OrdinalIgnoreCase)
if ($sessionsIndex -gt 0) {
    $sessionsRoot = $transcriptPath.Substring(0, $sessionsIndex + $sessionsMarker.Length - 1)
    $fileByThreadId = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in Get-ChildItem -LiteralPath $sessionsRoot -Recurse -Filter '*.jsonl' -File) {
        if ($file.Name -match '(?i)([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\.jsonl$') {
            $fileByThreadId[$Matches[1]] = $file.FullName
        }
    }

    $pendingChildIds = [Collections.Generic.Queue[string]]::new()
    $seenChildIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'sub_agent_activity' -and $entry.payload.agent_thread_id) {
            $childId = [string]$entry.payload.agent_thread_id
            if ($seenChildIds.Add($childId)) { $pendingChildIds.Enqueue($childId) }
        }
    }

    while ($pendingChildIds.Count -gt 0) {
        $childId = $pendingChildIds.Dequeue()
        if (-not $fileByThreadId.ContainsKey($childId)) { continue }

        $childPath = $fileByThreadId[$childId]
        if ($childPath -eq $transcriptPath) { continue }
        try { $childLines = @(Get-Content -LiteralPath $childPath) } catch { continue }
        if ($childLines.Count -eq 0) { continue }

        try { $meta = $childLines[0] | ConvertFrom-Json } catch { continue }
        if ($meta.payload.thread_source -ne 'subagent' -or $meta.payload.session_id -ne $hook.session_id) { continue }

        $childEntries = [Collections.Generic.List[object]]::new()
        foreach ($line in $childLines) {
            if ($line -notmatch $eventTypePattern) { continue }
            try { $childEntry = $line | ConvertFrom-Json } catch { continue }
            if ($childEntry.type -ne 'event_msg' -or $childEntry.payload.type -notin @('token_count', 'sub_agent_activity')) { continue }
            $childEntries.Add($childEntry)
        }
        if ($childEntries.Count -eq 0) { continue }

        foreach ($childEntry in $childEntries) {
            if ($childEntry.type -eq 'event_msg' -and $childEntry.payload.type -eq 'sub_agent_activity' -and $childEntry.payload.agent_thread_id) {
                $nestedId = [string]$childEntry.payload.agent_thread_id
                if ($seenChildIds.Add($nestedId)) { $pendingChildIds.Enqueue($nestedId) }
            }
        }

        $childPriorUsage = $null
        $childLatestUsage = $null
        $previousChildTotal = [int64]0
        $fileChildCalls = 0
        $childLatestActivity = $null
        foreach ($entry in $childEntries) {
            $entryTimestamp = [datetimeoffset]$entry.timestamp
            if ($entry.type -ne 'event_msg' -or $entry.payload.type -ne 'token_count' -or $entryTimestamp -gt $turnEnd) { continue }
            $usage = $entry.payload.info.total_token_usage
            $childLatestUsage = $usage
            if ($entryTimestamp -lt $turnStart) {
                $childPriorUsage = $usage
                $previousChildTotal = [int64]$usage.total_tokens
                continue
            }
            $currentChildTotal = [int64]$usage.total_tokens
            if ($currentChildTotal -gt $previousChildTotal) {
                $fileChildCalls++
            }
            $previousChildTotal = $currentChildTotal
            $childLatestActivity = $entryTimestamp
        }
        if (-not $childLatestUsage) { continue }

        $sessionChildTotalTokens += [int64]$childLatestUsage.total_tokens
        $childPriorInputTokens = if ($childPriorUsage) { [int64]$childPriorUsage.input_tokens } else { [int64]0 }
        $childPriorCachedInputTokens = if ($childPriorUsage) { [int64]$childPriorUsage.cached_input_tokens } else { [int64]0 }
        $childPriorOutputTokens = if ($childPriorUsage) { [int64]$childPriorUsage.output_tokens } else { [int64]0 }
        $childPriorTotalTokens = if ($childPriorUsage) { [int64]$childPriorUsage.total_tokens } else { [int64]0 }
        $fileChildTotalTokens = [int64]$childLatestUsage.total_tokens - $childPriorTotalTokens
        if ($fileChildTotalTokens -gt 0) {
            $childInputTokens += [int64]$childLatestUsage.input_tokens - $childPriorInputTokens
            $childCachedInputTokens += [int64]$childLatestUsage.cached_input_tokens - $childPriorCachedInputTokens
            $childOutputTokens += [int64]$childLatestUsage.output_tokens - $childPriorOutputTokens
            $childTotalTokens += $fileChildTotalTokens
            $childCalls += $fileChildCalls
            $childAgentCount++
            if ($childLatestActivity -and $childLatestActivity -gt $latestActivity) { $latestActivity = $childLatestActivity }
        }
    }
}

$combinedInputTokens = $inputTokens + $childInputTokens
$combinedCachedInputTokens = $cachedInputTokens + $childCachedInputTokens
$combinedOutputTokens = $outputTokens + $childOutputTokens
$combinedTotalTokens = $totalTokens + $childTotalTokens
$combinedCalls = $mainCalls + $childCalls
$sessionMainTotalTokens = [int64]$latestTotalUsage.total_tokens
$sessionTotalTokens = $sessionMainTotalTokens + $sessionChildTotalTokens
$cacheHitRate = if ($combinedInputTokens) { [double]$combinedCachedInputTokens / $combinedInputTokens * 100 } else { 0 }
$duration = ($latestActivity - $turnStart).TotalMinutes
$culture = [Globalization.CultureInfo]::InvariantCulture
$message = '本轮任务总消耗（含子 Agent）：{0} · 输入 {1} · 输出 {2} · 缓存读取 {3} · 缓存命中率 {4:N1}% · 主任务 {5} · 子 Agent {6}（{7} 个） · 模型调用 {8} 次 · 主任务上下文 {9}/{10} ({11:N1}%) · 当前会话总消耗（含子 Agent）{12}（主 Agent {13} + 子 Agent {14}） · 本轮耗时 {15:N1}min' -f `
    $combinedTotalTokens.ToString('N0', $culture), $combinedInputTokens.ToString('N0', $culture), $combinedOutputTokens.ToString('N0', $culture), $combinedCachedInputTokens.ToString('N0', $culture), `
    $cacheHitRate, $totalTokens.ToString('N0', $culture), $childTotalTokens.ToString('N0', $culture), $childAgentCount, $combinedCalls, `
    ([int64]$latestUsage.total_tokens).ToString('N0', $culture), $contextWindow.ToString('N0', $culture), $contextPercent, $sessionTotalTokens.ToString('N0', $culture), `
    $sessionMainTotalTokens.ToString('N0', $culture), $sessionChildTotalTokens.ToString('N0', $culture), $duration

@{ continue = $true; systemMessage = $message } | ConvertTo-Json -Compress
