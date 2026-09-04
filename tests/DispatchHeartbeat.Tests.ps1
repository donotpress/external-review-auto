# THE DISPATCH LOOP MUST SAY IT IS ALIVE.
#
# Without a heartbeat the poll loop is silent from the "[dispatch] Scaled
# TimeoutSec" line until either a lone straggler appears or the budget expires --
# up to $TimeoutSec + 30, which is 732s on a 35k-token panel and 1830s on a large
# one. Inside that window the log cannot distinguish "working" from "died ten
# minutes ago", and that ambiguity has now cost two rounds:
#
#   bulk-refresh-vpn-headless r1/r2 (2026-09-02) -- the driver read the silence as
#     death and re-dispatched while r1 was still running. Both seats paid twice.
#   direction-paths-2026-09-04 r1 -- the dispatcher was reaped by its launcher's
#     tool timeout (nohup & under a 120s tool call, process group reaped) at
#     ~01:21. Nothing recorded it. Establishing merely WHEN it died took process
#     forensics plus an argument from the survival of round-1-claim.json, because
#     the log's last line was the dispatch line.
#
# The emission itself is one Write-Host inside a loop that already wakes every
# 500ms. What is worth testing is the DECISION, which is why it is pure -- the
# same reason Test-EraStragglerExpired in the same loop is pure.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/DispatchHeartbeat.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'workflow.ps1')
}

Describe 'Get-EraHeartbeatSec' -Tag Unit {

    It 'defaults to 60s when the env var is unset or blank' {
        Get-EraHeartbeatSec -EnvValue $null | Should -Be 60
        Get-EraHeartbeatSec -EnvValue ''    | Should -Be 60
        Get-EraHeartbeatSec -EnvValue '   ' | Should -Be 60
    }

    It 'honours an explicit interval' {
        Get-EraHeartbeatSec -EnvValue '15'  | Should -Be 15
        Get-EraHeartbeatSec -EnvValue '300' | Should -Be 300
    }

    It 'treats 0 as deliberately disabled, not as missing' {
        # 0 must survive the "is it blank" check -- an operator who turns the
        # heartbeat off should get silence, not the 60s default back.
        Get-EraHeartbeatSec -EnvValue '0' | Should -Be 0
    }

    It 'falls back to the default on garbage rather than to silence' {
        # THE DIRECTION MATTERS. Silence is the failure this feature removes, so an
        # unparseable tunable must not produce it. A naive `[int]::TryParse` whose
        # failure path left $heartbeatSec at 0 would disable the heartbeat for
        # anyone with a typo in their env -- quietly, which is the same defect
        # class again.
        foreach ($bad in @('soon', '60s', '-5', '1.5', 'true', '٥')) {
            Get-EraHeartbeatSec -EnvValue $bad | Should -Be 60 -Because "'$bad' is not a valid interval"
        }
    }
}

Describe 'Test-EraHeartbeatDue' -Tag Unit {

    It 'fires exactly at the scheduled beat, not a second early' {
        Test-EraHeartbeatDue -ElapsedSec 59 -NextBeatSec 60 -HeartbeatSec 60 | Should -BeFalse
        Test-EraHeartbeatDue -ElapsedSec 60 -NextBeatSec 60 -HeartbeatSec 60 | Should -BeTrue
        Test-EraHeartbeatDue -ElapsedSec 61 -NextBeatSec 60 -HeartbeatSec 60 | Should -BeTrue
    }

    It 'is off when the interval is 0' {
        Test-EraHeartbeatDue -ElapsedSec 99999 -NextBeatSec 0 -HeartbeatSec 0 | Should -BeFalse
    }

    It 'beats at a steady cadence over a full budget, and never more often than asked' {
        # Replay the loop's own scheduling: on each due beat the caller advances
        # NextBeat by the interval. Over a 1830s budget at 60s that is 30 beats,
        # and the gap between them must never be under the interval.
        $beats = @()
        $next  = 60
        foreach ($t in 0..1830) {
            if (Test-EraHeartbeatDue -ElapsedSec $t -NextBeatSec $next -HeartbeatSec 60) {
                $beats += $t
                $next = $t + 60
            }
        }
        $beats.Count | Should -Be 30
        $beats[0]    | Should -Be 60
        for ($i = 1; $i -lt $beats.Count; $i++) {
            ($beats[$i] - $beats[$i-1]) | Should -Be 60
        }
    }

    It 'produces no beats at all across the same budget when disabled' {
        $n = 0
        foreach ($t in 0..1830) { if (Test-EraHeartbeatDue -ElapsedSec $t -NextBeatSec 0 -HeartbeatSec 0) { $n++ } }
        $n | Should -Be 0
    }
}

Describe 'the loop actually calls the heartbeat' -Tag Unit {

    It 'wires both functions into the dispatch poll loop' {
        # The pure functions above are worthless if the loop still has its own
        # inline copy -- the standing hazard in this repo. Pin the call sites.
        $src  = Get-Content -Raw (Join-Path $script:Root 'workflow.ps1')
        $code = [regex]::Replace($src, '(?s)<#.*?#>', '')
        $code | Should -Match 'Get-EraHeartbeatSec\s+-EnvValue\s+\$env:ERA_HEARTBEAT_SEC'
        $code | Should -Match 'Test-EraHeartbeatDue\s+-ElapsedSec'
        # ...and no second inline interval literal was left beside them.
        $hits = @(($code -split "`r?`n") |
                  Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\$heartbeatSec\s*=\s*\d' })
        $hits.Count | Should -Be 0 -Because "the interval has one definition; found: $($hits -join ' | ')"
    }

    It 'names which seats are outstanding, not just how many' {
        # "2 running" does not tell a post-mortem whether the expensive seat was
        # one of them. The seat names are the part worth having.
        $src  = Get-Content -Raw (Join-Path $script:Root 'workflow.ps1')
        $code = [regex]::Replace($src, '(?s)<#.*?#>', '')
        $code | Should -Match 'still running: \{4\}'
        $code | Should -Match '\$_\.Preset'
    }
}
