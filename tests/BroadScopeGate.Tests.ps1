# Tests for the broad-bundle consent gate.
#
# Background (2026-08-09): omitting -IncludeFiles selects the documented
# repo-wide audit, but era announced nothing about what that meant and had no
# ceiling. On a large repo it started collecting 72,378 files and died 18 minutes
# later with ERR_IPC_CHANNEL_CLOSED and a 16.9 MB log. The goal here is to turn
# that 18-minute failure into a 1-second refusal.
#
# The enumeration is deliberately NOT `git ls-files`: the repomix config sets
# useGitignore=$false, so the include set is a SUPERSET of tracked files and
# git would under-report exactly the case that hurts.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/BroadScopeGate.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'

    function New-ScopeRepo {
        param([string]$Root, [int]$MdFiles = 3)
        New-Item -ItemType Directory -Path (Join-Path $Root '.git') -Force | Out-Null
        1..$MdFiles | ForEach-Object {
            Set-Content -Path (Join-Path $Root "doc$_.md") -Value ('x' * 100)
        }
        # Noise that must NOT be counted: an ignored dir and an unmatched extension.
        New-Item -ItemType Directory -Path (Join-Path $Root 'node_modules/pkg') -Force | Out-Null
        Set-Content -Path (Join-Path $Root 'node_modules/pkg/index.md') -Value 'ignored'
        Set-Content -Path (Join-Path $Root '.git/HEAD') -Value 'ref: refs/heads/x'
        Set-Content -Path (Join-Path $Root 'image.png') -Value 'not-a-source-file'
    }
}

