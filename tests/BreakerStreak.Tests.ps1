# Circuit breaker: never dispatch into a backend on a fatal streak.
#
# MEASURED 2026-09-11/12: agy died fatally 4+ consecutive rounds ( then quota
# 0.00%); each round burned a full seat budget (~300-640s) failing
# identically. Streak scan over 293 metadata files / 74 failure seats:
# agy longest same-backend run 7, opencode 12, claude 3. N=3 fires at less
# than half the persistent-outage length with margin.
#
# Design (adjudicated): skip-only (REST-first cut per panel demand), fatal
# taxonomy owned by recovery (dead-transport + stall/timeout/empty =
# fatal; narration/contract/echo = seat flaky, backend alive), machine-
# scoped state file (per-topic stores reset and never see cross-topic
# streaks), never-zero rule (always dispatch at least the healthiest seat),
# 24h entry expiry. Void-round recovery via the existing agy branch +
# 'breaker-skip' in the recoverable list.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/BreakerStreak.Tests.ps1 -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
}

Describe 'Test-EraFatalFailure' -Tag Unit {
    It 'counts dead-transport codes as fatal' {
        foreach ($c in @('agy-stream-interrupted', 'opencode-no-output', 'agy-quota-exhausted', 'empty-capture')) {
            Test-EraFatalFailure -Result @{ ExitCode = -1; Error = $c } | Should -BeTrue
        }
    }

    It 'counts stalls, timeouts and crashes as fatal' {
        foreach ($c in @('stall-or-timeout', 'timeout', 'opencode run failed (exit=-1): boom', 'no-structured-output')) {
            Test-EraFatalFailure -Result @{ ExitCode = -1; Error = $c } | Should -BeTrue
        }
    }

    It 'does NOT count seat-level flakiness as fatal (backend is alive)' {
        foreach ($c in @('agentic-narration-capture', 'response-contract', 'prompt-echo')) {
            Test-EraFatalFailure -Result @{ ExitCode = -1; Error = $c } | Should -BeFalse
        }
    }

    It 'does NOT count successes' {
        Test-EraFatalFailure -Result @{ ExitCode = 0; Error = $null } | Should -BeFalse
    }
}

Describe 'breaker state file round-trips' -Tag Unit {
    It 'reads an empty state from a missing file (fail-open)' {
        $h = Read-EraBackendHealth -StatePath (Join-Path $TestDrive 'absent.json')
        $h.Count | Should -Be 0
    }

    It 'reads an empty state from a malformed file (fail-open)' {
        $p = Join-Path $TestDrive 'bad.json'
        '{{{not json' | Set-Content -LiteralPath $p -NoNewline
        (Read-EraBackendHealth -StatePath $p).Count | Should -Be 0
    }

    It 'round-trips streaks and expires entries older than 24h' {
        $p = Join-Path $TestDrive 'health.json'
        $old = [datetime]::UtcNow.AddHours(-25).ToString('o')
        $now = [datetime]::UtcNow.ToString('o')
        @{ agy = @{ consecutive_fatals = 3; last_ts = $old; last_error = 'x' }
           claude = @{ consecutive_fatals = 1; last_ts = $now; last_error = 'y' } } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $p -NoNewline
        $h = Read-EraBackendHealth -StatePath $p
        $h.ContainsKey('agy') | Should -BeFalse
        $h['claude'].consecutive_fatals | Should -Be 1
    }
}

Describe 'Select-EraBreakerSkips' -Tag Unit {
    BeforeAll {
        $script:Reg = @{
            gemini     = @{ backend = 'agy' }
            opus       = @{ backend = 'claude' }
            'muse-spark' = @{ backend = 'opencode' }
        }
    }

    It 'skips a backend on a streak of 3 with a logged reason' {
        $health = @{ agy = @{ consecutive_fatals = 3; last_ts = [datetime]::UtcNow.ToString('o'); last_error = 'stall' } }
        $s = Select-EraBreakerSkips -ReviewerList @('gemini', 'opus') -Registry $script:Reg `
            -Health $health -Threshold 3
        @($s.Skipped) | Should -Contain 'gemini'
        @($s.Skipped) | Should -Not -Contain 'opus'
    }

    It 'does not skip below the threshold' {
        $health = @{ agy = @{ consecutive_fatals = 2; last_ts = [datetime]::UtcNow.ToString('o'); last_error = 'stall' } }
        $s = Select-EraBreakerSkips -ReviewerList @('gemini', 'opus') -Registry $script:Reg `
            -Health $health -Threshold 3
        @($s.Skipped).Count | Should -Be 0
    }

    It 'never skips the last seat (dispatches the healthiest instead)' {
        $health = @{
            agy      = @{ consecutive_fatals = 9; last_ts = [datetime]::UtcNow.ToString('o'); last_error = 'x' }
            claude   = @{ consecutive_fatals = 5; last_ts = [datetime]::UtcNow.ToString('o'); last_error = 'y' }
            opencode = @{ consecutive_fatals = 3; last_ts = [datetime]::UtcNow.ToString('o'); last_error = 'z' }
        }
        $s = Select-EraBreakerSkips -ReviewerList @('gemini', 'opus', 'muse-spark') -Registry $script:Reg `
            -Health $health -Threshold 3
        @($s.Skipped).Count | Should -Be 2
        @($s.Skipped) | Should -Not -Contain 'muse-spark'
    }

    It 'breaker-skipped seats are recoverable (void-round REST fallback)' {
        $reg = @{ gemini = @{ backend = 'agy' }; 'muse-spark' = @{ backend = 'opencode' } }
        $r = Get-EraRecoverableFailures -ReviewerList @('gemini', 'muse-spark') -Results @{
            gemini       = @{ ExitCode = -1; Error = 'breaker-skip' }
            'muse-spark' = @{ ExitCode = -1; Error = 'breaker-skip' }
        } -Registry $reg
        @($r) | Should -Contain 'gemini'
        @($r) | Should -Contain 'muse-spark'
    }
}

Describe 'Update-EraBackendHealth' -Tag Unit {
    BeforeAll {
        $script:RegU = @{
            gemini       = @{ backend = 'agy' }
            opus         = @{ backend = 'claude' }
            'muse-spark' = @{ backend = 'opencode' }
        }
    }

    It 'increments on fatal, resets on success or seat-level flakiness' {
        $p = Join-Path $TestDrive 'upd.json'
        Update-EraBackendHealth -StatePath $p -Results @{
            gemini       = @{ ExitCode = -1; Error = 'stall-or-timeout' }
            opus         = @{ ExitCode = 0; Error = $null }
            'muse-spark' = @{ ExitCode = -1; Error = 'agentic-narration-capture' }
        } -Registry $script:RegU
        $h = Read-EraBackendHealth -StatePath $p
        $h['agy'].consecutive_fatals | Should -Be 1
        $h.ContainsKey('claude') | Should -BeFalse
        $h.ContainsKey('opencode') | Should -BeFalse
        Update-EraBackendHealth -StatePath $p -Results @{
            gemini = @{ ExitCode = -1; Error = 'stall-or-timeout' }
        } -Registry $script:RegU
        (Read-EraBackendHealth -StatePath $p)['agy'].consecutive_fatals | Should -Be 2
    }
}

Describe 'era.ps1 maintains streaks around dispatch' -Tag Unit {
    It 'updates health after dispatch returns' {
        $era = Get-Content -Raw "$PSScriptRoot/../runtimes/era.ps1"
        $era | Should -Match 'Update-EraBackendHealth'
    }
}
