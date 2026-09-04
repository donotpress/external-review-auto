# opencode's stall detector must fire INSIDE the budget it was actually given,
# and its appetite must come from a measurement rather than a guess.
#
# PART ONE -- THE CLAMP (2026-09-02). Interim round (deepseek-flash), R2,
# confirmed by the log of the very round that reported it:
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
# PART TWO -- THE APPETITE (2026-09-04). The clamp decided what to do with the
# appetite; it never asked where the appetite came from. It came from four
# guessed constants -- 600s for max/xhigh, 300s for high, 120s otherwise, plus
# `bundleTokens x 20ms` -- and measuring them against 8,199 assistant turns in
# the local opencode.db refuted both halves:
#
#   * the variant name predicts nothing. muse-spark peaks at 194.7s of silence
#     over its 421 productive turns (that worst case is an 'xhigh' one), while
#     deepseek-v4-flash at 'max' reaches 570.2s over 655. The MODEL differs, not
#     the knob. And the 120s fallback
#     tier kills 8.07% of productive era-seat turns, which is the 2026-08-22
#     ox-alpha incident with a number on it.
#   * the bundle overlay multiplied an INPUT token count by a GENERATION rate
#     (its own comment: "20ms/token ~ 50 tok/sec"). Silence vs input tokens is
#     r = +0.10; silence vs OUTPUT tokens is r = +0.83. Prefill measures
#     0.3 ms/token at the median -- the overlay charged ~65x that.
#
# Replaced by two terms that each carry their measurement:
#     PREFILL    = 120,000 ms + 3 ms x bundle token
#     GENERATION = 704,000 ms = 32,000 output tokens x 22 ms/token
# giving an 824s floor, above all 2,038 productive turns in the corpus (max
# 785.0s). Re-derive with tools/probes/opencode-silence.py; the reasoning is in
# docs/assessments/2026-09-04-stall-threshold-measured.md.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/OpencodeStallBudget.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'backends/opencode.ps1')
    $script:Src = Get-Content -Raw (Join-Path $script:Root 'backends/opencode.ps1')
}

