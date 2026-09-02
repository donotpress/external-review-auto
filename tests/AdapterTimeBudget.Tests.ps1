# Every wait inside an adapter has to come OUT of the dispatcher's budget.
#
# THE TWIN OF ae7594c ("an adapter cannot grant itself time the dispatcher will
# not wait"). That release fixed the ESCALATION path: the adapter used to
# reassign its own $TimeoutSec upwards, so both of its deadlines sat beyond the
# dispatcher's patience and neither could ever fire. It was fixed by clamping
# the stall threshold to (TimeoutSec - 30), and the ordering
#
#     stall threshold  <  adapter TimeoutSec  <  dispatcher TimeoutSec + 30
#
# was written into the adapter's own docstring as the invariant.
#
# 09ece30, committed AFTER that fix, added a global run mutex to serialise
# opencode seats -- and reintroduced the same defect through a different door:
#
#   * $lockWaitMs = 15 * 60 * 1000 is a FIXED 900s that is not derived from
#     $TimeoutSec at all. At the dispatcher's default 600s budget the adapter
#     is willing to block for 900s before it has started opencode, i.e. 270s
#     past the point where the dispatcher tree-kills it. Nothing is spent and
#     the seat is reported as "Timed out after 600 seconds (global)" -- the
#     mis-attribution ae7594c exists to prevent.
#
#   * $deadline (the adapter's own timeout) is StartNew()'d AFTER the mutex
#     wait, so the adapter's effective budget is (mutexWait + TimeoutSec). The
#     DEFAULT panel has two opencode seats serialised behind that mutex, so the
#     second one routinely waits ~TimeoutSec and then believes it has a further
#     TimeoutSec. It does not.
#
#   * the 'database is locked' retry sleeps 10s (then 20s) and recurses with the
#     UNCHANGED $TimeoutSec. Worst case is 3 x TimeoutSec + 30s of backoff
#     against a dispatcher that waits TimeoutSec + 30.
#
# Resolve-OpencodeRunBudget is the arithmetic, extracted so it is testable
# without spawning a process -- matching Resolve-OpencodeStallPlan and
# Get-ClaudeRemainingMs.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/AdapterTimeBudget.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'backends/opencode.ps1')
    $script:Src = Get-Content -Raw (Join-Path $script:Root 'backends/opencode.ps1')
}

