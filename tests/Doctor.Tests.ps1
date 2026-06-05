# Tests for the `-Doctor` preflight: Get-EraDoctorReport (checks gatherer, with
# injectable resolvers so PATH/module/env probing is testable) +
# Format-EraDoctorReport (pure renderer + readiness verdict).

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'workflow.ps1')

    # A raw-registry-shaped object (as ConvertFrom-Json yields): presets + an
    # underscore meta key that must be ignored.
    $script:Reg = [pscustomobject]@{
        'gemini'       = [pscustomobject]@{ backend = 'agy' }
        'opus'         = [pscustomobject]@{ backend = 'claude' }
        'haiku'        = [pscustomobject]@{ backend = 'claude' }   # dedups with opus
        'gemini-api'   = [pscustomobject]@{ backend = 'geminiapi' }
        'opus-api'     = [pscustomobject]@{ backend = 'anthropic' }
        'deepseek-api' = [pscustomobject]@{ backend = 'openaicompat'; api_key_env = 'DEEPSEEK_API_KEY' }
        '_agy_model_map' = [pscustomobject]@{ ignored = $true }
    }
}

Describe 'Get-EraDoctorReport' {
    It 'always includes the core prereq rows' {
        $r = Get-EraDoctorReport -Registry $script:Reg -CommandExists { $false } -ModuleExists { $false } -EnvValue { $null }
        ($r | Where-Object { $_.name -match 'PowerShell' }) | Should -Not -BeNullOrEmpty
        ($r | Where-Object { $_.name -match 'ThreadJob' })  | Should -Not -BeNullOrEmpty
        ($r | Where-Object { $_.name -match 'repomix' })    | Should -Not -BeNullOrEmpty
    }

    It 'derives distinct backend requirements from the registry (claude deduped)' {
        $r = Get-EraDoctorReport -Registry $script:Reg -CommandExists { $true } -ModuleExists { $true } -EnvValue { 'x' }
        @($r | Where-Object { $_.name -match 'claude' }).Count | Should -Be 1
        ($r | Where-Object { $_.name -match 'agy' })              | Should -Not -BeNullOrEmpty
        ($r | Where-Object { $_.name -match 'GEMINI_API_KEY' })   | Should -Not -BeNullOrEmpty
        ($r | Where-Object { $_.name -match 'ANTHROPIC_API_KEY' })| Should -Not -BeNullOrEmpty
        ($r | Where-Object { $_.name -match 'DEEPSEEK_API_KEY' }) | Should -Not -BeNullOrEmpty
    }

    It 'reflects presence/absence via the injected resolvers' {
        $r = Get-EraDoctorReport -Registry $script:Reg `
            -CommandExists { param($n) $n -eq 'agy' } `
            -ModuleExists  { $true } `
            -EnvValue      { param($n) if ($n -eq 'DEEPSEEK_API_KEY') { 'sk-x' } else { $null } }
        ($r | Where-Object { $_.name -match 'agy' }).ok              | Should -BeTrue
        ($r | Where-Object { $_.name -match 'claude' }).ok           | Should -BeFalse
        ($r | Where-Object { $_.name -match 'DEEPSEEK_API_KEY' }).ok | Should -BeTrue
        ($r | Where-Object { $_.name -match 'GEMINI_API_KEY' }).ok   | Should -BeFalse
    }

    It 'lists which presets each backend requirement unlocks' {
        $r = Get-EraDoctorReport -Registry $script:Reg -CommandExists { $true } -ModuleExists { $true } -EnvValue { 'x' }
        ($r | Where-Object { $_.name -match 'claude' }).unlocks | Should -Match 'opus'
        ($r | Where-Object { $_.name -match 'claude' }).unlocks | Should -Match 'haiku'
    }
}

Describe 'Format-EraDoctorReport' {
    It 'shows the fix for a missing required prereq and reports NOT READY' {
        $rows = Get-EraDoctorReport -Registry $script:Reg -CommandExists { $false } -ModuleExists { $false } -EnvValue { $null }
        $out  = Format-EraDoctorReport -Checks $rows
        $out | Should -Match 'npm install -g repomix'
        $out | Should -Match 'NOT READY'
    }

    It 'reports READY when core + at least one backend are present' {
        $rows = Get-EraDoctorReport -Registry $script:Reg -CommandExists { $true } -ModuleExists { $true } -EnvValue { 'x' }
        $out  = Format-EraDoctorReport -Checks $rows
        $out | Should -Match 'READY'
        $out | Should -Not -Match 'NOT READY'
    }
}
