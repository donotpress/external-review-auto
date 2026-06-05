# PR-B (Fix 3) tests: Test-AgenticNarrationCapture detector.
#
# The detector classifies an agy capture as a non-review (an agentic tool-intent
# narration captured instead of a real review) and returns $true to flag it.
#
# Final logic (spec Fix 3, R3-Gemini-I2 + R4-Opus-I3):
#   Flag IFF
#     (no markdown heading AND narration-match)
#   OR
#     (no heading AND no list marker AND length < 300)
#   A "(none)"-only response is treated as VALID (never flagged).
#   ALL anchored patterns use (?m)/(?im) so a multi-line real review whose FIRST
#   line is prose but which contains a heading later is NOT mis-flagged.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'backends/agy.ps1')
    . (Join-Path $script:SkillRoot 'workflow.ps1')
    $script:Reg = @{
        gemini = @{ backend = 'agy'; model_id = 'gemini-3.5-flash-high'; pricing = @{ input_per_m = 0.3; output_per_m = 1.2 } }
        'gemini-pro-low' = @{ backend = 'agy'; model_id = 'gemini-3.1-pro-low'; pricing = @{ input_per_m = 1.5; output_per_m = 5.0 } }
        minimax = @{ backend = 'opencode'; model_id = 'minimax/MiniMax-M2.7'; pricing = @{ input_per_m = 0.3; output_per_m = 1.2 } }
    }
}

Describe 'Test-AgenticNarrationCapture — TRUE positives (must be flagged)' {
    It 'flags "I will view tests/x.py..." narration (no heading)' {
        Test-AgenticNarrationCapture -Response 'I will view `tests/x.py` to understand the test setup before reviewing.' |
            Should -BeTrue
    }

    It 'flags "Let me run the unit tests" narration' {
        Test-AgenticNarrationCapture -Response 'Let me run the unit tests to confirm the current behavior.' |
            Should -BeTrue
    }

    It 'flags a short non-review text with no heading and no prose vocabulary (length floor)' {
        $resp = 'Just checking things out real quick here.'  # ~43 chars, no heading/list, no prose-review markers
        $resp.Length | Should -BeLessThan 300
        Test-AgenticNarrationCapture -Response $resp | Should -BeTrue
    }

    It 'does NOT flag a terse legitimate review under the length floor (prose-review gate)' {
        $resp = 'No correctness issues found; the concurrency fix is sound.'
        $resp.Length | Should -BeLessThan 300
        Test-AgenticNarrationCapture -Response $resp | Should -BeFalse
    }

    It 'flags file-listing narration even when it contains a list ("I will check these:")' {
        # The list-marker gate applies ONLY to the length branch; the narration
        # branch must still fire so an agentic capture that lists files it will
        # open does not slip through.
        $resp = "I will check these:`n- a.py`n- b.py"
        Test-AgenticNarrationCapture -Response $resp | Should -BeTrue
    }
}

