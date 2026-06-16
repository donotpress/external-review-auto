BeforeAll { . "$PSScriptRoot/../workflow.ps1" }
Describe 'Resolve-EraAuthJsonKeys' {
    BeforeEach {
        $script:fake = New-TemporaryFile
        @{ 'opencode-go' = @{ type='api'; key='OC_SECRET' }; 'google' = @{ type='oauth'; access='x' } } |
            ConvertTo-Json | Set-Content $script:fake
        [Environment]::SetEnvironmentVariable('OPENCODE_API_KEY', $null)
        [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $null)
    }
    It 'fills an empty known env var from auth.json' {
        Resolve-EraAuthJsonKeys -ApiKeyEnvs @('OPENCODE_API_KEY') -AuthPath $script:fake
        [Environment]::GetEnvironmentVariable('OPENCODE_API_KEY') | Should -Be 'OC_SECRET'
    }
    It 'never overwrites an env var that is already set' {
        [Environment]::SetEnvironmentVariable('OPENCODE_API_KEY', 'PREEXISTING')
        Resolve-EraAuthJsonKeys -ApiKeyEnvs @('OPENCODE_API_KEY') -AuthPath $script:fake
        [Environment]::GetEnvironmentVariable('OPENCODE_API_KEY') | Should -Be 'PREEXISTING'
    }
    It 'ignores env vars with no provider mapping' {
        Resolve-EraAuthJsonKeys -ApiKeyEnvs @('ANTHROPIC_API_KEY') -AuthPath $script:fake
        [Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY') | Should -BeNullOrEmpty
    }
    AfterEach { [Environment]::SetEnvironmentVariable('OPENCODE_API_KEY', $null) }
}
