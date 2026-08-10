# Tests for workflow.ps1::Invoke-PromptTokenSubstitution — PR 3
# Tag: Unit
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/PromptTokens.Tests.ps1 -Tag Unit"

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'workflow.ps1')
}

Describe 'Invoke-PromptTokenSubstitution' -Tag Unit {
    BeforeEach {
        # Create a temp review dir for each test
        $script:TmpDir = Join-Path $env:TEMP "era-prompt-test-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:TmpDir -ErrorAction SilentlyContinue
    }

    It 'prompt WITHOUT {{PREVIOUS_ROUND}} is unchanged' {
        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        $originalText = "# Review`n`nPlease review the attached bundle."
        Set-Content $promptFile -Value $originalText -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content $promptFile -Raw
        $result.Trim() | Should -Be $originalText.Trim()
    }

    It 'round-2 prompt WITH token: substitutes round-1-response.md contents' {
        # Write round-1-response.md
        $responsePath = Join-Path $script:TmpDir 'round-1-response.md'
        Set-Content $responsePath -Value "## Critical issues`n1. Nothing critical." -Encoding UTF8

        # Write round-2 prompt with token
        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        Set-Content $promptFile -Value "# Round 2`n`n{{PREVIOUS_ROUND}}`n`nConfirm fixes." -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content $promptFile -Raw
        $result | Should -Match "round 1"
        $result | Should -Match "Critical issues"
        $result | Should -Not -Match '\{\{PREVIOUS_ROUND\}\}'
    }

    It 'round-2 prompt WITH token, round-1 in flight (claim exists), gets [in flight] string' {
        # Write round-1-claim.json (in-flight marker)
        $claimPath = Join-Path $script:TmpDir 'round-1-claim.json'
        Set-Content $claimPath -Value '{"pid":9999,"started":"2026-05-28T00:00:00Z","reviewer":"gemini"}' -Encoding UTF8
        # No round-1-response.md

        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        Set-Content $promptFile -Value "See prior: {{PREVIOUS_ROUND}}" -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content $promptFile -Raw
        $result | Should -Match 'in flight'
        $result | Should -Not -Match '\{\{PREVIOUS_ROUND\}\}'
    }

    # --- in-flight guard must beat EVERY content branch, not just the glob ---
    # The guard used to gate only the per-preset $perPreset glob, so a round with
    # a live claim AND a canonical round-N-response.md fell through to the
    # canonical branch and was presented to round N+1 as a complete review.
    # Measured before the fix: the canonical body was inlined under
    # "## Previous round's review (round 1)" with no in-flight note.
    # The manifest is NOT a completion signal here — era.ps1 writes it
    # pre-dispatch — so a live claim is the only authority on in-flight-ness.
    It 'round-1 in flight AND a canonical response exists: canonical must NOT leak' {
        Set-Content (Join-Path $script:TmpDir 'round-1-claim.json') `
            -Value '{"pid":9999,"started":"2026-05-28T00:00:00Z","reviewer":"opus"}' -Encoding UTF8
        Set-Content (Join-Path $script:TmpDir 'round-1-response.md') `
            -Value 'CANONICAL-PARTIAL-CONTENT' -Encoding UTF8

        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        Set-Content $promptFile -Value "See prior: {{PREVIOUS_ROUND}}" -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content $promptFile -Raw
        $result | Should -Match 'in flight'
        $result | Should -Not -Match 'CANONICAL-PARTIAL-CONTENT'
        $result | Should -Not -Match "Previous round's review"
        $result | Should -Not -Match '\{\{PREVIOUS_ROUND\}\}'
    }

    It 'round-1 in flight AND per-preset + canonical responses exist: nothing leaks' {
        Set-Content (Join-Path $script:TmpDir 'round-1-claim.json') `
            -Value '{"pid":9999,"started":"2026-05-28T00:00:00Z","reviewer":"opus"}' -Encoding UTF8
        Set-Content (Join-Path $script:TmpDir 'round-1-gemini-response.md') `
            -Value 'GEMINI-EARLY-FINISHER' -Encoding UTF8
        Set-Content (Join-Path $script:TmpDir 'round-1-response.md') `
            -Value 'CANONICAL-PARTIAL-CONTENT' -Encoding UTF8

        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        Set-Content $promptFile -Value "See prior: {{PREVIOUS_ROUND}}" -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content $promptFile -Raw
        $result | Should -Match 'in flight'
        $result | Should -Not -Match 'GEMINI-EARLY-FINISHER'
        $result | Should -Not -Match 'CANONICAL-PARTIAL-CONTENT'
        $result | Should -Not -Match '\{\{PREVIOUS_ROUND\}\}'
    }

    It 'round-2 prompt WITH token, round-1 missing entirely, gets [not found] string' {
        # Neither response nor claim file exists
        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        Set-Content $promptFile -Value "Prior: {{PREVIOUS_ROUND}}" -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content $promptFile -Raw
        $result | Should -Match 'not found'
        $result | Should -Not -Match '\{\{PREVIOUS_ROUND\}\}'
    }

    # --- a backticked token is a MENTION, not a substitution site ------------
    # Measured on the real round-2 artifact (.external-reviews/era-grade):
    #   round-2-prompt.md            85,457 bytes
    #   round-1 per-preset responses 40,400 bytes
    #   source METAREVIEW-PROMPT-R2    4,657 bytes as finalised
    #   => 2 x 40,400 + 4,657 = 85,457 exactly
    # The source prompt named the token twice, both times inside inline code
    # spans (`{{PREVIOUS_ROUND}}`) because it was *discussing the feature*.
    # Both were expanded, so the whole panel was inlined twice and both
    # sentences were destroyed mid-clause. One of them read
    # "**Attack `{{PREVIOUS_ROUND}}` aggregation.**" — the request to review
    # this very code path was the thing the code path ate.
    It 'leaves a backtick-wrapped token literal' {
        Set-Content (Join-Path $script:TmpDir 'round-1-response.md') `
            -Value 'PRIOR-BODY' -Encoding UTF8
        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        Set-Content $promptFile -Value 'Attack `{{PREVIOUS_ROUND}}` aggregation.' -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content $promptFile -Raw
        $result | Should -Match '`\{\{PREVIOUS_ROUND\}\}`'
        $result | Should -Not -Match 'PRIOR-BODY'
    }

    It 'substitutes a bare token while leaving a backticked one alone' {
        Set-Content (Join-Path $script:TmpDir 'round-1-response.md') `
            -Value 'PRIOR-BODY' -Encoding UTF8
        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        Set-Content $promptFile `
            -Value "Prior work:`n`n{{PREVIOUS_ROUND}}`n`nNow attack ``{{PREVIOUS_ROUND}}`` aggregation." `
            -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content $promptFile -Raw
        # The bare one expanded exactly once...
        @([regex]::Matches($result, 'PRIOR-BODY')).Count | Should -Be 1
        # ...and the mention survived intact.
        $result | Should -Match '`\{\{PREVIOUS_ROUND\}\}`'
    }

    It 'caps an oversized previous round and says so' {
        $big = 'X' * 200000
        Set-Content (Join-Path $script:TmpDir 'round-1-opus-response.md') -Value $big -Encoding UTF8
        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        Set-Content $promptFile -Value 'Prior: {{PREVIOUS_ROUND}}' -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content $promptFile -Raw
        $result.Length | Should -BeLessThan 200000
        $result | Should -Match 'truncated'
    }

    It 'does not truncate a normally-sized panel round' {
        # Real measured sizes: gemini 10,658 / opus 19,869 / deepseek 9,873.
        foreach ($r in @(@{n='gemini';b=10658}, @{n='opus';b=19869}, @{n='deepseek-flash';b=9873})) {
            Set-Content (Join-Path $script:TmpDir "round-1-$($r.n)-response.md") `
                -Value ('Y' * $r.b) -Encoding UTF8
        }
        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        Set-Content $promptFile -Value 'Prior: {{PREVIOUS_ROUND}}' -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content $promptFile -Raw
        $result | Should -Not -Match 'truncated'
        $result | Should -Match ('Y' * 100)
    }

    It 'substitution with content containing backslashes does not corrupt output' {
        $responsePath = Join-Path $script:TmpDir 'round-1-response.md'
        Set-Content $responsePath -Value 'Path: C:\Users\test\file.ps1' -Encoding UTF8

        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        Set-Content $promptFile -Value "Context: {{PREVIOUS_ROUND}}" -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content $promptFile -Raw
        # Backslashes must survive intact (no regex backreference corruption).
        # -Match pattern uses regex: '\\' matches one literal backslash.
        # So 'C:\\Users' matches the literal string C:\Users in $result.
        $result | Should -Match 'C:\\Users\\test\\file'
        # Also assert the path was NOT doubled (no C:\\\\Users)
        $result | Should -Not -Match 'C:\\\\Users'
    }
}
