<#
.SYNOPSIS
    Generic OpenAI-compatible Chat Completions API backend for
    /external-review-auto. Covers any provider that implements the
    /v1/chat/completions schema: DeepSeek, MiniMax, Groq, Together,
    Mistral, OpenRouter, and many self-hosted endpoints.
.DESCRIPTION
    Provider is parameterized via ModelInfo:
      - api_base       : Full URL prefix, e.g. "https://api.deepseek.com/v1"
      - api_key_env    : Name of env var holding the API key
      - model_id       : Provider's model identifier
      - api_key_header : Optional, defaults to "Authorization" (with "Bearer " prefix)

    No process spawning. No TUI. No console pollution.

    Adapter signature mirrors backends/opencode.ps1.
#>

# The non-review detector is shared with every other adapter. A REST backend
# pastes the bundle into the request body, so "the bundle was not included,
# please paste it" is a routine failure here -- and it exits 200/OK, so nothing
# else catches it.
. (Join-Path $PSScriptRoot '_capture-validation.ps1')

function Invoke-OpenaicompatReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)][string]$ResponsePath,
        [Parameter(Mandatory)][hashtable]$ModelInfo,
        [int]$TimeoutSec = 600,
        [string]$AgyModelHint,        # ignored
        [string]$ModelOverride,       # honored
        [string]$OpencodeProvider     # ignored -- provider is in ModelInfo
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # --- Resolve provider config from ModelInfo ---
    $apiBase    = $ModelInfo.api_base
    $apiKeyEnv  = $ModelInfo.api_key_env
    $authHeader = if ($ModelInfo.api_key_header) { $ModelInfo.api_key_header } else { 'Authorization' }
    $modelId    = if ($ModelOverride) { $ModelOverride } else { $ModelInfo.model_id }

    if (-not $apiBase)   { throw "openaicompat backend requires ModelInfo.api_base (e.g. 'https://api.deepseek.com/v1')" }
    if (-not $apiKeyEnv) { throw "openaicompat backend requires ModelInfo.api_key_env (name of env var holding the key)" }

    $apiKey = [Environment]::GetEnvironmentVariable($apiKeyEnv)
    if (-not $apiKey) {
        throw "$apiKeyEnv env var not set. Provider URL: $apiBase"
    }

    # --- Build request body ---
    $promptText = Get-Content -Raw -LiteralPath $PromptPath -ErrorAction Stop
    $bundleText = Get-Content -Raw -LiteralPath $BundlePath -ErrorAction Stop
    $fullContent = "$promptText`n`n--- BUNDLE ($BundlePath) ---`n`n$bundleText"

    # Reasoning models can burn the budget thinking before emitting the answer;
    # allow per-preset override (default 8192).
    $maxTokens = if ($ModelInfo.max_tokens) { [int]$ModelInfo.max_tokens } else { 8192 }
    $body = @{
        model       = $modelId
        max_tokens  = $maxTokens
        temperature = 0.3
        messages    = @(
            @{ role = 'user'; content = $fullContent }
        )
    } | ConvertTo-Json -Depth 10 -Compress

    # --- Call the API ---
    $url = "$apiBase/chat/completions"
    $headers = @{ 'content-type' = 'application/json' }
    if ($authHeader -eq 'Authorization') {
        $headers['Authorization'] = "Bearer $apiKey"
    } else {
        $headers[$authHeader] = $apiKey
    }

    $warnings = @()
    $exitCode = 0
    $response = $null
    $inputTokens  = $null
    $outputTokens = $null
    $truncationWarning = $null
    $stderr = ''
    $detectorFired = $false

    try {
        $resp = Invoke-RestMethod -Uri $url -Method Post -Body $body -Headers $headers `
                                  -TimeoutSec $TimeoutSec -MaximumRetryCount 2 `
                                  -RetryIntervalSec 3 -ErrorAction Stop

        $choice = $resp.choices | Select-Object -First 1
        if (-not $choice) {
            throw "OpenAI-compat API returned no choices. Full: $($resp | ConvertTo-Json -Depth 5 -Compress)"
        }

        # Capture usage metrics
        if ($resp.usage) {
            $inputTokens  = $resp.usage.prompt_tokens
            $outputTokens = $resp.usage.completion_tokens
        }

        # Check for truncation
        if ($choice.finish_reason -eq 'length') {
            $truncationWarning = "Response hit max_tokens=$maxTokens; consider raising or tightening the prompt."
            $warnings += $truncationWarning
        } elseif ($choice.finish_reason -and $choice.finish_reason -ne 'stop') {
            $warnings += "Non-stop finish_reason: $($choice.finish_reason)"
        }

        $response = $choice.message.content
        # Reasoning models (e.g. DeepSeek) may leave content empty and put the
        # text in reasoning_content (or run out of tokens mid-think). Fall back so
        # the review is never silently blank.
        if (-not $response -and $choice.message.reasoning_content) {
            $response = $choice.message.reasoning_content
        }
        if (-not $response) {
            throw "OpenAI-compat API returned a choice with no content. finish_reason=$($choice.finish_reason)"
        }

        # Honest content validation. Deliberately BEFORE the truncation banner:
        # the banner adds ~180 characters, which would push a short non-answer
        # over the detector's 300-char length floor and defeat branch B2.
        if (Test-AgenticNarrationCapture -Response $response) {
            $detectorFired = $true
            $exitCode = -1
            $warnings += 'Provider returned a non-review (tool-intent narration / bundle-access refusal / sub-floor non-answer); detector fired — re-dispatch to retry.'
        }

        if ($truncationWarning) {
            $banner = @"
> [!WARNING]
> **Response was truncated at max_tokens.**
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
        throw "OpenAI-compat API call failed (provider=$apiBase, model=$modelId): $_"
    } finally {
        $sw.Stop()
    }

    return @{
        Response          = $response
        ExitCode          = $exitCode
        Error             = if ($detectorFired) { 'agentic-narration-capture' } else { $null }
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
