# tools/grade-round.ps1 must bundle everything the round is being asked to grade.
#
# Round-7 (opus) closed with a section headed "What I could not verify from this
# bundle". Two of the FOUR commits it was asked to grade were in it:
#
#   c8f4c56  "grade-round splatting"        -> "Cannot verify -- tools/grade-round.ps1
#                                              is not in the bundle."
#   4419f97  "measure enumerate-once and    -> "Cannot verify -- the assessment doc
#             decline it"                      is not in the bundle."
#
# It also flagged that nothing confirmed the new SkipDirExt shape was pinned by a
# test, because tests/IgnorePatternDepth.Tests.ps1 was not bundled either.
#
# That is grade cost paid for bundle scope, not for code quality: a reviewer
# asked "what changed since round N" and then handed a bundle that does not
# contain half of it can only answer "I cannot tell". The include list was a
# hand-maintained constant and drifted from what the repo was actually doing.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/GradeRoundBundle.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Tool = Join-Path $script:Root 'tools/grade-round.ps1'
    $script:Src  = Get-Content -Raw -LiteralPath $script:Tool
}

Describe 'the grading bundle covers the commits under review' -Tag Unit {

    It 'the tool exists and still takes an explicit -IncludeFiles override' {
        Test-Path -LiteralPath $script:Tool | Should -BeTrue
        (Get-Command $script:Tool).Parameters.Keys | Should -Contain 'IncludeFiles'
    }

    It 'declares -Reviewer exactly as era.ps1 does, so a panel binds either way' {
        # This file narrowed era's [string[]] to [string]. A bare comma list is
        # ONE string when the script is launched as `pwsh tools/grade-round.ps1
        # -Reviewer a,b` but an ARRAY when it is dot-invoked from inside a
        # PowerShell session -- which is how anyone iterating in a shell calls
        # it, and how the .EXAMPLE in this very file reads. Measured: it threw
        #   "Cannot process argument transformation on parameter 'Reviewer'.
        #    Cannot convert value to type System.String."
        # era.ps1 takes [string[]] AND splits on ',' itself, so matching its
        # declaration makes both invocation styles work.
        #
        # Second parameter-binding defect in this file: c8f4c56 was positional
        # array splatting. It is 170 lines long and dispatches money.
        $tool = (Get-Command $script:Tool).Parameters['Reviewer'].ParameterType
        $era  = (Get-Command (Join-Path $script:Root 'runtimes/era.ps1')).Parameters['Reviewer'].ParameterType
        $tool | Should -Be $era -Because 'a wrapper that narrows the type it forwards breaks its own documented example'
    }

    It 'unions the curated list with everything touched since the last graded round' {
        # The invariant: the bundle is DERIVED from the range being graded, not
        # a constant someone has to remember to update.
        $script:Src | Should -Match 'git diff --name-only'
        $union = $script:Src.IndexOf('git diff --name-only')
        $splat = $script:Src.IndexOf('IncludeFiles       = $IncludeFiles')
        $union | Should -BeGreaterThan 0
        $splat | Should -BeGreaterThan 0
        $union | Should -BeLessThan $splat -Because 'the union must happen before the list is handed to era'
    }

    It 'derives that range from the same $lastHead the "what changed" block reports' {
        # One source of truth for "what is being graded". If the prose says one
        # range and the bundle covers another, the reviewer is being misled.
        $lastHead = $script:Src.IndexOf('$lastHead  = $m.git_head')
        $union    = $script:Src.IndexOf('git diff --name-only')
        $lastHead | Should -BeGreaterThan 0
        $union    | Should -BeGreaterThan $lastHead
        # ...and the union references it rather than recomputing a range.
        $script:Src.Substring($union - 200, 260) | Should -Match '\$lastHead'
    }

    It 'honours an explicit -IncludeFiles instead of quietly widening it' {
        $script:Src | Should -Match "PSBoundParameters\.ContainsKey\('IncludeFiles'\)"
    }

    It 'bundles the harness that produces the round' {
        # c8f4c56 was a fix TO grade-round.ps1 and could not be checked.
        $script:Src | Should -Match "'tools/grade-round\.ps1'"
    }

    It 'bundles the assessment record, so measured declines are not re-argued' {
        # 4419f97 declined "enumerate once" on measurement and the reviewer could
        # not see the doc. Two rounds running, opus has re-listed items this repo
        # already settled -- that is the cost of not shipping the record.
        $script:Src | Should -Match "docs/assessments/2026-08-14-enumerate-once-declined\.md|docs/assessments/\*\.md"
    }

    It 'bundles the test that pins the ignore-pattern shapes' {
        # Opus: "nothing confirms the new SkipDirExt shape is pinned by a test".
        $script:Src | Should -Match "tests/IgnorePatternDepth\.Tests\.ps1|tests/IgnoreParity\.Tests\.ps1"
    }

    It 'names anything it drops rather than truncating silently' {
        # House rule: a bundle that quietly caps its own scope reads as "covered
        # everything" when it did not -- the exact failure this file exists for.
        $script:Src | Should -Match 'MaxDerived|derived-file cap|dropped'
    }
}

