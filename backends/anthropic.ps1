<#
.SYNOPSIS
    Direct Anthropic Messages API backend for /external-review-auto.
.DESCRIPTION
    Replaces the `claude --print` CLI with a single Invoke-RestMethod call to
    https://api.anthropic.com/v1/messages. No process spawning, no TUI, no
    console state pollution, no ANSI codes to strip out of the response.

    Required: $env:ANTHROPIC_API_KEY (get one at https://console.anthropic.com/).

    Adapter signature mirrors backends/claude.ps1 so workflow.ps1's dispatcher
    needs no changes.
#>

function Invoke-AnthropicReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)][string]$ResponsePath,
        [Parameter(Mandatory)][hashtable]$ModelInfo,
        [int]$TimeoutSec = 600,
        [string]$AgyModelHint,        # ignored
        [string]$ModelOverride,       # honored if model_id needs override
        [string]$OpencodeProvider     # ignored
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # --- Resolve API key ---
    $apiKey = $env:ANTHROPIC_API_KEY
    if (-not $apiKey) {
        throw "ANTHROPIC_API_KEY env var not set. Get a key at https://console.anthropic.com/, then set: `$env:ANTHROPIC_API_KEY = '...'"
    }

    # --- Resolve model ID ---
    $modelId = if ($ModelOverride) { $ModelOverride } else { $ModelInfo.model_id }

    # --- Build request body ---
    # Anthropic expects: { model, max_tokens, messages: [{role:"user", content:"..."}] }
    # We concatenate prompt + bundle as a single user message.
    $promptText = Get-Content -Raw $PromptPath -ErrorAction Stop
    $bundleText = Get-Content -Raw $BundlePath -ErrorAction Stop
    $fullContent = "$promptText`n`n--- BUNDLE ($BundlePath) ---`n`n$bundleText"

    $body = @{
        model      = $modelId
        max_tokens = 8192
        messages   = @(
            @{ role = 'user'; content = $fullContent }
        )
    } | ConvertTo-Json -Depth 10 -Compress

    # --- Call the API ---
    $url = 'https://api.anthropic.com/v1/messages'
    $headers = @{
        'x-api-key'         = $apiKey
        'anthropic-version' = '2023-06-01'
        'content-type'      = 'application/json'
    }

    $warnings = @()
    $exitCode = 0
    $response = $null
    $inputTokens  = $null
    $outputTokens = $null
    $truncationWarning = $null
    $stderr = ''

    try {
        $resp = Invoke-RestMethod -Uri $url -Method Post -Body $body -Headers $headers `
                                  -TimeoutSec $TimeoutSec -MaximumRetryCount 2 `
                                  -RetryIntervalSec 3 -ErrorAction Stop

        # Capture real usage metrics
        if ($resp.usage) {
            $inputTokens  = $resp.usage.input_tokens
            $outputTokens = $resp.usage.output_tokens
        }

        # Check for truncation
        if ($resp.stop_reason -eq 'max_tokens') {
            $truncationWarning = "Response hit max_tokens=8192; consider raising or tightening the prompt."
            $warnings += $truncationWarning
        } elseif ($resp.stop_reason -and $resp.stop_reason -notin @('end_turn','stop_sequence')) {
            $warnings += "Unusual stop_reason: $($resp.stop_reason)"
        }

        # Concatenate all text content blocks (Claude can return multi-block responses)
        $response = ($resp.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ''
        if (-not $response) {
            throw "Anthropic API returned no text content. stop_reason=$($resp.stop_reason). Full: $($resp | ConvertTo-Json -Depth 5 -Compress)"
        }

        if ($truncationWarning) {
            $banner = @"
> [!WARNING]
> **Claude response was truncated at max_tokens.**
> The text below is incomplete. Re-run with a tighter prompt or raise max_tokens.

"@
            $response = $banner + $response
        }

        $response | Set-Content -Path $ResponsePath -Encoding utf8
    } catch {
        $exitCode = -1
        $stderr = "$_"
        throw "Anthropic API call failed (model=$modelId): $_"
    } finally {
        $sw.Stop()
    }

    return @{
        Response          = $response
        ExitCode          = $exitCode
        CaptureMethod     = 'rest-api'
        InputTokens       = $inputTokens
        OutputTokens      = $outputTokens
        WallClockSec      = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        TruncationWarning = $truncationWarning
        Stderr            = $stderr
        Warnings          = $warnings
    }
}
