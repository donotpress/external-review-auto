# PR-A structural tests: per-session agy --model selection, removal of the
# settings.json swap + global mutex, Run-ID transcript correlation params,
# and era.ps1 resolving a default agy settings_value via -ResolvedAgyModel.

BeforeAll {
    $script:SkillRoot   = Split-Path $PSScriptRoot -Parent
    $script:AgySource   = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/agy.ps1')
    $script:WorkflowSrc = Get-Content -Raw (Join-Path $script:SkillRoot 'workflow.ps1')
    $script:EraSource   = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1')
}

Describe 'agy.ps1 selects the model via the --model flag' {
    It 'adds --model to the agy ArgumentList' {
        $script:AgySource | Should -Match "ArgumentList\.Add\(\s*'--model'\s*\)" `
            -Because 'model selection must be per-process via --model, not a settings.json swap'
    }

    It 'does NOT reference Set-AgyModel' {
        $script:AgySource | Should -Not -Match 'Set-AgyModel'
    }

    It 'does NOT reference Restore-AgyOriginalModel' {
        $script:AgySource | Should -Not -Match 'Restore-AgyOriginalModel'
    }

    It 'does NOT reference Get-CurrentAgyModel' {
        $script:AgySource | Should -Not -Match 'Get-CurrentAgyModel'
    }

    It 'does NOT reference the global settings mutex' {
        $script:AgySource | Should -Not -Match 'era-agy-settings-mutex'
    }

    It 'does NOT keep the $script:SavedAgyModel / $script:AgyBackupPath state' {
        $script:AgySource | Should -Not -Match '\$script:SavedAgyModel'
        $script:AgySource | Should -Not -Match '\$script:AgyBackupPath'
    }

    It 'preserves the env-scrub block (spawn-hardening must remain)' {
        $script:AgySource | Should -Match '\$psi\.Environment'
        $script:AgySource | Should -Match '\$psi\.CreateNoWindow\s*=\s*\$true'
    }
}

Describe 'agy adapter signature' {
    BeforeAll {
        . (Join-Path $script:SkillRoot 'backends/agy.ps1')
        $script:AgyCmd = Get-Command Invoke-AgyReview
    }

    It 'merged Invoke-AgyReview keeps -AgyModelHint / -ModelOverride' {
        $script:AgyCmd.Parameters.Keys | Should -Contain 'AgyModelHint'
        $script:AgyCmd.Parameters.Keys | Should -Contain 'ModelOverride'
    }

    It 'adds -ResolvedAgyModel' {
        $script:AgyCmd.Parameters.Keys | Should -Contain 'ResolvedAgyModel'
    }

    It 'accepts (and ignores) -OpencodeProvider' {
        $script:AgyCmd.Parameters.Keys | Should -Contain 'OpencodeProvider'
    }

    It 'defines an inner _SpawnAndCaptureOnce helper' {
        $script:AgySource | Should -Match '_SpawnAndCaptureOnce'
    }
}

Describe 'workflow.ps1 no longer blocks concurrent agy reviewers' {
    It 'does NOT define or call Test-ConcurrentAgyReviewers' {
        $script:WorkflowSrc | Should -Not -Match 'Test-ConcurrentAgyReviewers'
    }

    It 'threads -ResolvedAgyModel through the dispatcher' {
        $script:WorkflowSrc | Should -Match '-ResolvedAgyModel'
    }
}

Describe 'Get-AgyTranscriptResponse param block (Run-ID correlation)' {
    BeforeAll {
        . (Join-Path $script:SkillRoot 'backends/agy.ps1')
        $script:GetCmd = Get-Command Get-AgyTranscriptResponse
    }

    It 'includes $BundlePath' {
        $script:GetCmd.Parameters.Keys | Should -Contain 'BundlePath'
    }

    It 'includes $DispatchId' {
        $script:GetCmd.Parameters.Keys | Should -Contain 'DispatchId'
    }
}

Describe 'agy stall/deadline tuning (Fix 7)' {
    It 'removes the 360s hard-deadline cap' {
        $script:AgySource | Should -Not -Match "Min\(\s*\`$TimeoutSec\s*-\s*10\s*,\s*360\s*\)" `
            -Because 'the 360s clamp killed large-bundle Pro runs mid-think'
        $script:AgySource | Should -Not -Match ',\s*360\s*\)'
    }

    It 'deadline tracks $TimeoutSec' {
        $script:AgySource | Should -Match 'AddSeconds\(\s*\$TimeoutSec\s*-\s*5\s*\)'
    }

    It 'defines named Pro/Flash stall constants' {
        $script:AgySource | Should -Match '\$proStallSec\s*=\s*180'
        $script:AgySource | Should -Match '\$flashStallSec\s*=\s*90'
    }

    It 'scales stall off $TimeoutSec with a tier floor' {
        $script:AgySource | Should -Match '\[Math\]::Max\(\s*\$tierFloor\s*,\s*\[int\]\(\s*\$TimeoutSec\s*\*\s*0\.25\s*\)\s*\)'
    }
}

