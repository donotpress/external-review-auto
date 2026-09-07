# Tests for backends/_registry.json — catches typos when adding new presets.
# These are pure structural assertions; they don't touch CLIs or networks.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:RegistryPath = Join-Path $script:SkillRoot 'backends/_registry.json'
    $script:Registry = Get-Content -Raw $script:RegistryPath | ConvertFrom-Json

    # Real (non-helper) presets. Helper keys start with underscore.
    $script:Presets = $script:Registry.PSObject.Properties |
        Where-Object { -not $_.Name.StartsWith('_') }
}

Describe 'Registry: structural integrity' {
    It 'parses as valid JSON' {
        # If the BeforeAll ConvertFrom-Json didn't throw, we're good.
        $script:Registry | Should -Not -BeNullOrEmpty
    }

    It 'has at least one real preset' {
        $script:Presets.Count | Should -BeGreaterThan 0
    }
}

Describe 'Registry: every preset must have required fields' {
    It '<preset> has backend, model_id, pricing.input_per_m, pricing.output_per_m' -ForEach @(
        @{ preset = 'gemini' }
        @{ preset = 'gemini-pro-high' }
        @{ preset = 'gemini-pro-low' }
        @{ preset = 'opus' }
        @{ preset = 'sonnet' }
        @{ preset = 'haiku' }
        @{ preset = 'minimax' }
        @{ preset = 'deepseek' }
        @{ preset = 'gemini-api' }
        @{ preset = 'gemini-api-pro' }
        @{ preset = 'opus-api' }
        @{ preset = 'sonnet-api' }
        @{ preset = 'haiku-api' }
        @{ preset = 'deepseek-api' }
        @{ preset = 'deepseek-reasoner-api' }
        @{ preset = 'minimax-api' }
        @{ preset = 'longcat' }
        @{ preset = 'laguna-free' }
        @{ preset = 'grok' }
        @{ preset = 'qwen-max' }
        @{ preset = 'glm' }
        @{ preset = 'glm-flash' }
        @{ preset = 'kimi' }
        @{ preset = 'minimax-m3' }
        @{ preset = 'qwen-flash' }
    ) {
        $entry = $script:Registry.$preset
        $entry | Should -Not -BeNullOrEmpty -Because "preset '$preset' must exist in registry"
        $entry.backend | Should -Not -BeNullOrEmpty -Because "preset '$preset' must have a backend"
        $entry.model_id | Should -Not -BeNullOrEmpty -Because "preset '$preset' must have a model_id"
        $entry.pricing | Should -Not -BeNullOrEmpty -Because "preset '$preset' must have pricing"
        $entry.pricing.input_per_m | Should -BeGreaterOrEqual 0 -Because "preset '$preset' input_per_m must be a number >= 0"
        $entry.pricing.output_per_m | Should -BeGreaterOrEqual 0 -Because "preset '$preset' output_per_m must be a number >= 0"
    }
}

Describe 'Registry: every backend must resolve to a .ps1 file' {
    It 'backend <backend> file exists' -ForEach @(
        @{ backend = 'agy' }
        @{ backend = 'claude' }
        @{ backend = 'opencode' }
        @{ backend = 'geminiapi' }
        @{ backend = 'anthropic' }
        @{ backend = 'openaicompat' }
        @{ backend = 'tmux' }
        @{ backend = 'cmdc' }
    ) {
        $path = Join-Path $script:SkillRoot "backends/$backend.ps1"
        Test-Path $path | Should -BeTrue -Because "backend '$backend' is referenced from registry but $path doesn't exist"
    }

    It 'every preset references a backend with an existing .ps1' {
        foreach ($p in $script:Presets) {
            $backendFile = Join-Path $script:SkillRoot "backends/$($p.Value.backend).ps1"
            Test-Path $backendFile | Should -BeTrue -Because "preset '$($p.Name)' references backend '$($p.Value.backend)' but $backendFile is missing"
        }
    }
}

