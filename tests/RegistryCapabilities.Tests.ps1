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

    # Was 'declares 8192 — the value the adapters already hardcoded'. The
    # anthropic presets moved to 16384 when they moved to Opus 5 / Sonnet 5,
    # which think by default and spend that budget on thinking as well as
    # response text. The assertion was always a >0 floor; only the title
    # claimed a specific number, so only the title needed correcting.
    It 'declares a positive max_tokens for every REST preset' {
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

    # --- the two-doors invariant -------------------------------------------
    # A Claude model reaches the dispatcher through TWO independent doors:
    #   -Reviewer <preset>  -> the preset table's model_id
    #   -Model <hint>       -> _claude_model_map.<hint>.default.model_id
    # 562209f pinned the `opus` PRESET to Opus 5 and left the HINT MAP on
    # Opus 4.7, so the same word meant two different models depending on which
    # flag you used, and nothing in the output said so. Neither table is
    # authoritative over the other — they simply must not disagree.
    It '_claude_model_map agrees with the preset table on every shared name' {
        $disagreements = foreach ($p in $script:Registry._claude_model_map.PSObject.Properties) {
            $name = $p.Name
            $preset = $script:Registry.$name
            if (-not $preset) { continue }   # hint with no same-named preset
            $hintId   = $p.Value.default.model_id
            $presetId = $preset.model_id
            if ($hintId -ne $presetId) { "${name}: hint=$hintId preset=$presetId" }
        }
        @($disagreements) -join '; ' | Should -BeNullOrEmpty
    }

    It 'no Claude preset or hint pins a superseded Opus or Sonnet generation' {
        # opus-48 is the deliberate A/B holdback and is exempt by name.
        $superseded = @('claude-opus-4-7', 'claude-opus-4-6', 'claude-opus-4-5',
                        'claude-sonnet-4-6', 'claude-sonnet-4-5')

        $stale = foreach ($p in $script:Registry.PSObject.Properties) {
            if ($p.Name -like '_*' -or $p.Name -eq 'opus-48') { continue }
            if ($p.Value.model_id -in $superseded) { "$($p.Name)=$($p.Value.model_id)" }
        }
        foreach ($p in $script:Registry._claude_model_map.PSObject.Properties) {
            if ($p.Value.default.model_id -in $superseded) {
                $stale += "_claude_model_map.$($p.Name)=$($p.Value.default.model_id)"
            }
        }
        @($stale) -join '; ' | Should -BeNullOrEmpty
    }

    It 'Opus presets carry current Opus-tier pricing, not the Claude-3-era rate' {
        # Measured against the published catalogue 2026-08-09: the whole current
        # Opus tier (4.7, 4.8, 5) is $5/$25 per Mtok. The registry carried
        # $15/$75 — Claude 3 Opus pricing — which made every Opus estimate 3x
        # too high and tripped Invoke-CostPrompt's $15 aggregate cap early.
        foreach ($name in @('opus', 'opus-api', 'opus-48')) {
            $script:Registry.$name.pricing.input_per_m  | Should -Be 5.0  -Because "$name input"
            $script:Registry.$name.pricing.output_per_m | Should -Be 25.0 -Because "$name output"
        }
    }

    It 'the default panel names presets that exist in the registry' {
        $defaults = Get-Content -Raw (Join-Path $script:SkillRoot 'config/defaults.json') | ConvertFrom-Json
        foreach ($preset in $defaults.reviewer) {
            $script:Registry.PSObject.Properties.Name | Should -Contain $preset
        }
    }

    It 'the default panel contains no RETIRED preset' {
        # 2026-08-26: `ox-alpha` disappeared from `opencode models` entirely, and
        # it was sitting in the default panel. Every bare /era then dispatched a
        # reviewer that could not run — measured on this box's own artifacts,
        # rounds 1-3 returned an ox-alpha response and round 4 returned none,
        # with the panel silently degrading 4 -> 3 and no error reaching the
        # caller.
        #
        # Existing-in-the-registry is NOT the same as still-being-offered, which
        # is why the check above did not catch it. Anything marked `retired`
        # stays selectable by name (so it fails loudly) but must never be a
        # default.
        $defaults = Get-Content -Raw (Join-Path $script:SkillRoot 'config/defaults.json') | ConvertFrom-Json
        foreach ($preset in $defaults.reviewer) {
            [bool]$script:Registry.$preset.retired | Should -BeFalse -Because "$preset is retired"
        }
    }

    It 'every opencode preset has a _opencode_model_map entry' {
        # THE STALL-THRESHOLD TRAP, generalised. `_opencode_model_map` is what
        # sets the stall budget: with no entry, era resolves variant='default'
        # (120s base) and kills a reasoning model mid-think having captured only
        # its banner. ox-alpha lost two smoke tests to exactly this before the
        # cause was found, and the fix was recorded only in a note on one entry —
        # so the next opencode preset added would have repeated it. Now it fails
        # the build instead.
        $map = $script:Registry._opencode_model_map
        foreach ($prop in $script:Registry.PSObject.Properties) {
            $preset = $prop.Value
            if ($prop.Name.StartsWith('_')) { continue }
            if ($preset.backend -ne 'opencode') { continue }
            if ($preset.retired) { continue }
            $providerEntry = $map.($preset.opencode_provider)
            $providerEntry | Should -Not -BeNullOrEmpty -Because "$($prop.Name) names an unmapped provider"
            # Asserts the ENTRY EXISTS, not that `variants` is non-empty: an empty
            # list is legitimate for a model that has no variants, and several
            # minimax entries are exactly that. A MISSING entry is what actually
            # caused the ox-alpha stall deaths. (Whether minimax's empty list is
            # right for a reasoning-heavy model is a separate, unverified
            # question — flagged here rather than silently exempted.)
            $matched = @($providerEntry.PSObject.Properties.Value |
                Where-Object { $_.model_id -eq $preset.model_id })
            $matched.Count | Should -BeGreaterThan 0 -Because (
                "$($prop.Name) ($($preset.model_id)) has NO _opencode_model_map entry at all, " +
                "so era cannot discover its variants and dispatches it at the 120s default " +
                "stall budget"
            )
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
