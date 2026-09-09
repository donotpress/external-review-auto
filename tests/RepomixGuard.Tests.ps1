# Tests for the repomix invocation guard.
#
# Two defects, both visible in the 2026-08-09 incident:
#
#   1. era.ps1 interpolated the ENTIRE captured repomix output into the failure
#      exception. The run that collected 72,378 files produced a 16.9 MB log, so
#      the "error message" was 16.9 MB of bundle chatter.
#   2. The timeout branch called Stop-Job without Receive-Job, discarding every
#      diagnostic repomix had produced — an 18-minute failure that explained
#      nothing.
#
# Known limitation, deliberately NOT fixed here: Start-ThreadJob + Wait-Job +
# Stop-Job cannot bound a NATIVE child process. Stop-Job ends the thread; the
# node process repomix spawned keeps running. The adapters solve this with
# Process.Kill($true) (asserted by tests/ProcessTreeKill.Tests.ps1), but repomix
# resolves to a .ps1/.cmd shim on Windows, so spawning it under a Process handle
# needs its own shim-resolution logic and tests. See references/troubleshooting.md.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/RepomixGuard.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'
}

Describe 'Get-EraTruncatedText' -Tag Unit {
    It 'returns short text unchanged' {
        Get-EraTruncatedText -Text 'boom' -MaxChars 100 | Should -Be 'boom'
    }

    It 'returns empty string for null input' {
        Get-EraTruncatedText -Text $null -MaxChars 100 | Should -Be ''
    }

    It 'caps long text near MaxChars instead of echoing all of it' {
        $huge = 'x' * 200000
        $out = Get-EraTruncatedText -Text $huge -MaxChars 500
        $out.Length | Should -BeLessThan 800
    }

    It 'never returns MORE text than it was given' {
        # Truncating 101 chars against a 100-char budget used to yield 168 chars,
        # because the "[truncated: ...]" marker cost more than it saved.
        $t = 'x' * 101
        (Get-EraTruncatedText -Text $t -MaxChars 100).Length | Should -BeLessOrEqual $t.Length
    }

    It 'does not throw on a negative budget — it runs inside error handling' {
        # Both call sites pass 4000, but this is a shared helper invoked while
        # building an exception message. Throwing there would mask the original
        # error with an ArgumentOutOfRangeException.
        { Get-EraTruncatedText -Text ('x' * 1000) -MaxChars -5 } | Should -Not -Throw
    }

    It 'keeps the tail as well as the head — a subprocess error is usually last' {
        $text = ('a' * 100000) + 'FINAL-ERROR-LINE'
        $out = Get-EraTruncatedText -Text $text -MaxChars 600
        $out | Should -Match 'FINAL-ERROR-LINE'
        $out.Length | Should -BeLessThan 1000
    }

    It 'says how much it dropped, so the number is not silently lost' {
        $huge = 'x' * 200000
        $out = Get-EraTruncatedText -Text $huge -MaxChars 500
        $out | Should -Match '200000|truncated'
    }
}

Describe 'era.ps1 repomix guard' -Tag Unit {
    It 'does not interpolate the raw captured output into the failure exception' {
        $src = Get-Content -Raw $script:EraPath
        # The 16.9 MB error message shape.
        $src | Should -Not -Match 'exit code \$repomixExitCode`?: \$repomixResult'
        $src | Should -Match 'Get-EraTruncatedText'
    }

    # SUPERSEDED 2026-08-09. Two tests here used to assert the ThreadJob design:
    # that Receive-Job preceded Stop-Job on the timeout branch, and that era
    # DOCUMENTED its inability to tree-kill the native child. Both encoded a
    # workaround and a known limitation, and P3 removed the limitation, so they
    # now assert the stronger invariant that replaced it. Behavioural coverage
    # lives in tests/RepomixProcess.Tests.ps1.

    It 'surfaces partial output on the timeout branch' {
        $src = Get-Content -Raw $script:EraPath
        $timeoutIdx = $src.IndexOf('repomix timed out after')
        $timeoutIdx | Should -BeGreaterThan 0
        $branch = $src.Substring([Math]::Max(0, $timeoutIdx - 900), [Math]::Min(900, $timeoutIdx))
        # The tracked-process result carries output captured before the kill.
        $branch | Should -Match '\$repomixRun\.Output'
        $branch | Should -Match 'Get-EraTruncatedText'
    }

    It 'runs repomix under a tree-killable handle, not a ThreadJob' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Not -Match 'Start-ThreadJob -Name repomix'
        $src | Should -Match 'Invoke-EraRepomix'
        # The kill itself is Process.Kill($true) — the same invariant
        # tests/ProcessTreeKill.Tests.ps1 asserts for every backend adapter.
        $wf = Get-Content -Raw (Join-Path $script:SkillRoot 'workflow.ps1')
        $wf | Should -Match '\.Kill\(\$true\)'
        $wf | Should -Not -Match '(?m)^\s*\$proc\.Kill\(\)\s*$'
    }

    It 'no longer claims the native child cannot be killed' {
        # The old comment said Wait-Job/Stop-Job "cannot bound the NATIVE child
        # process". That is no longer true, so the claim must not survive as
        # stale documentation.
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Not -Match '(?i)cannot (bound|kill)[^\r\n]{0,80}(native|child)'
        $doc = Get-Content -Raw (Join-Path $script:SkillRoot 'references/troubleshooting.md')
        $doc | Should -Not -Match '(?i)known limitation.{0,120}Stop-Job'
    }
}

