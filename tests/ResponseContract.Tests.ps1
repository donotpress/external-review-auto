# Tests for the response contract.
#
# Background: adapters check non-empty text plus a finish reason, then return
# ExitCode=0, and Copy-PrimaryResponseAlias promotes on ExitCode alone. A
# reviewer returned ZERO of ten requested verdicts three times and each was
# recorded as a normal success. Worse, the promoted file feeds
# Invoke-PromptTokenSubstitution into round N+1 -- a bad round poisons the next.
#
# Decoration tolerance is not hypothetical. Measured on the 2026-08-09 panel:
# deepseek-flash answered '**P1: DO**' while gemini and opus answered 'P1: DO'.
# A naive check would have failed the sharpest response in the panel.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/ResponseContract.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'
}

Describe 'ConvertTo-EraContractNormalized' -Tag Unit {
    It 'strips markdown decoration' {
        ConvertTo-EraContractNormalized -Text '**P1: DO**' | Should -Be 'p1: do'
    }
    It 'collapses whitespace and lowercases' {
        ConvertTo-EraContractNormalized -Text "ORDER:`n`n   P2" | Should -Be 'order: p2'
    }
    It 'returns empty string for null' {
        ConvertTo-EraContractNormalized -Text $null | Should -Be ''
    }
}

Describe 'Get-EraResponseContract' -Tag Unit {
    It 'parses a marker into required tokens' {
        $p = "# Prompt`n<!-- era-require: ORDER:, DROP-ENTIRELY:, MISSING: -->`n## Output"
        $r = Get-EraResponseContract -PromptText $p
        $r.Count | Should -Be 3
        $r[0] | Should -Be 'ORDER:'
        $r[2] | Should -Be 'MISSING:'
    }

    It 'returns nothing when there is no marker — lenient by default' {
        # Every existing caller must keep working untouched.
        $r = Get-EraResponseContract -PromptText "# Just a normal prompt`nNo marker here."
        @($r).Count | Should -Be 0
    }

    It 'returns nothing for null or empty input' {
        @(Get-EraResponseContract -PromptText $null).Count | Should -Be 0
        @(Get-EraResponseContract -PromptText '').Count    | Should -Be 0
    }

    It 'ignores blank entries in the marker list' {
        $r = Get-EraResponseContract -PromptText '<!-- era-require: A:, , B: -->'
        @($r).Count | Should -Be 2
    }

    It 'reads a marker that wraps across lines instead of silently dropping tokens' {
        # (.+?) does not cross newlines without (?s), so a wrapped marker used to
        # keep only the tokens on the first line -- and a dropped token is a
        # contract silently weakened, which is the failure this feature exists to
        # prevent. Prompts wrap; an editor's hard wrap must not disarm the gate.
        $p = @"
# Prompt
<!-- era-require: ORDER:,
     DROP-ENTIRELY:,
     MISSING: -->
## Output
"@
        $r = @(Get-EraResponseContract -PromptText $p)
        $r | Should -Contain 'ORDER:'
        $r | Should -Contain 'DROP-ENTIRELY:'
        $r | Should -Contain 'MISSING:'
        @($r).Count | Should -Be 3
    }

    It 'stops at the first --> and does not swallow the rest of the document' {
        # The lazy quantifier must still terminate at the marker's own close,
        # otherwise crossing newlines would let one marker eat the whole prompt.
        $p = "<!-- era-require: A: -->`nBody text.`n<!-- some other comment -->`nMore."
        $r = @(Get-EraResponseContract -PromptText $p)
        @($r).Count | Should -Be 1
        $r[0] | Should -Be 'A:'
    }

    It 'first marker wins when a prompt declares more than one (documented, not accidental)' {
        $p = "<!-- era-require: A: -->`n<!-- era-require: B: -->"
        $r = @(Get-EraResponseContract -PromptText $p)
        @($r).Count | Should -Be 1
        $r[0] | Should -Be 'A:'
    }
}