Describe 'Registry: REST-backed presets must declare api_base + api_key_env' {
    It 'openaicompat preset <preset> has api_base and api_key_env' -ForEach @(
        @{ preset = 'deepseek-api' }
        @{ preset = 'deepseek-reasoner-api' }
        @{ preset = 'minimax-api' }
    ) {
        $entry = $script:Registry.$preset
        $entry.api_base | Should -Not -BeNullOrEmpty -Because "openaicompat preset '$preset' must have api_base"
        $entry.api_base | Should -Match '^https://' -Because "openaicompat api_base for '$preset' must be HTTPS"
        $entry.api_key_env | Should -Not -BeNullOrEmpty -Because "openaicompat preset '$preset' must have api_key_env"
        $entry.api_key_env | Should -Match '^[A-Z_]+$' -Because "api_key_env for '$preset' should be all-caps with underscores"
    }
}

Describe 'Registry: function-name resolution from backend name' {
    # The dispatcher uses TitleCase(backend) to compute the function name:
    #   $fnName = "Invoke-$((Get-Culture).TextInfo.ToTitleCase($backend))Review"
    # This must produce a name that exists in the backend's .ps1.
    It 'backend <backend> exposes function <expectedFn>' -ForEach @(
        @{ backend = 'agy';          expectedFn = 'Invoke-AgyReview' }
        @{ backend = 'claude';       expectedFn = 'Invoke-ClaudeReview' }
        @{ backend = 'opencode';     expectedFn = 'Invoke-OpencodeReview' }
        @{ backend = 'geminiapi';    expectedFn = 'Invoke-GeminiapiReview' }
        @{ backend = 'anthropic';    expectedFn = 'Invoke-AnthropicReview' }
        @{ backend = 'openaicompat'; expectedFn = 'Invoke-OpenaicompatReview' }
        @{ backend = 'tmux';         expectedFn = 'Invoke-TmuxReview' }
        @{ backend = 'cmdc';         expectedFn = 'Invoke-CmdcReview' }
    ) {
        $computed = "Invoke-$((Get-Culture).TextInfo.ToTitleCase($backend))Review"
        $computed | Should -Be $expectedFn

        $content = Get-Content -Raw (Join-Path $script:SkillRoot "backends/$backend.ps1")
        $content | Should -Match "function\s+$expectedFn\s*\{" -Because "backend file must define $expectedFn"
    }
}

Describe 'Registry: cmdc presets' {
    # These assert on registry DATA, never on notes prose -- a test that greps a
    # comment passes on the comment that explains the thing rather than on the
    # thing itself, which has already bitten this repo twice.

    BeforeAll {
        $script:CmdcPresets = @($script:Presets | Where-Object { $_.Value.backend -eq 'cmdc' })
    }

    It 'has at least one cmdc preset' {
        $script:CmdcPresets.Count | Should -BeGreaterThan 0
    }

    It 'cmdc_effort, where set, is a level cmdc accepts' {
        # cmdc 1.50.0 VALIDATES --effort and refuses an unsupported one, which the
        # adapter reports as a preset bug (backends/cmdc.ps1:316). A typo here
        # costs a dispatch, so catch it structurally instead.
        $valid = @('low', 'medium', 'high', 'xhigh', 'max')
        foreach ($p in $script:Presets) {
            $eff = $p.Value.cmdc_effort
            if ($null -ne $eff -and $eff -ne '') {
                $valid | Should -Contain $eff -Because "preset '$($p.Name)' sets cmdc_effort='$eff', which cmdc will refuse"
            }
        }
    }

    It 'only a cmdc preset sets cmdc_effort' {
        # On any other backend the key is inert: nothing reads it, so it would
        # silently promise a reasoning level the seat never receives.
        foreach ($p in $script:Presets) {
            if ($null -ne $p.Value.cmdc_effort -and $p.Value.cmdc_effort -ne '') {
                $p.Value.backend | Should -Be 'cmdc' -Because "preset '$($p.Name)' sets cmdc_effort but runs on backend '$($p.Value.backend)', which never reads it"
            }
        }
    }

    It 'every cmdc model_id is <provider>/<model>, the form cmdc --list-models prints' {
        foreach ($p in $script:CmdcPresets) {
            $p.Value.model_id | Should -Match '^[A-Za-z0-9._-]+/[A-Za-z0-9._:-]+$' -Because "preset '$($p.Name)' model_id '$($p.Value.model_id)' is not in the provider/model form cmdc expects"
        }
    }
}
