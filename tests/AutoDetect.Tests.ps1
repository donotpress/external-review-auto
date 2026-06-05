# Tests for runtimes/era.ps1 -AutoDetect flag — PR 4
# Tag: Unit
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/AutoDetect.Tests.ps1 -Tag Unit"
#
# These tests validate era.ps1's -AutoDetect behavior by inspecting the source
# and by running the script in controlled conditions, without requiring repomix,
# a live git repo with recent commits, or a backend CLI.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'
}

Describe 'PR4: -AutoDetect flag' -Tag Unit {
    It 'era.ps1 param block declares [switch]$AutoDetect' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match '\[switch\]\$AutoDetect'
    }

    It '-AutoDetect throws helpful error if git is not on PATH' {
        $tmpDir = Join-Path $env:TEMP "era-autodetect-test-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            # Remove git from PATH for this test by running in a child process
            # with a cleared PATH. On Windows, wrap with cmd to strip PATH.
            $output = & pwsh -NonInteractive -Command @"
`$ErrorActionPreference = 'Stop'
`$env:PATH = 'C:\Windows\System32'  # git not here
try {
    & '$($script:EraPath)' -TopicSlug 'test' -AutoDetect -Force 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            # Either error message or the script throwing counts
            ($output -match 'AutoDetect requires git' -or $output -match 'git.*PATH' -or $output -match 'not on PATH') | Should -BeTrue
        } finally {
            Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        }
    }

    It '-AutoDetect throws helpful error if not in git work tree' {
        $tmpDir = Join-Path $env:TEMP "era-autodetect-nogit-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        # Do NOT create a .git directory — this is a non-repo directory
        try {
            $output = & pwsh -NonInteractive -Command @"
`$ErrorActionPreference = 'Stop'
Set-Location '$($tmpDir -replace "'", "''")'
try {
    & '$($script:EraPath)' -TopicSlug 'test' -AutoDetect -Force 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
            ($output -match 'work tree' -or $output -match 'git work tree' -or $output -match 'not inside a git') | Should -BeTrue
        } finally {
            Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        }
    }

    It '-AutoDetect + -Force skips confirmation prompt (era.ps1 source check)' {
        $src = Get-Content -Raw $script:EraPath
        # -Force skips Read-Host; the source must check -not $Force (via the
        # compound guard: -not (Get-ForceMode) -and -not $Force) before prompting
        $src | Should -Match 'if \(-not \(Get-ForceMode\) -and -not \$Force\)'
        $src | Should -Match 'AutoDetect confirmation'
    }

    It '-AutoDetect + -IncludeFiles is additive (source check: union merge)' {
        $src = Get-Content -Raw $script:EraPath
        # The source must combine $IncludeFiles with $autoCandidates
        $src | Should -Match 'autoCandidates'
        $src | Should -Match '\$IncludeFiles.*autoCandidates|\$autoCandidates.*\$IncludeFiles'
    }
}
