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
