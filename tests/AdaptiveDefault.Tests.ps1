# Adaptive default-reviewer selection: when -Reviewer is omitted, /era should pick
# the first AVAILABLE backend (live-detected) instead of blindly defaulting to agy
# and erroring if agy isn't installed. Resolvers are injected so it's testable.

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'workflow.ps1')
    $script:Reg = [pscustomobject]@{
        'gemini-pro-low' = [pscustomobject]@{ backend = 'agy' }
        'sonnet'         = [pscustomobject]@{ backend = 'claude' }
        'deepseek'       = [pscustomobject]@{ backend = 'opencode' }
        'gemini-api'     = [pscustomobject]@{ backend = 'geminiapi' }
        'deepseek-api'   = [pscustomobject]@{ backend = 'openaicompat'; api_key_env = 'DEEPSEEK_API_KEY' }
    }
}

Describe 'Test-EraBackendAvailable' {
    It 'detects a CLI backend via CommandExists' {
        Test-EraBackendAvailable -Backend 'claude' -CommandExists { param($n) $n -eq 'claude' } -EnvValue { $null } | Should -BeTrue
        Test-EraBackendAvailable -Backend 'agy'    -CommandExists { param($n) $n -eq 'claude' } -EnvValue { $null } | Should -BeFalse
    }
    It 'detects a REST backend via its env var' {
        Test-EraBackendAvailable -Backend 'geminiapi' -CommandExists { $false } -EnvValue { param($n) if ($n -eq 'GEMINI_API_KEY') { 'k' } } | Should -BeTrue
    }
    It 'detects openaicompat via the preset api_key_env' {
        Test-EraBackendAvailable -Backend 'openaicompat' -ApiKeyEnv 'DEEPSEEK_API_KEY' -CommandExists { $false } -EnvValue { param($n) if ($n -eq 'DEEPSEEK_API_KEY') { 'k' } } | Should -BeTrue
        Test-EraBackendAvailable -Backend 'openaicompat' -ApiKeyEnv 'DEEPSEEK_API_KEY' -CommandExists { $false } -EnvValue { $null } | Should -BeFalse
    }
}

Describe 'Resolve-DefaultReviewer' {
    It 'prefers gemini-pro-low when agy is available' {
        Resolve-DefaultReviewer -Registry $script:Reg -CommandExists { $true } -EnvValue { $null } | Should -Be 'gemini-pro-low'
    }
    It 'falls back to sonnet (claude) when agy is absent but claude is present' {
        Resolve-DefaultReviewer -Registry $script:Reg -CommandExists { param($n) $n -eq 'claude' } -EnvValue { $null } | Should -Be 'sonnet'
    }
    It 'falls back to deepseek (opencode) when only opencode is present' {
        Resolve-DefaultReviewer -Registry $script:Reg -CommandExists { param($n) $n -eq 'opencode' } -EnvValue { $null } | Should -Be 'deepseek'
    }
    It 'falls back to a REST preset when only an API key is set' {
        Resolve-DefaultReviewer -Registry $script:Reg -CommandExists { $false } -EnvValue { param($n) if ($n -eq 'GEMINI_API_KEY') { 'k' } } | Should -Be 'gemini-api'
    }
    It 'returns $null when nothing is available' {
        Resolve-DefaultReviewer -Registry $script:Reg -CommandExists { $false } -EnvValue { $null } | Should -BeNullOrEmpty
    }
    It 'honors a custom preference order (the ERA_DEFAULT_REVIEWER override)' {
        Resolve-DefaultReviewer -Registry $script:Reg -Preference @('deepseek','sonnet') -CommandExists { $true } -EnvValue { $null } | Should -Be 'deepseek'
    }
}
