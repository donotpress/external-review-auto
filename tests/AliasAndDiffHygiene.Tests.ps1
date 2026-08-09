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

    It 'keeps the failed answer as evidence, under a name the next round will not read' {
        # NOT round-1-gemini-response.md: that shape is exactly what
        # Invoke-PromptTokenSubstitution globs to build round N+1, so demoting
        # into it fed the rejected answer straight back in.
        $dir = New-RoundDir (Join-Path $env:TEMP "era-alias-eviden-$(New-Guid)")
        try {
            Set-Content -Path (Join-Path $dir 'round-1-response.md') -Value 'OFF-CONTRACT ANSWER'
            $results = @{ gemini = @{ Preset = 'gemini'; ExitCode = -1; ContentOk = $false
                                      Error = 'response-contract'; Response = 'OFF-CONTRACT ANSWER' } }
            Copy-PrimaryResponseAlias -ReviewDir $dir -Round 1 -ReviewerList @('gemini') -Results $results
            $kept = Join-Path $dir 'round-1-gemini-response.rejected.md'
            Test-Path $kept | Should -BeTrue
            (Get-Content -Raw $kept) | Should -Match 'OFF-CONTRACT ANSWER'
            Test-Path (Join-Path $dir 'round-1-gemini-response.md') | Should -BeFalse
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

Describe 'A demoted failure must not re-enter via {{PREVIOUS_ROUND}}' -Tag Unit {
    It 'does not inject a contract-failed response into the next round' {
        # The round-2 panel caught this: demoting a failed solo response to
        # round-N-<preset>-response.md put it into exactly the shape the new
        # panel aggregation globs (round-N-*-response.md). The B1 fix relocated
        # the poison instead of removing it, and the B3 fix opened the door it
        # moved to. Demotions must not match the aggregation glob.
        $dir = New-RoundDir (Join-Path $env:TEMP "era-prev-rejected-$(New-Guid)")
        try {
            Set-Content -Path (Join-Path $dir 'round-1-response.md') -Value 'POISON-OFF-CONTRACT'
            $results = @{ gemini = @{ Preset = 'gemini'; ExitCode = -1; ContentOk = $false
                                      Error = 'response-contract' } }
            Copy-PrimaryResponseAlias -ReviewDir $dir -Round 1 -ReviewerList @('gemini') -Results $results

            $prompt = Join-Path $dir 'p.md'
            Set-Content -Path $prompt -Value '{{PREVIOUS_ROUND}}'
            Invoke-PromptTokenSubstitution -PromptFile $prompt -ReviewDir $dir -RoundN 2

            (Get-Content -Raw $prompt) | Should -Not -Match 'POISON-OFF-CONTRACT'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'still keeps the rejected answer on disk as evidence' {
        $dir = New-RoundDir (Join-Path $env:TEMP "era-prev-evid2-$(New-Guid)")
        try {
            Set-Content -Path (Join-Path $dir 'round-1-response.md') -Value 'REJECTED-BODY'
            $results = @{ gemini = @{ Preset = 'gemini'; ExitCode = -1; ContentOk = $false
                                      Error = 'response-contract' } }
            Copy-PrimaryResponseAlias -ReviewDir $dir -Round 1 -ReviewerList @('gemini') -Results $results
            $found = @(Get-ChildItem -Path $dir -Filter 'round-1-*rejected*' -File)
            $found.Count | Should -BeGreaterThan 0
            (Get-Content -Raw $found[0].FullName) | Should -Match 'REJECTED-BODY'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'reports an in-flight prior round rather than a partial panel' {
        # The per-preset branch preceded the claim-file branch, so a round still
        # in flight yielded whatever reviewers had finished, presented as if it
        # were the complete panel.
        $dir = New-RoundDir (Join-Path $env:TEMP "era-prev-inflight-$(New-Guid)")
        try {
            Set-Content -Path (Join-Path $dir 'round-1-gemini-response.md') -Value 'EARLY-FINISHER'
            Set-Content -Path (Join-Path $dir 'round-1-claim.json') -Value '{}'
            $prompt = Join-Path $dir 'p.md'
            Set-Content -Path $prompt -Value '{{PREVIOUS_ROUND}}'
            Invoke-PromptTokenSubstitution -PromptFile $prompt -ReviewDir $dir -RoundN 2
            $text = Get-Content -Raw $prompt
            $text | Should -Match 'in flight'
            $text | Should -Not -Match 'EARLY-FINISHER'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'never removes the canonical when it is the only copy' {
        # On a multi-reviewer round where nobody passed, removing the canonical
        # is only safe if a per-preset copy exists to serve as evidence.
        $dir = New-RoundDir (Join-Path $env:TEMP "era-prev-onlycopy-$(New-Guid)")
        try {
            Set-Content -Path (Join-Path $dir 'round-1-response.md') -Value 'ONLY-COPY'
            $results = @{
                a = @{ Preset = 'a'; ExitCode = -1; Error = 'timeout' }
                b = @{ Preset = 'b'; ExitCode = -1; Error = 'timeout' }
            }
            Copy-PrimaryResponseAlias -ReviewDir $dir -Round 1 -ReviewerList @('a', 'b') -Results $results
            # No per-preset file exists, so the canonical is the only artifact.
            # It must be preserved (renamed as evidence), not destroyed.
            @(Get-ChildItem -Path $dir -Filter 'round-1-*' -File).Count | Should -BeGreaterThan 0
            (Get-ChildItem -Path $dir -Filter 'round-1-*' -File | ForEach-Object { Get-Content -Raw $_.FullName }) -join '' |
                Should -Match 'ONLY-COPY'
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
