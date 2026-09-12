# UX batch: fallback-preset alias, round-health line, unblock hints.
#
# - ERA_FALLBACK_PRESET is the documented name; ERA_AGY_FALLBACK keeps working
#   (alias-only: four order-sensitive assertions in ResponseContract.Tests.ps1
#   pin the old string, so the old string stays where it is).
# - Format-EraRoundHealth is ADDITIVE (muse-spark: removal first needs proof no
#   log parser greps the six lines; until then the health line joins them).
# - Get-EraFallbackBlocker names what would unlock a fallback when none is
#   available (first preference preset + its requirement, or the
#   out-of-panel hint when every preference is in-run).
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/UxBatch.Tests.ps1 -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"

    function script:EnvWith {
        param([hashtable]$Vars)
        return { param($n) if ($Vars.ContainsKey($n)) { $Vars[$n] } else { $null } }.GetNewClosure()
    }
}

Describe 'Get-EraFallbackPresetOverride' -Tag Unit {
    It 'returns null when neither name is set' {
        Get-EraFallbackPresetOverride -EnvValue (script:EnvWith @{}) | Should -BeNullOrEmpty
    }

    It 'reads the new name' {
        Get-EraFallbackPresetOverride -EnvValue (script:EnvWith @{ ERA_FALLBACK_PRESET = 'sonnet' }) |
            Should -Be 'sonnet'
    }

    It 'keeps the old name working' {
        Get-EraFallbackPresetOverride -EnvValue (script:EnvWith @{ ERA_AGY_FALLBACK = 'haiku' }) |
            Should -Be 'haiku'
    }

    It 'prefers the new name when both are set, trims whitespace' {
        Get-EraFallbackPresetOverride -EnvValue (script:EnvWith @{ ERA_FALLBACK_PRESET = '  sonnet  '; ERA_AGY_FALLBACK = 'haiku' }) |
            Should -Be 'sonnet'
    }

    It 'passes off/0 through (the disable path keys on the resolved value)' {
        Get-EraFallbackPresetOverride -EnvValue (script:EnvWith @{ ERA_FALLBACK_PRESET = 'off' }) |
            Should -Be 'off'
        Get-EraFallbackPresetOverride -EnvValue (script:EnvWith @{ ERA_AGY_FALLBACK = '0' }) |
            Should -Be '0'
    }
}

Describe 'Format-EraRoundHealth' -Tag Unit {
    It 'names each seat and counts ok on one line' {
        $line = Format-EraRoundHealth -Results @{
            opus   = @{ ExitCode = 0 }
            gemini = @{ ExitCode = -1; Error = 'agy-stream-interrupted' }
        } -ReviewerList @('opus', 'gemini') -FallbackPreset $null
        $line | Should -Match '^\[era\] Round health: 1/2 ok'
        $line | Should -Match 'opus: ok'
        $line | Should -Match 'gemini: agy-stream-interrupted'
        $line | Should -Not -Match 'fallback'
    }

    It 'names the fallback preset when one ran' {
        $line = Format-EraRoundHealth -Results @{
            opus        = @{ ExitCode = 0 }
            gemini      = @{ ExitCode = -1; Error = 'agy-stream-interrupted' }
            'gemini-api' = @{ ExitCode = 0 }
        } -ReviewerList @('opus', 'gemini') -FallbackPreset 'gemini-api'
        $line | Should -Match 'fallback: gemini-api'
    }

    It 'labels an errorless failure unknown instead of blank' {
        $line = Format-EraRoundHealth -Results @{ opus = @{ ExitCode = -1 } } `
            -ReviewerList @('opus') -FallbackPreset $null
        $line | Should -Match 'opus: unknown'
    }
}

Describe 'Get-EraFallbackBlocker' -Tag Unit {
    BeforeAll {
        $script:RegB = @{
            'gemini-api' = @{ backend = 'geminiapi'; api_key_env = 'GEMINI_API_KEY' }
            sonnet       = @{ backend = 'claude' }
            gemini       = @{ backend = 'agy' }
        }
    }

    It 'names the first preference preset and its requirement' {
        Get-EraFallbackBlocker -Registry $script:RegB -Exclude @('gemini') |
            Should -Match ([regex]::Escape("'gemini-api' needs `$env:GEMINI_API_KEY"))
    }

    It 'falls through excluded presets to the next requirement' {
        Get-EraFallbackBlocker -Registry $script:RegB -Exclude @('gemini', 'gemini-api') |
            Should -Match "'sonnet' needs the claude CLI"
    }

    It 'says out-of-panel when every preference is in-run' {
        Get-EraFallbackBlocker -Registry $script:RegB -Exclude @('gemini', 'gemini-api', 'sonnet') |
            Should -Match 'out-of-panel'
    }
}
Describe 'blocker mirrors the resolver preference order' -Tag Unit {
    It 'lists the same preference defaults (drift breaks the hint)' {
        $src = Get-Content -Raw "$PSScriptRoot/../workflow.ps1"
        $listOf = {
            param($fnName)
            $start = $src.IndexOf("function $fnName")
            if ($start -lt 0) { return $null }
            $p = $src.IndexOf('[string[]]$Preference', $start)
            if ($p -lt 0 -or ($p - $start) -gt 2500) { return $null }
            $open = $src.IndexOf('@(', $p)
            $close = $src.IndexOf(')', $open)
            if ($open -lt 0 -or $close -lt 0) { return $null }
            return (($src.Substring($open + 2, $close - $open - 2) -split ',') |
                ForEach-Object { $_.Trim().Trim("'") }) -join '|'
        }
        $resolver = & $listOf 'Resolve-EraAgyFallback'
        $blocker = & $listOf 'Get-EraFallbackBlocker'
        $resolver | Should -Not -BeNullOrEmpty
        $blocker | Should -Be $resolver
    }
}

Describe 'era.ps1 wires the UX batch' -Tag Unit {    BeforeAll { $script:EraSrc = Get-Content -Raw "$PSScriptRoot/../runtimes/era.ps1" }

    It 'resolves the fallback override through the helper' {
        $script:EraSrc | Should -Match 'Get-EraFallbackPresetOverride'
    }

    It 'prints the round-health line after the summary' {
        $script:EraSrc | Should -Match 'Format-EraRoundHealth'
        $sumIdx = $script:EraSrc.IndexOf('Format-EraRoundSummary')
        $healthIdx = $script:EraSrc.IndexOf('Format-EraRoundHealth')
        $healthIdx | Should -BeGreaterThan $sumIdx
    }

    It 'keeps the legacy env string in place (ResponseContract order pins)' {
        $script:EraSrc | Should -Match 'ERA_AGY_FALLBACK'
    }

    It 'resolves the override through the helper, not inline env reads' {
        $script:EraSrc | Should -Match 'Get-EraFallbackPresetOverride'
    }
}

Describe 'docs/error-codes.md covers every deliberate code' -Tag Unit {
    It 'names each code the recovery paths key on (anti-drift)' {
        $doc = Get-Content -Raw "$PSScriptRoot/../docs/error-codes.md"
        foreach ($c in @('response-contract', 'agentic-narration-capture', 'prompt-echo',
                         'empty-capture', 'tmux-seat-exited', 'tmux-seat-truncated',
                         'stall-or-timeout', 'agy-stream-interrupted', 'opencode-no-output',
                         'agy-quota-exhausted', 'breaker-skip', 'timeout', 'no-structured-output',
                         'answered-badly', 'not-delivered')) {
            $doc | Should -Match ([regex]::Escape($c))
        }
    }
}
