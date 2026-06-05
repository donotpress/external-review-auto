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