Describe 'Test-AgenticNarrationCapture — FALSE positives (must NOT be flagged)' {
    It 'does NOT flag a real review that OPENS with narration but contains a heading later (multiline)' {
        $resp = @"
First, I will look at the dispatch flow to understand the concurrency model.

## Critical issues

- The mutex wait is too short for Pro runs.
- The 360s cap defeats timeout scaling.

## Minor

Nothing else of note.
"@
        Test-AgenticNarrationCapture -Response $resp | Should -BeFalse `
            -Because 'patterns are (?m); a heading anywhere means it is a real review'
    }

    It 'does NOT flag a terse valid review with headings' {
        $resp = @"
## Critical issues

(none)

## Minor

(none)
"@
        Test-AgenticNarrationCapture -Response $resp | Should -BeFalse
    }

    It 'does NOT flag a normal full review' {
        $resp = @"
## Summary

The design is sound overall. A few items below.

## Critical issues

1. Race condition in the dispatcher when two reviewers share a bundle path.
2. Cost cap is bypassed when the estimate is null.

## Suggestions

- Add a regression test for the overlapping-dispatch case.
"@
        Test-AgenticNarrationCapture -Response $resp | Should -BeFalse
    }

    It 'does NOT flag a bare "(none)" response (valid empty-form, under floor)' {
        Test-AgenticNarrationCapture -Response '(none)' | Should -BeFalse
    }

    It 'does NOT flag "2026 update:" as a list marker (precise list regex)' {
        # A short response whose first line is "2026 update: ..." must not be
        # treated as a list (\d+[.)] only, NOT [-*+\d]); but with no heading and
        # <300 chars and no real list marker it WOULD fall to the length floor.
        # So make it long enough that only the list-regex precision is under test:
        # confirm "2026 update:" alone is not counted as a list marker by checking
        # that a >=300 char response with only "2026 update:" lines is NOT flagged
        # (no heading, length>=300 => length branch off; no narration => clean).
        $body = ('2026 update: everything is fine and nothing needs changing here. ' * 6)
        $body.Length | Should -BeGreaterOrEqual 300
        Test-AgenticNarrationCapture -Response $body | Should -BeFalse
    }
}

Describe 'Test-AgenticNarrationCapture — R8: bundle-unavailable refusal captures' {
    # Found live by the convergence loop (round-2 gemini-pro-high): agy --print
    # sometimes returns a refusal ("I cannot review the bundle content because it
    # was not included ... please paste the content") instead of a review. At >300
    # chars, no heading, and not matching the narration verbs, it slipped through
    # as content_ok=true. These captures are NOT reviews and must be flagged.
    It 'flags the actual round-2 "cannot review the bundle ... paste the content" refusal' {
        $resp = @"
I cannot review the bundle content because it was not included in your message, and you have explicitly instructed me to not open, read, fetch, list, or run anything.

Since I am restricted from using my tools to read the file at C:\Users\x\round-2-bundle.xml, please paste the content of the bundle directly into our conversation so that I can review it for you!
"@
        $resp.Length | Should -BeGreaterThan 300 -Because 'this proves the length-floor branch does NOT catch it'
        Test-AgenticNarrationCapture -Response $resp | Should -BeTrue
    }

    It 'flags a short "unable to access the bundle" refusal' {
        Test-AgenticNarrationCapture -Response 'I am unable to access the attached bundle. Please paste the file content.' |
            Should -BeTrue
    }

    It 'does NOT flag a real review (with heading) that discusses bundle-attach failures in prose' {
        $resp = @"
## Critical issues
- The adapter cannot review the bundle content if agy fails to attach it; add a guard.

## Minor
(none)
"@
        Test-AgenticNarrationCapture -Response $resp | Should -BeFalse `
            -Because 'a heading means it is a real review even if it mentions the failure mode'
    }

    It 'does NOT flag a terse valid review under a heading saying "I cannot find any issues"' {
        $resp = @"
## What is correct
- I cannot find any issues; the concurrency fix and the retry path look sound.
"@
        Test-AgenticNarrationCapture -Response $resp | Should -BeFalse
    }
}

