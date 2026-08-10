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
        $src = Get-Content -Raw $script:EraPath
        $dispatchIdx = $src.IndexOf('$results = Invoke-ReviewerDispatch')
        $contractIdx = $src.IndexOf('Get-EraResponseContract')
        $fallbackIdx = $src.IndexOf('ERA_AGY_FALLBACK')
        $dispatchIdx | Should -BeGreaterThan 0
        $contractIdx | Should -BeGreaterThan $dispatchIdx
        $contractIdx | Should -BeLessThan $fallbackIdx
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
