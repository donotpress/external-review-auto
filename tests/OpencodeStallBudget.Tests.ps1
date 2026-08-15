# opencode's stall detector must fire INSIDE the budget it was actually given.
#
# Interim round (deepseek-flash), R2 -- confirmed by the log of the very round
# that reported it:
#
#   [dispatch] Scaled TimeoutSec 600s -> 1800s for 174313-token bundle.
#   [opencode] Escalating timeout from 1800s to 3152s (variant=max,
#              bundle=156116tok, stall threshold 3122.32s + 30s margin).
#
# The dispatcher waits TimeoutSec + 30 = 1830s and then abandons the reviewer.
# The adapter had just decided it had 3152s, with a stall threshold at 3122s.
# Both of its own deadlines sit BEYOND the dispatcher's patience, so for a
# large max-variant bundle:
#
#   * the stall detector can never fire (3122s > 1830s)
#   * the adapter's own timeout can never fire (3152s > 1830s)
#   * the dispatcher always wins, and labels it "Timed out after N seconds
#     (global)" -- so a silent-think stall is mis-attributed and the forensic
#     snapshot the stall path writes is never produced
#
# which is the exact mis-labelling the escalation was written to PREVENT.
#
# The escalation cannot work: an adapter cannot grant itself time the dispatcher
# will not wait. So the fix inverts it -- keep the budget we were handed, and
# CLAMP THE STALL THRESHOLD to fire inside it. Same intent (stall wins the race,
# correct label), achieved with time that actually exists.
#
# Ordering this restores, for every bundle size:
#     stall threshold  <  adapter TimeoutSec  <  dispatcher TimeoutSec + 30
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/OpencodeStallBudget.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'backends/opencode.ps1')
    $script:Src = Get-Content -Raw (Join-Path $script:Root 'backends/opencode.ps1')
}

