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

Describe 'Test-EraCaptureAcceptable — one classification, not six copies' -Tag Unit {
    # Round 5 and 6, both reviewers: the same ~15-line block (narration detector,
    # echo detector, ExitCode/ContentOk/Error, skip the disk write) was
    # replicated across six adapters. opus's verdict: "half is defensible, half
    # is not". The three REST adapters and claude reach the decision at the same
    # point with the same inputs -- that half is collapsed here. agy decides
    # inside its retry loop and opencode returns early with its own shape; those
    # two genuinely differ and keep their own call sites.

    It 'accepts a real structured review' {
        $v = Test-EraCaptureAcceptable -Response "## Critical issues`n- workflow.ps1:1 is wrong" -Vendor 'Gemini'
        $v.Ok | Should -BeTrue
        $v.Error | Should -BeNullOrEmpty
    }

    It 'rejects a narration / bundle-refusal capture, with a vendor-named reason' {
        $v = Test-EraCaptureAcceptable -Response 'I cannot review the bundle content because it was not included. Please paste it.' -Vendor 'Gemini'
        $v.Ok      | Should -BeFalse
        $v.Error   | Should -Be 'agentic-narration-capture'
        $v.Warning | Should -Match 'Gemini'
    }

    It 'rejects an echoed prompt and labels it distinctly' {
        $prompt = ('Review the dispatcher for correctness of the retry loop and the cost caps, citing file and line for every claim. ' * 8)
        $pf = New-TemporaryFile; Set-Content -LiteralPath $pf -Value $prompt
        try {
            $v = Test-EraCaptureAcceptable -Response $prompt -PromptPath $pf -Vendor 'Claude'
            $v.Ok    | Should -BeFalse
            $v.Error | Should -Be 'prompt-echo'
        } finally { Remove-Item $pf -Force -ErrorAction SilentlyContinue }
    }

    It 'checks narration BEFORE echo, so the cheaper and more specific label wins' {
        # A short refusal is also technically prompt-shaped; it should be
        # reported as the refusal it is.
        $v = Test-EraCaptureAcceptable -Response 'I am unable to access the attached bundle. Please paste the file content.' -Vendor 'X'
        $v.Error | Should -Be 'agentic-narration-capture'
    }
}

