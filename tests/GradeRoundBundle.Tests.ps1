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
