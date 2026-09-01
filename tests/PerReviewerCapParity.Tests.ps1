# The per-reviewer cost cap exists twice, and only one copy was reachable.
#
# Found by the same sweep as the opencode delivery constants: any number the PLAN
# decides and an ADAPTER independently re-decides is a drift candidate, and this
# codebase's most expensive failures are all that shape.
#
# workflow.ps1's Get-PerReviewerCap is the plan's copy. backends/agy.ps1 inlines
# it -- deliberately and with a stated reason (the adapter dot-sources only
# itself, so it cannot call the plan's function) -- to gate its own in-adapter
# retry. The values agreed when this was written. Nothing checked that they still
# do, and Get-PerReviewerCap takes -CheapCap / -ExpensiveCap parameters, so the
# plan's answer is not even a constant.
#
# The direction that costs money: the adapter's cap drifting HIGH lets it re-spawn
# a reviewer the plan would have refused to pay for, inside the adapter, after the
# cost prompt has already been answered.
#
# Also here: the bundle size that feeds that gate used to fail OPEN. `if
# (Test-Path) { ... } else { 0 }` made an unreadable bundle cost zero estimated
# input tokens, so the cap could not fire at all -- a benign-looking value
# standing in for a failed measurement, which is the third distinct instance of
# that shape in this repo (the token-count gate, Get-EraBundleLineCounts, and the
# opencode size probe).
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/PerReviewerCapParity.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'workflow.ps1')
    . (Join-Path $script:Root 'backends/agy.ps1')
}

Describe 'the agy adapter and the plan agree on the per-reviewer cap' -Tag Unit {

    It 'agrees across the whole pricing range, including the boundary' {
        foreach ($inPerM in @(0, 0.1, 0.14, 1, 5, 9.99, 10, 10.01, 25, 100)) {
            $plan    = Get-PerReviewerCap -Pricing @{ input_per_m = $inPerM }
            $adapter = Get-AgyPerReviewerCap -InputPerM $inPerM
            $adapter | Should -Be $plan -Because "input_per_m=$inPerM must cost the same on both sides"
        }
    }

    It 'returns the tier values, and records how far from firing the gate is' {
        Get-AgyPerReviewerCap -InputPerM 0.3  | Should -Be 2.0
        Get-AgyPerReviewerCap -InputPerM 25.0 | Should -Be 10.0

        # HONEST ABOUT REACHABILITY. An earlier version of this test was titled
        # "is not a cap that can never fire", which the opus seat of the
        # twin-sweep panel correctly called an unearned claim: it asserts values
        # from a pure function and says nothing about whether the GATE fires.
        #
        # The gate is `($firstCost + $projRetryCost) -gt $cap` with both terms
        # ~= (T/1e6) * inPerM, so it needs T > 1e6 / inPerM input tokens PER
        # ATTEMPT. At agy's $0.30/Mtok that is ~3.3M tokens, i.e. an ~11 MB
        # bundle -- well past every delivery ceiling era enforces.
        #
        # So this cap is nearly as unreachable as the hardcoded $15 it replaced;
        # 7.5x smaller is the same category. The PARITY it is tested for is real
        # and worth keeping (an adapter cap drifting above the plan's would let
        # the adapter re-spawn a reviewer the plan refused to pay for). Its
        # liveness is not, and this records the number rather than implying it.
        $tokensToFire = [Math]::Ceiling(1e6 / 0.3)
        $tokensToFire | Should -BeGreaterThan 3000000
    }
}

Describe 'the size that feeds the cap is measured, not defaulted' -Tag Unit {

    It 'reports UNKNOWN, not zero, for a bundle it could not read' {
        # Zero input tokens means zero estimated cost, which means the retry gate
        # cannot fire -- the adapter re-spawns a reviewer the cap existed to stop.
        #
        # But it must not THROW either, which is where the first cut of this fix
        # landed: agy's delivery mode is disk-read, so this number feeds only a
        # cost estimate and the retry gate, and killing the reviewer to protect a
        # few cents of retry refuses work that would have succeeded. The opus seat
        # of the twin-sweep panel called that the expensive direction, and it is
        # right. $null scopes the failure to the decision the number feeds: the
        # retry is skipped, the reviewer still runs.
        Get-AgyBundleBytes -BundlePath (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-agy-bundle.xml') |
            Should -BeNullOrEmpty
    }

    It 'skips the retry rather than pricing it against an unknown size' {
        $src = Get-Content -Raw (Join-Path $script:Root 'backends/agy.ps1')
        $src | Should -Match 'if \(\$null -eq \$estInputTokens\)'
        $src | Should -Match 'Skipping retry: the bundle could not be sized'
    }

    It 'returns the real size when it can read it' {
        $f = Join-Path ([System.IO.Path]::GetTempPath()) ("era-agysz-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
        try {
            Set-Content -LiteralPath $f -Value ('z' * 4096) -NoNewline -Encoding ascii
            Get-AgyBundleBytes -BundlePath $f | Should -Be 4096
        } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}