Describe 'Resolve-OpencodeStallPlan' -Tag Unit {

    It 'never lets the stall threshold reach the budget, at any size or variant' {
        foreach ($to in @(120, 600, 1800)) {
            foreach ($v in @('max','xhigh','high','medium','default')) {
                foreach ($bytes in @(0, 50KB, 624465, 8MB)) {
                    $p = Resolve-OpencodeStallPlan -TimeoutSec $to -Variant $v -BundleBytes $bytes
                    ($p.StallThresholdMs / 1000) | Should -BeLessThan $to `
                        -Because "stall must beat the adapter timeout (to=$to v=$v bytes=$bytes)"
                }
            }
        }
    }

    It 'still fits the round that motivated the clamp inside its budget' {
        # The interim round's 624 KB bundle at the dispatcher's 1800s. Under the
        # old arithmetic the appetite was 3122.32s and the clamp was the only
        # thing keeping it reachable; under the measured one it is 1292.348s and
        # fits on its own. The invariant the clamp exists for is asserted either
        # way -- that is the point of asserting the invariant and not the number.
        $p = Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'max' -BundleBytes 624465
        $p.BundleTokenEst | Should -Be 156116
        ($p.StallThresholdMs / 1000) | Should -BeLessThan 1800 `
            -Because 'a threshold beyond the budget can never fire'
        $p.Clamped | Should -BeFalse -Because '1292.348s already fits inside 1770s'
    }

    It 'still clamps when the budget genuinely cannot fund the appetite' {
        # Non-vacuity for the clamp: a seat that queued behind the run mutex.
        $tight = Resolve-OpencodeStallPlan -TimeoutSec 300 -Variant 'max' -BundleBytes 624465
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

Describe 'the appetite is the measurement, not the variant' -Tag Unit {

    It 'gives every variant the same answer' {
        # The finding that removed the tiers: silence tracks the MODEL and the
        # amount it generates, not the reasoning-effort knob. Two providers'
        # vocabularies ('high'/'max' vs 'minimal'..'xhigh'), an unknown name and
        # the no-flag fallback must all land on the same number.
        foreach ($bytes in @(0, 20000, 124188, 624465)) {
            $ref = (Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'max' -BundleBytes $bytes).StallThresholdMs
            foreach ($v in @('xhigh','high','medium','low','minimal','default','totally-bogus-zzz','')) {
                (Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant $v -BundleBytes $bytes).StallThresholdMs |
                    Should -Be $ref -Because "variant '$v' must not move the threshold (bytes=$bytes)"
            }
        }
    }

    It 'floors at the measured 824s, whatever the bundle' {
        # 120s prefill floor + 704s generation. Checked, not asserted: no
        # productive turn in the 2,038-turn corpus has a silent stretch longer
        # than 824s, and the largest is 785.0s.
        $p = Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'default' -BundleBytes 0
        $p.PrefillMs     | Should -Be 120000
        $p.GenerationMs  | Should -Be 704000
        $p.WantedMs      | Should -Be 824000
        $p.Clamped       | Should -BeFalse
    }

    It 'clears the largest silence any productive era seat has taken' {
        # 570.2s, deepseek-v4-flash, over 1,078 productive turns on models era
        # dispatches. A threshold at or under this kills real answers; the whole
        # rewrite exists because the shipping value for 'high' was 300s.
        foreach ($bytes in @(0, 20000, 124188)) {
            (Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'high' -BundleBytes $bytes).StallThresholdMs |
                Should -BeGreaterThan 570200 -Because "bytes=$bytes must not kill a working seat"
        }
        # ...and the value this replaced would have failed that, which is the
        # non-vacuity the rest of the file needs.
        $oldHighBase = [Math]::Max(300000, [int](20000 / 4) * 20)
        $oldHighBase | Should -BeLessThan 570200
    }

    It 'charges prefill 3 ms per bundle token, not 20' {
        # The overlay's constant was a generation rate applied to an input count.
        # Measured prefill: 0.3 ms/token at the median, 2.4 ms/token at the worst
        # single observation (229.2s at ~95k input).
        $a = Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'max' -BundleBytes 400000
        $b = Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'max' -BundleBytes 800000
        ($b.WantedMs - $a.WantedMs) | Should -Be ((100000 - 50000) * 3 + (50000 * 3)) `
            -Because '100,000 extra tokens at 3 ms each'
        $a.PrefillMs | Should -Be (120000 + 100000 * 3)
    }

    It 'reports the two terms so the log can show its working' {
        $p = Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'max' -BundleBytes 124188
        ($p.PrefillMs + $p.GenerationMs) | Should -Be $p.WantedMs
        $script:Src | Should -Match 'prefill \+ \$\(\$stallPlan\.GenerationMs/1000\)s generation'
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

    It 'does not warn on every healthy round' {
        # The clamp is now the NORMAL case (824s floor vs 600-900s seat budgets),
        # so the warning had to move off it or become noise nobody reads. It is
        # attached to the clamped threshold falling under the measured line below
        # which THAT MODEL gets killed while working.
        $script:Src | Should -Match '\$killRiskSec = Get-OpencodeKillRiskSec -ModelId \$modelId'
        $script:Src | Should -Match 'if \(\(\$stallThresholdMs / 1000\) -lt \$killRiskSec\)'
    }

    It 'and the flat constant it replaced would have warned on every default round' {
        # MEASURED ON A LIVE ROUND, 2026-09-04. era's default budget is 600s; the
        # adapter sees 599s after startup; the clamp yields 569s. The first cut of
        # this warning used a flat 571 -- deepseek's figure -- so it fired on a
        # muse-spark round that finished healthy in 73.4 seconds, two seconds under
        # the line. That is the "warning nobody reads" failure the branch exists to
        # avoid, reintroduced by the constant inside it.
        $defaultBudgetThresholdSec = (Resolve-OpencodeStallPlan -TimeoutSec 599 -Variant 'xhigh' -BundleBytes 17411).StallThresholdMs / 1000
        $defaultBudgetThresholdSec | Should -Be 569 -Because 'this is the number the live round printed'

        # The old flat line warns here...
        $defaultBudgetThresholdSec | Should -BeLessThan 571
        # ...and the measured, per-model line does not, for the seat that ran.
        $defaultBudgetThresholdSec | Should -BeGreaterThan (Get-OpencodeKillRiskSec -ModelId 'opencode-go/muse-spark-1.3-contributor')
        # ...while still warning for the seat that genuinely can exceed it.
        $defaultBudgetThresholdSec | Should -BeLessThan (Get-OpencodeKillRiskSec -ModelId 'opencode-go/deepseek-v4-flash')
    }

    It 'carries each seat its own measured line' {
        # Longest silent stretch of a PRODUCTIVE turn, per model, from the corpus.
        (Get-OpencodeKillRiskSec -ModelId 'opencode-go/deepseek-v4-flash')          | Should -Be 571
        (Get-OpencodeKillRiskSec -ModelId 'opencode-go/deepseek-v4-pro')            | Should -Be 571
        (Get-OpencodeKillRiskSec -ModelId 'opencode-go/muse-spark-1.2-contributor') | Should -Be 195
        (Get-OpencodeKillRiskSec -ModelId 'opencode-go/muse-spark-1.3-contributor') | Should -Be 195
        (Get-OpencodeKillRiskSec -ModelId 'opencode-go/ox-alpha-free')              | Should -Be 786
        (Get-OpencodeKillRiskSec -ModelId 'minimax/MiniMax-M2.7')                   | Should -Be 39
    }

    It 'gives an unmeasured model the worst of the seats era dispatches' {
        # Over-warning on a model with no measurement is the safe direction.
        (Get-OpencodeKillRiskSec -ModelId 'opencode-go/some-new-model') |
            Should -Be (Get-OpencodeKillRiskSec -ModelId 'opencode-go/deepseek-v4-flash')
        (Get-OpencodeKillRiskSec -ModelId '') | Should -Be 571
    }
}

Describe 'Phase 1 must not contradict the stall plan' -Tag Unit {
    # Round-8 (deepseek-flash) finding 2. ae7594c's ordering claim --
    # "stall threshold < adapter TimeoutSec < dispatcher TimeoutSec+30" -- left
    # out a FOURTH, earlier deadline: the Phase-1 first-token watchdog, which
    # kills any process with zero output after $firstTokenSec (default 120s) and
    # is entirely variant-blind.
    #
    # But the stall plan's premise is that a run may think silently for minutes
    # before its first token. So on exactly the case the clamp was built for:
    #
    #   stall threshold (624 KB bundle, 1800s budget) : 1292s of permitted silence
    #   Phase-1 default                               :  120s -> kills first
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
