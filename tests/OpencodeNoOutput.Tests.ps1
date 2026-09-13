# opencode dead-seat code + fallback widening.
#
# MEASURED 2026-09-11 (ebook-pipeline round 3): muse-spark on the read-tool
# path issued one `Read round-3-bundle.xml`, then 860s of zero stdout bytes
# until the dispatcher tree-killed it. The seat failed as free-text
# "opencode run failed (exit=-1...)" -- deliberately NON-recoverable under
# Get-EraRecoverableFailures (free-text exceptions are network/auth-shaped
# things a retry cannot fix). But THIS shape -- exit -1 with zero stdout
# bytes -- means the model never emitted anything: same dead-transport class
# as agy-stream-interrupted, and a REST re-dispatch can plausibly succeed.
# (Same shape measured 2026-09-04 direction-paths round 2, 124 KB bundle.)
#
# Narrow on purpose: exit -1 WITH output bytes keeps its free-text error
# (died mid-answer is a different fact). Only the zero-output shape codes.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/OpencodeNoOutput.Tests.ps1 -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
}

Describe 'Convert-EraAdapterResultError' -Tag Unit {
    It 'codes a zero-stdout opencode death as opencode-no-output' {
        $r = Convert-EraAdapterResultError -Result @{
            ExitCode = -1
            Stderr   = 'opencode run failed (exit=-1, model=m): boom [opencode-no-output stdout=0 delivery=read-tool]'
        }
        $r | Should -Be 'opencode-no-output'
    }

    It 'returns null when the seat died mid-answer (stdout > 0)' {
        $r = Convert-EraAdapterResultError -Result @{
            ExitCode = -1
            Stderr   = 'opencode run failed (exit=-1, model=m): boom [opencode-no-output stdout=512 delivery=read-tool]'
        }
        $r | Should -BeNullOrEmpty
    }

    It 'returns null for records with no trailer' {
        $r = Convert-EraAdapterResultError -Result @{
            ExitCode = -1
            Stderr   = 'opencode run failed (exit=-1, model=m): some other failure'
        }
        $r | Should -BeNullOrEmpty
    }

    It 'returns null for non-opencode adapter failures' {
        $r = Convert-EraAdapterResultError -Result @{
            ExitCode = -1
            Stderr   = 'claude CLI failed (exit=1, model=nope): unknown model'
        }
        $r | Should -BeNullOrEmpty
    }

    It 'returns null when the record has no Stderr' {
        Convert-EraAdapterResultError -Result @{ ExitCode = -1 } | Should -BeNullOrEmpty
        Convert-EraAdapterResultError -Result $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-EraRecoverableFailures admits the deliberate dead-seat code' -Tag Unit {
    BeforeAll {
        $script:Reg = @{ 'muse-spark' = @{ backend = 'opencode' } }
    }
    It 'recovers opencode-no-output (ran, returned no review)' {
        $r = Get-EraRecoverableFailures -ReviewerList @('muse-spark') `
            -Results @{ 'muse-spark' = @{ ExitCode = -1; Error = 'opencode-no-output' } } -Registry $script:Reg
        @($r) | Should -Contain 'muse-spark'
    }
}

Describe 'era.ps1 counts opencode deaths for the dead-transport gate' -Tag Unit {
    # Gate truth table lives in FirstByteDetection.Tests.ps1 (single map
    # signature since the fourth code); this pins opencode's membership.
    It 'counts opencode-no-output seats and still dispatches at most once' {
        $era = Get-Content -Raw "$PSScriptRoot/../runtimes/era.ps1"
        $era | Should -Match "'opencode-no-output'"
        ([regex]::Matches($era, '=\s*Invoke-ReviewerDispatch')).Count | Should -Be 2
    }

    It 'opencode stamps the trailer on its zero-output exit-fail throw' {
        $adapter = Get-Content -Raw "$PSScriptRoot/../backends/opencode.ps1"
        $adapter | Should -Match 'opencode-no-output stdout='
    }
}