Describe 'a UNC / WSL-native repo root is diagnosed as itself, not as a locked directory' -Tag Unit {
    # TWO FAULTS, ONE repomix ERROR, OPPOSITE FIXES. era runs as Windows pwsh
    # (there is no native Linux build here -- `pwsh` in WSL execs pwsh.exe), and
    # a Windows process cannot hold a UNC path as its cwd: given
    # \\wsl.localhost\... it falls back to C:\Windows, repomix scans THAT, and
    # aborts on the first unreadable directory. The old message blamed a locked
    # application and told the operator to add an ignore pattern -- for a
    # directory they never asked era to read.
    #
    # Reported by a peer session on 2026-09-06 that measured it twice and named
    # the misdiagnosis. Reproduced and fixed the same day; the identical file
    # that fails under /home passes every gate staged under /mnt/c.
    BeforeAll {
        $script:EraSrc = Get-Content -Raw -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtimes/era.ps1')
    }

    It 'branches on a UNC repo root before falling through to the locked-directory advice' {
        $script:EraSrc | Should -Match 'wsl\.localhost'
        $script:EraSrc | Should -Match 'repo root is not on a Windows drive'
    }

    It 'tells the operator the drive-mapping workaround does NOT work' {
        # PowerShell's ProviderPath normalises W:\... back to the UNC form, so a
        # mapped drive fails identically. The peer tried it first.
        $script:EraSrc | Should -Match 'NOT a fix.*net use'
    }

    It 'still keeps the locked-directory advice for the non-UNC case' {
        # Guards against the new branch swallowing the original diagnosis, which
        # is correct for the fault it was written for (a live Chrome profile).
        $script:EraSrc | Should -Match 'a LIVE application holding its own data directory'
    }
}

Describe 'the UNC refusal prints a recipe and does NOT auto-stage' -Tag Unit {
    # RULING 2026-09-06, asked for by a peer session that offered to build
    # auto-staging and leaned against it themselves. The deciding argument is
    # PROVENANCE, not taste: Write-ReviewManifest records git_head/git_branch/
    # git_clean as the round's anchor, and a staged copy is a fresh `git init`,
    # so an auto-staged round would anchor to a SHA that exists nowhere and every
    # later citation of it would point at a commit nobody can resolve. era's
    # dirty-tree gate already refuses rather than stash for that exact reason.
    BeforeAll {
        $script:EraSrc = Get-Content -Raw -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtimes/era.ps1')
    }

    It 'emits a recipe naming the caller''s own slug and include set' {
        $script:EraSrc | Should -Match 'recipe\s+:'
        $script:EraSrc | Should -Match '\$incl'
        $script:EraSrc | Should -Match '\$slug'
    }

    It 'the recipe captures origin provenance before the cd' {
        # A staged round anchors to a fresh git init. The recipe must leave a
        # record of what it was staged FROM, or the manifest cites a SHA that
        # exists nowhere -- the failure the no-auto-stage ruling exists to
        # prevent, reintroduced by the ruling's own workaround.
        $branch = [regex]::Match($script:EraSrc,
            '(?s)if \(\$rootIsUnc.*?Nothing was dispatched and nothing was spent\."\)').Value
        $branch | Should -Match '\.era-origin'
        $branch | Should -Match 'origin_head'
        # captured BEFORE the cd, or it resolves against the staged repo.
        # Scoped to the recipe: the ruling's own comment above it mentions
        # `git init` first, so unscoped IndexOf compares against prose.
        $recipe = $branch.Substring($branch.IndexOf('mktemp'))
        $recipe.IndexOf('rev-parse HEAD') | Should -BeLessThan $recipe.IndexOf('cd ')
    }

    It 'still REFUSES -- it does not stage, copy or dispatch on the caller''s behalf' {
        # The whole point. If this branch ever gains a Copy-Item/git init it has
        # become the thing this ruling rejected.
        $branch = [regex]::Match($script:EraSrc,
            '(?s)if \(\$rootIsUnc.*?Nothing was dispatched and nothing was spent\."\)').Value
        # Assert on SIDE EFFECTS, not on strings: `git init` legitimately appears
        # in the recipe TEXT, so grepping for it cannot tell a quoted instruction
        # from an executed command. The first version of this test could not, and
        # failed on the recipe it was written to protect.
        $branch | Should -Not -BeNullOrEmpty
        foreach ($sideEffect in 'Copy-Item', 'New-Item', 'Start-Process', 'Invoke-Expression', 'Remove-Item') {
            $branch | Should -Not -Match $sideEffect -Because 'the UNC branch must refuse, not stage'
        }
        $branch | Should -Match 'Stop-EraWithError'
    }
}
