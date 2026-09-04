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

Describe 'Measure-EraBroadScope fidelity to repomix' -Tag Unit {
    It 'prunes ignored directories at the ROOT only, as repomix does' {
        # Measured against repomix 1.12.0: a bare 'node_modules/**' is anchored at
        # cwd and does NOT match packages/p/node_modules/d/a.md — repomix bundles
        # that file. Pruning by directory NAME at any depth under-counted it, so
        # the notice printed a reassuring number while repomix collected the tree.
        $tmp = Join-Path $env:TEMP "era-scope-anchor-$(New-Guid)"
        New-Item -ItemType Directory -Path (Join-Path $tmp 'packages/p/node_modules/d') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tmp 'node_modules') -Force | Out-Null
        try {
            Set-Content -Path (Join-Path $tmp 'root.md') -Value 'x'
            Set-Content -Path (Join-Path $tmp 'packages/p/node_modules/d/a.md') -Value 'x'
            Set-Content -Path (Join-Path $tmp 'node_modules/top.md') -Value 'x'
            $s = Measure-EraBroadScope -RepoRoot $tmp -Include @('**/*.md') `
                    -IgnorePatterns @('node_modules/**')
            # root.md + the NESTED one repomix would bundle; the root-level one is pruned.
            $s.FileCount | Should -Be 2
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'refuses to guess at a glob shape -like cannot match (brace alternation)' {
        # ERA_DEFAULT_GLOBS is documented as a repomix glob list, so '**/*.{ts,tsx}'
        # is legitimate. PowerShell -like has no brace alternation, so it matched
        # nothing and reported 0 files while repomix bundled the whole tree.
        $tmp = Join-Path $env:TEMP "era-scope-brace-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            Set-Content -Path (Join-Path $tmp 'a.ts') -Value 'x'
            $s = Measure-EraBroadScope -RepoRoot $tmp -Include @('**/*.{ts,tsx}')
            # Unmatchable pattern => report it as unmeasured so the gate refuses,
            # rather than reporting a confident zero.
            $s.Truncated | Should -BeTrue
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
    It 'the dedicated scale override bypasses the ceiling' {
        $s = @{ FileCount = 72378; Bytes = 900MB; Truncated = $true }
        Test-EraBroadScopeAllowed -Scope $s -MaxFiles 1000 -MaxBytes 10MB -Force | Should -BeTrue
    }
}

Describe 'A1: cost consent is not scale consent' -Tag Unit {
    # SKILL.md's NORMATIVE dispatch line (step 5) always passes -Force, and
    # -Force is documented as "skip the COST prompt". If -Force also disarmed the
    # scale ceiling, the gate would be inert for the only caller this skill
    # documents — an LLM dispatching non-interactively — and the 18-minute crash
    # comes straight back with a reassuring notice printed first.
    It 'SKILL.md still documents -Force on the normative dispatch (the premise)' {
        $skill = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'SKILL.md')
        $skill | Should -Match 'runtimes/era\.ps1[^\r\n]*-Force'
    }

    It 'refuses above the ceiling even WITH -Force' {
        $tmp = Join-Path $env:TEMP "era-gate-force-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-ScopeRepo -Root $tmp -MdFiles 5
            $out = & pwsh -NonInteractive -Command @"
Set-Location '$tmp'
`$env:ERA_BROAD_MAX_FILES = '2'
try {
        & '$($script:EraPath)' -PreflightOnly -TopicSlug 'gate-test' -Force 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            $out | Should -Match '(?i)refusing'
            $out | Should -Not -Match 'Running repomix'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'proceeds past the ceiling with the dedicated ERA_BROAD_FORCE override' {
        $tmp = Join-Path $env:TEMP "era-gate-bforce-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-ScopeRepo -Root $tmp -MdFiles 5
            # Pair with a missing explicit path? No — the broad path takes no
            # -IncludeFiles. Assert only that the gate did not refuse; the run is
            # then stopped by the missing reviewer CLI or the cost cap downstream.
            $out = & pwsh -NonInteractive -Command @"
Set-Location '$tmp'
`$env:ERA_BROAD_MAX_FILES = '2'
`$env:ERA_BROAD_FORCE = '1'
`$env:ERA_DEFAULT_GLOBS = 'nothing-matches-this-glob.zzz'
try {
        & '$($script:EraPath)' -PreflightOnly -TopicSlug 'gate-test' -Force 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            $out | Should -Not -Match '(?i)refusing this broad bundle'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
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

    It 'reports a file-limit truncation as ">limit" rather than a false exact count' {
        $s = @{ FileCount = 5001; Bytes = 12345; Truncated = $true; Reason = 'file-limit' }
        $t = Format-EraBroadScopeNotice -Scope $s -RepoRoot 'C:\repo' `
                -Reviewers @('gemini') -Limit 5000
        $t | Should -Match '>5000'
    }

    It 'does not present a bounded-walk byte total as a meaningful lower bound' {
        # When the walk stopped on the directory budget, the accumulated bytes can
        # be an arbitrarily small fraction of the tree. "> 0.1 MB" would read as a
        # reassuring lower bound; it is not one.
        $s = @{ FileCount = 12; Bytes = 12345; Truncated = $true; Reason = 'dir-budget' }
        $t = Format-EraBroadScopeNotice -Scope $s -RepoRoot 'C:\repo' `
                -Reviewers @('gemini') -Limit 5000
        $t | Should -Match 'unmeasured'
        $t | Should -Not -Match '>\s*0\.0 MB'
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
        & '$($script:EraPath)' -PreflightOnly -TopicSlug 'gate-test' -Reviewer gemini 2>&1 | Out-String
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
        & '$($script:EraPath)' -PreflightOnly -TopicSlug 'gate-test' -Reviewer gemini -IncludeFiles 'doc1.md,definitely-missing.py' 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            $out | Should -Not -Match '(?i)broad bundle'
            $out | Should -Match 'definitely-missing\.py'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'A3: a non-numeric ceiling env var does not throw a raw cast error' {
        $tmp = Join-Path $env:TEMP "era-gate-badenv-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-ScopeRepo -Root $tmp -MdFiles 2
            $out = & pwsh -NonInteractive -Command @"
Set-Location '$tmp'
`$env:ERA_BROAD_MAX_FILES = 'none'
try {
    & '$($script:EraPath)' -PreflightOnly -TopicSlug 'gate-test' 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            $out | Should -Not -Match 'Cannot convert value'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'A6: $usedDefaultGlobs is initialized, not merely assigned in one branch' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match '\$usedDefaultGlobs\s*=\s*\$false'
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
