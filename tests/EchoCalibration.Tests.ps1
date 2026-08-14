# The prompt-echo threshold, calibrated against a COMMITTED corpus.
#
# WHY THIS FILE EXISTS
#
# The original threshold was derived from ad-hoc analysis of the local
# .external-reviews/ tree, which is gitignored. The numbers were real, the method
# was sound, and the answer was wrong -- because that corpus is almost entirely
# LARGE hand-written prompts, while the detector ships against era's ~600-char
# default template. 34 of 50 historical prompts are under 2,000 chars; the regime
# that mattered was the one with no data in it.
#
# The result was a detector that rejected a 7,655-character genuine review, wrote
# no artifact, and billed a fallback. Found by the round-5 panel hours after it
# shipped. Nobody could have caught it by reading, and nobody could re-run the
# calibration because the script was thrown away and the corpus was not in the
# repo.
#
# So: the corpus lives in tests/fixtures/echo-corpus/, spans three length
# regimes, and is generated deterministically (seeded, non-repetitive -- a
# repetitive prompt matches its own prefix everywhere and flatters the metric).
#
# WHAT THIS ASSERTS THAT A BOOLEAN TEST CANNOT
#
#   1. REGIME COVERAGE. Calibrating on one regime again is itself a failure.
#   2. MARGIN, not verdicts. A pass/fail test goes green right up until the
#      moment separation collapses. This fails when the gap NARROWS, before any
#      case flips.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/EchoCalibration.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'backends/_capture-validation.ps1')
    $script:CorpusDir = Join-Path $PSScriptRoot 'fixtures/echo-corpus'
    # No threshold literal lives here. It used to ($script:Threshold = 0.15, a
    # third copy of a number defined twice already in _capture-validation.ps1),
    # and the only test that read it scored a predicate the detector does not
    # use. Verdict assertions call Test-EraPromptEcho directly instead.

    function script:Get-Pairs {
        param([string]$Regime)
        $d = Join-Path $script:CorpusDir $Regime
        Get-ChildItem -LiteralPath $d -Filter '*-prompt.md' -File | ForEach-Object {
            $name = $_.Name -replace '-prompt\.md$', ''
            @{
                Regime   = $Regime
                Name     = $name
                Prompt   = Get-Content -Raw -LiteralPath $_.FullName
                Response = Get-Content -Raw -LiteralPath (Join-Path $d "$name-response.md")
            }
        }
    }
    $script:Regimes = @('short', 'medium', 'long')
    $script:All = @($script:Regimes | ForEach-Object { script:Get-Pairs -Regime $_ })
}

Describe 'the corpus itself' -Tag Unit {
    It 'covers every length regime — calibrating on one again is the original bug' {
        foreach ($r in $script:Regimes) {
            @(script:Get-Pairs -Regime $r).Count | Should -BeGreaterThan 0 -Because "regime '$r' must have data"
        }
    }

    It 'the regimes really are different lengths, and one of them is the shipped default' {
        $norm = { param($t) (($t -replace '\s+', ' ').Trim()).Length }
        $short  = (script:Get-Pairs -Regime 'short'  | Select-Object -First 1)
        $medium = (script:Get-Pairs -Regime 'medium' | Select-Object -First 1)
        $long   = (script:Get-Pairs -Regime 'long'   | Select-Object -First 1)
        (& $norm $short.Prompt)  | Should -BeLessThan 1000   -Because 'era.ps1 ships a ~628-char default template'
        (& $norm $medium.Prompt) | Should -BeGreaterThan 1000
        (& $norm $long.Prompt)   | Should -BeGreaterThan 8000
    }

    It 'includes the shapes that actually caused trouble' {
        # A model restating its instructions is what tripped the one-directional
        # ratio; a follow-up review discussing the prior round is the case people
        # assume will false-positive.
        (script:Get-Pairs -Regime 'short')  | Where-Object { $_.Name -eq 'restates-instructions' }  | Should -Not -BeNullOrEmpty
        (script:Get-Pairs -Regime 'long')   | Where-Object { $_.Name -eq 'discusses-prior-round' }  | Should -Not -BeNullOrEmpty
        (script:Get-Pairs -Regime 'medium') | Where-Object { $_.Name -eq 'quotes-the-prompt' }      | Should -Not -BeNullOrEmpty
    }
}

Describe 'no legitimate review is flagged, in ANY regime' -Tag Unit {
    It 'every committed pair passes' {
        $bad = @()
        foreach ($p in $script:All) {
            if (Test-EraPromptEcho -PromptText $p.Prompt -Response $p.Response) {
                $rr = Get-EraPromptEchoRatio -PromptText $p.Prompt -Response $p.Response
                $bad += ("{0}/{1} fwd={2:N3} rev={3:N3}" -f $p.Regime, $p.Name, $rr.Forward, $rr.Reverse)
            }
        }
        ($bad -join '; ') | Should -BeNullOrEmpty
    }
}