Describe 'Resolve-OpencodeRunBudget' -Tag Unit {

    It 'never lets the lock wait alone exceed the dispatcher''s patience' {
        # THE SHIPPED BUG, stated as an assertion. The literal was 900s, so this
        # failed for every budget below 900 -- which includes the dispatcher's
        # own 600s default and every unscaled round era has ever dispatched.
        foreach ($budget in @(60, 120, 300, 600, 900, 1800)) {
            $b = Resolve-OpencodeRunBudget -TimeoutSec $budget
            ($b.LockWaitMs / 1000) | Should -BeLessOrEqual $budget -Because "a ${budget}s budget cannot fund a $($b.LockWaitMs/1000)s wait"
        }
    }

    It 'leaves room to actually run after the wait' {
        # A lock wait that consumes the whole budget is not better than one that
        # overruns it: the seat still produces nothing. Reserve a run floor.
        $b = Resolve-OpencodeRunBudget -TimeoutSec 600 -RunFloorSec 60
        ($b.LockWaitMs / 1000) | Should -Be 540
        $b.RemainingSec        | Should -Be 600
    }

    It 'charges time already spent against the remaining budget' {
        # The second serialised opencode seat enters the run having already
        # burned the first seat's whole run in the mutex. Its own deadline must
        # be what is LEFT, not a fresh copy of the original.
        $b = Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec 500
        $b.RemainingSec  | Should -Be 100
        ($b.LockWaitMs / 1000) | Should -Be 40
        $b.Exhausted     | Should -BeFalse
    }

    It 'reports exhaustion rather than returning a negative budget' {
        $b = Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec 900
        $b.RemainingSec | Should -Be 0
        $b.LockWaitMs   | Should -Be 0
        $b.Exhausted    | Should -BeTrue
    }

    It 'holds the ordering invariant at every budget and elapsed pair' {
        # The sweep is the point: the previous instance of this defect was found
        # by reading one log line, and the fix that followed it was pinned by a
        # sweep exactly like this one. Same treatment here.
        foreach ($budget in @(60, 300, 600, 1200, 1800)) {
            foreach ($elapsed in @(0, 1, 59, 100, 599, 1799, 5000)) {
                $b = Resolve-OpencodeRunBudget -TimeoutSec $budget -ElapsedSec $elapsed
                $b.RemainingSec        | Should -BeGreaterOrEqual 0
                $b.RemainingSec        | Should -BeLessOrEqual $budget
                ($b.LockWaitMs / 1000) | Should -BeLessOrEqual $b.RemainingSec
                # NOT `($elapsed + $b.RemainingSec) -le max($budget,$elapsed)`.
                # That was here, and the opus seat of the twin-sweep panel showed
                # it is an identity for every possible implementation of
                # RemainingSec -- it cannot fail, so it guards nothing. The
                # assertion that CAN fail is that the lock wait leaves a run
                # floor, which is the line above.
                ($b.RemainingSec - ($b.LockWaitMs / 1000)) | Should -BeGreaterOrEqual 0
            }
        }
    }

    It 'never plans to run past the point the dispatcher stops waiting' {
        # THE SAME BUG, TWICE INSIDE ITS OWN FIX.
        #
        # Cut 1 wrote `[Math]::Max(60, $remaining)`, copying claude.ps1's floor,
        # which for any TimeoutSec under 60 hands the adapter more time than it
        # was given.
        #
        # Cut 2 capped that floor at $TimeoutSec -- and the BLINDED SEAT of the
        # panel run on this very diff pointed out that it is still wrong where it
        # matters most: at elapsed >= TimeoutSec the floor returns 60s, so the
        # second serialised opencode seat plans (elapsed + 60) against a
        # dispatcher that waits TimeoutSec + 30 and is about to tree-kill it. The
        # test that shipped with cut 2 ASSERTED that 60, so it was green while
        # over budget.
        #
        # A floor cannot fix an exhausted budget. The run either fits or it does
        # not: EffectiveSec is now exactly what is left, and Viable says whether
        # that is enough to be worth launching. The caller refuses instead of
        # starting a run nobody will wait for.
        foreach ($budget in @(1, 10, 30, 59, 60, 61, 600, 1800)) {
            foreach ($elapsed in @(0, 1, 59, 600, 1799, 5000)) {
                $b = Resolve-OpencodeRunBudget -TimeoutSec $budget -ElapsedSec $elapsed
                ($elapsed + $b.EffectiveSec) | Should -BeLessOrEqual ([Math]::Max($budget, $elapsed)) `
                    -Because "a ${budget}s seat ${elapsed}s in may not plan a $($b.EffectiveSec)s run"
                $b.EffectiveSec | Should -Be $b.RemainingSec
            }
        }
    }

    It 'says a spent budget is not worth launching instead of flooring it' {
        # The queued seat's honest outcome. Starting a 60s run at elapsed 600 of a
        # 600s budget produces nothing and is recorded as a generic global
        # timeout, which is the mis-attribution this whole line of fixes exists
        # to prevent.
        $spent = Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec 900
        $spent.EffectiveSec | Should -Be 0
        $spent.Viable       | Should -BeFalse
        $spent.Exhausted    | Should -BeTrue

        $thin = Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec 599
        $thin.EffectiveSec  | Should -Be 1
        $thin.Viable        | Should -BeFalse -Because '1s is not enough for opencode to emit anything'

        $ok = Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec 100
        $ok.EffectiveSec    | Should -Be 500
        $ok.Viable          | Should -BeTrue

        # A budget smaller than the run floor is still viable -- the caller asked
        # for a short run, which is its business.
        (Resolve-OpencodeRunBudget -TimeoutSec 30).Viable | Should -BeTrue
    }

    It 'does not refuse a short budget the moment startup costs a second' {
        # FOUND BY TRYING TO USE IT, not by review. The first cut tested
        # `remaining >= Min(RunFloorSec, TimeoutSec)`, and for any TimeoutSec at
        # or under the 60s floor that reduces to `remaining >= TimeoutSec` -- so
        # ONE SECOND of startup (variant resolution, registry read, temp files)
        # made every short run non-viable. A probe with TimeoutSec=40 was refused
        # at 39s remaining, by the guard written to stop refusals that cost
        # capability. Exactly the direction rule 2 of the review prompt names.
        #
        # The floor for "is this worth starting" is not the lock's reservation.
        # It is mechanical: the poll loop wakes every 10s, so a run with less
        # than one poll plus margin left is killed on its first wake having
        # produced nothing and billed the prefill.
        foreach ($budget in @(15, 20, 30, 40, 59, 60)) {
            (Resolve-OpencodeRunBudget -TimeoutSec $budget -ElapsedSec 1).Viable |
                Should -BeTrue -Because "a ${budget}s run is still worth starting one second in"
        }
        # ...and the case this guard exists for is unchanged.
        (Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec 592).Viable | Should -BeFalse
        (Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec 560).Viable | Should -BeTrue
    }

    It 'composes with Resolve-OpencodeStallPlan so the stall still fires first' {
        # The stall plan is handed the REMAINING budget, not the original one.
        # Fed the original after a long mutex wait, its threshold sits past the
        # dispatcher's patience again -- ae7594c's exact outcome, one door over.
        $b    = Resolve-OpencodeRunBudget -TimeoutSec 1800 -ElapsedSec 1500
        $plan = Resolve-OpencodeStallPlan -TimeoutSec $b.RemainingSec -Variant 'max' -BundleBytes 600000
        ($plan.StallThresholdMs / 1000) | Should -BeLessThan $b.RemainingSec
        $plan.Clamped | Should -BeTrue -Because 'a 300s remainder cannot fund a max variant''s 600s base appetite'
    }
}

Describe 'the opencode adapter spends the budget it was handed' -Tag Unit {

    # These are WIRING assertions on source text and they are labelled as such:
    # the constants they cover are locals inside Invoke-OpencodeReview, which
    # cannot be reached without spawning a real opencode process. The arithmetic
    # itself is covered behaviourally above.

    It 'has no fixed 15-minute lock wait left' {
        $script:Src | Should -Not -Match '\$lockWaitMs\s*=\s*15\s*\*\s*60\s*\*\s*1000'
        $script:Src | Should -Match 'Resolve-OpencodeRunBudget'
    }

    It 'hands the stall plan the REMAINING budget, not the original one' {
        $script:Src | Should -Not -Match 'Resolve-OpencodeStallPlan -TimeoutSec \$TimeoutSec\b'
        $script:Src | Should -Match 'Resolve-OpencodeStallPlan -TimeoutSec \$effectiveTimeoutSec'
    }

    It 'checks its own deadline against the remaining budget' {
        $script:Src | Should -Match '\$deadline\.Elapsed\.TotalSeconds -gt \$effectiveTimeoutSec'
    }

    It 'refuses to launch a run the dispatcher will not wait for' {
        $script:Src | Should -Match 'if \(-not \$runBudget\.Viable\)'
    }

    It 'shrinks the budget it passes to a lock retry' {
        # Recursing with the original $TimeoutSec grants the adapter a second
        # full budget the dispatcher will not wait for.
        $script:Src | Should -Not -Match "\`$retryArgs\['LockRetries'\] = \`$LockRetries - 1\s*\r?\n\s*return Invoke-OpencodeReview"
        $script:Src | Should -Match "\`$retryArgs\['TimeoutSec'\]"
    }
}
