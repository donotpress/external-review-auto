# Tests for canonical-response promotion and diff/manifest hygiene.
#
# All three reviewers of the 2026-08-09 graded panel independently named the same
# #1 blocker: Copy-PrimaryResponseAlias returns early when there is one reviewer,
# so a contract-FAILED single-reviewer response stays as round-N-response.md and
# feeds round N+1 via {{PREVIOUS_ROUND}}. That is the exact poisoning the
# response contract exists to prevent, on the configuration the docs tell people
# to drop to ("Drop to one with an explicit -Reviewer").
#
# opus additionally noted the alias hardcodes a preference for gemini, so on a
# 3-model panel the canonical answer is always the cheapest model. Measured on
# that same run: round-1-response.md was byte-identical to gemini's 10,658-byte
# answer while opus produced 19,869 bytes, and only gemini's reached round N+1.
#
# deepseek-flash noted the diff/manifest glob expansion has no artifact filter,
# so on the broad path era hashes its OWN review artifacts into the baseline and
# every subsequent round sees them as changed.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/AliasAndDiffHygiene.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"

    function New-RoundDir {
        param([string]$Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $Root
    }
}

Describe 'Single-reviewer contract failure must not stay canonical' -Tag Unit {
    It 'removes round-N-response.md when the only reviewer failed the contract' {
        $dir = New-RoundDir (Join-Path $env:TEMP "era-alias-solo-$(New-Guid)")
        try {
            Set-Content -Path (Join-Path $dir 'round-1-response.md') -Value 'OFF-CONTRACT ANSWER'
            $results = @{ gemini = @{ Preset = 'gemini'; ExitCode = -1; ContentOk = $false
                                      Error = 'response-contract'; Response = 'OFF-CONTRACT ANSWER' } }
            Copy-PrimaryResponseAlias -ReviewDir $dir -Round 1 -ReviewerList @('gemini') -Results $results
            Test-Path (Join-Path $dir 'round-1-response.md') | Should -BeFalse
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'keeps the failed answer as evidence under its preset name' {
        $dir = New-RoundDir (Join-Path $env:TEMP "era-alias-eviden-$(New-Guid)")
        try {
            Set-Content -Path (Join-Path $dir 'round-1-response.md') -Value 'OFF-CONTRACT ANSWER'
            $results = @{ gemini = @{ Preset = 'gemini'; ExitCode = -1; ContentOk = $false
                                      Error = 'response-contract'; Response = 'OFF-CONTRACT ANSWER' } }
            Copy-PrimaryResponseAlias -ReviewDir $dir -Round 1 -ReviewerList @('gemini') -Results $results
            $kept = Join-Path $dir 'round-1-gemini-response.md'
            Test-Path $kept | Should -BeTrue
            (Get-Content -Raw $kept) | Should -Match 'OFF-CONTRACT ANSWER'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'leaves a SUCCESSFUL single-reviewer response exactly where it is' {
        $dir = New-RoundDir (Join-Path $env:TEMP "era-alias-ok-$(New-Guid)")
        try {
            Set-Content -Path (Join-Path $dir 'round-1-response.md') -Value 'GOOD ANSWER'
            $results = @{ gemini = @{ Preset = 'gemini'; ExitCode = 0; Response = 'GOOD ANSWER' } }
            Copy-PrimaryResponseAlias -ReviewDir $dir -Round 1 -ReviewerList @('gemini') -Results $results
            Test-Path (Join-Path $dir 'round-1-response.md') | Should -BeTrue
            (Get-Content -Raw (Join-Path $dir 'round-1-response.md')) | Should -Match 'GOOD ANSWER'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'does not promote a contract-failed reviewer on a multi-reviewer panel either' {
        $dir = New-RoundDir (Join-Path $env:TEMP "era-alias-panel-$(New-Guid)")
        try {
            Set-Content -Path (Join-Path $dir 'round-1-gemini-response.md') -Value 'BAD'
            Set-Content -Path (Join-Path $dir 'round-1-opus-response.md')   -Value 'GOOD'
            $results = @{
                gemini = @{ Preset = 'gemini'; ExitCode = -1; ContentOk = $false; Error = 'response-contract' }
                opus   = @{ Preset = 'opus';   ExitCode = 0 }
            }
            Copy-PrimaryResponseAlias -ReviewDir $dir -Round 1 -ReviewerList @('gemini', 'opus') -Results $results
            (Get-Content -Raw (Join-Path $dir 'round-1-response.md')) | Should -Match 'GOOD'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }
}

Describe 'Canonical promotion follows the caller order, not a vendor name' -Tag Unit {
    It 'promotes the first successful reviewer in the requested order' {
        # The alias used to hardcode gemini first, so on the shipped panel the
        # canonical answer was always the cheapest model regardless of substance.
        $dir = New-RoundDir (Join-Path $env:TEMP "era-alias-order-$(New-Guid)")
        try {
            Set-Content -Path (Join-Path $dir 'round-1-opus-response.md')   -Value 'OPUS-ANSWER'
            Set-Content -Path (Join-Path $dir 'round-1-gemini-response.md') -Value 'GEMINI-ANSWER'
            $results = @{
                opus   = @{ Preset = 'opus';   ExitCode = 0 }
                gemini = @{ Preset = 'gemini'; ExitCode = 0 }
            }
            Copy-PrimaryResponseAlias -ReviewDir $dir -Round 1 -ReviewerList @('opus', 'gemini') -Results $results
            (Get-Content -Raw (Join-Path $dir 'round-1-response.md')) | Should -Match 'OPUS-ANSWER'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'no longer hardcodes a gemini preference' {
        $wf = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'workflow.ps1')
        $wf | Should -Not -Match "ReviewerList -contains 'gemini'"
    }
}

Describe '{{PREVIOUS_ROUND}} carries the whole panel, not one model' -Tag Unit {
    It 'includes every successful reviewer response from the prior round' {
        # Otherwise the panel's value is discarded between rounds: only the
        # promoted model's answer survives into round N+1.
        $dir = New-RoundDir (Join-Path $env:TEMP "era-prev-panel-$(New-Guid)")
        try {
            Set-Content -Path (Join-Path $dir 'round-1-gemini-response.md') -Value 'GEMINI-SAID-THIS'
            Set-Content -Path (Join-Path $dir 'round-1-opus-response.md')   -Value 'OPUS-SAID-THIS'
            Set-Content -Path (Join-Path $dir 'round-1-response.md')        -Value 'GEMINI-SAID-THIS'
            $prompt = Join-Path $dir 'p.md'
            Set-Content -Path $prompt -Value "Before`n{{PREVIOUS_ROUND}}`nAfter"

            Invoke-PromptTokenSubstitution -PromptFile $prompt -ReviewDir $dir -RoundN 2

            $text = Get-Content -Raw $prompt
            $text | Should -Match 'GEMINI-SAID-THIS'
            $text | Should -Match 'OPUS-SAID-THIS'
            $text | Should -Not -Match '\{\{PREVIOUS_ROUND\}\}'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'still works for a single-reviewer prior round' {
        $dir = New-RoundDir (Join-Path $env:TEMP "era-prev-solo-$(New-Guid)")
        try {
            Set-Content -Path (Join-Path $dir 'round-1-response.md') -Value 'SOLO-ANSWER'
            $prompt = Join-Path $dir 'p.md'
            Set-Content -Path $prompt -Value "{{PREVIOUS_ROUND}}"
            Invoke-PromptTokenSubstitution -PromptFile $prompt -ReviewDir $dir -RoundN 2
            (Get-Content -Raw $prompt) | Should -Match 'SOLO-ANSWER'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }
}

Describe 'Diff and manifest ignore era''s own artifacts' -Tag Unit {
    It 'does not hash .external-reviews files into the manifest' {
        # On the broad path $effectiveInclude is globs, and the expansion
        # recursed with no artifact filter -- so era hashed its own review
        # history into the baseline and every later round saw it as changed.
        $repo = New-RoundDir (Join-Path $env:TEMP "era-diffhyg-$(New-Guid)")
        try {
            New-Item -ItemType Directory -Path (Join-Path $repo 'src') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $repo '.external-reviews/t') -Force | Out-Null
            # A root-level match is required for the guard to engage at all:
            # measured, Test-Path '<repo>\*.md' is FALSE when no .md sits
            # directly at the root, and the whole hashing block is skipped. With
            # one present, Get-ChildItem -Recurse then sweeps the entire tree --
            # including .external-reviews. That is the contamination.
            Set-Content -Path (Join-Path $repo 'top.md') -Value 'root source'
            Set-Content -Path (Join-Path $repo 'src/a.md') -Value 'source'
            Set-Content -Path (Join-Path $repo '.external-reviews/t/round-1-response.md') -Value 'prior review'
            $reviewDir = Join-Path $repo '.external-reviews/t'

            $bundle = Join-Path $reviewDir 'round-1-bundle.xml'
            Set-Content -Path $bundle -Value '<files/>'
            # '*.md' rather than '**/*.md': measured, Get-ChildItem -Recurse
            # expands '*.md' to every .md in the tree (including the artifact),
            # while '**/*.md' matches only one level and never reaches it. The
            # first is the glob that actually reproduces the contamination.
            Write-ReviewManifest -ReviewDir $reviewDir -Round 1 -TopicSlug 't' `
                -Files @($bundle) -SourceFiles @('*.md') -RepoRoot $repo

            $manifest = Get-Content -Raw (Join-Path $reviewDir 'round-1-manifest.json') | ConvertFrom-Json
            $keys = @($manifest.source_hashes.PSObject.Properties.Name)
            $keys | Should -Contain 'top.md'
            $keys | Should -Contain 'src/a.md'
            @($keys | Where-Object { $_ -like '*external-reviews*' }) | Should -BeNullOrEmpty
        } finally { Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue }
    }
}

Describe 'Repomix shim routing is extension-driven' -Tag Unit {
    It 'never routes a POSIX shim through pwsh -File' {
        # deepseek-flash claimed POSIX shims were sent to `pwsh -File`. Measured:
        # they are not, because CommandType is Application there. But the guard
        # ORed on CommandType without checking the extension, so an
        # ExternalScript without .ps1 would have misrouted. Close it.
        $r = Resolve-EraRepomixCommand -Source '/usr/local/bin/repomix' -CommandType 'ExternalScript'
        $r.FilePath | Should -Be '/usr/local/bin/repomix'
        @($r.Arguments).Count | Should -Be 0
    }
}
