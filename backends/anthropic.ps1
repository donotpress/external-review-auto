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

# The non-review detector is shared with every other adapter. A REST backend
# pastes the bundle into the request body, so "the bundle was not included,
# please paste it" is a routine failure here -- and it exits 200/OK, so nothing
# else catches it.
. (Join-Path $PSScriptRoot '_capture-validation.ps1')

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
    $promptText = Get-Content -Raw -LiteralPath $PromptPath -ErrorAction Stop
    $bundleText = Get-Content -Raw -LiteralPath $BundlePath -ErrorAction Stop
    $fullContent = "$promptText`n`n--- BUNDLE ($BundlePath) ---`n`n$bundleText"

    # Capability from the registry, falling back to the value this adapter used
    # to hardcode. Raising a cap is now a config edit, not a code edit.
    $maxTokens = if ($ModelInfo.max_tokens) { [int]$ModelInfo.max_tokens } else { 8192 }

    $body = @{
        model      = $modelId
        max_tokens = $maxTokens
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
    $detectorFired = $false
    $captureError = $null

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
            $truncationWarning = "Response hit max_tokens=$maxTokens; consider raising max_tokens for this preset in backends/_registry.json or tightening the prompt."
            $warnings += $truncationWarning
        } elseif ($resp.stop_reason -and $resp.stop_reason -notin @('end_turn','stop_sequence')) {
            $warnings += "Unusual stop_reason: $($resp.stop_reason)"
        }

        # Concatenate all text content blocks (Claude can return multi-block responses)
        $response = ($resp.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ''
        if (-not $response) {
            throw "Anthropic API returned no text content. stop_reason=$($resp.stop_reason). Full: $($resp | ConvertTo-Json -Depth 5 -Compress)"
        }

        # Honest content validation. Deliberately BEFORE the truncation banner:
        # the banner adds ~190 characters, which would push a short non-answer
        # over the detector's 300-char length floor and defeat branch B2.
        if (Test-AgenticNarrationCapture -Response $response) {
            $detectorFired = $true
            $captureError = 'agentic-narration-capture'
            $exitCode = -1
            $warnings += 'Claude returned a non-review (tool-intent narration / bundle-access refusal / sub-floor non-answer); detector fired — re-dispatch to retry.'
        } elseif (Test-EraPromptEcho -PromptPath $PromptPath -Response $response) {
            # A well-formed-looking answer that is just the prompt handed back.
            # The narration detector cannot catch it: all of its branches are
            # gated on the response having no markdown heading, and an era
            # prompt is full of them.
            $detectorFired = $true
            $captureError = 'prompt-echo'
            $exitCode = -1
            $warnings += 'Claude returned the prompt echoed back rather than a review (prompt-echo detector fired); re-dispatch to retry.'
        }

        if ($truncationWarning) {
            $banner = @"
> [!WARNING]
> **Claude response was truncated at max_tokens.**
> The text below is incomplete. Re-run with a tighter prompt or raise max_tokens.

"@
            $response = $banner + $response
        }

        # A non-review is not written to disk, matching agy and opencode, so it
        # cannot be picked up by the round-N-*-response.md glob that builds the
        # next round's {{PREVIOUS_ROUND}} context.
        if (-not $detectorFired) {
            $response | Set-Content -LiteralPath $ResponsePath -Encoding utf8
        }
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
        Error             = $captureError
        ContentOk         = ($exitCode -eq 0)
        CaptureMethod     = 'rest-api'
        InputTokens       = $inputTokens
        OutputTokens      = $outputTokens
        WallClockSec      = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        TruncationWarning = $truncationWarning
        Stderr            = $stderr
        Warnings          = $warnings
    }
}
