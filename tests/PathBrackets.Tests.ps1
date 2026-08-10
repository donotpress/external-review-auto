# Tests for workflow.ps1 under paths containing PowerShell wildcard metacharacters.
# Tag: Unit
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/PathBrackets.Tests.ps1 -Tag Unit"
#
# WHY THIS FILE EXISTS
# --------------------
# `[` and `]` are wildcard metacharacters to every PowerShell provider cmdlet
# that binds -Path. A path like `C:\proj[old]\...` or `src/app/[id]/page.tsx`
# (Next.js dynamic routing is the common real-world source) is read as a
# character-class pattern, matches nothing, and the cmdlet reports "not found"
# for a file that plainly exists. -LiteralPath is the documented opt-out.
#
# Measured on the pre-fix tree, with the topic dir under `proj[old]\`:
#   Get-NextReviewRound          -> 1   (expected 2; blind to round-1-manifest.json)
#   Reserve-ReviewRound          -> 1   (expected 2; COLLIDES with the existing round 1)
#   Invoke-PromptTokenSubstitution -> no-op; {{PREVIOUS_ROUND}} shipped verbatim
#   Write-ReviewManifest         -> bracketed source declared in .sources but
#                                   absent from .source_hashes
# The round-numbering collision is the severe one: round N+1 reserves N and
# overwrites the prior round's artifacts.
#
# These tests pin the invariant "era is correct on paths the filesystem accepts",
# not the implementation detail of which parameter is used.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'workflow.ps1')
}

Describe 'workflow.ps1 on wildcard-metacharacter paths' -Tag Unit {
    BeforeEach {
        $script:Base = Join-Path $env:TEMP "era-brackets-$(New-Guid)"
        # 'proj[old]' is the hostile component; everything below it inherits it.
        $script:RepoRoot = Join-Path $script:Base 'proj[old]'
        $script:TmpDir   = Join-Path $script:RepoRoot '.external-reviews\topic'
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Get-NextReviewRound sees an existing manifest under a bracketed dir' {
        Set-Content -LiteralPath (Join-Path $script:TmpDir 'round-1-manifest.json') -Value '{}' -Encoding UTF8

        Get-NextReviewRound -ReviewDir $script:TmpDir | Should -Be 2
    }

    It 'Reserve-ReviewRound does not collide with an existing round under a bracketed dir' {
        Set-Content -LiteralPath (Join-Path $script:TmpDir 'round-1-manifest.json') -Value '{}' -Encoding UTF8

        $reserved = Reserve-ReviewRound -ReviewDir $script:TmpDir -Reviewer 'opus'

        # Reserving 1 here would overwrite round 1's artifacts.
        $reserved | Should -Be 2
        Test-Path -LiteralPath (Join-Path $script:TmpDir 'round-2-claim.json') | Should -BeTrue
    }

    It 'Reserve-ReviewRound respects a live claim under a bracketed dir' {
        Set-Content -LiteralPath (Join-Path $script:TmpDir 'round-1-claim.json') `
            -Value '{"pid":1,"reviewer":"opus"}' -Encoding UTF8

        Reserve-ReviewRound -ReviewDir $script:TmpDir -Reviewer 'gemini' | Should -Be 2
    }

    It 'Invoke-PromptTokenSubstitution substitutes under a bracketed dir' {
        Set-Content -LiteralPath (Join-Path $script:TmpDir 'round-1-response.md') `
            -Value 'PRIOR-REVIEW-BODY' -Encoding UTF8
        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        Set-Content -LiteralPath $promptFile -Value "Prior: {{PREVIOUS_ROUND}}" -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content -LiteralPath $promptFile -Raw
        $result | Should -Match 'PRIOR-REVIEW-BODY'
        $result | Should -Not -Match '\{\{PREVIOUS_ROUND\}\}'
    }

    It 'the in-flight guard still holds under a bracketed dir' {
        Set-Content -LiteralPath (Join-Path $script:TmpDir 'round-1-claim.json') `
            -Value '{"pid":1,"reviewer":"opus"}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:TmpDir 'round-1-response.md') `
            -Value 'CANONICAL-PARTIAL-CONTENT' -Encoding UTF8
        $promptFile = Join-Path $script:TmpDir 'round-2-prompt.md'
        Set-Content -LiteralPath $promptFile -Value "Prior: {{PREVIOUS_ROUND}}" -Encoding UTF8

        Invoke-PromptTokenSubstitution -PromptFile $promptFile -ReviewDir $script:TmpDir -RoundN 2

        $result = Get-Content -LiteralPath $promptFile -Raw
        $result | Should -Match 'in flight'
        $result | Should -Not -Match 'CANONICAL-PARTIAL-CONTENT'
    }

    It 'Write-ReviewManifest hashes a bracketed source file' {
        New-Item -ItemType Directory -Path (Join-Path $script:RepoRoot 'src\app\[id]') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:RepoRoot 'src\app\[id]\page.tsx') `
            -Value 'export default 1' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:RepoRoot 'src\app\normal.tsx') `
            -Value 'plain' -Encoding UTF8
        $bundle = Join-Path $script:TmpDir 'bundle.xml'
        Set-Content -LiteralPath $bundle -Value 'x' -Encoding UTF8

        $manifestPath = Write-ReviewManifest -ReviewDir $script:TmpDir -Round 1 -TopicSlug 'topic' `
            -Files @($bundle) `
            -SourceFiles @('src/app/[id]/page.tsx', 'src/app/normal.tsx') -RepoRoot $script:RepoRoot

        $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $keys = @($m.source_hashes.PSObject.Properties.Name)
        # A file silently absent from source_hashes can never register as changed,
        # so the round-over-round delta signal is permanently blind to it.
        $keys | Should -Contain 'src/app/[id]/page.tsx'
        $keys | Should -Contain 'src/app/normal.tsx'
    }

    It 'Write-ReviewManifest hashes the bundle file itself under a bracketed dir' {
        $bundle = Join-Path $script:TmpDir 'bundle.xml'
        Set-Content -LiteralPath $bundle -Value 'x' -Encoding UTF8

        $manifestPath = Write-ReviewManifest -ReviewDir $script:TmpDir -Round 1 -TopicSlug 'topic' -Files @($bundle)

        $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        @($m.files).Count | Should -Be 1
        $m.files[0].sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'Copy-PrimaryResponseAlias promotes and demotes under a bracketed dir' {
        Set-Content -LiteralPath (Join-Path $script:TmpDir 'round-1-gemini-response.md') `
            -Value 'GEMINI-BAD' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:TmpDir 'round-1-opus-response.md') `
            -Value 'OPUS-GOOD' -Encoding UTF8

        Copy-PrimaryResponseAlias -ReviewDir $script:TmpDir -Round 1 `
            -ReviewerList @('gemini', 'opus') `
            -Results @{
                gemini = @{ ExitCode = 1 }
                opus   = @{ ExitCode = 0 }
            }

        # The failed member is demoted out of the {{PREVIOUS_ROUND}} glob shape...
        Test-Path -LiteralPath (Join-Path $script:TmpDir 'round-1-gemini-response.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:TmpDir 'round-1-gemini-response.rejected.md') | Should -BeTrue
        # ...and the passing member becomes the canonical.
        (Get-Content -LiteralPath (Join-Path $script:TmpDir 'round-1-response.md') -Raw).Trim() |
            Should -Be 'OPUS-GOOD'
    }
}