Describe 'git log is untrusted text and must not become control plane' -Tag Unit {
    # Round-8 (opus) BLOCKER 1, and the evidence was the round's own prompt.
    #
    # grade-round.ps1 splices raw `git log --oneline` into {{CHANGES_SINCE}}.
    # Commit 9d78231's SUBJECT contains the literal {{PREVIOUS_ROUND}} -- it is
    # the commit that fixed the token's double-definition, so of course it names
    # it. era then ran Invoke-PromptTokenSubstitution over the finished prompt
    # and expanded the token INSIDE the ``` fence:
    #
    #   9d78231 fix: two regexes answered one question about ## Previous round's
    #   review (round 7, 2 reviewer(s))
    #   ### Reviewer: gemini
    #   [...~32 KB of the round-7 panel...]
    #   , and disagreed
    #   8421bda fix: an empty include list is the WHOLE REPO to repomix...
    #
    # Measured on round-8-prompt.md: 4 '### Reviewer:' headers where 2 is
    # healthy. Two live consequences -- the orientation section the reviewer is
    # told to "verify against the code" is corrupted and two of thirteen commits
    # are unreadable, and the whole panel is carried TWICE (~32 KB per reviewer,
    # against the 160 KB ceiling Get-EraDiffPreviousReviewBlock exists to stop).
    #
    # workflow.ps1 stated the assumption outright -- "a token inside a fenced
    # block is still expanded ... the inline-span form is the one that occurs in
    # practice." This repo's own tooling falsified it, in the round that graded
    # the commit that wrote it.
    #
    # Same class as the era-require fix: reviewer-controlled text became control
    # plane. The symmetric rule is READ the control plane before splicing
    # untrusted text, and NEUTRALIZE control tokens in untrusted text before
    # splicing it. This is the second half.

    BeforeAll {
        $script:Root2 = Split-Path $PSScriptRoot -Parent
        . (Join-Path $script:Root2 'workflow.ps1')
        $script:ToolSrc = Get-Content -Raw (Join-Path $script:Root2 'tools/grade-round.ps1')
    }

    It 'neutralizes template tokens in the changes block before the prompt is written' {
        $neutralize = $script:ToolSrc.IndexOf("-replace '\{\{")
        $write      = $script:ToolSrc.IndexOf('Set-Content -LiteralPath $promptPath')
        $neutralize | Should -BeGreaterThan 0 -Because 'the git log text must be defanged'
        $write      | Should -BeGreaterThan 0
        $neutralize | Should -BeLessThan $write -Because 'defanging after the write is not defanging'
    }

    It 'end to end: a commit subject naming the token no longer inlines the panel' {
        # The real substitution function, over a prompt built the way
        # grade-round builds one, with the real commit subject that caused this.
        $rev = Join-Path ([System.IO.Path]::GetTempPath()) ('era-inj-' + [guid]::NewGuid())
        New-Item -ItemType Directory $rev -Force | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $rev 'round-1-response.md') -Value 'PANEL TEXT' -Encoding UTF8
            $fence = [string][char]0x60 * 3
            $subject = '9d78231 fix: two regexes answered one question about {{PREVIOUS_ROUND}}, and disagreed'

            # The transform grade-round applies to untrusted git output.
            $changes = $subject -replace '\{\{([A-Z_]+)\}\}', '{{ $1 }}'

            $p = Join-Path $rev 'prompt.md'
            @('## What changed', $fence, $changes, $fence, '', '## Previous round', '{{PREVIOUS_ROUND}}') |
                Set-Content -LiteralPath $p -Encoding UTF8

            $null = Invoke-PromptTokenSubstitution -PromptFile $p -ReviewDir $rev -RoundN 2
            $after = Get-Content -Raw -LiteralPath $p

            ([regex]::Matches($after, 'PANEL TEXT')).Count | Should -Be 1 `
                -Because 'the panel belongs under ## Previous round ONCE, not inside the commit list too'
            $after | Should -Match 'and disagreed' -Because 'the commit subject must survive readable'
            $after | Should -Match '9d78231' -Because 'the entry must not be split'
        } finally { Remove-Item -LiteralPath $rev -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'and the un-neutralized form really does inline it — non-vacuity' {
        # If this ever stops being true the guard above is pointless.
        $rev = Join-Path ([System.IO.Path]::GetTempPath()) ('era-inj2-' + [guid]::NewGuid())
        New-Item -ItemType Directory $rev -Force | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $rev 'round-1-response.md') -Value 'PANEL TEXT' -Encoding UTF8
            $fence = [string][char]0x60 * 3
            $p = Join-Path $rev 'prompt.md'
            @('## What changed', $fence,
              '9d78231 fix: two regexes answered one question about {{PREVIOUS_ROUND}}, and disagreed',
              $fence, '', '## Previous round', '{{PREVIOUS_ROUND}}') |
                Set-Content -LiteralPath $p -Encoding UTF8
            $null = Invoke-PromptTokenSubstitution -PromptFile $p -ReviewDir $rev -RoundN 2
            ([regex]::Matches((Get-Content -Raw -LiteralPath $p), 'PANEL TEXT')).Count |
                Should -Be 2 -Because 'un-neutralized, the fenced mention expands too -- that is the bug'
        } finally { Remove-Item -LiteralPath $rev -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