Describe 'agy kills the whole process tree on stall/timeout (R-C2)' {
    # agy resolves to agy.cmd (a shim) which spawns node.exe as a child. A bare
    # $agyProc.Kill() terminates only the cmd wrapper, orphaning the node agent as
    # a zombie. Kill($true) tears down the entire tree (PS7). Found live in the
    # convergence loop.
    It 'uses Kill($true) to tear down the process tree' {
        $script:AgySource | Should -Match '\.Kill\(\s*\$true\s*\)'
    }
    It 'does NOT use a bare .Kill() that would orphan the node child' {
        $script:AgySource | Should -Not -Match '\.Kill\(\s*\)'
    }
}

Describe 'era.ps1 resolves a default agy settings_value and passes -ResolvedAgyModel' {
    It 'preserves agy_model_family / agy_model_tier in the registryHash copy' {
        $script:EraSource | Should -Match 'agy_model_family'
        $script:EraSource | Should -Match 'agy_model_tier'
    }

    It 'passes the agy model map into Invoke-ReviewerDispatch for per-reviewer default resolution' {
        # PR-A originally passed a single batch -ResolvedAgyModel (first agy
        # reviewer's token), which collapsed heterogeneous agy batches to one
        # model. The fix hands the dispatcher the _agy_model_map so each agy
        # reviewer derives its own default from its preset family/tier.
        $script:EraSource | Should -Match '-AgyModelMap'
        $script:EraSource | Should -Match '_agy_model_map'
    }
}

Describe 'per-reviewer agy default --model resolution (heterogeneous batch)' {
    # Regression for the spec-review finding: with -Reviewer gemini,gemini-pro-low
    # and NO -Model hint, both ThreadJobs were receiving the FIRST agy reviewer's
    # default settings_value, so gemini-pro-low wrongly ran Flash. The default
    # --model token MUST be resolved per reviewer from THAT reviewer's own
    # agy_model_family/agy_model_tier -> _agy_model_map[family][tier].settings_value.
    BeforeAll {
        . (Join-Path $script:SkillRoot 'workflow.ps1')
        $script:Reg     = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/_registry.json') | ConvertFrom-Json
        # Build the same family/tier map era.ps1 hands the dispatcher.
        $script:AgyMap  = @{}
        $script:Reg._agy_model_map.PSObject.Properties | ForEach-Object { $script:AgyMap[$_.Name] = $_.Value }
        # Per-reviewer family/tier from the registry presets.
        $script:Gemini      = $script:Reg.'gemini'
        $script:GeminiProLo = $script:Reg.'gemini-pro-low'
    }

    It 'exposes a callable per-reviewer resolver (Resolve-AgyDefaultModelToken)' {
        Get-Command Resolve-AgyDefaultModelToken -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "resolves gemini's default to 'Gemini 3.5 Flash (High)'" {
        $token = Resolve-AgyDefaultModelToken -AgyModelMap $script:AgyMap `
            -Family $script:Gemini.agy_model_family -Tier $script:Gemini.agy_model_tier
        $token | Should -BeExactly 'Gemini 3.5 Flash (High)'
    }

    It "resolves gemini-pro-low's default to 'Gemini 3.1 Pro (Low)'" {
        $token = Resolve-AgyDefaultModelToken -AgyModelMap $script:AgyMap `
            -Family $script:GeminiProLo.agy_model_family -Tier $script:GeminiProLo.agy_model_tier
        $token | Should -BeExactly 'Gemini 3.1 Pro (Low)'
    }

    It 'yields TWO DISTINCT --model tokens for a gemini,gemini-pro-low batch' {
        $tokens = @('gemini', 'gemini-pro-low') | ForEach-Object {
            $preset = $script:Reg.$_
            Resolve-AgyDefaultModelToken -AgyModelMap $script:AgyMap `
                -Family $preset.agy_model_family -Tier $preset.agy_model_tier
        }
        ($tokens | Select-Object -Unique).Count | Should -Be 2 `
            -Because 'a heterogeneous agy batch must not collapse to one model'
        $tokens[0] | Should -BeExactly 'Gemini 3.5 Flash (High)'
        $tokens[1] | Should -BeExactly 'Gemini 3.1 Pro (Low)'
    }
}
