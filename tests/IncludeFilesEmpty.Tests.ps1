# Tests for the "omitted" vs "passed empty" distinction on -IncludeFiles.
#
# Background (2026-08-09): a caller dispatched two reviewers in one bash line —
#     FILES="a.py,b.py" && setsid nohup pwsh -File era.ps1 ... -IncludeFiles "$FILES" & \
#       echo ok; sleep 3; setsid nohup pwsh -File era.ps1 ... -IncludeFiles "$FILES" &
# In bash `&` binds looser than `&&`, so the assignment landed in a SUBSHELL and
# the SECOND dispatch received -IncludeFiles "". PowerShell unwraps a
# single-element array, so `if ($IncludeFiles)` saw a falsy value and could not
# tell that from omission — era fell back to the repo-wide default globs and
# repomix began collecting 72,378 files, crashing after a 16.9 MB log.
#
# Omission remains the DOCUMENTED broad-repo-audit mode (SKILL.md). Only an
# EXPLICIT -IncludeFiles that resolves to nothing is refused.
#
# Note the asymmetry this repairs: zero files MATCHED was already fatal
# (era.ps1 "Bundle is empty"); zero files SPECIFIED silently became everything.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/IncludeFilesEmpty.Tests.ps1"

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'

    function Invoke-EraIn {
        <# Runs era.ps1 out-of-process in a throwaway git repo and returns stdout+stderr. #>
        param([string]$WorkDir, [string]$ArgLiteral)
        & pwsh -NonInteractive -Command @"
Set-Location '$WorkDir'
try {
    & '$($script:EraPath)' -TopicSlug 'empty-test' -Force $ArgLiteral 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
    }

    function New-TmpRepo {
        param([string]$Prefix)
        $d = Join-Path $env:TEMP "era-$Prefix-$(New-Guid)"
        New-Item -ItemType Directory -Path (Join-Path $d '.git') -Force | Out-Null
        $d
    }
}

Describe 'Explicit -IncludeFiles that resolves empty is refused' -Tag Unit {
    It 'refuses -IncludeFiles "" instead of falling back to the repo-wide globs' {
        $tmp = New-TmpRepo 'empty-str'
        try {
            $out = Invoke-EraIn -WorkDir $tmp -ArgLiteral '-IncludeFiles ""'
            $out | Should -Match 'resolved to zero paths'
            # It must NOT have proceeded to the broad path.
            $out | Should -Not -Match 'Running repomix'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'refuses -IncludeFiles "," — non-empty input the normaliser reduces to nothing' {
        $tmp = New-TmpRepo 'comma'
        try {
            $out = Invoke-EraIn -WorkDir $tmp -ArgLiteral '-IncludeFiles ","'
            $out | Should -Match 'resolved to zero paths'
            $out | Should -Not -Match 'Running repomix'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'refuses a whitespace-and-separator-only list' {
        $tmp = New-TmpRepo 'ws'
        try {
            $out = Invoke-EraIn -WorkDir $tmp -ArgLiteral '-IncludeFiles " , , "'
            $out | Should -Match 'resolved to zero paths'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'names the shell-quoting cause so the caller can fix the dispatch' {
        $tmp = New-TmpRepo 'hint'
        try {
            $out = Invoke-EraIn -WorkDir $tmp -ArgLiteral '-IncludeFiles ""'
            $out | Should -Match 'subshell|&&'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}

Describe 'True omission still reaches the documented broad-audit path' -Tag Unit {
    It 'omitting -IncludeFiles does NOT trigger the empty-include refusal' {
        # An empty repo: the broad path runs, matches nothing, and dies at the
        # pre-existing "Bundle is empty" guard. The point is WHICH guard fires.
        $tmp = New-TmpRepo 'omit'
        try {
            $out = Invoke-EraIn -WorkDir $tmp -ArgLiteral ''
            $out | Should -Not -Match 'resolved to zero paths'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'era.ps1 keys the refusal off $PSBoundParameters, not truthiness' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match "PSBoundParameters\.ContainsKey\('IncludeFiles'\)"
    }
}

Describe '-AutoDetect on a clean tree refuses the broad fallback' -Tag Unit {
    It 'refuses when it finds nothing and no -IncludeFiles narrows the run' {
        $tmp = New-TmpRepo 'autodetect-clean'
        try {
            # A real, clean git repo with one commit so HEAD~1 and status are both empty.
            Remove-Item -Recurse -Force (Join-Path $tmp '.git')
            Push-Location $tmp
            try {
                & git init -q 2>&1 | Out-Null
                & git config user.email 't@t.t' 2>&1 | Out-Null
                & git config user.name 'T' 2>&1 | Out-Null
                Set-Content -Path (Join-Path $tmp 'a.md') -Value '# a'
                & git add -A 2>&1 | Out-Null
                & git commit -q -m init 2>&1 | Out-Null
            } finally { Pop-Location }

            $out = Invoke-EraIn -WorkDir $tmp -ArgLiteral '-AutoDetect'
            $out | Should -Match 'Refusing to fall back'
            $out | Should -Not -Match 'Running repomix'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'never proposes era''s own .external-reviews artifacts as changed files' {
        # era reserves the round and writes .external-reviews/<slug>/round-N-*
        # BEFORE the -AutoDetect block runs, so `git status --porcelain` reports
        # that directory as untracked and it became the sole "changed file" on a
        # clean tree — era proposing its own output for review.
        $tmp = New-TmpRepo 'autodetect-selfref'
        try {
            Remove-Item -Recurse -Force (Join-Path $tmp '.git')
            Push-Location $tmp
            try {
                & git init -q 2>&1 | Out-Null
                & git config user.email 't@t.t' 2>&1 | Out-Null
                & git config user.name 'T' 2>&1 | Out-Null
                Set-Content -Path (Join-Path $tmp 'a.md') -Value '# a'
                & git add -A 2>&1 | Out-Null
                & git commit -q -m init 2>&1 | Out-Null
            } finally { Pop-Location }

            $out = Invoke-EraIn -WorkDir $tmp -ArgLiteral '-AutoDetect'
            $out | Should -Not -Match 'You passed -IncludeFiles: \.external-reviews'
            $out | Should -Match 'Refusing to fall back'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'still proceeds when -AutoDetect finds nothing but -IncludeFiles was given' {
        $tmp = New-TmpRepo 'autodetect-explicit'
        try {
            Remove-Item -Recurse -Force (Join-Path $tmp '.git')
            Push-Location $tmp
            try {
                & git init -q 2>&1 | Out-Null
                & git config user.email 't@t.t' 2>&1 | Out-Null
                & git config user.name 'T' 2>&1 | Out-Null
                Set-Content -Path (Join-Path $tmp 'a.md') -Value '# a'
                & git add -A 2>&1 | Out-Null
                & git commit -q -m init 2>&1 | Out-Null
            } finally { Pop-Location }

            # Pair with a missing path so the run stops at path validation —
            # which is AFTER the -AutoDetect block — instead of dispatching a
            # real (slow, billable) reviewer just to prove the guard held.
            $out = Invoke-EraIn -WorkDir $tmp -ArgLiteral '-AutoDetect -IncludeFiles "a.md,definitely-missing.py"'
            $out | Should -Not -Match 'Refusing to fall back'
            $out | Should -Match 'definitely-missing\.py'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}
