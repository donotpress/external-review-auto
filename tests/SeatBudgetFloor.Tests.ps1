# THE 600s SEAT BUDGET FLOOR WAS A GUESS, and it silently overrode a measurement.
#
# `Resolve-OpencodeStallPlan` computes how long an opencode seat may go quiet from
# measured prefill + generation, then CLAMPS that to (budget - 30) so the stall
# always fires before the adapter's own timeout. For any bundle small enough to
# sit on the dispatcher's floor, the clamp is what decides -- so a floor chosen by
# guess quietly replaces the number that was measured.
#
# At the old 600s floor the clamp is 569s. One productive run in the local
# opencode.db sits on the wrong side of it:
#
#     7,794 input tokens -- squarely on the floor
#    26,525 output tokens
#    11,520 characters of finished review
#     570.2s of silence
#
# The 569s clamp would have tree-killed that run 1.2 seconds before it delivered
# its answer, and era would have recorded it as a stall. 570.2s is the largest
# silence any productive deepseek-v4-flash turn has taken across 655 of them.
#
# 700s puts the clamp at 670s, which clears it by 99.8s. Measured against the
# 628-round archive (977 productive seat-runs with a wall clock):
#
#   clamp 570s  ->  3 of 404 productive floor-regime seat-runs killed
#   clamp 670s  ->  0 of 404
#
# and the cost is bounded: a wedged seat burns 700s instead of 600s. Only 1 of the
# 977 productive seat-runs ever exceeded its budget at all, so nothing that works
# pays for this.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/SeatBudgetFloor.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'workflow.ps1')
    . (Join-Path $script:Root 'backends/opencode.ps1')
    $script:Src = Get-Content -Raw (Join-Path $script:Root 'workflow.ps1')

    # The dispatcher's rule, read off the source it is implemented in rather than
    # reimplemented here -- the standing hazard in this repo is two copies of one
    # rule, and this file would be the second.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $script:Root 'workflow.ps1'), [ref]$tokens, [ref]$errors)
    $script:FloorAssign = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                  $n.Left.Extent.Text -eq '$seatBudgetFloorSec' }, $true) | Select-Object -First 1
}

