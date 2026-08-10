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

Describe 'The traversal guard is not bypassable by bracketing the path' -Tag Integration {
    # MEASURED bypass. The guard exempted any entry matching '[*?\[\]]' on the
    # reasoning that "glob patterns match inside the repo tree by definition".
    # That is true of '*' and '?', and false of '[' and ']' -- those are
    # ordinary characters in a real filename (every Next.js dynamic route has
    # them), so a bracketed RELATIVE traversal skipped the check entirely:
    #
    #   ../secret.md      -> traversal blocked? True
    #   ../secret[1].md   -> traversal blocked? False
    #
    # Absolute out-of-repo paths are a separate, deliberate flow: P6 staging
    # rewrites them before this guard runs. Relative traversal is what the
    # guard still exists to stop, which is what these cases exercise.
    BeforeAll {
        function script:Invoke-EraTraversal {
            param([string]$Repo, [string]$ArgLiteral)
            & pwsh -NonInteractive -Command @"
Set-Location -LiteralPath '$Repo'
try { & '$($script:EraPath)' -TopicSlug 'trav-test' -Force $ArgLiteral 2>&1 | Out-String }
catch { Write-Output "CAUGHT: `$(`$_.Exception.Message)" }
"@ 2>&1 | Out-String
        }
    }
    BeforeEach {
        $script:Base = Join-Path $env:TEMP "era-trav-$(New-Guid)"
        $script:Repo = Join-Path $script:Base 'repo'
        New-Item -ItemType Directory -Path (Join-Path $script:Repo '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Repo 'src\app\[id]') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Repo 'in.md') -Value 'inside' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:Repo 'src\app\[id]\page.tsx') -Value 'route' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:Base 'secret.md')    -Value 'OUT' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:Base 'secret[1].md') -Value 'OUT' -Encoding UTF8
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'blocks a plain relative traversal' {
        $out = Invoke-EraTraversal -Repo $script:Repo -ArgLiteral '-IncludeFiles "in.md,../secret.md"'
        $out | Should -Match 'path traversal blocked'
    }

    It 'blocks a relative traversal whose filename contains brackets' {
        $out = Invoke-EraTraversal -Repo $script:Repo -ArgLiteral '-IncludeFiles "in.md,../secret[1].md"'
        $out | Should -Match 'path traversal blocked'
    }

    It 'still accepts a legitimate bracketed path INSIDE the repo' {
        # The guard against over-correcting: a Next.js dynamic route is a normal
        # file and must not be mistaken for traversal.
        $out = Invoke-EraTraversal -Repo $script:Repo `
            -ArgLiteral '-IncludeFiles "src/app/[id]/page.tsx,definitely-missing.py"'
        $out | Should -Not -Match 'path traversal blocked'
        # Pair with a missing file so the run stops at validation instead of
        # dispatching a real reviewer; the control is that it names THAT file.
        $out | Should -Match 'definitely-missing\.py'
    }

    It 'still accepts a genuine glob' {
        $out = Invoke-EraTraversal -Repo $script:Repo -ArgLiteral '-IncludeFiles "*.md,definitely-missing.py"'
        $out | Should -Not -Match 'path traversal blocked'
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
            # Anchor the negative to the ERROR line: the correct staging message
            # legitimately echoes the full source path, which also ends in
            # '-ext\outside.md', so a bare negative match would reject the fix.
            $out | Should -Not -Match 'not found relative to repo root[^\r\n]*-ext[\\/]outside\.md'
        } finally {
            Remove-Item -Recurse -Force $repo, $ext -ErrorAction SilentlyContinue
        }
    }
}
