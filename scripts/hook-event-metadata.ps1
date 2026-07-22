function ConvertFrom-CodexHookEventMetadata {
    param(
        [AllowEmptyString()]
        [string]$EventJson
    )

    if ([string]::IsNullOrWhiteSpace($EventJson)) {
        throw 'Hook event JSON is empty.'
    }

    try {
        $event = $EventJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $marker = [regex]::Match($EventJson, ',\s*"last_assistant_message"\s*:')
        if (-not $marker.Success) { throw }

        $prefix = $EventJson.Substring(0, $marker.Index)
        $values = @{}
        foreach ($name in @('cwd', 'session_id', 'turn_id', 'transcript_path', 'hook_event_name')) {
            $pattern = '(?:^|[,{])\s*"' + [regex]::Escape($name) + '"\s*:\s*("(?:\\.|[^"\\])*")'
            $match = [regex]::Match($prefix, $pattern)
            if ($match.Success) {
                $values[$name] = [string]($match.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop)
            }
        }
        $event = [pscustomobject]$values
    }

    foreach ($required in @('session_id', 'turn_id', 'transcript_path')) {
        if ([string]::IsNullOrWhiteSpace([string]$event.$required)) {
            throw "Hook event is missing $required."
        }
    }

    [pscustomobject][ordered]@{
        cwd             = [string]$event.cwd
        session_id      = [string]$event.session_id
        turn_id         = [string]$event.turn_id
        transcript_path = [string]$event.transcript_path
        hook_event_name = [string]$event.hook_event_name
    }
}
