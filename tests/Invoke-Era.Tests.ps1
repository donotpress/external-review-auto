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

Describe 'PR2-D: Comma-string -IncludeFiles detection' -Tag Unit {
    It 'era.ps1 source contains comma-detection block' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match "commaFlagged"
        $src | Should -Match 'PS-array syntax'
    }

    It 'comma-string -IncludeFiles produces error with helpful message before repomix' {
        $tmpDir = Join-Path $env:TEMP "era-test-comma-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            New-Item -ItemType Directory -Path (Join-Path $tmpDir '.git') -Force | Out-Null
            $output = & pwsh -NonInteractive -Command @"
`$ErrorActionPreference = 'Stop'
try {
    & '$($script:EraPath)' -TopicSlug 'era-test' -IncludeFiles 'a,b,c' -Force 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            $output | Should -Match 'comma'
            $output | Should -Match "PS-array syntax"
        } finally {
            Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        }
    }
}
