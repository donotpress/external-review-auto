BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    $script:Era = Join-Path (Split-Path $PSScriptRoot -Parent) 'runtimes/era.ps1'
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
}

Describe '#3 ConvertTo-EraNativePath' {
    It 'rewrites /c/x/y -> C:/x/y on Windows' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        ConvertTo-EraNativePath '/c/Users/x' | Should -Be 'C:/Users/x'
    }
    It 'leaves native + relative paths unchanged' {
        ConvertTo-EraNativePath 'C:/Users/x' | Should -Be 'C:/Users/x'
        ConvertTo-EraNativePath 'docs/spec.md' | Should -Be 'docs/spec.md'
    }
    It 'is idempotent' {
        $once = ConvertTo-EraNativePath '/d/a/b'
        ConvertTo-EraNativePath $once | Should -Be $once
    }
}

Describe '#1 Resolve-EraAgyFallback' {
    BeforeAll {
        $script:reg = @{
            'gemini-pro-low' = @{ backend='agy' }
            'gemini'         = @{ backend='agy' }
            'gemini-api'     = @{ backend='geminiapi' }
            'deepseek-http'  = @{ backend='openaicompat'; api_key_env='OPENCODE_API_KEY' }
            'sonnet'         = @{ backend='claude' }
        }
    }
    It 'picks the first available non-agy preset by preference' {
        $cmd = { param($n) $false }
        $env = { param($n) if ($n -eq 'GEMINI_API_KEY') { 'k' } else { $null } }
        Resolve-EraAgyFallback -Registry $script:reg -CommandExists $cmd -EnvValue $env | Should -Be 'gemini-api'
    }
    It 'honors a valid non-agy override' {
        $cmd = { param($n) $n -eq 'claude' }
        $env = { param($n) $null }
        Resolve-EraAgyFallback -Registry $script:reg -Override 'sonnet' -CommandExists $cmd -EnvValue $env | Should -Be 'sonnet'
    }
    It 'ignores an "off" override and falls through to preference' {
        $cmd = { param($n) $n -eq 'claude' }
        $env = { param($n) $null }
        Resolve-EraAgyFallback -Registry $script:reg -Override 'off' -CommandExists $cmd -EnvValue $env | Should -Be 'sonnet'
    }
    It 'never returns an agy preset and returns $null when nothing is available' {
        $cmd = { param($n) $false }
        $env = { param($n) $null }
        Resolve-EraAgyFallback -Registry $script:reg -CommandExists $cmd -EnvValue $env | Should -BeNullOrEmpty
    }
    It 'excludes presets already in the run' {
        $cmd = { param($n) $n -eq 'claude' }
        $env = { param($n) $null }
        Resolve-EraAgyFallback -Registry $script:reg -Exclude @('sonnet') -CommandExists $cmd -EnvValue $env | Should -BeNullOrEmpty
    }
}

Describe '#2 git guard (source check)' {
    It 'era.ps1 guards the git rev-parse call with Get-Command' {
        $src = Get-Content -Raw $script:Era
        $src | Should -Match 'elseif \(Get-Command git'
    }
}

Describe '#4 clean preflight error (out-of-process)' {
    It 'a bad -IncludeFiles prints [era] ERROR: and exits 1 with no exception stack' {
        # Run in a throwaway repo. Previously this ran from whatever cwd Pester
        # had, i.e. the era skill repo itself, so it was never hermetic — and
        # once the dirty-tree gate (9808e80) landed, the real repo's untracked
        # files made era refuse before it ever reached include validation.
        $tmp = Join-Path $env:TEMP "era-preflight-$(New-Guid)"
        New-Item -ItemType Directory -Path (Join-Path $tmp '.git') -Force | Out-Null
        Push-Location $tmp
        try {
            $out = & pwsh -NoProfile -File $script:Era -TopicSlug t -Reviewer gemini-api `
                -IncludeFiles 'totally-missing-xyz-12345.md' -Force 2>&1 | Out-String
            $code = $LASTEXITCODE
            $code | Should -Be 1
            $out  | Should -Match '\[era\] ERROR:'
            $out  | Should -Not -Match 'System\.Management\.Automation'
        } finally {
            Pop-Location
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
