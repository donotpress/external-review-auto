# Tests for `era.ps1 -Command exposure`: the exposure receipt listing.
#
# 2026-09-08, eighth item (feature, not defect): round-N-manifest.json already
# records exactly what source left the machine and to whom (files+sha256,
# sources, reviewers_requested, git_head/branch/clean, timestamp), but the
# only way to read it is to know the path. Exposure surfaces it read-only:
# no dispatch, no round allocation, no manifest writes -- safe beside a
# round in flight.
#
# pin: run with  pwsh -Command "Invoke-Pester -Path tests/Exposure.Tests.ps1"

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'workflow.ps1')

    function script:New-ExposureTree {
        <# Synthetic .external-reviews tree: two topics, mixed shapes. #>
        $root = Join-Path $env:TEMP "era-exposure-$(New-Guid)"
        $alpha = Join-Path $root '.external-reviews\alpha'
        $beta  = Join-Path $root '.external-reviews\beta'
        New-Item -ItemType Directory -Path $alpha -Force | Out-Null
        New-Item -ItemType Directory -Path $beta -Force | Out-Null
        # Full receipt + metadata sibling: destinations resolve to backend/model.
        Set-Content -LiteralPath (Join-Path $alpha 'round-1-manifest.json') -Encoding UTF8 -Value (@{
            files = @(@{ sha256 = 'aa'; path = 'bundle.xml' }, @{ sha256 = 'bb'; path = 'prompt.md' })
            reviewers_requested = @('gemini', 'opus')
            round = 1; sources = @('a.md', 'b.md')
            git_branch = 'master'; git_head = '34a9fa44e5066456b5fb7f48f83f35455ea1a2ed'
            previous_round = $null; git_dirty = @(); topic_slug = 'alpha'
            timestamp = '2026-09-08T05:12:16Z'; git_clean = $true
            source_hashes = @{ 'a.md' = 'h1'; 'b.md' = 'h2' }
        } | ConvertTo-Json -Depth 10)
        Set-Content -LiteralPath (Join-Path $alpha 'round-1-metadata.json') -Encoding UTF8 -Value (@{
            reviewers = @(
                @{ preset = 'gemini'; backend = 'agy'; model = 'gemini-3.8-flash-high'; wall_clock_sec = 119.7 }
                @{ preset = 'opus'; backend = 'claude'; model = 'claude-opus-5'; wall_clock_sec = 426.2 }
            )
        } | ConvertTo-Json -Depth 10)
        # Bare manifest, no metadata sibling: destinations stay preset-named.
        Set-Content -LiteralPath (Join-Path $alpha 'round-2-manifest.json') -Encoding UTF8 -Value (@{
            files = @(@{ sha256 = 'cc'; path = 'bundle.xml' })
            reviewers_requested = @('muse-spark')
            round = 2; sources = @('a.md')
            git_branch = 'wip'; git_head = 'def456'
            previous_round = 1; git_dirty = @(' M a.md'); topic_slug = 'alpha'
            timestamp = '2026-09-09T01:00:00Z'; git_clean = $false
            source_hashes = @{ 'a.md' = 'h3' }
        } | ConvertTo-Json -Depth 10)
        # Second topic, plus a corrupt receipt that must not kill the listing.
        Set-Content -LiteralPath (Join-Path $beta 'round-1-manifest.json') -Encoding UTF8 -Value (@{
            files = @(); reviewers_requested = @('haiku')
            round = 1; sources = @()
            git_branch = 'master'; git_head = 'abc123'
            previous_round = $null; git_dirty = @(); topic_slug = 'beta'
            timestamp = '2026-09-07T00:00:00Z'; git_clean = $true
            source_hashes = @{}
        } | ConvertTo-Json -Depth 10)
        Set-Content -LiteralPath (Join-Path $beta 'round-9-manifest.json') -Encoding UTF8 -Value 'not json {{{'
        return $root
    }
}

Describe 'Get-EraExposureReport' {
    It 'lists every well-formed receipt across topics' {
        $root = New-ExposureTree
        try {
            @((Get-EraExposureReport -RepoRoot $root)).Count | Should -Be 3
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'resolves destinations to backend/model from the metadata sibling' {
        $root = New-ExposureTree
        try {
            $row = Get-EraExposureReport -RepoRoot $root | Where-Object { $_.TopicSlug -eq 'alpha' -and $_.Round -eq 1 }
            $row.Destinations -join '; ' | Should -Match 'gemini.*agy.*gemini-3\.8-flash-high'
            $row.Destinations -join '; ' | Should -Match 'opus.*claude.*claude-opus-5'
            $row.SourcesCount | Should -Be 2
            $row.GitClean     | Should -BeTrue
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'falls back to preset names when no metadata sibling exists' {
        $root = New-ExposureTree
        try {
            $row = Get-EraExposureReport -RepoRoot $root | Where-Object { $_.TopicSlug -eq 'alpha' -and $_.Round -eq 2 }
            @($row.Destinations).Count | Should -Be 1
            $row.Destinations[0] | Should -Match 'muse-spark'
            $row.GitClean | Should -BeFalse
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'skips a corrupt receipt without killing the listing' {
        $root = New-ExposureTree
        try {
            { Get-EraExposureReport -RepoRoot $root } | Should -Not -Throw
            @((Get-EraExposureReport -RepoRoot $root)).Count | Should -Be 3
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'filters by topic slug when asked' {
        $root = New-ExposureTree
        try {
            $rows = @(Get-EraExposureReport -RepoRoot $root -TopicSlug 'beta')
            $rows.Count | Should -Be 1
            $rows[0].TopicSlug | Should -Be 'beta'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns nothing, without throwing, when no receipts exist' {
        $root = Join-Path $env:TEMP "era-exposure-empty-$(New-Guid)"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            Get-EraExposureReport -RepoRoot $root | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Format-EraExposureReport' {
    It 'renders what was sent, to whom, and when, grep-ably' {
        $root = New-ExposureTree
        try {
            $out = Format-EraExposureReport -Rows (Get-EraExposureReport -RepoRoot $root)
            $out | Should -Match 'alpha'
            $out | Should -Match 'round 1'
            $out | Should -Match 'gemini-3\.8-flash-high'
            $out | Should -Match '2026-09-08'
            $out | Should -Match '34a9fa44e506'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'says plainly when there is nothing to show' {
        Format-EraExposureReport -Rows @() | Should -Match 'No exposure receipts'
    }
}
