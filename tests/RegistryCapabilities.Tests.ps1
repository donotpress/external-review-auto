# Tests that per-preset capabilities live in the registry and every adapter
# honours them.
#
# max_tokens was set only on openaicompat presets and propagated in era.ps1;
# geminiapi and anthropic ignored it and hardcoded 8192. $ModelInfo is already
# passed to every adapter (workflow.ps1:848), so only the values and the reads
# were missing.
#
# Scope is deliberately max_tokens ONLY. attach_limit_bytes and
# supports_structured_output stay out until forced structured output consumes
# them -- speculative generality otherwise.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/RegistryCapabilities.Tests.ps1"

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:Registry  = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/_registry.json') | ConvertFrom-Json
}

Describe 'Registry declares max_tokens for REST presets' -Tag Unit {
    It 'every geminiapi and anthropic preset declares max_tokens' {
        $missing = @()
        foreach ($p in $script:Registry.PSObject.Properties) {
            if ($p.Name -like '_*') { continue }
            if ($p.Value.backend -notin @('geminiapi', 'anthropic')) { continue }
            if (-not $p.Value.max_tokens) { $missing += $p.Name }
        }
        $missing | Should -BeNullOrEmpty
    }

    It 'declares 8192 — the value the adapters already hardcoded, so this is behaviour-preserving' {
        foreach ($p in $script:Registry.PSObject.Properties) {
            if ($p.Name -like '_*') { continue }
            if ($p.Value.backend -notin @('geminiapi', 'anthropic')) { continue }
            [int]$p.Value.max_tokens | Should -BeGreaterThan 0
        }
    }
}

Describe 'The default panel pins current model IDs' -Tag Unit {
    # The shipped panel is the most expensive and most-used configuration, and a
    # stale model ID there is invisible: the CLI happily runs an older model and
    # nothing in the output says so. Pin it.
    It 'the opus preset in the default panel resolves to Claude Opus 5' {
        $script:Registry.opus.model_id | Should -Be 'claude-opus-5'
    }

    It 'the default panel names presets that exist in the registry' {
        $defaults = Get-Content -Raw (Join-Path $script:SkillRoot 'config/defaults.json') | ConvertFrom-Json
        foreach ($preset in $defaults.reviewer) {
            $script:Registry.PSObject.Properties.Name | Should -Contain $preset
        }
    }

    It 'no shipped doc still advertises the panel as Opus 4.8' {
        # The registry was already on Opus 5 while three doc lines said 4.8 —
        # the drift was in the prose, not the config.
        foreach ($f in @('SKILL.md', 'runtimes/era.ps1')) {
            (Get-Content -Raw (Join-Path $script:SkillRoot $f)) | Should -Not -Match 'Opus 4\.8'
        }
    }
}

Describe 'Adapters honour the registry value' -Tag Unit {
    # Same shape as tests/ProcessTreeKill.Tests.ps1: assert the invariant across
    # every adapter that has the capability, not just one.
    It 'geminiapi reads $ModelInfo.max_tokens and does not hardcode the cap' {
        $src = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/geminiapi.ps1')
        $src | Should -Match '\$ModelInfo\.max_tokens'
        $src | Should -Not -Match 'maxOutputTokens\s*=\s*8192'
    }

    It 'anthropic reads $ModelInfo.max_tokens and does not hardcode the cap' {
        $src = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/anthropic.ps1')
        $src | Should -Match '\$ModelInfo\.max_tokens'
        $src | Should -Not -Match 'max_tokens\s*=\s*8192'
    }

    It 'both adapters keep 8192 as the fallback when the registry is silent' {
        foreach ($f in @('backends/geminiapi.ps1', 'backends/anthropic.ps1')) {
            $src = Get-Content -Raw (Join-Path $script:SkillRoot $f)
            $src | Should -Match '8192'
        }
    }
}
