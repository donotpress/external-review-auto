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

    It 'leaves room to actually run after the wait, reserving ONE floor' {
        # A lock wait that consumes the whole budget is not better than one that
        # overruns it: the seat still produces nothing.
        #
        # ONE floor, not two. It reserved RunFloorSec=60 while viability needed
        # only MinRunSec=15, and opus (v2.8.2 panel) showed what the gap did: for
        # any TimeoutSec at or under 60 the lock wait computed to ZERO, so
        # `WaitOne(0)` -- and the LOCK-RETRY path passes RemainingSec straight in
        # as TimeoutSec, which after a 10s backoff on a 600s seat is routinely
        # under 60. The one call that exists because of a lock collision was the
        # one call that never queued for the lock.
        #
        # The two numbers here were the literals 585 and 600, which silently
        # encoded MinRunSec=15. When the floor moved to 17 (the first-token
        # reachability constraint, opus, 2026-09-02 panel) they failed -- which is
        # the RIGHT failure, and it is why they now derive: what this test is for
        # is "the wait is everything above ONE floor", not the digit 585.
        # OpencodeConstantParity.Tests.ps1 is where the floor's own value is
        # pinned; duplicating it here is what made two tests need editing for one
        # deliberate change.
        $b = Resolve-OpencodeRunBudget -TimeoutSec 600
        ($b.LockWaitMs / 1000) | Should -Be (600 - (Get-OpencodeMinRunSec))
        $b.RemainingSec        | Should -Be 600
    }

    It 'still queues for the lock on a retry-sized budget' {
        # The regression opus named, stated as the assertion it needs.
        foreach ($t in @(20, 30, 45, 59, 60, 90)) {
            $b = Resolve-OpencodeRunBudget -TimeoutSec $t
            ($b.LockWaitMs / 1000) | Should -BeGreaterThan 0 -Because "a ${t}s seat must still wait for the run lock"
            ($b.LockWaitMs / 1000) | Should -BeLessOrEqual $t
        }
        # ...and only stops queueing when there is not even a minimum run left.
        (Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec 590).LockWaitMs | Should -Be 0
    }

    It 'charges time already spent against the remaining budget' {
        # The second serialised opencode seat enters the run having already
        # burned the first seat's whole run in the mutex. Its own deadline must
        # be what is LEFT, not a fresh copy of the original.
        $b = Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec 500
        $b.RemainingSec  | Should -Be 100
        # 100 left, minus the one MinRunSec floor. Derived, not the literal 85 --
        # see the note in 'leaves room to actually run after the wait'.
        ($b.LockWaitMs / 1000) | Should -Be (100 - (Get-OpencodeMinRunSec))
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

                # THE FLOOR, WHICH IS THE WHOLE POINT, AND WHICH THIS SWEEP DID
                # NOT ASSERT FOR TWO RELEASES.
                #
                # What used to be here was `LockWaitMs/1000 -le RemainingSec`
                # followed by `RemainingSec - LockWaitMs/1000 -ge 0` -- the same
                # inequality written twice, once rearranged, under a comment
                # congratulating itself for having replaced an identity with
                # "the assertion that CAN fail". It can fail, but only on a lock
                # wait LONGER than the budget. It says nothing about the thing
                # the lock wait exists to protect: that something is left over to
                # run in.
                #
                # MEASURED, against a decoy whose lock wait consumes the entire
                # remaining budget (`LockWaitMs = remaining * 1000`, floor zero):
                # the old pair passed 35 of 35 budget/elapsed pairs. The
                # assertion below fails 23 of those 35 -- the twelve it lets
                # through are the exhausted ones, where zero left over is the
                # honest answer.
                $floor = [Math]::Min((Get-OpencodeMinRunSec), $b.RemainingSec)
                ($b.RemainingSec - ($b.LockWaitMs / 1000)) | Should -BeGreaterOrEqual $floor `
                    -Because ("a ${budget}s seat ${elapsed}s in must keep ${floor}s to run in, " +
                              "not hand all $($b.RemainingSec)s of it to the lock wait")

                # AND THE OTHER END OF IT. The floor assertion alone is satisfied
                # by LockWaitMs = 0, which is not a safe default: `WaitOne(0)` on
                # the run mutex is the exact defect Resolve-OpencodeRunBudget was
                # written to remove -- the one call that exists because of a lock
                # collision was the one call that never queued for the lock. So
                # the wait is pinned as MAXIMAL, not merely bounded. Raised by the
                # muse-spark seat of the panel on the change that added the floor
                # assertion above, which had closed one direction and left this
                # one open.
                $b.LockWaitMs | Should -Be ([int]([Math]::Max(0, $b.RemainingSec - (Get-OpencodeMinRunSec)) * 1000)) `
                    -Because "a ${budget}s seat ${elapsed}s in must queue for the lock with everything above the floor"
                #
                # `LockWaitMs/1000 -le RemainingSec` is NOT kept alongside it.
                # With the default MinRunSec the floor above is >= 0, so
                # `remaining - lockWait >= floor` already entails
                # `lockWait <= remaining`: writing both back would re-commit the
                # duplication this change exists to remove. (It stops being
                # entailed only if a caller passes a NEGATIVE MinRunSec, which
                # nothing does and which would be a different bug.) The point
                # assertions above -- 600/585, 100/85, the 590-elapsed zero --
                # pin the exact arithmetic; the sweep pins the rule.
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

        # A budget smaller than the run floor is still viable at the start -- the
        # caller asked for a short run, which is its business.
        (Resolve-OpencodeRunBudget -TimeoutSec 30).Viable | Should -BeTrue
        (Resolve-OpencodeRunBudget -TimeoutSec 5).Viable  | Should -BeTrue
    }

    It 'decides viability on TIME LEFT, not on the budget it started from' {
        # gemini, v2.8.2 panel: the previous rule exempted short runs with
        # `$TimeoutSec -le $MinRunSec`, which made the verdict depend on the
        # ORIGINAL budget rather than on what is left --
        #
        #   TimeoutSec 15, elapsed 1  -> 14s left -> VIABLE
        #   TimeoutSec 20, elapsed 6  -> 14s left -> REFUSED
        #
        # Same seat, same 14 seconds, opposite answers. The exemption exists to
        # stop startup cost refusing a deliberately short run; it should therefore
        # key on how much has been SPENT, not on what was asked for.
        # The rule is now a function of (remaining, elapsed) and NOTHING else, so
        # holding elapsed fixed, a bigger budget is never worse:
        foreach ($t in @(15, 16, 20, 30, 60, 600)) {
            (Resolve-OpencodeRunBudget -TimeoutSec $t -ElapsedSec 1).Viable |
                Should -BeTrue -Because "a ${t}s seat one second in has barely started"
        }

        # gemini's pair, kept because the ANSWER changed rather than the framing:
        # these two do still differ, and now for a stated reason. 14s left one
        # second into a 15s budget is startup; 14s left six seconds into a 20s
        # budget is a seat losing time it will keep losing. The distinction is
        # elapsed, which is observable, not TimeoutSec, which is just what was
        # asked for.
        $a = Resolve-OpencodeRunBudget -TimeoutSec 15 -ElapsedSec 1
        $b = Resolve-OpencodeRunBudget -TimeoutSec 20 -ElapsedSec 6
        $a.RemainingSec | Should -Be 14
        $b.RemainingSec | Should -Be 14
        $a.Viable       | Should -BeTrue
        $b.Viable       | Should -BeFalse
    }

    It 'is monotone: more time left never hurts, more time spent never helps' {
        # The property that makes the rule defensible without arguing about any
        # single boundary.
        foreach ($e in @(0, 1, 2, 3, 10, 100)) {
            $prev = $false
            foreach ($rem in @(0, 5, 14, 15, 16, 100)) {
                $v = (Resolve-OpencodeRunBudget -TimeoutSec ($rem + [int]$e) -ElapsedSec $e).Viable
                if ($prev) { $v | Should -BeTrue -Because "at elapsed ${e}s, ${rem}s left cannot be worse than less" }
                $prev = $v
            }
        }
        foreach ($rem in @(5, 14, 30)) {
            $seen = @(0, 1, 2, 3, 10, 100 | ForEach-Object {
                (Resolve-OpencodeRunBudget -TimeoutSec ($rem + $_) -ElapsedSec $_).Viable })
            # once false, never true again as elapsed grows
            $i = [array]::IndexOf($seen, $false)
            if ($i -ge 0) { @($seen[$i..($seen.Count-1)]) | Should -Not -Contain $true }
        }
    }

    It 'still refuses when the QUEUE ate the budget, which is the case it exists for' {
        (Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec 592).Viable | Should -BeFalse
        (Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec 560).Viable | Should -BeTrue
        (Resolve-OpencodeRunBudget -TimeoutSec 20  -ElapsedSec 12).Viable  | Should -BeFalse
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

    It 'lowers the first-token deadline to somewhere the poll loop can reach' {
        # gemini, v2.8.2 panel. The lowering exists so the no-output branch can
        # still fire on a queued seat; a floor of 10 against a <=15s budget puts
        # it exactly on the first poll (which `-gt` misses) or past it, so the
        # timeout always wins and the branch is unreachable -- the opposite of
        # what the comment claims.
        #
        # The poll interval is 10s, so the deadline must sit strictly below
        # $effectiveTimeoutSec AND be reachable by a wake. Proportional does both.
        $script:Src | Should -Not -Match '\$lowered = \[Math\]::Max\(10, \$effectiveTimeoutSec - 10\)'
        $script:Src | Should -Match '\$lowered = \[Math\]::Max\(1, \[int\]\(\$effectiveTimeoutSec \* 0\.6\)\)'
        foreach ($eff in @(10, 15, 20, 60, 600)) {
            $lowered = [Math]::Max(1, [int]($eff * 0.6))
            $lowered | Should -BeLessThan $eff -Because "a deadline at or past the timeout can never fire (eff=$eff)"
        }
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