Describe 'Write-ReviewMetadata — Fix 4 honest fields' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-meta-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }
    AfterEach {
        Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes content_ok / capture_strategy / retry_count / retry_reason per reviewer' {
        $results = @{
            gemini = @{
                Preset = 'gemini'; ExitCode = 0; Response = "## Issues`n- a`n- b"
                CaptureMethod = 'polling'; CaptureStrategy = 'run-id-match'
                ContentOk = $true; RetryCount = 0; RetryReason = $null
                OutputTokens = 10; WallClockSec = 5; TruncationWarning = $null; Warnings = @()
            }
        }
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $results -Registry $script:Reg -BundleTokens 1000
        $meta = Get-Content -Raw (Join-Path $script:Dir 'round-1-metadata.json') | ConvertFrom-Json
        $e = $meta.reviewers[0]
        $e.content_ok | Should -BeTrue
        $e.capture_strategy | Should -Be 'run-id-match'
        $e.retry_count | Should -Be 0
    }

    It 'records content_ok=false on a clean exit when the detector fired (ExitCode -1)' {
        $results = @{
            gemini = @{
                Preset = 'gemini'; ExitCode = -1; Error = 'agentic-narration-capture'
                Response = 'I will view tests/x.py'; CaptureMethod = 'polling'
                CaptureStrategy = 'run-id-match'; ContentOk = $false
                RetryCount = 1; RetryReason = 'agentic-narration-capture'
                FirstAttempt = @{ strategy = 'run-id-match'; chars = 22; input_tokens = 100; output_tokens = 6; est_cost_total_usd = 0.0001 }
                OutputTokens = 6; WallClockSec = 4; Warnings = @('bad'); TruncationWarning = $null
            }
        }
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $results -Registry $script:Reg -BundleTokens 1000
        $meta = Get-Content -Raw (Join-Path $script:Dir 'round-1-metadata.json') | ConvertFrom-Json
        $e = $meta.reviewers[0]
        $e.content_ok | Should -BeFalse
        $e.retry_count | Should -Be 1
        $e.retry_reason | Should -Be 'agentic-narration-capture'
        $e.first_attempt.chars | Should -Be 22
    }

    It 'preserves first_attempt and adds its cost to the round total on a successful retry' {
        $results = @{
            gemini = @{
                Preset = 'gemini'; ExitCode = 0; Response = "## Issues`n- real review"
                CaptureMethod = 'polling'; CaptureStrategy = 'run-id-match'
                ContentOk = $true; RetryCount = 1; RetryReason = 'agentic-narration-capture'
                FirstAttempt = @{ strategy = 'run-id-match'; chars = 20; input_tokens = 100; output_tokens = 5; est_cost_total_usd = 0.5 }
                OutputTokens = 10; WallClockSec = 8; TruncationWarning = $null; Warnings = @()
            }
        }
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $results -Registry $script:Reg -BundleTokens 1000
        $meta = Get-Content -Raw (Join-Path $script:Dir 'round-1-metadata.json') | ConvertFrom-Json
        $e = $meta.reviewers[0]
        $e.first_attempt.est_cost_total_usd | Should -Be 0.5
        # round total must include the 0.5 discarded first-attempt cost.
        $e.est_cost_total_usd | Should -BeGreaterOrEqual 0.5
    }

    It 'records the first-attempt cost (non-zero) on a cap-skip failure (Fix 1)' {
        # Cap-skip path: the adapter skips the retry but attempt-1 really spent
        # ~full-bundle input, so FirstAttempt carries a non-zero est_cost_total_usd
        # which Write-ReviewMetadata must fold into the failure round total.
        $results = @{
            gemini = @{
                Preset = 'gemini'; ExitCode = -1; Error = 'agentic-narration-capture'
                Response = 'I will view tests/x.py'; CaptureMethod = 'polling'
                CaptureStrategy = 'run-id-match'; ContentOk = $false
                RetryCount = 0; RetryReason = 'agentic-narration-capture'
                FirstAttempt = @{ strategy = 'run-id-match'; chars = 22; input_tokens = 4000000; output_tokens = 6; est_cost_total_usd = 12.0 }
                OutputTokens = 6; WallClockSec = 9; Warnings = @('cap-skip'); TruncationWarning = $null
            }
        }
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $results -Registry $script:Reg -BundleTokens 1000
        $meta = Get-Content -Raw (Join-Path $script:Dir 'round-1-metadata.json') | ConvertFrom-Json
        $e = $meta.reviewers[0]
        $e.content_ok | Should -BeFalse
        $e.first_attempt.est_cost_total_usd | Should -Be 12.0
        # the failure round total must reflect the discarded first-attempt spend,
        # NOT 0 (the bug this fix closes).
        $e.est_cost_total_usd | Should -Be 12.0
    }

    It 'labels an exhausted empty capture as empty-capture, not narration (Fix 2)' {
        $results = @{
            gemini = @{
                Preset = 'gemini'; ExitCode = -1; Error = 'empty-capture'
                Response = $null; CaptureMethod = 'polling'
                CaptureStrategy = 'run-id-match'; ContentOk = $false
                RetryCount = 1; RetryReason = 'empty-capture'
                FirstAttempt = @{ strategy = 'run-id-match'; chars = 0; input_tokens = 100; output_tokens = 0; est_cost_total_usd = 0.0001 }
                OutputTokens = 0; WallClockSec = 3; Warnings = @('empty'); TruncationWarning = $null
            }
        }
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $results -Registry $script:Reg -BundleTokens 1000
        $meta = Get-Content -Raw (Join-Path $script:Dir 'round-1-metadata.json') | ConvertFrom-Json
        $e = $meta.reviewers[0]
        $e.retry_reason | Should -Be 'empty-capture'
        $e.error | Should -Be 'empty-capture'
    }

    It 'defaults the new fields safely for non-agy backends' {
        $results = @{
            minimax = @{
                Preset = 'minimax'; ExitCode = 0; Response = "## Issues`n- a"
                CaptureMethod = 'json'; OutputTokens = 5; WallClockSec = 3
                TruncationWarning = $null; Warnings = @()
            }
        }
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $results -Registry $script:Reg -BundleTokens 1000
        $meta = Get-Content -Raw (Join-Path $script:Dir 'round-1-metadata.json') | ConvertFrom-Json
        $e = $meta.reviewers[0]
        $e.content_ok | Should -BeTrue          # mirrors clean exit
        $e.retry_count | Should -Be 0
    }
}