Describe 'Resolve-OpencodeStallPlan' -Tag Unit {

    It 'reproduces the measured round: a 624 KB bundle at variant max' {
        # The real numbers from the interim round.
        $p = Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'max' -BundleBytes 624465
        $p.BundleTokenEst | Should -Be 156116
        $p.WantedMs | Should -Be 3122320 -Because 'the raw appetite is unchanged; only what we do with it changes'
        $p.Clamped  | Should -BeTrue
        # The thing that was broken: it must now fit inside the budget.
        ($p.StallThresholdMs / 1000) | Should -BeLessThan 1800 `
            -Because 'a threshold beyond the budget can never fire'
    }

    It 'never lets the stall threshold reach the budget, at any size or variant' {
        foreach ($to in @(120, 600, 1800)) {
            foreach ($v in @('max','high','medium')) {
                foreach ($bytes in @(0, 50KB, 624465, 8MB)) {
                    $p = Resolve-OpencodeStallPlan -TimeoutSec $to -Variant $v -BundleBytes $bytes
                    ($p.StallThresholdMs / 1000) | Should -BeLessThan $to `
                        -Because "stall must beat the adapter timeout (to=$to v=$v bytes=$bytes)"
                }
            }
        }
    }

    It 'leaves a small bundle exactly as it was — no clamp, no change' {
        # Regression guard: the common case must not move. 20,000 bytes is
        # 5,000 tokens -> 100s of overlay, under the 120s medium base, so the
        # base wins. (An earlier version of this test used 40,000 bytes and
        # expected 120000; that was the TEST being wrong about the arithmetic --
        # 40 KB is 200s of overlay, which correctly dominates the base.)
        $p = Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'medium' -BundleBytes 20000
        $p.Clamped | Should -BeFalse
        $p.StallThresholdMs | Should -Be 120000 -Because 'the medium base, untouched'
    }

    It 'is byte-identical to the ORIGINAL formula whenever no clamp is needed' {
        # The change must be a no-op for every case that already fit. This
        # replicates the pre-fix arithmetic verbatim and requires agreement.
        foreach ($to in @(600, 1800)) {
            foreach ($v in @('max','high','medium')) {
                foreach ($bytes in @(0, 1KB, 20000, 40000, 100KB)) {
                    $baseMs   = switch ($v) { 'max' {600000} 'high' {300000} default {120000} }
                    $scaledMs = [int]($bytes / 4) * 20
                    $original = [Math]::Max($baseMs, $scaledMs)
                    $p = Resolve-OpencodeStallPlan -TimeoutSec $to -Variant $v -BundleBytes $bytes
                    if (-not $p.Clamped) {
                        $p.StallThresholdMs | Should -Be $original `
                            -Because "unclamped cases must not move (to=$to v=$v bytes=$bytes)"
                    }
                }
            }
        }
    }

    It 'keeps the variant bases when they fit' {
        (Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'max'  -BundleBytes 0).StallThresholdMs | Should -Be 600000
        (Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'high' -BundleBytes 0).StallThresholdMs | Should -Be 300000
    }

    It 'reports when it clamped, so the operator learns the budget is too small' {
        $tight = Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'max' -BundleBytes 624465
        $tight.Clamped   | Should -BeTrue
        $tight.WantedMs  | Should -BeGreaterThan $tight.StallThresholdMs
        $tight.CeilingMs | Should -Be $tight.StallThresholdMs
    }

    It 'stays sane on an absurdly small budget' {
        $p = Resolve-OpencodeStallPlan -TimeoutSec 40 -Variant 'max' -BundleBytes 8MB
        $p.StallThresholdMs | Should -BeGreaterThan 0
        ($p.StallThresholdMs / 1000) | Should -BeLessThan 40
    }
}

Describe 'the adapter no longer grants itself time the dispatcher will not wait' -Tag Unit {
    It 'does not raise its own TimeoutSec' {
        # The escalation assigned $TimeoutSec = $minTimeoutForVariant. An adapter
        # cannot extend the dispatcher's patience by reassigning its own
        # parameter, and doing so is what put both deadlines out of reach.
        $script:Src | Should -Not -Match '\$TimeoutSec\s*=\s*\$minTimeoutForVariant'
    }

    It 'computes the stall plan through the shared resolver' {
        $script:Src | Should -Match 'Resolve-OpencodeStallPlan -TimeoutSec'
    }

    It 'still announces the numbers it chose' {
        # A clamp that happens silently is a cap that reads as "covered" -- the
        # same house rule the grading bundle just had to learn.
        $script:Src | Should -Match '\[opencode\] Stall threshold'
    }
}

Describe 'Phase 1 must not contradict the stall plan' -Tag Unit {
    # Round-8 (deepseek-flash) finding 2. ae7594c's ordering claim --
    # "stall threshold < adapter TimeoutSec < dispatcher TimeoutSec+30" -- left
    # out a FOURTH, earlier deadline: the Phase-1 first-token watchdog, which
    # kills any process with zero output after $firstTokenSec (default 120s) and
    # is entirely variant-blind.
    #
    # But the stall plan's premise is that a 'max' variant may think silently for
    # minutes before its first token, and it grants 600s of base appetite. So on
    # exactly the case the clamp was built for:
    #
    #   stall threshold (max, 624 KB bundle) : 1770s of permitted silence
    #   Phase-1 default                      :  120s -> kills first
    #
    # A model thinking silently for 121s was killed and labelled "possible
    # limit/popup block" -- the same mis-attribution the clamp exists to prevent
    # -- and Phase 1 is the one kill path that wrote no forensic snapshot.

    BeforeAll {
        $script:Src2 = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'backends/opencode.ps1')
        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'backends/opencode.ps1')
    }

    It 'the contradiction is real arithmetic, not a style point' {
        # Non-vacuity for everything below.
        $plan = Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'max' -BundleBytes 624465
        ($plan.StallThresholdMs / 1000) | Should -BeGreaterThan 120 `
            -Because 'the plan permits far more silence than the Phase-1 default allows'
    }

    It 'reconciles the first-token deadline with the plan' {
        $script:Src2 | Should -Match 'First-token deadline raised'
        $reconcile = $script:Src2.IndexOf('$firstTokenSec = $planSilenceSec')
        $useIt     = $script:Src2.IndexOf('$firstTokenDeadline.Elapsed.TotalSeconds -gt $firstTokenSec')
        $reconcile | Should -BeGreaterThan 0
        $useIt     | Should -BeGreaterThan $reconcile -Because 'reconciling after the check would not reconcile anything'
    }

    It 'but an explicit operator override still wins' {
        $script:Src2 | Should -Match 'if \(-not \$env:ERA_OPENCODE_FIRST_TOKEN_SEC\)' `
            -Because 'the operator saying 120s means 120s'
    }

    It 'and the Phase-1 kill now leaves a forensic snapshot like the others' {
        $branch = [regex]::Match($script:Src2,
            '(?s)if \(-not \$hasSeenOutput -and \$firstTokenDeadline.*?throw "opencode: no response within').Value
        $branch | Should -Match 'snapshotPartialAndDebug' `
            -Because 'the failure you can least diagnose must not also be the one with no artifact'
    }

    It 'the dead 75%-of-budget branch is gone' {
        # Measured dead: 'ceilingMs >= TimeoutSec*1000' holds only for
        # TimeoutSec <= 1, and the dispatcher floor is the 600s default.
        $script:Src2 | Should -Not -Match '0\.75'
        # ...and the real budgets still behave.
        foreach ($to in @(600, 1800)) {
            $p = Resolve-OpencodeStallPlan -TimeoutSec $to -Variant 'max' -BundleBytes 8MB
            ($p.StallThresholdMs / 1000) | Should -Be ($to - 30)
        }
    }
}