Describe 'Test-ResponseContract' -Tag Unit {
    It 'passes when every required token is present' {
        $v = Test-ResponseContract -Response "ORDER: P1`nMISSING: none" -Required @('ORDER:', 'MISSING:')
        $v.Ok | Should -BeTrue
        @($v.Missing).Count | Should -Be 0
    }

    It 'accepts markdown-decorated headers — the measured deepseek case' {
        $v = Test-ResponseContract -Response '**P1: DO**' -Required @('P1:')
        $v.Ok | Should -BeTrue
    }

    It 'reports each missing token' {
        $v = Test-ResponseContract -Response 'ORDER: P1' -Required @('ORDER:', 'MISSING:', 'DROP:')
        $v.Ok | Should -BeFalse
        $v.Missing | Should -Contain 'MISSING:'
        $v.Missing | Should -Contain 'DROP:'
        $v.Missing | Should -Not -Contain 'ORDER:'
    }

    It 'is lenient when no contract is supplied' {
        (Test-ResponseContract -Response 'anything at all' -Required @()).Ok | Should -BeTrue
        (Test-ResponseContract -Response 'anything at all' -Required $null).Ok | Should -BeTrue
    }

    It 'fails an empty response against a real contract' {
        (Test-ResponseContract -Response '' -Required @('ORDER:')).Ok | Should -BeFalse
    }

    It 'treats a required token containing glob characters literally' {
        # .Contains(), not -like: '[x]' must not be read as a character class.
        $v = Test-ResponseContract -Response 'result [x] done' -Required @('[x]')
        $v.Ok | Should -BeTrue
    }
}

Describe 'era.ps1 enforces the contract at the dispatcher layer' -Tag Unit {
    It 'checks the contract after dispatch and BEFORE the agy fallback' {
        # Placement matters: a contract failure should be able to trigger the
        # existing agy fallback re-dispatch.
        #
        # SUPERSEDED 2026-08-10: this used to anchor on Get-EraResponseContract,
        # using the CAPTURE call as a proxy for the APPLICATION point. Those are
        # now deliberately far apart -- the capture moved above the
        # {{PREVIOUS_ROUND}} substitution so reviewer text cannot install a
        # contract. The invariant this test actually means is about where the
        # contract is APPLIED, so it now anchors on Assert-EraResponseContract.
        # Same invariant, correct anchor; not weakened.
        $src = Get-Content -Raw $script:EraPath
        $dispatchIdx = $src.IndexOf('$results = Invoke-ReviewerDispatch')
        $applyIdx    = $src.IndexOf('Assert-EraResponseContract -Results')
        $fallbackIdx = $src.IndexOf('ERA_AGY_FALLBACK')
        $dispatchIdx | Should -BeGreaterThan 0
        $applyIdx    | Should -BeGreaterThan $dispatchIdx
        $applyIdx    | Should -BeLessThan $fallbackIdx
    }

    It 'marks a contract failure the same way opencode marks a bad capture' {
        # The marking lives in workflow.ps1's Assert-EraResponseContract, which
        # era.ps1 calls at two points (see the fallback test below).
        $wf = Get-Content -Raw (Join-Path $script:SkillRoot 'workflow.ps1')
        $wf | Should -Match "response-contract"
        $wf | Should -Match 'ExitCode\s*=\s*-1'
        $wf | Should -Match 'ContentOk\s*=\s*\$false'
    }
}

Describe 'Assert-EraResponseContract' -Tag Unit {
    It 'marks a failing result and leaves a passing one alone' {
        $results = @{
            good = @{ Preset = 'good'; ExitCode = 0; Response = 'ORDER: x' }
            bad  = @{ Preset = 'bad';  ExitCode = 0; Response = 'nothing here' }
        }
        $n = Assert-EraResponseContract -Results $results -Required @('ORDER:')
        $n | Should -Be 1
        $results['good'].ExitCode  | Should -Be 0
        $results['bad'].ExitCode   | Should -Be -1
        $results['bad'].ContentOk  | Should -BeFalse
        $results['bad'].Error      | Should -Be 'response-contract'
    }

    It 'skips results that already failed, preserving the original error' {
        $results = @{ x = @{ Preset = 'x'; ExitCode = -1; Response = $null; Error = 'timeout' } }
        Assert-EraResponseContract -Results $results -Required @('ORDER:') | Should -Be 0
        $results['x'].Error | Should -Be 'timeout'
    }

    It 'is a no-op when no contract is declared' {
        $results = @{ x = @{ Preset = 'x'; ExitCode = 0; Response = 'whatever' } }
        Assert-EraResponseContract -Results $results -Required @() | Should -Be 0
        $results['x'].ExitCode | Should -Be 0
    }

    It 'is idempotent — a second pass finds nothing new' {
        $results = @{ x = @{ Preset = 'x'; ExitCode = 0; Response = 'nope' } }
        Assert-EraResponseContract -Results $results -Required @('ORDER:') | Should -Be 1
        Assert-EraResponseContract -Results $results -Required @('ORDER:') | Should -Be 0
    }
}

