# Tests for git status --porcelain parsing.
#
# The old parse stripped three characters and kept the remainder, so a rename
# 'R  old -> new' produced the non-path 'old -> new', and core.quotePath wrapped
# non-ASCII names in quotes that survived into the path. Both then failed
# Test-Path with a confusing "paths not found".
#
# Measured on this box with --porcelain -z, a rename emits TWO NUL-terminated
# fields, DESTINATION FIRST:
#   [R  new.md]  [old.md]  [?? probe.ps1]  [?? untracked.md]
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/PorcelainParse.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"

    function New-GitRepoWithRename {
        param([string]$Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        Push-Location $Root
        try {
            & git init -q 2>&1 | Out-Null
            & git config user.email 't@t.t' 2>&1 | Out-Null
            & git config user.name  'T'     2>&1 | Out-Null
            Set-Content -Path (Join-Path $Root 'old.md') -Value 'a'
            & git add -A 2>&1 | Out-Null
            & git commit -q -m init 2>&1 | Out-Null
            & git mv old.md new.md 2>&1 | Out-Null
            Set-Content -Path (Join-Path $Root 'untracked.md') -Value 'z'
        } finally { Pop-Location }
    }
}

Describe 'Get-EraPorcelainPaths' -Tag Unit {
    It 'returns the rename DESTINATION, never the "old -> new" arrow form' {
        $tmp = Join-Path $env:TEMP "era-porc-ren-$(New-Guid)"
        try {
            New-GitRepoWithRename -Root $tmp
            $paths = Get-EraPorcelainPaths -RepoRoot $tmp
            $paths | Should -Contain 'new.md'
            @($paths | Where-Object { $_ -match '->' }) | Should -BeNullOrEmpty
            # The source path must not be reported as a changed file: it no
            # longer exists, so it would fail Test-Path downstream.
            $paths | Should -Not -Contain 'old.md'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'returns untracked files' {
        $tmp = Join-Path $env:TEMP "era-porc-unt-$(New-Guid)"
        try {
            New-GitRepoWithRename -Root $tmp
            Get-EraPorcelainPaths -RepoRoot $tmp | Should -Contain 'untracked.md'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'handles a path containing spaces without quoting artefacts' {
        $tmp = Join-Path $env:TEMP "era-porc-sp-$(New-Guid)"
        try {
            New-GitRepoWithRename -Root $tmp
            Set-Content -Path (Join-Path $tmp 'a spaced name.md') -Value 'x'
            $paths = Get-EraPorcelainPaths -RepoRoot $tmp
            $paths | Should -Contain 'a spaced name.md'
            @($paths | Where-Object { $_ -match '"' }) | Should -BeNullOrEmpty
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'returns an empty list for a clean repo' {
        $tmp = Join-Path $env:TEMP "era-porc-clean-$(New-Guid)"
        try {
            New-GitRepoWithRename -Root $tmp
            Push-Location $tmp
            try { & git add -A 2>&1 | Out-Null; & git commit -q -m x 2>&1 | Out-Null } finally { Pop-Location }
            @(Get-EraPorcelainPaths -RepoRoot $tmp).Count | Should -Be 0
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'returns an empty list outside a git repo instead of throwing' {
        $tmp = Join-Path $env:TEMP "era-porc-nogit-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            { Get-EraPorcelainPaths -RepoRoot $tmp } | Should -Not -Throw
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}

Describe 'era.ps1 uses the shared porcelain helper' -Tag Unit {
    It 'has no hand-rolled three-character strip left' {
        $src = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtimes/era.ps1')
        $src | Should -Not -Match "replace\s+'\^\.\{3\}'"
        $src | Should -Match 'Get-EraPorcelainPaths'
    }
}
