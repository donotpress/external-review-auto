<#
.SYNOPSIS
    Direct Gemini REST API backend for /external-review-auto.
.DESCRIPTION
    Replaces the agy CLI with a single Invoke-RestMethod call to Google's
    generativelanguage.googleapis.com endpoint. No process spawning, no TTY,
    no transcript polling, no console state pollution.

    Required: $env:GEMINI_API_KEY (get one free at https://aistudio.google.com/apikey).

    Adapter signature mirrors backends/agy.ps1 (BundlePath, PromptPath,
    ResponsePath, ModelInfo, TimeoutSec, plus the ignored cross-backend
    params AgyModelHint / ModelOverride / OpencodeProvider) so the existing
    dispatcher (workflow.ps1::Invoke-ReviewerDispatch) needs no changes.
#>

function Invoke-GeminiapiReview {
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
    $apiKey = $env:GEMINI_API_KEY
    if (-not $apiKey) {
        throw "GEMINI_API_KEY env var not set. Get a free key at https://aistudio.google.com/apikey, then set: `$env:GEMINI_API_KEY = '...'"
    }

    # --- Resolve model ID ---
    # ModelInfo.model_id comes from registry (e.g. 'gemini-3.5-flash-high'),
    # but the public REST API uses bare model IDs without tier suffixes.
    # Map: <family>-<tier> → <family>. Honor explicit ModelOverride if provided.
    $modelId = if ($ModelOverride) { $ModelOverride } else { $ModelInfo.model_id }
    # Strip tier suffixes ('-high', '-medium', '-low') -- these are agy concepts
    $modelId = $modelId -replace '-(high|medium|low)$', ''

    # --- Build request body ---
    $promptText = Get-Content -Raw $PromptPath -ErrorAction Stop
    $bundleText = Get-Content -Raw $BundlePath -ErrorAction Stop

    $body = @{
        contents = @(
            @{
                role  = 'user'
                parts = @(
                    @{ text = $promptText },
                    @{ text = "`n`n--- BUNDLE ($BundlePath) ---`n`n$bundleText" }
                )
            }
        )
        generationConfig = @{
            temperature       = 0.3
            maxOutputTokens   = 8192
        }
    } | ConvertTo-Json -Depth 12 -Compress

    # --- Call the API ---
    $url = "https://generativelanguage.googleapis.com/v1beta/models/${modelId}:generateContent?key=$apiKey"
    $headers = @{ 'Content-Type' = 'application/json' }

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

        # --- Extract text response ---
        $candidate = $resp.candidates | Select-Object -First 1
        if (-not $candidate) {
            throw "Gemini API returned no candidates. Full response: $($resp | ConvertTo-Json -Depth 5 -Compress)"
        }

        # Capture usage metrics (real, not approximated)
        if ($resp.usageMetadata) {
            $inputTokens  = $resp.usageMetadata.promptTokenCount
            $outputTokens = $resp.usageMetadata.candidatesTokenCount
        }

        # Check for truncation (finishReason = MAX_TOKENS)
        if ($candidate.finishReason -eq 'MAX_TOKENS') {
            $truncationWarning = "Response hit maxOutputTokens=8192; consider raising or tightening the prompt."
            $warnings += $truncationWarning
        } elseif ($candidate.finishReason -and $candidate.finishReason -ne 'STOP') {
            $warnings += "Non-STOP finishReason: $($candidate.finishReason)"
        }

        # Concatenate all text parts (Gemini can return multi-part responses)
        $response = ($candidate.content.parts | Where-Object { $_.text } | ForEach-Object { $_.text }) -join ''
        if (-not $response) {
            throw "Gemini API returned a candidate with no text parts. finishReason=$($candidate.finishReason)"
        }

        # Prepend truncation banner if needed (same format as agy adapter)
        if ($truncationWarning) {
            $banner = @"
> [!WARNING]
> **Gemini response was truncated at maxOutputTokens.**
> The text below is incomplete. Re-run with a tighter prompt or raise maxOutputTokens.

"@
            $response = $banner + $response
        }

        $response | Set-Content -Path $ResponsePath -Encoding utf8
    } catch {
        $exitCode = -1
        $stderr = "$_"
        throw "Gemini API call failed: $_"
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