Describe 'Copy-PrimaryResponseAlias — first successful in preference order' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-alias-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }
    AfterEach {
        Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'prefers exact gemini when successful' {
        'GEMINI'  | Set-Content (Join-Path $script:Dir 'round-1-gemini-response.md')
        'MINIMAX' | Set-Content (Join-Path $script:Dir 'round-1-minimax-response.md')
        $results = @{ gemini = @{ ExitCode = 0 }; minimax = @{ ExitCode = 0 } }
        Copy-PrimaryResponseAlias -ReviewDir $script:Dir -Round 1 `
            -ReviewerList @('minimax','gemini') -Results $results
        (Get-Content -Raw (Join-Path $script:Dir 'round-1-response.md')).Trim() | Should -Be 'GEMINI'
    }

    It 'falls back to first successful when gemini is absent (non-gemini default)' {
        'MINIMAX'  | Set-Content (Join-Path $script:Dir 'round-1-minimax-response.md')
        'DEEPSEEK' | Set-Content (Join-Path $script:Dir 'round-1-deepseek-response.md')
        $results = @{ minimax = @{ ExitCode = 0 }; deepseek = @{ ExitCode = 0 } }
        Copy-PrimaryResponseAlias -ReviewDir $script:Dir -Round 1 `
            -ReviewerList @('minimax','deepseek') -Results $results
        (Get-Content -Raw (Join-Path $script:Dir 'round-1-response.md')).Trim() | Should -Be 'MINIMAX'
    }

    It 'skips a failed primary and uses the next successful reviewer' {
        'GEMINI_BAD' | Set-Content (Join-Path $script:Dir 'round-1-gemini-response.md')
        'MINIMAX'    | Set-Content (Join-Path $script:Dir 'round-1-minimax-response.md')
        $results = @{ gemini = @{ ExitCode = -1 }; minimax = @{ ExitCode = 0 } }
        Copy-PrimaryResponseAlias -ReviewDir $script:Dir -Round 1 `
            -ReviewerList @('gemini','minimax') -Results $results
        (Get-Content -Raw (Join-Path $script:Dir 'round-1-response.md')).Trim() | Should -Be 'MINIMAX'
    }

    It 'is a no-op for a single-reviewer run' {
        $results = @{ gemini = @{ ExitCode = 0 } }
        Copy-PrimaryResponseAlias -ReviewDir $script:Dir -Round 1 `
            -ReviewerList @('gemini') -Results $results
        Test-Path (Join-Path $script:Dir 'round-1-response.md') | Should -BeFalse
    }

    It 'Copy-GeminiResponseAlias wrapper still works (one-release compat)' {
        'GEMINI'  | Set-Content (Join-Path $script:Dir 'round-1-gemini-response.md')
        'MINIMAX' | Set-Content (Join-Path $script:Dir 'round-1-minimax-response.md')
        Copy-GeminiResponseAlias -ReviewDir $script:Dir -Round 1 `
            -ReviewerList @('gemini','minimax') -GeminiResult @{ ExitCode = 0 }
        (Get-Content -Raw (Join-Path $script:Dir 'round-1-response.md')).Trim() | Should -Be 'GEMINI'
    }
}