Describe 'echoes ARE flagged, in ANY regime' -Tag Unit {
    It 'a full echo of every corpus prompt is caught' {
        $missed = @()
        foreach ($p in $script:All) {
            if (-not (Test-EraPromptEcho -PromptText $p.Prompt -Response $p.Prompt)) {
                $missed += "$($p.Regime)/$($p.Name)"
            }
        }
        ($missed -join '; ') | Should -BeNullOrEmpty
    }

    It 'a half echo is caught wherever the guards allow it to be judged' {
        $missed = @()
        foreach ($p in $script:All) {
            $half = $p.Prompt.Substring(0, [int]($p.Prompt.Length / 2))
            $r = Get-EraPromptEchoRatio -PromptText $p.Prompt -Response $half
            if (-not $r.Judged) { continue }   # below the length guard: the narration floor owns it
            if (-not (Test-EraPromptEcho -PromptText $p.Prompt -Response $half)) {
                $missed += ("{0}/{1} min={2:N3}" -f $p.Regime, $p.Name, $r.Min)
            }
        }
        ($missed -join '; ') | Should -BeNullOrEmpty
    }
}

Describe 'the MARGIN, which is the thing that actually degrades' -Tag Unit {
    It 'the REVERSE direction is what separates them, and forward does not' {
        # Measured on this corpus: forward legit max 0.450 EXCEEDS forward TP
        # min 0.350 -- the two populations overlap, so forward alone can never
        # decide. Reverse is 1.000 vs 0.100. Recording it here so nobody
        # "simplifies" the detector back to one direction.
        $legFwd = @(); $legRev = @(); $tpFwd = @(); $tpRev = @()
        foreach ($p in $script:All) {
            $l = Get-EraPromptEchoRatio -PromptText $p.Prompt -Response $p.Response
            if ($l.Judged) { $legFwd += $l.Forward; $legRev += $l.Reverse }
            foreach ($frac in @(1.0, 0.5, 0.25)) {
                $slice = $p.Prompt.Substring(0, [int]($p.Prompt.Length * $frac))
                $e = Get-EraPromptEchoRatio -PromptText $p.Prompt -Response $slice
                if ($e.Judged) { $tpFwd += $e.Forward; $tpRev += $e.Reverse }
            }
        }
        $legFwdMax = ($legFwd | Measure-Object -Maximum).Maximum
        $tpFwdMin  = ($tpFwd  | Measure-Object -Minimum).Minimum
        $legRevMax = ($legRev | Measure-Object -Maximum).Maximum
        $tpRevMin  = ($tpRev  | Measure-Object -Minimum).Minimum
        Write-Host ("[calibration] forward: legit max={0:N3} vs TP min={1:N3}  (OVERLAPS - unusable alone)" -f $legFwdMax, $tpFwdMin)
        Write-Host ("[calibration] reverse: legit max={0:N3} vs TP min={1:N3}  (separates)" -f $legRevMax, $tpRevMin)

        $legRevMax | Should -BeLessThan 0.60
        $tpRevMin  | Should -BeGreaterOrEqual 0.60
        ($tpRevMin - $legRevMax) | Should -BeGreaterThan 0.50 -Because 'the reverse gap is the safety margin'
    }

    # DELETED 2026-08-14 (round-7 opus, finding 8): 'the worst legitimate pair
    # sits well below the worst echo'.
    #
    # It scored min(Forward, Reverse) against a single $script:Threshold = 0.15.
    # That is NEITHER conjunct of the shipped predicate, which is
    #
    #     Forward >= 0.15  AND  Reverse >= 0.60        (Test-EraPromptEcho)
    #
    # so the test and the detector could disagree in both directions. A
    # legitimate pair at Forward=0.45, Reverse=0.20 fails the deleted assertion
    # while the detector correctly passes it -- i.e. it would have blocked a
    # perfectly good corpus addition. It was also the THIRD copy of the 0.15
    # literal, and it is deleted rather than annotated because everything it
    # covered is already covered better, without the drift:
    #
    #   verdicts -- 'no legitimate review is flagged' and 'echoes ARE flagged'
    #               above call Test-EraPromptEcho ITSELF, so they cannot drift
    #               from the predicate; they ARE the predicate.
    #   margin   -- 'the REVERSE direction is what separates them' above asserts
    #               a gap of > 0.50 on the dimension that actually discriminates,
    #               which is strictly stronger than the > 0.20 asserted here on a
    #               dimension the detector does not use that way.
    #
    # $script:Threshold went with it. Get-EraPromptEchoRatio stays in this file
    # for MARGIN NUMBERS only, which is what the file header says it is for.
}
