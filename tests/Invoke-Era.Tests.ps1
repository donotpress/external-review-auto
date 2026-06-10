# Tests for runtimes/era.ps1 — Bug-fix regressions (PR 2)
# These are unit-level tests that exercise the input-validation paths added in
# PR 2 without requiring repomix, a backend CLI, or live API calls.
# Tag: Unit
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/Invoke-Era.Tests.ps1 -Tag Unit"
#
# Coverage:
#   - Task 2.1: -Diff flag no longer produces SwitchParameter binding error
#   - Task 2.2: Missing -IncludeFiles paths produce a specific error before repomix runs
#   - Task 2.3: Comma-string -IncludeFiles produces a specific helpful error message

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'
}

Describe 'PR2-B: -Diff SwitchParameter binding' -Tag Unit {
    It '$Diff.IsPresent resolves before any local $diffResult assignment — no SwitchParameter error' {
        # Verify that the era.ps1 source no longer uses $diff (which would shadow
        # the [switch]$Diff param) — it should use $diffResult throughout.
        $src = Get-Content -Raw $script:EraPath
        # Local variable must be $diffResult, not bare $diff (case-insensitive check)
        $src | Should -Match '\$diffResult'
        # The bare assignment "$diff = Get-ReviewDiff" must NOT appear
        $src | Should -Not -Match '(?i)\$diff\s*='
    }

    It 'era.ps1 param block declares [switch]$Diff (not [bool] or [string])' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match '\[switch\]\$Diff'
    }
}

Describe 'PR2-C: Test-Path validation before repomix' -Tag Unit {
    It 'era.ps1 calls Test-Path on IncludeFiles before "Running repomix"' {
        $src = Get-Content -Raw $script:EraPath
        # Find line positions to verify ordering. Use IndexOf on the raw source
        # (faster than per-line iteration and avoids MatchInfo casting issues).
        $testPathIdx = $src.IndexOf('Test-Path $_')
        if ($testPathIdx -lt 0) { $testPathIdx = $src.IndexOf('Test-Path $f') }
        if ($testPathIdx -lt 0) { $testPathIdx = $src.IndexOf('Test-Path $_)') }
        # Fallback: find 'missing' array variable which is part of the validation block
        if ($testPathIdx -lt 0) { $testPathIdx = $src.IndexOf('$missing = @(') }
        $repomixIdx   = $src.IndexOf('"Running repomix..."')
        $testPathIdx  | Should -BeGreaterThan 0
        $repomixIdx   | Should -BeGreaterThan 0
        # Test-Path validation must appear before the repomix invocation
        $testPathIdx  | Should -BeLessThan $repomixIdx
    }

    It 'missing -IncludeFiles path produces error naming the missing path' {
        # Invoke era.ps1 with a non-existent file path. We intercept before
        # repomix by checking the error message content.
        $tmpDir = Join-Path $env:TEMP "era-test-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            # Create a minimal .git marker so era.ps1 treats tmpDir as repo root
            New-Item -ItemType Directory -Path (Join-Path $tmpDir '.git') -Force | Out-Null
            $output = & pwsh -NonInteractive -Command @"
`$ErrorActionPreference = 'Stop'
try {
    & '$($script:EraPath)' -TopicSlug 'era-test' -IncludeFiles 'this-file-does-not-exist.md' -Force 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            $output | Should -Match 'not found|not found relative to repo root|this-file-does-not-exist\.md'
        } finally {
            Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        }
    }
}

# 2026-06-10 hardening P5.1: comma-joined -IncludeFiles are now SPLIT and
# accepted (consistent with -Reviewer's comma handling), replacing the old
# PR2-D detect-and-reject contract (whose commaFlagged block had already been
# removed from era.ps1 — this Describe was failing against thin air).
Describe 'P5.1: Comma-string -IncludeFiles is split and accepted' -Tag Unit {
    It 'era.ps1 source contains the P5.1 split block' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match 'hardening P5\.1'
        $src | Should -Match "-split ','"
    }

    It 'comma-string -IncludeFiles is split into individual paths (missing-file error names each)' {
        $tmpDir = Join-Path $env:TEMP "era-test-comma-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            New-Item -ItemType Directory -Path (Join-Path $tmpDir '.git') -Force | Out-Null
            $output = & pwsh -NonInteractive -Command @"
Set-Location '$tmpDir'
`$ErrorActionPreference = 'Stop'
try {
    & '$($script:EraPath)' -TopicSlug 'era-test' -IncludeFiles 'nope-one.py,nope-two.py' -Force 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            # The path-validation error must reference BOTH split entries —
            # proof the comma string became two paths, not one literal.
            $output | Should -Match 'nope-one\.py'
            $output | Should -Match 'nope-two\.py'
        } finally {
            Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        }
    }
}

# 2026-06-10 hardening P6: absolute out-of-repo -IncludeFiles are STAGED into
# the round's artifact dir (path-mirrored) instead of being rejected; relative
# traversal stays blocked.
Describe 'P6: Out-of-repo -IncludeFiles staging' -Tag Unit {
    It 'stages an absolute out-of-repo file into round-N-external with a mirrored path' {
        $tmpDir = Join-Path $env:TEMP "era-test-p6-$(New-Guid)"
        $extDir = Join-Path $env:TEMP "era-test-p6-ext-$(New-Guid)"
        New-Item -ItemType Directory -Path (Join-Path $tmpDir '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path $extDir -Force | Out-Null
        $extFile = Join-Path $extDir 'outside.ps1'
        Set-Content -Path $extFile -Value '# outside the repo'
        try {
            # Pair the external file with a missing in-repo file so the run
            # stops at path validation AFTER staging (no repomix/dispatch).
            $output = & pwsh -NonInteractive -Command @"
Set-Location '$tmpDir'
try {
    & '$($script:EraPath)' -TopicSlug 'p6-test' -IncludeFiles @('$extFile', 'definitely-missing.py') -Force 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            $output | Should -Match 'Staged out-of-repo file'
            $staged = Get-ChildItem -Recurse (Join-Path $tmpDir '.external-reviews/p6-test') -Filter 'outside.ps1' -ErrorAction SilentlyContinue
            $staged | Should -Not -BeNullOrEmpty
            $staged.FullName | Should -Match 'round-1-external'
            # Privacy: staged mirrors must never embed the username — files
            # under $HOME mirror as 'HOME/...', and $env:TEMP is under $HOME
            # on Windows, so this asserts the anonymization end-to-end.
            $userName = [System.Environment]::UserName
            $stagedRelative = $staged.FullName.Substring((Join-Path $tmpDir '.external-reviews').Length)
            $stagedRelative | Should -Not -Match ([regex]::Escape($userName))
            $stagedRelative | Should -Match 'HOME'
        } finally {
            Remove-Item -Recurse -Force $tmpDir, $extDir -ErrorAction SilentlyContinue
        }
    }

    It 'still blocks relative path traversal' {
        $tmpDir = Join-Path $env:TEMP "era-test-p6b-$(New-Guid)"
        New-Item -ItemType Directory -Path (Join-Path $tmpDir 'sub/.git') -Force | Out-Null
        Set-Content -Path (Join-Path $tmpDir 'secret.txt') -Value 'outside'
        try {
            $output = & pwsh -NonInteractive -Command @"
Set-Location '$(Join-Path $tmpDir 'sub')'
try {
    & '$($script:EraPath)' -TopicSlug 'p6-test' -IncludeFiles '../secret.txt' -Force 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            $output | Should -Match 'traversal|not found'
            $output | Should -Not -Match 'Staged out-of-repo'
        } finally {
            Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        }
    }
}
