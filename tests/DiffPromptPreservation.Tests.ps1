# -Diff must not throw away caller-supplied prompt content.
#
# Round-5 panel, two independent findings on the same gate:
#
#   gemini (BLOCKER): `-Diff` with `-ConversationFile` and no
#     `-PromptOverrideFile` overwrites $promptPath, discarding the injected
#     '## Session context'.
#   opus: `-SpecReview` sets $PromptOverrideFile (era.ps1:613) but never sets
#     $script:UserSuppliedPromptOverride -- that flag is assigned from
#     $PSBoundParameters at era.ps1:150 -- so `-SpecReview -Diff` also takes the
#     destructive branch and discards the generated spec-review prompt.
#
# Both verified before fixing. The gate asked "did the caller pass
# -PromptOverrideFile?" when the question it needed to ask was "does this prompt
# carry content the caller supplied?". Three ways to say yes, only one checked.
#
# The round-4 fix comment above that branch literally lists "-ConversationFile
# injection" as something it protects. It did not.
#
# NOT simply "always prepend": the diff template is self-contained -- it carries
# its own '## Output format' block and its own instructions. Prepending it to the
# untouched generic default template would hand the reviewer two conflicting
# output formats. Replace only when the existing prompt is that generic default.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/DiffPromptPreservation.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'workflow.ps1')
    $script:EraSrc = Get-Content -Raw (Join-Path $script:Root 'runtimes/era.ps1')

    $script:Diff = @"
# Follow-up Review - my-topic, Round 2

<previous_review>
prior stuff
</previous_review>

## Output format
## Critical issues (must fix)
"@
    $script:Caller = @"
# My own prompt

## Session context

We are debugging the dispatcher's straggler path.

## Output format
ORDER: ...
"@
}

Describe 'Merge-EraDiffPrompt' -Tag Unit {
    It 'keeps caller content, with the diff context first' {
        $m = Merge-EraDiffPrompt -DiffPrompt $script:Diff -ExistingPrompt $script:Caller -ExistingCarriesCallerContent $true
        $m | Should -Match 'Session context'
        $m | Should -Match 'Follow-up Review'
        $m.IndexOf('Follow-up Review') | Should -BeLessThan $m.IndexOf('Session context') -Because 'the delta comes first, then the stable caller context'
    }

    It 'replaces the generic default outright — two output-format blocks is worse than one' {
        $m = Merge-EraDiffPrompt -DiffPrompt $script:Diff -ExistingPrompt "# External Review Prompt`n`n## Output format`n## Critical issues" -ExistingCarriesCallerContent $false
        $m | Should -Be $script:Diff
        ([regex]::Matches($m, '## Output format')).Count | Should -Be 1
    }

    It 'is safe when there is no existing prompt at all' {
        Merge-EraDiffPrompt -DiffPrompt $script:Diff -ExistingPrompt '' -ExistingCarriesCallerContent $true | Should -Be $script:Diff
        Merge-EraDiffPrompt -DiffPrompt $script:Diff -ExistingPrompt $null -ExistingCarriesCallerContent $true | Should -Be $script:Diff
    }
}

Describe 'era.ps1 marks every prompt that carries caller content' -Tag Unit {
    It 'uses Merge-EraDiffPrompt rather than deciding inline' {
        $script:EraSrc | Should -Match 'Merge-EraDiffPrompt'
        # The bare destructive write must be gone.
        $script:EraSrc | Should -Not -Match '(?m)^\s*\$diffPrompt \| Set-Content'
    }

    It 'gates on caller-content, NOT on -PromptOverrideFile having been passed' {
        # The precise defect: $script:UserSuppliedPromptOverride answers a
        # narrower question than the branch needs.
        # Anchor on the CALL, not on any mention -- a comment naming the
        # function also matches, and IndexOf returns the first hit.
        $idx = $script:EraSrc.IndexOf('Merge-EraDiffPrompt -DiffPrompt')
        $idx | Should -BeGreaterThan 0
        $window = $script:EraSrc.Substring([Math]::Max(0, $idx - 400), 700)
        $window | Should -Not -Match 'UserSuppliedPromptOverride'
        $window | Should -Match 'PromptCarriesCallerContent'
    }

    It '-SpecReview marks its generated prompt as caller content' {
        # era.ps1:613 sets the local $PromptOverrideFile; without this the
        # generated spec-review prompt is discarded on a -Diff follow-up.
        $i = $script:EraSrc.IndexOf('-SpecReview: generated spec-review prompt')
        $i | Should -BeGreaterThan 0
        $script:EraSrc.Substring([Math]::Max(0, $i - 600), 700) | Should -Match 'PromptCarriesCallerContent\s*=\s*\$true'
    }

    It '-ConversationFile marks the prompt as caller content on BOTH injection paths' {
        foreach ($marker in @("-ConversationFile: injected into", "-ConversationFile: appended as")) {
            $i = $script:EraSrc.IndexOf($marker)
            $i | Should -BeGreaterThan 0 -Because "$marker should exist"
            $script:EraSrc.Substring([Math]::Max(0, $i - 700), 800) |
                Should -Match 'PromptCarriesCallerContent\s*=\s*\$true' -Because "$marker must mark the prompt"
        }
    }

    It 'an explicitly passed -PromptOverrideFile and an auto-detected pending prompt both mark it' {
        ([regex]::Matches($script:EraSrc, 'PromptCarriesCallerContent\s*=\s*')).Count |
            Should -BeGreaterOrEqual 4 -Because 'override, pending-prompt, SpecReview, and both ConversationFile paths'
    }
}

