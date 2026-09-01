# A DEGRADED PANEL MUST SAY SO, AND THE MANIFEST MUST RECORD WHO WAS ASKED.
#
# Two gaps found on 2026-08-26, both the same shape as the void-round defect
# these sit beside: era knew something and did not say it.
#
#   1. `Get-EraVoidRoundReport` already computed `UsableCount` and already built
#      a per-reviewer failure explanation, but the caller printed it ONLY when
#      every reviewer failed. A 4-model panel returning 3 exited 0 and said
#      nothing — and the entire argument for a panel is that losing one member
#      is survivable BECAUSE you still know it happened.
#
#   2. `round-N-manifest.json` recorded git state, sources, files and hashes but
#      not which reviewers the round REQUESTED. So "was reviewer X dispatched?"
#      could not be answered from the artifacts. That is not hypothetical: it
#      produced a wrong claim in a published release note, where a round invoked
#      with an explicit short `-Reviewer` list was later read as evidence of a
#      silent panel degradation, with nothing on disk to check it against.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'workflow.ps1')

    # Defined here, not inside a Describe: a `function script:X` declared in a
    # Describe body is not in scope for its It blocks.
    function script:New-Artifact {
        param([string]$Dir, [string]$Preset, [int]$Round = 1)
        # Long enough to survive any length floor in Test-EraReviewerArtifact.
        Set-Content -LiteralPath (Join-Path $Dir "round-$Round-$Preset-response.md") `
            -Value ("## Critical issues`n1. something real`n" + ('x' * 400)) -Encoding utf8
    }
}

Describe 'Get-EraVoidRoundReport reports a PARTIAL panel, not just a void one' -Tag Unit {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) "era-panel-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'counts only the reviewers that produced a usable artifact' {
        script:New-Artifact -Dir $script:Dir -Preset 'gemini'
        script:New-Artifact -Dir $script:Dir -Preset 'opus'
        $results = @{
            gemini = @{ ExitCode = 0 }
            opus   = @{ ExitCode = 0 }
            dead   = @{ ExitCode = 1; Error = 'model withdrawn' }
        }
        $r = Get-EraVoidRoundReport -ReviewDir $script:Dir -Round 1 -Results $results -RequestedCount 3
        $r.IsVoid      | Should -BeFalse -Because 'two reviewers did produce reviews'
        $r.UsableCount | Should -Be 2
    }

    It 'names the failed reviewer and why, so a partial round is diagnosable' {
        script:New-Artifact -Dir $script:Dir -Preset 'gemini'
        $results = @{
            gemini = @{ ExitCode = 0 }
            dead   = @{ ExitCode = 1; Error = 'model withdrawn' }
        }
        $r = Get-EraVoidRoundReport -ReviewDir $script:Dir -Round 1 -Results $results -RequestedCount 2
        ($r.Lines -join "`n") | Should -Match 'dead'
        ($r.Lines -join "`n") | Should -Match 'model withdrawn'
        # The healthy one must NOT be listed as a problem.
        ($r.Lines -join "`n") | Should -Not -Match 'gemini'
    }

    It 'a fully healthy panel reports nothing to complain about' {
        script:New-Artifact -Dir $script:Dir -Preset 'gemini'
        script:New-Artifact -Dir $script:Dir -Preset 'opus'
        $results = @{ gemini = @{ ExitCode = 0 }; opus = @{ ExitCode = 0 } }
        $r = Get-EraVoidRoundReport -ReviewDir $script:Dir -Round 1 -Results $results -RequestedCount 2
        $r.UsableCount   | Should -Be 2
        @($r.Lines).Count | Should -Be 0
    }
}

Describe 'era.ps1 prints the partial-panel warning' -Tag Unit {
    BeforeAll { $script:Src = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1') }

    It 'has a branch for UsableCount below the requested count' {
        # The data was always there; only the branch that says it was missing.
        $script:Src | Should -Match 'UsableCount\s+-lt\s+@\(\$reviewerList\)\.Count'
    }

    It 'does NOT exit non-zero on a partial panel' {
        # A survivable degradation must not read as a failed round, or callers
        # retry — and re-spend — over a reviewer that is simply down. Exit 2 is
        # reserved for a round that produced nothing.
        $branch = [regex]::Match(
            $script:Src,
            'elseif \(\$voidReport\.UsableCount[\s\S]{0,2000}?\n    \}'
        ).Value
        $branch | Should -Not -BeNullOrEmpty -Because 'the partial branch must exist'
        $branch | Should -Not -Match '(?m)^\s*exit\s'
        $branch | Should -Match 'WARNING'
    }
}

Describe 'the manifest records which reviewers were requested' -Tag Unit {
    It 'Write-ReviewManifest accepts and persists ReviewersRequested' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "era-manifest-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $f = Join-Path $dir 'subject.txt'
            Set-Content -LiteralPath $f -Value 'hello' -Encoding utf8

            $out = Write-ReviewManifest -ReviewDir $dir -Round 1 -TopicSlug 'panel-test' `
                -PreviousRound $null -Files @($f) -RepoRoot $dir `
                -ReviewersRequested @('gemini', 'opus', 'deepseek-flash', 'muse-spark')

            $m = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
            @($m.reviewers_requested) | Should -Be @('gemini', 'opus', 'deepseek-flash', 'muse-spark')
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'era.ps1 actually passes the requested list' {
        # A parameter nothing populates is the same as no parameter. This is the
        # half that makes the record real.
        $src = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1')
        $src | Should -Match 'Write-ReviewManifest[^\r\n]*-ReviewersRequested \$reviewerList'
    }
}

Describe 'reviewers are told to flag what they cannot execute' -Tag Unit {
    BeforeAll { $script:Src = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1') }

    It 'every prompt template carries the [UNVERIFIED] instruction' {
        # Measured 2026-08-26 across four review rounds: the panel was near
        # flawless on STRUCTURAL findings (unreachable branches, vacuous tests,
        # a guard on one path and not its sibling) and produced its only two
        # false positives on ENVIRONMENTAL claims — a socket-inheritance
        # mechanism that did not reproduce, and a shutdown duration derived by
        # summing timeout bounds rather than measuring (28s claimed, 3.6s
        # actual). Both were raised by two reviewers independently, in prose
        # indistinguishable from the correct findings.
        #
        # The tag does not make the model right; it makes the caller able to
        # triage, which is the part that was missing.
        $cites = ([regex]::Matches($script:Src, 'Cite locations as file:line')).Count
        $tags  = ([regex]::Matches($script:Src, '\[UNVERIFIED\]')).Count
        $cites | Should -BeGreaterThan 0
        # >= not ==. The invariant is that no citation-asking template LACKS the
        # tag, not that the two counts match: -PremiseCheck appends a section that
        # invites [UNVERIFIED] without asking for citations, and an equality test
        # made a correct addition look like a regression.
        $tags  | Should -BeGreaterOrEqual $cites -Because 'every prompt that asks for citations must also ask for this'
    }

    It 'it tells the reviewer HOW to settle the claim, not just to flag it' {
        $script:Src | Should -Match 'command or measurement that would settle it'
    }

    It 'it explicitly excludes structural findings from tagging' {
        # Tagging everything would be the same as tagging nothing.
        $script:Src | Should -Match 'Do not tag those'
    }
}
