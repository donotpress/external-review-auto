# THREE DEFECTS THE 2026-09-04 PANEL FOUND, AND THE ONE MEASUREMENT THAT EXPLAINED
# THE BUG THEY WERE POINTED AT.
#
# The bug: an opencode read-tool seat intermittently exits 0 with EMPTY stdout.
# Diagnosed from the local opencode.db, not guessed. Under `--variant max`,
# deepseek-v4-flash reasons until it hits a 32,000-token OUTPUT ceiling and returns
# a message whose parts are {step-start, reasoning, step-finish} -- no text part at
# all. Two messages in that database have output=32000 EXACTLY and BOTH have zero
# text chars; a SUCCESSFUL run on the same bundle came in at 31,942, i.e. 58 tokens
# from failing. deepseek folds reasoning INTO the output count (its `reasoning`
# field reads 0 while output is tens of thousands); muse-spark reports reasoning
# separately (~11k) and so cannot exhaust the output ceiling the same way, which is
# why it is 3/3 clean at xhigh and is NOT exposed by the same mechanism.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/PhaseOneAndVariantCeiling.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'backends/opencode.ps1')
    $script:Reg  = Get-Content -Raw (Join-Path $script:Root 'backends/_registry.json') | ConvertFrom-Json
    $script:Src  = Get-Content -Raw (Join-Path $script:Root 'backends/opencode.ps1')
    $script:Code = [regex]::Replace($script:Src, '(?s)<#.*?#>', '')

    function script:ChosenVariant {
        param([string]$ModelId)
        $prov, $fam = $ModelId -split '/', 2
        $v = @($script:Reg._opencode_model_map.$prov.$fam.variants)
        foreach ($p in @('xhigh','max','high','medium','low')) { if ($v -contains $p) { return $p } }
        return 'default'
    }
}

Describe 'deepseek-v4-flash is not asked for maximum reasoning effort' -Tag Unit {

    It 'sends high, not max' {
        script:ChosenVariant -ModelId 'opencode-go/deepseek-v4-flash' | Should -Be 'high'
    }

    It 'lists only variants opencode declares for it' {
        # opencode declares high/low/max for this model. 'medium' never existed
        # here and was inert only because the loop stopped at 'max' first.
        $v = @($script:Reg._opencode_model_map.'opencode-go'.'deepseek-v4-flash'.variants)
        $v | Should -Not -Contain 'medium'
        $v | Should -Not -Contain 'max'
        $v | Should -Contain 'high'
    }

    It 'loses no stall budget on a real bundle by dropping max' {
        # The whole cost of this change would be a tighter stall window. It is not:
        # above ~30k tokens the bundle-size overlay dominates the variant base.
        $max  = Resolve-OpencodeStallPlan -TimeoutSec 702 -Variant 'max'  -BundleBytes 124188
        $high = Resolve-OpencodeStallPlan -TimeoutSec 702 -Variant 'high' -BundleBytes 124188
        $high.StallThresholdMs | Should -Be $max.StallThresholdMs
    }

    It 'records WHY, so the next person does not put max back' {
        $note = $script:Reg._opencode_model_map.'opencode-go'.'deepseek-v4-flash'._variants_note
        $note | Should -Match '32,000'
        $note | Should -Match '31,942'
    }
}

Describe 'Phase 1 is reachable again' -Tag Unit {

    It 'does not treat the startup banner as output' {
        # opencode writes "> build - <model>" to STDERR at launch. Summing
        # stdout+stderr and testing `-gt 0` set $hasSeenOutput true at the first
        # poll of every run that started, so `-not $hasSeenOutput` was never true
        # and Phase 1 could not fire. Measured on a real capture: 176 stderr bytes
        # against 2 on stdout.
        $script:Code | Should -Match '\$outputBaseline'
        $script:Code | Should -Match '\$now\s+-gt\s+\$outputBaseline'
        $script:Code | Should -Not -Match 'if \(\$now -gt 0\) \{ \$hasSeenOutput = \$true \}'
    }

    It 'still gates Phase 1 on having seen no output' {
        $script:Code | Should -Match '-not \$hasSeenOutput -and \$firstTokenDeadline'
    }

    It 'initialises the baseline before the loop' {
        $script:Code | Should -Match '\$outputBaseline\s*=\s*\$null'
    }
}

Describe 'the run mutex is released on every exit from the function' -Tag Unit {

    It 'releases before the non-viable-budget throw' {
        # The mutex is taken above; the try/finally that releases it opens further
        # down, so this throw jumped straight past the release.
        $i = $script:Code.IndexOf('if (-not $runBudget.Viable)')
        $i | Should -BeGreaterThan 0
        $window = $script:Code.Substring($i, 900)
        $window | Should -Match 'ReleaseMutex'
        # ...and the release must come BEFORE the throw, not after it.
        $rel = $window.IndexOf('ReleaseMutex')
        $thr = $window.IndexOf('throw (')
        $rel | Should -BeLessThan $thr
    }
}

Describe 'the exitfail snapshot cannot grow without bound' -Tag Unit {

    It 'prunes the debug directory like the stall path does' {
        $i = $script:Code.IndexOf('exitfail-$stamp')
        $i | Should -BeGreaterThan 0
        $before = $script:Code.Substring([Math]::Max(0, $i - 700), 700)
        $before | Should -Match 'Select-Object -Skip 40'
    }
}