Describe 'Get-EraDiffPreviousReviewBlock — never carry the panel twice' -Tag Unit {
    # Round-6 (opus), finding 3: a regression from 4e6f6c4 (mine).
    # Invoke-PromptTokenSubstitution has ALREADY expanded {{PREVIOUS_ROUND}} into
    # $promptPath by the time the -Diff block runs, and the diff block then built
    # <previous_review> from a SECOND call to Get-EraPreviousRoundText, which
    # Merge-EraDiffPrompt concatenates onto it. Before 4e6f6c4 the duplicate was
    # canonical (1 review) + panel (3); afterwards it is panel + panel. Each call
    # caps independently at 80,000 chars, so the ceiling is 160 KB of duplicated
    # prior-round text, uploaded once per reviewer.

    It 'omits the block when the prompt already carried {{PREVIOUS_ROUND}}' {
        Get-EraDiffPreviousReviewBlock -PreviousText 'panel text' -AlreadyInPrompt $true |
            Should -BeNullOrEmpty
    }

    It 'emits it when the prompt did not' {
        $b = Get-EraDiffPreviousReviewBlock -PreviousText 'panel text' -AlreadyInPrompt $false
        $b | Should -Match 'previous_review'
        $b | Should -Match 'panel text'
    }

    It 'emits nothing for empty previous text either way' {
        Get-EraDiffPreviousReviewBlock -PreviousText '' -AlreadyInPrompt $false | Should -BeNullOrEmpty
    }

    It 'era.ps1 takes the flag FROM the substitution, not from a second regex' {
        # SUPERSEDED 2026-08-14 (round-7 opus, blocker 1). This used to assert
        # that era.ps1 captured the flag with its OWN regex BEFORE calling
        # Invoke-PromptTokenSubstitution -- an ordering invariant over two
        # separate definitions of one rule. They drifted within a single commit
        # of being written (see the Describe below), so the ordering is no
        # longer the invariant: HAVING a second definition is the defect.
        # The replacement invariant is that the flag is assigned from the call.
        $era = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtimes/era.ps1')
        $era | Should -Match 'Get-EraDiffPreviousReviewBlock'
        $era | Should -Match 'PromptHadPreviousRoundToken\s*=\s*(\r?\n\s*)?Invoke-PromptTokenSubstitution' `
            -Because 'the substituting regex is the only thing that knows whether a token was consumed'
    }
}

Describe 'Invoke-PromptTokenSubstitution reports what it did — one rule, one definition' -Tag Unit {
    # Round-7 (opus), BLOCKER 1 -- a NEW defect, introduced by ab17ea0, the
    # commit that fixed round 6's finding. Two regexes answered one question and
    # disagreed:
    #
    #   era.ps1     -match '\{\{PREVIOUS_ROUND\}\}'                 (decides SUPPRESS)
    #   workflow.ps1        '(?<!`)\{\{PREVIOUS_ROUND\}\}(?!`)'     (decides SUBSTITUTE)
    #
    # The second deliberately skips BACKTICKED mentions -- an inline code span is
    # a MENTION, not a substitution site, and expanding those produced the
    # measured 85,457-byte wreck documented at the Replace site. The first had no
    # such guard.
    #
    # So for a prompt whose only occurrences are backticked -- exactly the shape
    # this repo's own meta-review prompts take; round-7-prompt.md carries THREE
    # such occurrences -- the flag was $true, nothing was expanded, and
    # Get-EraDiffPreviousReviewBlock returned ''. A -Diff follow-up dispatched
    # with NO prior review at all, silently, after paying to read and assemble
    # it. Measured before fixing:
    #
    #   backticked mention only   flag=True  expanded=False  diffBlockLen=0
    #   plain token               flag=True  expanded=True   diffBlockLen=0
    #   no token at all           flag=False expanded=False  diffBlockLen=60
    #
    # The fix is NOT to patch the second regex to agree. It is to delete it:
    # the substituting regex is the only definition, and it now reports its own
    # outcome. Patching would leave two copies to drift again -- this pair
    # drifted within one commit of being created.

    BeforeAll {
        $script:Bt = [char]0x60   # backtick built as a variable: inline, it escapes
        $script:TokTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("era-tok-" + [guid]::NewGuid())
        New-Item -ItemType Directory $script:TokTmp -Force | Out-Null
        $script:TokRev = Join-Path $script:TokTmp 'rev'
        New-Item -ItemType Directory $script:TokRev -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:TokRev 'round-1-response.md') `
            -Value 'REAL PRIOR REVIEW TEXT' -Encoding UTF8

        function script:New-TokPrompt([string]$Text) {
            $p = Join-Path $script:TokTmp (([guid]::NewGuid()).ToString() + '.md')
            Set-Content -LiteralPath $p -Value $Text -Encoding UTF8
            return $p
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:TokTmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns $true when it actually substituted a live token' {
        $p = New-TokPrompt 'Prior round: {{PREVIOUS_ROUND}} — react to it.'
        $r = Invoke-PromptTokenSubstitution -PromptFile $p -ReviewDir $script:TokRev -RoundN 2
        $r | Should -BeOfType [bool] -Because 'the caller needs a definite answer, not $null'
        $r | Should -BeTrue
        (Get-Content -Raw -LiteralPath $p) | Should -Match 'REAL PRIOR REVIEW TEXT'
    }

    It 'returns $false when the only occurrences are BACKTICKED mentions' {
        # The blocker, stated as a test. Nothing was substituted, so the caller
        # must be told the prompt does NOT carry the previous round.
        $p = New-TokPrompt ('Attack ' + $script:Bt + '{{PREVIOUS_ROUND}}' + $script:Bt + ' aggregation.')
        $r = Invoke-PromptTokenSubstitution -PromptFile $p -ReviewDir $script:TokRev -RoundN 2
        $r | Should -BeOfType [bool]
        $r | Should -BeFalse -Because 'a mention in an inline code span is not a substitution'
        $after = Get-Content -Raw -LiteralPath $p
        $after | Should -Not -Match 'REAL PRIOR REVIEW TEXT' -Because 'the mention must stay a mention'
        $after | Should -Match '\{\{PREVIOUS_ROUND\}\}' -Because 'the literal text survives verbatim'
    }

    It 'returns $false when the prompt has no token at all' {
        $p = New-TokPrompt 'Just review the diff please.'
        $r = Invoke-PromptTokenSubstitution -PromptFile $p -ReviewDir $script:TokRev -RoundN 2
        $r | Should -BeOfType [bool]
        $r | Should -BeFalse
    }

    It 'returns $false when the prompt file does not exist' {
        $r = Invoke-PromptTokenSubstitution -PromptFile (Join-Path $script:TokTmp 'nope.md') `
                -ReviewDir $script:TokRev -RoundN 2
        $r | Should -BeOfType [bool]
        $r | Should -BeFalse
    }

    It 'end to end: a backticked mention no longer deletes the previous round from a -Diff round' {
        # This is the defect itself. Compose the two functions exactly as era.ps1
        # does and assert the prior review SURVIVES.
        $p = New-TokPrompt ('Round 2: attack ' + $script:Bt + '{{PREVIOUS_ROUND}}' + $script:Bt + ' aggregation.')
        $flag  = Invoke-PromptTokenSubstitution -PromptFile $p -ReviewDir $script:TokRev -RoundN 2
        $block = Get-EraDiffPreviousReviewBlock -PreviousText 'REAL PRIOR REVIEW TEXT' -AlreadyInPrompt $flag
        $block | Should -Match 'REAL PRIOR REVIEW TEXT' -Because 'nothing put it in the prompt, so the block must carry it'
    }

    It 'and a REAL token still suppresses the block, so the panel is never carried twice' {
        # The round-6 fix must survive this change: both directions pinned.
        $p = New-TokPrompt 'Prior round: {{PREVIOUS_ROUND}} — react to it.'
        $flag  = Invoke-PromptTokenSubstitution -PromptFile $p -ReviewDir $script:TokRev -RoundN 2
        $block = Get-EraDiffPreviousReviewBlock -PreviousText 'REAL PRIOR REVIEW TEXT' -AlreadyInPrompt $flag
        $block | Should -BeNullOrEmpty -Because 'the prompt already carries it; a second copy is up to 160 KB per reviewer'
    }

    It 'era.ps1 holds no independent {{PREVIOUS_ROUND}} match expression' {
        # The structural half: one rule, one definition. Comments may name the
        # token freely; what must not exist is a second -match/-notmatch against
        # it deciding control flow.
        $era = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtimes/era.ps1')
        $codeMatches = [regex]::Matches($era, '-(?:not)?match\s+''[^'']*PREVIOUS_ROUND[^'']*''')
        $codeMatches.Count | Should -Be 0 -Because 'workflow.ps1 owns the rule; era.ps1 consumes its verdict'
    }
}
