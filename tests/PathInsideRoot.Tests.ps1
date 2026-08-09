# Tests for Test-EraPathInsideRoot.
#
# Background (measured 2026-08-09): era used
# `$full.StartsWith($repoRoot, OrdinalIgnoreCase)` with no directory-separator
# boundary. With repo root C:\a\era-p6, the SIBLING C:\a\era-p6-ext\outside.md
# tested as INSIDE the repo and was relativized to '-ext/outside.md', which then
# failed Test-Path with a confusing "paths not found". The guard fails closed —
# the harm is silent loss of an explicitly requested file, not exfiltration.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/PathInsideRoot.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'
}

Describe 'Test-EraPathInsideRoot' -Tag Unit {
    It 'treats the root itself as inside' {
        Test-EraPathInsideRoot -Path 'C:\repo' -Root 'C:\repo' | Should -BeTrue
    }

    It 'treats a true child as inside' {
        Test-EraPathInsideRoot -Path 'C:\repo\src\a.md' -Root 'C:\repo' | Should -BeTrue
    }

    It 'treats a prefix-sharing SIBLING as outside' {
        # The measured defect.
        Test-EraPathInsideRoot -Path 'C:\repo-ext\outside.md' -Root 'C:\repo' | Should -BeFalse
    }

    It 'treats a sibling that differs only after the root name as outside' {
        Test-EraPathInsideRoot -Path 'C:\Users\Joshua2\x.md' -Root 'C:\Users\Joshua' | Should -BeFalse
    }

    It 'ignores a trailing separator on the root' {
        Test-EraPathInsideRoot -Path 'C:\repo\a.md' -Root 'C:\repo\' | Should -BeTrue
    }

    It 'is case-insensitive' {
        Test-EraPathInsideRoot -Path 'C:\REPO\a.md' -Root 'c:\repo' | Should -BeTrue
    }

    It 'accepts forward slashes' {
        Test-EraPathInsideRoot -Path 'C:/repo/a.md' -Root 'C:\repo' | Should -BeTrue
    }

    It 'returns false when either side is null or empty' {
        Test-EraPathInsideRoot -Path $null            -Root 'C:\repo' | Should -BeFalse
        Test-EraPathInsideRoot -Path 'C:\repo\a.md'   -Root ''        | Should -BeFalse
    }

    It 'does not require the path to exist on disk' {
        Test-EraPathInsideRoot -Path 'C:\repo\nope\never.md' -Root 'C:\repo' | Should -BeTrue
    }
}

Describe 'era.ps1 uses the predicate, not a bare StartsWith' -Tag Unit {
    It 'has no boundary-less StartsWith($repoRoot) left in era.ps1' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Not -Match 'StartsWith\(\$repoRoot'
        $src | Should -Not -Match 'StartsWith\(\$homeFull'
        $src | Should -Match 'Test-EraPathInsideRoot'
    }

    It 'has no boundary-less StartsWith($RepoRoot) left in workflow.ps1' {
        $wf = Get-Content -Raw (Join-Path $script:SkillRoot 'workflow.ps1')
        $wf | Should -Not -Match 'StartsWith\(\$RepoRoot'
    }
}

Describe 'Integration: a prefix-sharing sibling is staged, not misclassified' -Tag Integration {
    It 'stages an out-of-repo file whose parent shares the repo-root prefix' {
        # Repo root  : <tmp>\era-pfx
        # Source file: <tmp>\era-pfx-ext\outside.md   <-- shares the prefix
        $stamp = "$(New-Guid)".Substring(0, 8)
        $repo  = Join-Path $env:TEMP "era-pfx-$stamp"
        $ext   = Join-Path $env:TEMP "era-pfx-$stamp-ext"
        New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path $ext -Force | Out-Null
        try {
            Set-Content -Path (Join-Path $repo 'inrepo.md') -Value '# in-repo'
            $extFile = Join-Path $ext 'outside.md'
            Set-Content -Path $extFile -Value 'OUTSIDE-PREFIX-MARKER'

            # Pair with a missing in-repo path so the run stops at path
            # validation AFTER staging (no repomix, no dispatch).
            $out = & pwsh -NonInteractive -Command @"
Set-Location '$repo'
try {
    & '$($script:EraPath)' -TopicSlug 'pfx-test' -Force -IncludeFiles '$extFile,definitely-missing.py' 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String

            # Before the fix this printed "paths not found ... -ext/outside.md".
            $out | Should -Match 'Staged out-of-repo file'
            $out | Should -Not -Match '\-ext[\\/]outside\.md'
        } finally {
            Remove-Item -Recurse -Force $repo, $ext -ErrorAction SilentlyContinue
        }
    }
}