Describe 'Contract failures recover on any backend, not just agy' -Tag Unit {
    It 'triggers the fallback re-dispatch for a contract failure on ANY backend' {
        # Two of three round-2 panel reviewers named this: the fallback fired
        # only when a preset's backend was 'agy', so a REST or opencode reviewer
        # that failed the contract spent the whole round with zero usable output
        # and no recovery path at all.
        $src = Get-Content -Raw $script:EraPath
        $trigger = $src.IndexOf('ERA_AGY_FALLBACK')
        $trigger | Should -BeGreaterThan 0
        $window = $src.Substring($trigger, [Math]::Min(1400, $src.Length - $trigger))
        # The trigger set must include contract failures regardless of backend.
        $window | Should -Match "response-contract"
        $window | Should -Match 'failedRecoverable|failedContract'
    }
}

Describe 'The fallback is priced and cannot resurrect a declined reviewer' -Tag Unit {
    It 'prices the fallback against its per-reviewer cap before dispatching' {
        # Named by all three reviewers across rounds 2-4: the fallback never went
        # through Invoke-CostPrompt, so it was an unbudgeted full-bundle upload
        # that no cap could stop.
        $src = Get-Content -Raw $script:EraPath
        # Anchor on the fallback-preset resolution rather than the env-var
        # mention, and give the window room — the pricing block sits well after
        # the ERA_AGY_FALLBACK reference.
        $anchor = $src.IndexOf('$fallbackPreset = Resolve-EraAgyFallback')
        $anchor | Should -BeGreaterThan 0
        $window = $src.Substring($anchor, [Math]::Min(2000, $src.Length - $anchor))
        $window | Should -Match 'Get-PerReviewerCap'
        $window | Should -Match 'skipping'
    }

    It 'excludes the full requested list, so a cost-declined reviewer cannot return' {
        # A reviewer dropped at the cost prompt is absent from $approvedList, so
        # excluding only that list let the fallback pick the very reviewer the
        # user had just declined to pay for.
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match '\$fallbackExclude\s*='
        $src | Should -Match 'Resolve-EraAgyFallback[^\r\n]*-Exclude \$fallbackExclude'
    }
}

