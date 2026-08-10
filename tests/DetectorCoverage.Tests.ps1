# The non-review detector must run on EVERY backend, not just the agentic two.
#
# Measured 2026-08-10: Test-AgenticNarrationCapture — the detector that catches
# a tool-intent narration, a sub-300-char non-answer, or a "the bundle was not
# included, please paste it" refusal — was dot-sourced by only 2 of the 6
# adapters (agy.ps1:79, opencode.ps1:25). claude, anthropic, geminiapi and
# openaicompat accepted ANY non-empty string as a review:
#
#   claude.ps1:206   if ($exitCode -eq 0 -and $clean) { break }   -> writes at :242
#   geminiapi.ps1    throws only when there are no text parts at all
#   openaicompat.ps1 throws only when content AND reasoning_content are empty
#   anthropic.ps1    same shape
#
# So a two-character answer from `opus` — a SHIPPED DEFAULT PANEL MEMBER — was
# recorded ExitCode=0, written to disk, marked content_ok=true, promoted to
# round-N-response.md, and fed into round N+1 via {{PREVIOUS_ROUND}}. None of
# the void-round work catches this: the artifact exists and the exit code is 0,
# which is exactly what those gates key on.
#
# The B3 branch matters most for the REST adapters specifically: they paste the
# bundle into the request body, so "I don't see an attached bundle, please paste
# it" is a routine failure for them and was scored as a full success.
#
# False-positive risk is low by construction: every branch of the detector is
# gated on the response having NO markdown heading, so any structured review is
# untouched. The non-vacuity cases below pin that.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/DetectorCoverage.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'backends/_capture-validation.ps1')

    $script:Src = @{}
    foreach ($b in @('agy', 'claude', 'opencode', 'geminiapi', 'openaicompat', 'anthropic')) {
        $script:Src[$b] = Get-Content -Raw (Join-Path $script:Root "backends/$b.ps1")
    }

    # A non-review the REST backends see routinely: they paste the bundle into the
    # request body, so a model that claims it never arrived is a real failure mode.
    $script:Refusal = 'I cannot review the bundle content because it was not included in this request. Please paste the bundle content and I will review it.'
    # A genuine structured review. Every detector branch is gated on "no heading",
    # so this must survive untouched on every backend.
    $script:RealReview = @"
## Critical issues
- workflow.ps1:1517 trusts ContentOk over the artifact on disk.

## Minor
- nit: the comment above Copy-PrimaryResponseAlias is stale.
"@

    function script:New-IOTriple {
        $b = New-TemporaryFile; 'BUNDLE' | Set-Content -LiteralPath $b
        $p = New-TemporaryFile; 'PROMPT' | Set-Content -LiteralPath $p
        # A path that does NOT exist yet, so "was the artifact written?" is testable.
        $r = Join-Path ([System.IO.Path]::GetTempPath()) ("era-dc-" + [guid]::NewGuid() + ".md")
        return @{ Bundle = $b; Prompt = $p; Resp = $r }
    }
}

Describe 'every backend routes its capture through the shared detector' -Tag Unit {
    It '<_> dot-sources the shared _capture-validation.ps1' -ForEach @('agy','claude','opencode','geminiapi','openaicompat','anthropic') {
        $script:Src[$_] | Should -Match '_capture-validation\.ps1'
    }

    It '<_> applies Test-AgenticNarrationCapture to its captured response' -ForEach @('agy','claude','opencode','geminiapi','openaicompat','anthropic') {
        $script:Src[$_] | Should -Match 'Test-AgenticNarrationCapture'
    }

    It '<_> reports a detector hit as an honest failure, not a success' -ForEach @('claude','geminiapi','openaicompat','anthropic') {
        # Mirrors the opencode precedent: ExitCode=-1 + ContentOk=$false +
        # Error='agentic-narration-capture'.
        $script:Src[$_] | Should -Match "agentic-narration-capture"
    }
}

Describe 'geminiapi — behavioural, with the HTTP call mocked' -Tag Unit {
    BeforeAll {
        . (Join-Path $script:Root 'backends/geminiapi.ps1')
        $script:SavedGeminiKey = $env:GEMINI_API_KEY
        $env:GEMINI_API_KEY = 'test-key-not-used-because-the-call-is-mocked'
        $script:Info = @{ model_id = 'gemini-2.5-flash'; max_tokens = 8192 }
    }
    AfterAll { $env:GEMINI_API_KEY = $script:SavedGeminiKey }

    It 'fails honestly on a bundle-unavailable refusal instead of scoring it a review' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                candidates = @([pscustomobject]@{
                    finishReason = 'STOP'
                    content = [pscustomobject]@{ parts = @([pscustomobject]@{ text = $script:Refusal }) }
                })
                usageMetadata = [pscustomobject]@{ promptTokenCount = 10; candidatesTokenCount = 20 }
            }
        }
        $io = script:New-IOTriple
        $r = Invoke-GeminiapiReview -BundlePath $io.Bundle -PromptPath $io.Prompt -ResponsePath $io.Resp -ModelInfo $script:Info
        $r.ExitCode  | Should -Be -1
        $r.ContentOk | Should -BeFalse
        $r.Error     | Should -Be 'agentic-narration-capture'
        Test-Path -LiteralPath $io.Resp | Should -BeFalse -Because 'a non-review must not land where the {{PREVIOUS_ROUND}} glob will read it'
    }

    It 'still accepts a real structured review (non-vacuity)' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                candidates = @([pscustomobject]@{
                    finishReason = 'STOP'
                    content = [pscustomobject]@{ parts = @([pscustomobject]@{ text = $script:RealReview }) }
                })
                usageMetadata = [pscustomobject]@{ promptTokenCount = 10; candidatesTokenCount = 20 }
            }
        }
        $io = script:New-IOTriple
        $r = Invoke-GeminiapiReview -BundlePath $io.Bundle -PromptPath $io.Prompt -ResponsePath $io.Resp -ModelInfo $script:Info
        $r.ExitCode  | Should -Be 0
        $r.ContentOk | Should -BeTrue
        (Get-Content -Raw $io.Resp) | Should -Match 'Critical issues'
    }
}