Describe 'every backend routes its capture through the shared detector' -Tag Unit {
    It '<_> dot-sources the shared _capture-validation.ps1' -ForEach @('agy','claude','opencode','geminiapi','openaicompat','anthropic') {
        $script:Src[$_] | Should -Match '_capture-validation\.ps1'
    }

    It '<_> validates its capture before returning success' -ForEach @('agy','claude','opencode','geminiapi','openaicompat','anthropic') {
        # SUPERSEDED 2026-08-14: this named Test-AgenticNarrationCapture
        # directly. Four adapters now reach the decision through
        # Test-EraCaptureAcceptable, which runs the narration check and the echo
        # check in one place. The invariant is "this adapter validates", not
        # "this adapter calls one particular function" -- accept either.
        $script:Src[$_] | Should -Match 'Test-AgenticNarrationCapture|Test-EraCaptureAcceptable'
    }

    It '<_> classifies via the shared helper rather than its own copy' -ForEach @('claude','geminiapi','openaicompat','anthropic') {
        # The four that reach the decision at the same point with the same
        # inputs. agy and opencode keep their own call sites on purpose.
        $script:Src[$_] | Should -Match 'Test-EraCaptureAcceptable'
        # ...and no longer carry the inline pair.
        $script:Src[$_] | Should -Not -Match 'elseif \(Test-EraPromptEcho'
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

Describe 'Test-EraPromptEcho — a response that is the prompt is not a review' -Tag Unit {
    # The measured 2026-08-09 case (c): gemini-pro-high hit its output cap and
    # what landed on disk was THE PROMPT, ECHOED BACK. Nothing caught it as
    # content: the narration detector does not fire (an era prompt has markdown
    # headings, so every one of its branches is gated off), and a response
    # contract cannot help either — the prompt necessarily CONTAINS the tokens it
    # requires, so an echo satisfies it. Measured: Test-ResponseContract on an
    # echoed prompt returns Ok=$true, Missing=[].
    #
    # THRESHOLD, measured against the real local corpus in .external-reviews/
    # (69 legitimate prompt->response pairs across 28 topics, gitignored so not
    # reproducible from a clean clone — numbers recorded in
    # docs/assessments/2026-08-10-prompt-echo-threshold.md):
    #
    #   window   legit max   legit p95   pairs>0   TP full   TP half   TP quarter
    #      20        0.150       0.100        50     1.000     0.500        0.250
    #      40        0.050       0.050        21     1.000     0.500        0.250
    #      60        0.025       0.025        10     1.000     0.500        0.250
    #      80        0.000       0.000         0     1.000     0.475        0.225
    #     120        0.000       0.000         0     1.000     0.475        0.225
    #     240        0.000       0.000         0     1.000     0.450        0.200
    #
    # The decay from 50 nonzero pairs at W=20 to zero at W=80 shows the metric
    # really is measuring overlap rather than always returning 0. W=120 sits well
    # inside the clean plateau; 0.15 is above every legitimate value observed at
    # any window size and below the worst true positive (a quarter-echo, 0.225).
    #
    # The hardest false-positive case is covered by that corpus: round 2+ prompts
    # embed the previous round's full responses via {{PREVIOUS_ROUND}} (the
    # era-grade round-2 prompt is 85 KB of mostly prior review text) and
    # reviewers discuss them at length. Still 0.000 — reviewers paraphrase and
    # re-cite line numbers, they do not reproduce 120-char verbatim runs.

    BeforeAll {
        # A REALISTICALLY SIZED era prompt. Real ones run 3 KB (era-grade round 3)
        # to 85 KB (round 2, which embeds the prior round via {{PREVIOUS_ROUND}}).
        # Size matters to this metric: a quarter-echo only clears the threshold
        # once the prompt is long enough for windows to land inside the echoed
        # prefix. The short-prompt limit is asserted explicitly further down.
        $sections = 1..14 | ForEach-Object { @"
## Area $_ — dispatcher correctness

Review area $_ of the attached bundle. Check the retry loop for the case where
the child process is killed at the hard deadline but a readable transcript was
already captured, and confirm the per-reviewer cost cap is evaluated before the
replay rather than after it. Cite file:line for every claim you make, and do not
speculate about code that is not present in the bundle you were given.
"@ }
        $script:Prompt = @"
# Round 1 review request

Review the attached bundle. It is the dispatcher for an external-review skill.

<!-- era-require: ORDER:, DROP-ENTIRELY:, MISSING: -->

$($sections -join "`n")

## Output format
ORDER: <your ranked list of the findings above, most severe first>
DROP-ENTIRELY: <the ones not worth fixing, with one line of reasoning each>
MISSING: <anything the prompt did not ask about but that you think matters>

## Ground rules
Do not speculate about code you cannot see in the bundle. Cite file:line for
every claim. If you cannot verify something, say so rather than guessing.
"@
        # Guard the fixture itself: if someone shrinks this prompt the
        # truncated-echo case below stops being a real test.
        $script:Prompt.Length | Should -BeGreaterThan 3000
    }

    It 'flags a full echo of the prompt' {
        Test-EraPromptEcho -PromptText $script:Prompt -Response $script:Prompt | Should -BeTrue
    }

    It 'flags a TRUNCATED echo — the measured case (c) shape' {
        # The model hit maxOutputTokens partway through echoing.
        $quarter = $script:Prompt.Substring(0, [int]($script:Prompt.Length / 4))
        Test-EraPromptEcho -PromptText $script:Prompt -Response $quarter | Should -BeTrue
    }

    It 'does NOT flag a real review that quotes the prompt in passing' {
        $review = @"
## Critical issues
- workflow.ps1:1517 trusts the adapter's ContentOk over the artifact on disk.
  The prompt asks me to "Rank every finding" — done below.

## ORDER:
1. The content_ok lie (workflow.ps1:1517)
2. The void round exiting 0 (era.ps1:1688)

## DROP-ENTIRELY:
- The cosmetic comment drift; it costs nothing to leave.

## MISSING:
- Nothing about what happens when two dispatches race on the same round number.
"@
        Test-EraPromptEcho -PromptText $script:Prompt -Response $review | Should -BeFalse
    }

    It 'does NOT flag a long substantive review' {
        $long = ("## Critical issues`n" + (1..60 | ForEach-Object { "- finding $_ at workflow.ps1:$(1000+$_) — the dispatcher does not check X." }) -join "`n")
        Test-EraPromptEcho -PromptText $script:Prompt -Response $long | Should -BeFalse
    }

    It 'never fires on a prompt too short to sample meaningfully' {
        Test-EraPromptEcho -PromptText 'Review this.' -Response 'Review this.' | Should -BeFalse
    }

    It 'DOCUMENTED LIMIT: the short-prompt guard is a hard cutoff at 2x the window' {
        # The coded guard: a prompt shorter than WindowChars*2 is never judged,
        # because a small prompt cannot be told apart from a legitimate short
        # answer that restates the question. Assert the boundary itself rather
        # than a fuzzy partial-echo ratio -- how much of a partial echo it takes
        # to fire depends on prompt length AND repetitiveness (a repetitive
        # prompt matches its own prefix everywhere), which is not a stable thing
        # to pin. Real era prompts are 3-85 KB; measured quarter-echo = 0.225.
        $filler = 'Review the dispatcher for correctness and rank every finding you locate with a file and line. '
        $under = ($filler * 3).Substring(0, 239)
        $over  = ($filler * 8)
        $under.Length | Should -BeLessThan 240
        $over.Length  | Should -BeGreaterThan 240

        # Fully echoed, but under the cutoff -> deliberately not judged.
        Test-EraPromptEcho -PromptText $under -Response $under | Should -BeFalse
        # Same content, over the cutoff -> judged, and it is an echo.
        Test-EraPromptEcho -PromptText $over -Response $over | Should -BeTrue
    }

    It 'does NOT flag a real review that restates its instructions (SHORT shipped prompt)' {
        # THE REGRESSION opus found in round 5, reproduced.
        #
        # The threshold was derived only against the 3-85 KB hand-written prompts
        # in .external-reviews/. It ships against era's own DEFAULT template,
        # which is ~628 chars normalised. The geometry: a false positive needs a
        # contiguous verbatim run of 120 + 5*span/39 chars. At 85 KB that is
        # ~11,000 chars (hence the honest 0.000). At 628 chars it is ~195 -- and
        # two adjacent sentences of era's own template are 314.
        #
        # 34 of the 50 historical prompts in the corpus are under 2,000 chars and
        # 28 are under 1,000, so the SHORT regime is the dominant one in practice
        # and is precisely the one that was never measured.
        #
        # Cost of the false positive: ExitCode=-1, NO artifact written (the echo
        # path deliberately writes nothing), a billed fallback dispatch, and on a
        # solo run exit 2 on a round that had a good review in hand.
        $shortPrompt = @"
# External Review Prompt - My Topic

You are reviewing the attached codebase bundle. Provide structured feedback.

All source files are fully included in the attached bundle. Review ONLY what is in the bundle. Do NOT attempt to open, view, fetch, or read any file outside the bundle.

Cite locations as file:line using the line numbers shown in the bundle; if unsure of a number, cite the function/symbol name instead of guessing.

## Output format

## Critical issues
1. ...

## Important issues
1. ...

Be terse. If a section is empty, write "(none)".
"@
        # A model restating its constraints before answering -- common behaviour.
        $restated = 'All source files are fully included in the attached bundle. Review ONLY what is in the bundle. Do NOT attempt to open, view, fetch, or read any file outside the bundle. Cite locations as file:line using the line numbers shown in the bundle; if unsure of a number, cite the function/symbol name instead of guessing.'
        $findings = (1..70 | ForEach-Object { "- finding $_ : workflow.ps1:$(1000 + $_) mishandles the retry budget when the child is killed at the deadline." }) -join "`n"
        $goodReview = "Understood. Restating my constraints before I begin:`n`n$restated`n`n## Critical issues`n$findings`n`n## What looks good`n1. The artifact-grounded content_ok is sound."

        $goodReview.Length | Should -BeGreaterThan 5000 -Because 'this is a substantial, genuine review'
        Test-EraPromptEcho -PromptText $shortPrompt -Response $goodReview | Should -BeFalse
    }

    It 'STILL flags a full echo of that same SHORT prompt (the fix must not disarm the detector)' {
        $shortPrompt = @"
# External Review Prompt - My Topic

You are reviewing the attached codebase bundle. Provide structured feedback.

All source files are fully included in the attached bundle. Review ONLY what is in the bundle. Do NOT attempt to open, view, fetch, or read any file outside the bundle.

Cite locations as file:line using the line numbers shown in the bundle; if unsure of a number, cite the function/symbol name instead of guessing.

## Output format

## Critical issues
1. ...

Be terse. If a section is empty, write "(none)".
"@
        Test-EraPromptEcho -PromptText $shortPrompt -Response $shortPrompt | Should -BeTrue
    }

    It 'requires overlap in BOTH directions, not just prompt-into-response' {
        # The structural property that kills the false-positive class: an echo is
        # mostly-prompt in BOTH directions; a review that quotes its prompt is
        # only prompt-shaped in one.
        $prompt = ('Review the dispatcher for correctness of the retry loop and the cost caps, citing file and line for every claim you make. ' * 6)
        $quote  = $prompt.Substring(0, 400)
        $review = $quote + ' ' + (('## Findings ' + ('- workflow.ps1:1517 trusts ContentOk over the artifact on disk, which is the defect. ' * 60)))
        # Forward overlap is high (the quote covers much of a short prompt)...
        # ...but the review is overwhelmingly NOT prompt text, so it must pass.
        Test-EraPromptEcho -PromptText $prompt -Response $review | Should -BeFalse
        # And the echo of that same prompt must still fire.
        Test-EraPromptEcho -PromptText $prompt -Response $prompt | Should -BeTrue
    }

    It 'is safe on null / empty input' {
        Test-EraPromptEcho -PromptText $null -Response $null | Should -BeFalse
        Test-EraPromptEcho -PromptText $script:Prompt -Response '' | Should -BeFalse
    }

    It 'ignores whitespace and case differences in the echo' {
        # A model that re-wraps or re-cases the prompt is still echoing it.
        $mangled = ($script:Prompt.ToUpperInvariant() -replace "`n", "`n`n  ")
        Test-EraPromptEcho -PromptText $script:Prompt -Response $mangled | Should -BeTrue
    }
}

Describe 'every backend checks for a prompt echo' -Tag Unit {
    It '<_> checks for a prompt echo, directly or via the shared classifier' -ForEach @('agy','claude','opencode','geminiapi','openaicompat','anthropic') {
        # SUPERSEDED 2026-08-14, same reason as the narration row above: four
        # adapters now reach the echo check through Test-EraCaptureAcceptable.
        # That the helper actually runs it is pinned behaviourally in
        # 'Test-EraCaptureAcceptable — one classification, not six copies'.
        $script:Src[$_] | Should -Match 'Test-EraPromptEcho|Test-EraCaptureAcceptable'
    }

    It 'geminiapi fails honestly on an echoed prompt (behavioural, HTTP mocked)' {
        . (Join-Path $script:Root 'backends/geminiapi.ps1')
        $saved = $env:GEMINI_API_KEY
        $env:GEMINI_API_KEY = 'test-key-not-used-because-the-call-is-mocked'
        try {
            $io = script:New-IOTriple
            # The adapter must compare against the prompt file it was handed.
            $bigPrompt = (1..40 | ForEach-Object { "Section $_. Review the dispatcher for correctness of the retry loop, the cost caps, and the capture path; cite file:line for every claim you make." }) -join "`n"
            Set-Content -LiteralPath $io.Prompt -Value $bigPrompt
            Mock -CommandName Invoke-RestMethod -MockWith {
                [pscustomobject]@{
                    candidates = @([pscustomobject]@{
                        finishReason = 'MAX_TOKENS'
                        content = [pscustomobject]@{ parts = @([pscustomobject]@{ text = $bigPrompt }) }
                    })
                    usageMetadata = [pscustomobject]@{ promptTokenCount = 10; candidatesTokenCount = 8192 }
                }
            }
            $r = Invoke-GeminiapiReview -BundlePath $io.Bundle -PromptPath $io.Prompt -ResponsePath $io.Resp -ModelInfo @{ model_id = 'gemini-2.5-flash'; max_tokens = 8192 }
            $r.ExitCode  | Should -Be -1
            $r.ContentOk | Should -BeFalse
            $r.Error     | Should -Be 'prompt-echo'
            Test-Path -LiteralPath $io.Resp | Should -BeFalse
        } finally { $env:GEMINI_API_KEY = $saved }
    }
}