Describe 'The agy fallback response is contract-checked too' -Tag Unit {
    It 'enforces the contract both BEFORE and AFTER the agy fallback block' {
        # Measured 2026-08-09 on a live dispatch: with the check placed only
        # before the fallback, a failing agy reviewer triggered a re-dispatch to
        # gemini-api, and the FALLBACK's own answer was never checked. It was
        # written as round-1-response.md with content_ok=true while missing the
        # required token -- the exact failure mode this feature exists to stop,
        # inside the feature itself.
        $src = Get-Content -Raw $script:EraPath
        $calls = [regex]::Matches($src, 'Assert-EraResponseContract')
        $calls.Count | Should -BeGreaterOrEqual 2
        $fallbackIdx = $src.IndexOf('ERA_AGY_FALLBACK')
        $fallbackIdx | Should -BeGreaterThan 0
        @($calls | Where-Object { $_.Index -lt $fallbackIdx }).Count | Should -BeGreaterOrEqual 1
        @($calls | Where-Object { $_.Index -gt $fallbackIdx }).Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'Convergence signals are no longer dead' -Tag Unit {
    It 'selects the primary result by ExitCode, not by the rarely-set ContentOk' {
        # Only agy and opencode ever set ContentOk; geminiapi, anthropic, claude
        # and openaicompat never do, so the old filter selected nothing for a
        # REST-only run.
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Not -Match '\$results\.Values\s*\|\s*Where-Object\s*\{\s*\$_\.ContentOk\s*\}'
        $src | Should -Match '\$_\.ExitCode\s*-eq\s*0'
    }

    It 'derives response length from Response, since no adapter sets ResponseChars' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Not -Match '\$primaryResult\.ResponseChars'
        $src | Should -Match '\$primaryResult\.Response\.Length'
    }
}

Describe 'the contract is read from the PROMPT, never from reviewer-supplied text' -Tag Unit {
    # Reviewer-controlled text became control plane.
    #
    # era.ps1 substituted {{PREVIOUS_ROUND}} into the prompt file at :988 and then
    # read the contract back out of that same file at :1566.
    # Get-EraResponseContract uses -match, which returns the FIRST hit. So a
    # marker sitting inside a previous round's REVIEW TEXT could install the
    # contract for round N+1.
    #
    # It is reachable in the normal configuration precisely because no shipped
    # prompt carries a marker: with no real marker to win the race, ANY marker a
    # reviewer quotes becomes the contract. Every reviewer then fails it, which
    # also triggers the (billable) fallback dispatch. This repo reviews itself
    # and its reviewers quote era-require markers constantly -- the round-1/2
    # responses under .external-reviews/era-grade/ contain them verbatim.

    BeforeAll {
        $script:CtlEra = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtimes/era.ps1')
        # Match the ASSIGNMENT, not every mention of the function name -- the
        # explanatory comment at the capture site names it too.
        $script:CtlCalls = [regex]::Matches($script:CtlEra, '(?m)^\s*\$contractRequired\s*=\s*@\(Get-EraResponseContract')
        $script:CtlCaptureCount = $script:CtlCalls.Count
        $script:CtlCaptureIdx = if ($script:CtlCalls.Count -gt 0) { $script:CtlCalls[0].Index } else { -1 }
    }

    It 'era.ps1 captures the contract BEFORE {{PREVIOUS_ROUND}} substitution' {
        $capture = $script:CtlCaptureIdx
        $subst   = $script:CtlEra.IndexOf('Invoke-PromptTokenSubstitution -PromptFile')
        $capture | Should -BeGreaterThan 0
        $subst   | Should -BeGreaterThan 0
        $capture | Should -BeLessThan $subst -Because 'after substitution the prompt file contains reviewer text'
    }

    It 'but still captures it AFTER the prompt file is finalized' {
        # Otherwise a -PromptOverrideFile / -ConversationFile contract is missed:
        # the contract travels WITH the prompt, it just must be read before any
        # untrusted text is spliced in.
        $finalized = $script:CtlEra.IndexOf('{{CONVERSATION_CONTEXT}}')
        $finalized | Should -BeGreaterThan 0
        $script:CtlCaptureIdx | Should -BeGreaterThan $finalized
    }

    It 'does not re-read the contract out of the prompt file after substitution' {
        # Exactly one CALL site (a comment naming the function does not count);
        # a second read downstream of the substitution reopens the hole.
        $script:CtlCaptureCount | Should -Be 1
    }

    It 'HAZARD (characterisation): an injected marker wins when the prompt has none' {
        # Real functions, no mocks. This is WHY the ordering above matters; it
        # must keep passing so nobody "simplifies" the capture back down the file.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-ctl-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            # A previous round's review that merely QUOTES a contract marker.
            Set-Content -LiteralPath (Join-Path $dir 'round-1-response.md') -Value @"
## Critical issues
- The contract marker ``<!-- era-require: SHRUBBERY: -->`` is parsed with -match,
  which returns the first hit.
"@
            # Round 2's prompt carries NO marker of its own -- the shipped default.
            $promptFile = Join-Path $dir 'round-2-prompt.md'
            Set-Content -LiteralPath $promptFile -Value "# Round 2`n`n{{PREVIOUS_ROUND}}`n`n## Output format`nFindings below."

            $before = @(Get-EraResponseContract -PromptText (Get-Content -Raw -LiteralPath $promptFile))
            $before.Count | Should -Be 0 -Because 'the prompt itself declares no contract'

            Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $dir -RoundN 2

            $after = @(Get-EraResponseContract -PromptText (Get-Content -Raw -LiteralPath $promptFile))
            $after | Should -Contain 'SHRUBBERY:' -Because 'the reviewer just installed a contract that the prompt never asked for'
        } finally {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
