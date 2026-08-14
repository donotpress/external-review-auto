# Tests for workflow.ps1::Invoke-CostPrompt — the cost confirmation guard.
# These tests use ERA_FORCE=1 (non-interactive mode) to bypass Read-Host.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'workflow.ps1')
}

Describe 'Invoke-CostPrompt' {
    Context 'force mode (ERA_FORCE=1)' {
        It 'returns all reviewers when costs are under cap' {
            $env:ERA_FORCE = '1'
            try {
            $result = Invoke-CostPrompt -ReviewerList @('gemini', 'sonnet') `
                -PerReviewerCosts @{ gemini = 0.05; sonnet = 0.02 } `
                -AggregateCost 0.07 `
                -AggregateCap 15.0 `
                -PerReviewerCaps @{ gemini = 2.0; sonnet = 2.0 }
                $result.Count | Should -Be 2
                $result | Should -Contain 'gemini'
                $result | Should -Contain 'sonnet'
            } finally {
                Remove-Item Env:\ERA_FORCE -ErrorAction SilentlyContinue
            }
        }

        It 'returns all reviewers when individual costs exceed per-reviewer cap (force skips prompts)' {
            $env:ERA_FORCE = '1'
            try {
                $result = Invoke-CostPrompt -ReviewerList @('opus') `
                    -PerReviewerCosts @{ opus = 15.0 } `
                    -AggregateCost 15.0 `
                    -AggregateCap 15.0 `
                    -PerReviewerCaps @{ opus = 2.0 }
                $result.Count | Should -Be 1
                $result | Should -Contain 'opus'
            } finally {
                Remove-Item Env:\ERA_FORCE -ErrorAction SilentlyContinue
            }
        }

        It 'returns all reviewers when aggregate cost exceeds aggregate cap (force skips prompts)' {
            $env:ERA_FORCE = '1'
            try {
                $result = Invoke-CostPrompt -ReviewerList @('opus-api', 'sonnet-api') `
                    -PerReviewerCosts @{ 'opus-api' = 8.0; 'sonnet-api' = 8.0 } `
                    -AggregateCost 16.0 `
                    -PerReviewerCaps @{ 'opus-api' = 10.0; 'sonnet-api' = 10.0 } `
                    -AggregateCap 15.0
                $result.Count | Should -Be 2
            } finally {
                Remove-Item Env:\ERA_FORCE -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Get-ForceMode detection' {
        It 'returns true when ERA_FORCE=1' {
            $env:ERA_FORCE = '1'
            try {
                Get-ForceMode | Should -BeTrue
            } finally {
                Remove-Item Env:\ERA_FORCE -ErrorAction SilentlyContinue
            }
        }

        It 'returns false when ERA_FORCE is not set' {
            Remove-Item Env:\ERA_FORCE -ErrorAction SilentlyContinue
            # In a test environment, $host.Name is typically 'ConsoleHost',
            # and [Environment]::UserInteractive is $true, so Get-ForceMode
            # should return $false when ERA_FORCE is unset.
            $result = Get-ForceMode
            $result | Should -BeFalse
        }
    }
}

Describe 'Get-PerReviewerCap' {
    It 'returns cheap cap for pricing under $10/m' {
        $result = Get-PerReviewerCap -Pricing @{ input_per_m = 3.0; output_per_m = 15.0 }
        $result | Should -Be 2.0
    }

    It 'returns expensive cap for pricing >= $10/m' {
        $result = Get-PerReviewerCap -Pricing @{ input_per_m = 10.0; output_per_m = 50.0 }
        $result | Should -Be 10.0
    }
}

Describe 'Get-EraCostReport — the estimate is always reported, even under -Force' -Tag Unit {
    # Measured 2026-08-11: Invoke-CostPrompt returns the full reviewer list
    # immediately when Get-ForceMode is true, with NO cap check. Get-ForceMode is
    # true when -Force is passed OR when the host is non-interactive -- and
    # SKILL.md instructs the driving LLM to always pass -Force. So the $2/$10
    # per-reviewer caps and the $15 aggregate cap never fired in the documented
    # usage; they are enforced through a prompt that is always skipped.
    #
    # Decision (2026-08-11): report loudly, never block. Across 43 recorded
    # rounds nothing ever came close -- worst round $1.76 against a $15 cap,
    # worst single reviewer $1.71 against its $10 cap -- so blocking would have
    # bought nothing, while a wrong ceiling could refuse a legitimate large
    # round. Visibility is the gap worth closing.

    BeforeAll {
        $script:Caps = @{ gemini = 2.0; opus = 10.0; 'deepseek-flash' = 2.0 }
    }

    It 'lists every reviewer and the round total' {
        $r = Get-EraCostReport -ReviewerList @('gemini','opus') `
            -PerReviewerCosts @{ gemini = 0.03; opus = 1.71 } -PerReviewerCaps $script:Caps `
            -AggregateCost 1.74 -AggregateCap 15.0
        $joined = ($r.Lines -join ' ')
        $joined | Should -Match 'gemini'
        $joined | Should -Match 'opus'
        $joined | Should -Match '1\.7'
    }

    It 'is silent about caps when everything is under them' {
        $r = Get-EraCostReport -ReviewerList @('gemini','opus') `
            -PerReviewerCosts @{ gemini = 0.03; opus = 1.71 } -PerReviewerCaps $script:Caps `
            -AggregateCost 1.74 -AggregateCap 15.0
        @($r.Warnings).Count | Should -Be 0
        @($r.OverCap).Count  | Should -Be 0
    }

    It 'warns, by name and number, when a reviewer exceeds its own cap' {
        $r = Get-EraCostReport -ReviewerList @('gemini','opus') `
            -PerReviewerCosts @{ gemini = 0.03; opus = 12.40 } -PerReviewerCaps $script:Caps `
            -AggregateCost 12.43 -AggregateCap 15.0
        @($r.OverCap) | Should -Contain 'opus'
        ($r.Warnings -join ' ') | Should -Match 'opus'
        ($r.Warnings -join ' ') | Should -Match '12\.4'
        ($r.Warnings -join ' ') | Should -Match '10'
    }

    It 'warns when the ROUND total exceeds the aggregate cap' {
        $r = Get-EraCostReport -ReviewerList @('gemini','opus') `
            -PerReviewerCosts @{ gemini = 8.0; opus = 9.0 } -PerReviewerCaps @{ gemini = 20.0; opus = 20.0 } `
            -AggregateCost 17.0 -AggregateCap 15.0
        ($r.Warnings -join ' ') | Should -Match '17'
        ($r.Warnings -join ' ') | Should -Match '15'
    }

    It 'treats an unknown cost as unbounded rather than as zero' {
        # PowerShell coerces $null -le N to $true; Invoke-CostPrompt already
        # guards this and the report must not be more lenient than the gate.
        $r = Get-EraCostReport -ReviewerList @('gemini') `
            -PerReviewerCosts @{} -PerReviewerCaps $script:Caps `
            -AggregateCost 0 -AggregateCap 15.0
        @($r.OverCap) | Should -Contain 'gemini'
    }

    It 'is safe on an empty reviewer list' {
        $r = Get-EraCostReport -ReviewerList @() -PerReviewerCosts @{} -PerReviewerCaps @{} `
            -AggregateCost 0 -AggregateCap 15.0
        @($r.Warnings).Count | Should -Be 0
    }
}

Describe 'era.ps1 reports cost before the gate, and records it' -Tag Unit {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:EraSrc = Get-Content -Raw (Join-Path $root 'runtimes/era.ps1')
        $script:WfSrc  = Get-Content -Raw (Join-Path $root 'workflow.ps1')
    }

    It 'emits the report UNCONDITIONALLY, before Invoke-CostPrompt can skip out' {
        $report = $script:EraSrc.IndexOf('Get-EraCostReport')
        $prompt = $script:EraSrc.IndexOf('Invoke-CostPrompt -ReviewerList')
        $report | Should -BeGreaterThan 0
        $prompt | Should -BeGreaterThan 0
        $report | Should -BeLessThan $prompt -Because 'the prompt returns early under -Force; the report must already have run'
    }

    It 'carries the warnings into the round metadata' {
        $script:EraSrc | Should -Match '-CostWarnings'
        $script:WfSrc  | Should -Match 'cost_warnings'
    }
}
