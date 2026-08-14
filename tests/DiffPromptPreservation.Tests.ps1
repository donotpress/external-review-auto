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

    It 'era.ps1 records whether the prompt carried the token BEFORE substituting it' {
        $era = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtimes/era.ps1')
        $era | Should -Match 'Get-EraDiffPreviousReviewBlock'
        # The flag must be captured before Invoke-PromptTokenSubstitution consumes the token.
        $flag  = $era.IndexOf('PromptHadPreviousRoundToken')
        $subst = $era.IndexOf('Invoke-PromptTokenSubstitution -PromptFile')
        $flag  | Should -BeGreaterThan 0
        $flag  | Should -BeLessThan $subst -Because 'after substitution the token is gone and cannot be detected'
    }
}