Describe 'openaicompat — behavioural, with the HTTP call mocked' -Tag Unit {
    BeforeAll {
        . (Join-Path $script:Root 'backends/openaicompat.ps1')
        $env:ERA_DC_FAKE_KEY = 'x'
        $script:Info = @{ api_base = 'https://example.test/v1'; api_key_env = 'ERA_DC_FAKE_KEY'; model_id = 'm'; max_tokens = 4096 }
    }
    AfterAll { Remove-Item Env:\ERA_DC_FAKE_KEY -ErrorAction SilentlyContinue }

    It 'fails honestly on a two-character non-answer' {
        # The exact shape already sitting in OpenaicompatReasoning.Tests.ps1:
        # content = 'ok' was a full success before this change.
        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = 'ok' }; finish_reason = 'stop' })
                usage   = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1 }
            }
        }
        $io = script:New-IOTriple
        $r = Invoke-OpenaicompatReview -BundlePath $io.Bundle -PromptPath $io.Prompt -ResponsePath $io.Resp -ModelInfo $script:Info
        $r.ExitCode  | Should -Be -1
        $r.ContentOk | Should -BeFalse
        Test-Path -LiteralPath $io.Resp | Should -BeFalse
    }

    It 'still accepts a real structured review (non-vacuity)' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = $script:RealReview }; finish_reason = 'stop' })
                usage   = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1 }
            }
        }
        $io = script:New-IOTriple
        $r = Invoke-OpenaicompatReview -BundlePath $io.Bundle -PromptPath $io.Prompt -ResponsePath $io.Resp -ModelInfo $script:Info
        $r.ExitCode  | Should -Be 0
        $r.ContentOk | Should -BeTrue
        (Get-Content -Raw $io.Resp) | Should -Match 'Critical issues'
    }
}

Describe 'anthropic — behavioural, with the HTTP call mocked' -Tag Unit {
    # NOTE: there is no Anthropic API key on this box and the opus-api/sonnet-api/
    # haiku-api presets remain LIVE-UNVERIFIED in the registry. These tests mock
    # Invoke-RestMethod, so they make no network call and need no key — they check
    # the adapter's own logic only, and claim nothing about the live backend.
    BeforeAll {
        . (Join-Path $script:Root 'backends/anthropic.ps1')
        $script:SavedAnthropicKey = $env:ANTHROPIC_API_KEY
        $env:ANTHROPIC_API_KEY = 'test-key-not-used-because-the-call-is-mocked'
        $script:Info = @{ model_id = 'claude-opus-5'; max_tokens = 16384 }
    }
    AfterAll { $env:ANTHROPIC_API_KEY = $script:SavedAnthropicKey }

    It 'fails honestly on a bundle-unavailable refusal' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                content    = @([pscustomobject]@{ type = 'text'; text = $script:Refusal })
                stop_reason = 'end_turn'
                usage      = [pscustomobject]@{ input_tokens = 10; output_tokens = 20 }
            }
        }
        $io = script:New-IOTriple
        $r = Invoke-AnthropicReview -BundlePath $io.Bundle -PromptPath $io.Prompt -ResponsePath $io.Resp -ModelInfo $script:Info
        $r.ExitCode  | Should -Be -1
        $r.ContentOk | Should -BeFalse
        Test-Path -LiteralPath $io.Resp | Should -BeFalse
    }

    It 'still accepts a real structured review (non-vacuity)' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                content    = @([pscustomobject]@{ type = 'text'; text = $script:RealReview })
                stop_reason = 'end_turn'
                usage      = [pscustomobject]@{ input_tokens = 10; output_tokens = 20 }
            }
        }
        $io = script:New-IOTriple
        $r = Invoke-AnthropicReview -BundlePath $io.Bundle -PromptPath $io.Prompt -ResponsePath $io.Resp -ModelInfo $script:Info
        $r.ExitCode  | Should -Be 0
        $r.ContentOk | Should -BeTrue
        (Get-Content -Raw $io.Resp) | Should -Match 'Critical issues'
    }
}
