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
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match "response-contract"
        $src | Should -Match '\$res\.ExitCode\s*=\s*-1'
        $src | Should -Match '\$res\.ContentOk\s*=\s*\$false'
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