Describe 'Measure-EraBroadScope' -Tag Unit {
    It 'counts files matching the include globs and skips ignored directories' {
        $tmp = Join-Path $env:TEMP "era-scope-count-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-ScopeRepo -Root $tmp -MdFiles 3
            $s = Measure-EraBroadScope -RepoRoot $tmp -Include @('**/*.md') `
                    -IgnorePatterns @('node_modules/**', '.git/**')
            $s.FileCount | Should -Be 3
            $s.Truncated | Should -BeFalse
            $s.Bytes     | Should -BeGreaterThan 0
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'does not count files outside the include globs' {
        $tmp = Join-Path $env:TEMP "era-scope-ext-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-ScopeRepo -Root $tmp -MdFiles 2
            $s = Measure-EraBroadScope -RepoRoot $tmp -Include @('**/*.py') `
                    -IgnorePatterns @('node_modules/**', '.git/**')
            $s.FileCount | Should -Be 0
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'short-circuits at the limit instead of walking the whole tree' {
        $tmp = Join-Path $env:TEMP "era-scope-limit-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-ScopeRepo -Root $tmp -MdFiles 20
            $s = Measure-EraBroadScope -RepoRoot $tmp -Include @('**/*.md') `
                    -IgnorePatterns @('node_modules/**', '.git/**') -Limit 5
            $s.Truncated | Should -BeTrue
            # It stops just past the limit rather than counting all 20.
            $s.FileCount | Should -BeLessOrEqual 6
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'bounds the directory walk, so a deep tree with no matches cannot spin' {
        # The file-count limit alone does NOT bound the walk: directories with no
        # matching files never increment the counter, so a junction loop (or just
        # a pathological tree) would enumerate forever.
        $tmp = Join-Path $env:TEMP "era-scope-dirs-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $p = $tmp
            1..60 | ForEach-Object {
                $p = Join-Path $p "d$_"
                New-Item -ItemType Directory -Path $p -Force | Out-Null
            }
            $s = Measure-EraBroadScope -RepoRoot $tmp -Include @('**/*.md') -MaxDirs 10
            # Bailing early means the count is incomplete — which must read as
            # truncated so the consent gate refuses rather than waving it through.
            $s.Truncated | Should -BeTrue
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'does not follow directory reparse points (junction loop terminates)' {
        $tmp = Join-Path $env:TEMP "era-scope-junc-$(New-Guid)"
        New-Item -ItemType Directory -Path (Join-Path $tmp 'sub') -Force | Out-Null
        Set-Content -Path (Join-Path $tmp 'a.md') -Value 'x'
        $made = $true
        try { New-Item -ItemType Junction -Path (Join-Path $tmp 'sub/loop') -Target $tmp -ErrorAction Stop | Out-Null }
        catch { $made = $false }
        try {
            if (-not $made) { Set-ItResult -Skipped -Because 'junctions are not creatable here' ; return }
            $s = Measure-EraBroadScope -RepoRoot $tmp -Include @('**/*.md') -MaxDirs 500
            # It terminates, and does not re-count a.md through the loop.
            $s.FileCount | Should -Be 1
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'honours .external-reviews as an ignored directory' {
        $tmp = Join-Path $env:TEMP "era-scope-ext-rev-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-ScopeRepo -Root $tmp -MdFiles 1
            New-Item -ItemType Directory -Path (Join-Path $tmp '.external-reviews/t') -Force | Out-Null
            1..5 | ForEach-Object {
                Set-Content -Path (Join-Path $tmp ".external-reviews/t/round-$_-response.md") -Value 'prior'
            }
            $s = Measure-EraBroadScope -RepoRoot $tmp -Include @('**/*.md') `
                    -IgnorePatterns @('node_modules/**', '.git/**', '.external-reviews/**')
            $s.FileCount | Should -Be 1
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-EraBroadScopeAllowed' -Tag Unit {
    It 'allows a scope under both ceilings' {
        $s = @{ FileCount = 10; Bytes = 1000; Truncated = $false }
        Test-EraBroadScopeAllowed -Scope $s -MaxFiles 1000 -MaxBytes 10MB | Should -BeTrue
    }
    It 'refuses on file count' {
        $s = @{ FileCount = 5000; Bytes = 1000; Truncated = $false }
        Test-EraBroadScopeAllowed -Scope $s -MaxFiles 1000 -MaxBytes 10MB | Should -BeFalse
    }
    It 'refuses on byte size even when the file count is small' {
        $s = @{ FileCount = 5; Bytes = 50MB; Truncated = $false }
        Test-EraBroadScopeAllowed -Scope $s -MaxFiles 1000 -MaxBytes 10MB | Should -BeFalse
    }
    It 'refuses a truncated enumeration — an unknown count is not a safe count' {
        $s = @{ FileCount = 5001; Bytes = 1000; Truncated = $true }
        Test-EraBroadScopeAllowed -Scope $s -MaxFiles 100000 -MaxBytes 100MB | Should -BeFalse
    }
    It '-Force overrides every ceiling' {
        $s = @{ FileCount = 72378; Bytes = 900MB; Truncated = $true }
        Test-EraBroadScopeAllowed -Scope $s -MaxFiles 1000 -MaxBytes 10MB -Force | Should -BeTrue
    }
}

Describe 'Format-EraBroadScopeNotice' -Tag Unit {
    It 'reports count, bytes, repo root, gitignore status and destination' {
        $s = @{ FileCount = 42; Bytes = 2097152; Truncated = $false }
        $t = Format-EraBroadScopeNotice -Scope $s -RepoRoot 'C:\repo' `
                -Reviewers @('gemini', 'opus') -Limit 5000
        $t | Should -Match '42'
        $t | Should -Match 'C:\\repo'
        $t | Should -Match '(?i)gitignore'
        $t | Should -Match 'gemini, opus'
        $t | Should -Match '(?i)2(\.0)? MB'
    }

    It 'reports a truncated enumeration as ">limit" rather than a false exact count' {
        $s = @{ FileCount = 5001; Bytes = 12345; Truncated = $true }
        $t = Format-EraBroadScopeNotice -Scope $s -RepoRoot 'C:\repo' `
                -Reviewers @('gemini') -Limit 5000
        $t | Should -Match '>5000'
    }
}

Describe 'era.ps1 broad-path gate (out-of-process)' -Tag Unit {
    It 'announces the broad bundle and refuses above the ceiling, before repomix' {
        $tmp = Join-Path $env:TEMP "era-gate-refuse-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-ScopeRepo -Root $tmp -MdFiles 5
            $out = & pwsh -NonInteractive -Command @"
Set-Location '$tmp'
`$env:ERA_BROAD_MAX_FILES = '2'
try {
    & '$($script:EraPath)' -TopicSlug 'gate-test' -Reviewer gemini 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            $out | Should -Match '(?i)broad bundle'
            $out | Should -Match '(?i)refusing'
            # The whole point: this costs a second, not an 18-minute repomix run.
            $out | Should -Not -Match 'Running repomix'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'stays silent on the narrow path — an explicit -IncludeFiles is not a broad bundle' {
        $tmp = Join-Path $env:TEMP "era-gate-narrow-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-ScopeRepo -Root $tmp -MdFiles 5
            $out = & pwsh -NonInteractive -Command @"
Set-Location '$tmp'
`$env:ERA_BROAD_MAX_FILES = '2'
try {
    & '$($script:EraPath)' -TopicSlug 'gate-test' -Reviewer gemini -IncludeFiles 'doc1.md,definitely-missing.py' 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            $out | Should -Not -Match '(?i)broad bundle'
            $out | Should -Match 'definitely-missing\.py'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'gates BEFORE invoking repomix (source ordering)' {
        $src = Get-Content -Raw $script:EraPath
        $gateIdx = $src.IndexOf('Test-EraBroadScopeAllowed')
        $rmxIdx  = $src.IndexOf('"Running repomix..."')
        $gateIdx | Should -BeGreaterThan 0
        $gateIdx | Should -BeLessThan $rmxIdx
    }

    It '-Force is the documented override for the ceiling' {
        $src = Get-Content -Raw $script:EraPath
        # (?s) so the match can span the call's line continuation.
        $src | Should -Match '(?s)Test-EraBroadScopeAllowed.{0,200}-Force'
    }
}
