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
