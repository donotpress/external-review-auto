# Tests for the end-of-round summary line (Format-EraRoundSummary).
#
# 2026-09-08: the line read `Done. Wall clock: 119.7s` for a round whose own
# dispatcher logged `720s elapsed` -- it printed one arbitrary seat's
# WallClockSec (first value out of a hashtable, i.e. unordered) under a
# round-level name. A field whose name does not describe what it measures.
# The line now reports the slowest seat, honestly labeled.
#
# pin: run with  pwsh -Command "Invoke-Pester -Path tests/RoundSummary.Tests.ps1"

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'workflow.ps1')
}

Describe 'Format-EraRoundSummary' {
    It 'reports the slowest seat, not an arbitrary first value' {
        $results = @{
            gemini = @{ WallClockSec = 119.7 }
            opus   = @{ WallClockSec = 426.2 }
            spark  = @{ WallClockSec = 314.1 }
        }
        Format-EraRoundSummary -Results $results -TokenCount 146503 | Should -Be 'Done. Slowest seat: 426.2s | Tokens: 146503'
    }

    It 'does not label any seat time as the round wall clock' {
        $results = @{ gemini = @{ WallClockSec = 119.7 } }
        Format-EraRoundSummary -Results $results -TokenCount 1 | Should -Not -Match 'Wall clock'
    }

    It 'ignores seats that reported no time (abandoned/timeout synthetics)' {
        $results = @{
            gemini = @{ WallClockSec = 119.7 }
            straggler = @{ ExitCode = -1; Error = 'timeout' }
        }
        Format-EraRoundSummary -Results $results -TokenCount 5 | Should -Be 'Done. Slowest seat: 119.7s | Tokens: 5'
    }

    It 'returns nothing when no seat reported a time' {
        $results = @{ straggler = @{ ExitCode = -1; Error = 'timeout' } }
        Format-EraRoundSummary -Results $results -TokenCount 5 | Should -BeNullOrEmpty
    }
}