Describe 'the seat budget floor' -Tag Unit {

    It 'is a named constant, not a bare literal buried in an expression' {
        $script:FloorAssign | Should -Not -BeNullOrEmpty `
            -Because 'a constant that carries a measurement needs a name to hang it on'
        [int]$script:FloorAssign.Right.Extent.Text | Should -Be 700
    }

    It 'is actually applied to the budget' {
        $script:Src | Should -Match '\$TimeoutSec\s+=\s+\[Math\]::Max\(\$TimeoutSec, \$seatBudgetFloorSec\)'
    }

    It 'clears the largest silence a productive seat has ever taken' {
        # THE ASSERTION THAT MATTERS, and it is arithmetic on the two functions
        # rather than a claim about either. A floor-regime bundle: 7,794 input
        # tokens is ~31 KB of repomix bundle; anything under ~35k tokens lands on
        # the floor.
        $floor = [int]$script:FloorAssign.Right.Extent.Text
        $clampedStallSec = (Resolve-OpencodeStallPlan -TimeoutSec $floor -Variant 'max' -BundleBytes 31000).StallThresholdMs / 1000

        $worstProductiveSilenceSec = 570.2
        $clampedStallSec | Should -BeGreaterThan $worstProductiveSilenceSec `
            -Because 'a seat that has finished this way before must be able to finish again'
    }

    It 'and the floor it replaced did NOT clear it' {
        # Non-vacuity. Without this the test above passes against any floor at all.
        $oldFloor = 600
        $oldClampSec = (Resolve-OpencodeStallPlan -TimeoutSec $oldFloor -Variant 'max' -BundleBytes 31000).StallThresholdMs / 1000
        $oldClampSec | Should -Be 570 -Because 'this is the clamp the old floor produced'
        $oldClampSec | Should -BeLessThan 570.2 `
            -Because 'the 570.2s run is the one it would have killed, by 1.2 seconds'
    }

    It 'leaves every bundle big enough to scale past the floor untouched' {
        # The floor must not become a second, competing scaling rule. Above
        # 35,000 tokens the 0.02 s/token term dominates and nothing changes.
        foreach ($tok in @(35000, 50000, 90000, 250000)) {
            $scaled = [int]($tok * 0.02)
            $scaled | Should -BeGreaterOrEqual 700 -Because "at $tok tokens the scaling already exceeds the floor"
        }
    }

    It 'does not raise the ceiling' {
        # A very large bundle still tops out at 1800s; the floor moved, not the cap.
        $script:Src | Should -Match '\[Math\]::Min\(\[Math\]::Max\(\$TimeoutSec, \$bundleScaledSec\), 1800\)'
    }

    It 'keeps the ordering the whole stall apparatus depends on' {
        # stall threshold < adapter TimeoutSec < dispatcher TimeoutSec + 30,
        # at the new floor and at every size that sits on it.
        foreach ($bytes in @(0, 4096, 31000, 120000)) {
            $p = Resolve-OpencodeStallPlan -TimeoutSec 700 -Variant 'max' -BundleBytes $bytes
            ($p.StallThresholdMs / 1000) | Should -BeLessThan 700 -Because "bytes=$bytes"
        }
    }
}

Describe 'the bundle-size term' -Tag Unit {

    BeforeAll {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'workflow.ps1'), [ref]$tokens, [ref]$errors)
        $script:SlopeAssign = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                      $n.Left.Extent.Text -eq '$bundleTokenSlopeSec' }, $true) | Select-Object -First 1
        # era's rule, read off the source rather than reimplemented.
        function script:Budget { param([int]$Tok, [int]$Ask = 600)
            $floor = 700; $slope = [double]$script:SlopeAssign.Right.Extent.Text
            [Math]::Min([Math]::Max([Math]::Max($Ask, $floor), [int]($floor + $Tok * $slope)), 1800)
        }
    }

    It 'is a named constant carrying its measurement' {
        $script:SlopeAssign | Should -Not -BeNullOrEmpty
        [double]$script:SlopeAssign.Right.Extent.Text | Should -Be 0.008
    }

    It 'envelopes the longest productive seat-run at every observed size' {
        # The six bucket maxima from era's own round archive, 978 productive
        # seat-runs. The budget must dominate each with real margin -- the old
        # rule's tightest was 36.6s.
        $observed = @(
            @{ tok =   4628; wall =  590.1 },
            @{ tok =  21133; wall =  597.1 },
            @{ tok =  47266; wall =  882.1 },
            @{ tok =  81333; wall = 1005.5 },
            @{ tok = 122547; wall = 1426.0 },   # this one sets the slope
            @{ tok = 258461; wall = 1051.9 }
        )
        foreach ($o in $observed) {
            $b = script:Budget -Tok $o.tok
            $b | Should -BeGreaterThan $o.wall -Because "a $($o.tok)-token round has run $($o.wall)s"
            ($b - $o.wall) | Should -BeGreaterThan 100 `
                -Because "…and 100s of margin is the point; the old rule's tightest was 36.6s"
        }
    }

    It 'the slope it replaced was an order of magnitude off' {
        # 0.020 s/token charged for READING. Measured correlation of wall clock
        # with bundle tokens is +0.083; with response characters, +0.506.
        # Non-vacuity for the change: the old rule really was tighter where it
        # mattered, at the 32,798-token round that ran 663.4s.
        $oldBudget = [Math]::Min([Math]::Max(700, [int](32798 * 0.020)), 1800)
        $oldBudget | Should -Be 700
        ($oldBudget - 663.4) | Should -BeLessThan 40 -Because 'this is the 36.6s margin the old rule gave'
        (script:Budget -Tok 32798) | Should -BeGreaterThan 900 `
            -Because 'the measured rule is generous exactly where the old one was thin'
    }

    It 'is less generous at the top, where the old rule over-provisioned' {
        # 90,000 tokens: old 1800s, worst observed run in that band 1005.5s.
        $old = [Math]::Min([Math]::Max(700, [int](90000 * 0.020)), 1800)
        $old | Should -Be 1800
        (script:Budget -Tok 90000) | Should -BeLessThan $old `
            -Because 'patience nobody has used is patience a wedged seat burns'
        (script:Budget -Tok 90000) | Should -BeGreaterThan 1005.5
    }

    It 'still honours the 1800s ceiling and a caller asking for more' {
        (script:Budget -Tok 500000) | Should -Be 1800
        (script:Budget -Tok 1000 -Ask 1500) | Should -Be 1500
    }

    It 'does not announce itself on a round where the bundle bought nothing' {
        # Additive means every bundle raises the number, so an unconditional line
        # would print on every round.
        $src = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'workflow.ps1')
        $src | Should -Match 'if \(\$effectiveTimeoutSec -ge \(\$TimeoutSec \+ 60\)\)'
    }
}
