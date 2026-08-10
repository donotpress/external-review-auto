# Tests for `**/`-globstar expansion in Expand-EraIncludePath.
# Tag: Unit
#
# WHY THIS FILE EXISTS
# --------------------
# era's broad-audit path builds its include list from ~40 globs of the shape
# '**/*.md', '**/*.ps1', '**/*.ts' (era.ps1:991). repomix reads those with
# minimatch semantics: `**/` matches every depth INCLUDING the repo root.
# PowerShell has no globstar -- `**` is just two `*` -- so the same string
# means something completely different to Get-ChildItem.
#
# Measured on a root.md / sub/mid.md / sub/deep/deep.md tree, pre-fix:
#
#   Get-ChildItem -Path <root>\**\*.md -File -Recurse   -> root.md          (1)
#   Get-ChildItem -Path <root>\**\*.md -File            -> mid.md           (1)
#   Get-ChildItem -LiteralPath <root> -Filter *.md -Rec -> all three        (3)
#
# So on the broad path repomix BUNDLED every .md at every depth while era's
# manifest hashed one file. Everything nested was sent to reviewers and never
# entered source_hashes, which means it could never register as changed and
# every later round's delta was blind to it. That is the manifest-baseline
# half of panel item #2.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/GlobstarExpansion.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
}

Describe 'Expand-EraIncludePath honours `**/` at every depth' -Tag Unit {
    BeforeEach {
        $script:Root = Join-Path $env:TEMP "era-glob-$(New-Guid)"
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'sub\deep') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'root.md')          -Value 'r' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:Root 'sub\mid.md')       -Value 'm' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:Root 'sub\deep\deep.md') -Value 'd' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:Root 'sub\other.txt')    -Value 'o' -Encoding UTF8
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "'**/*.md' matches root, mid and deep — the minimatch meaning" {
        $names = @(Expand-EraIncludePath -Entry '**/*.md' -RepoRoot $script:Root |
                    ForEach-Object { Split-Path $_ -Leaf } | Sort-Object)
        $names | Should -Be @('deep.md', 'mid.md', 'root.md')
    }

    It "'**/*.md' does not drag in other extensions" {
        $got = @(Expand-EraIncludePath -Entry '**/*.md' -RepoRoot $script:Root)
        ($got | Where-Object { $_ -like '*other.txt' }) | Should -BeNullOrEmpty
    }

    It "a prefixed globstar 'sub/**/*.md' is rooted at that subtree" {
        $names = @(Expand-EraIncludePath -Entry 'sub/**/*.md' -RepoRoot $script:Root |
                    ForEach-Object { Split-Path $_ -Leaf } | Sort-Object)
        $names | Should -Be @('deep.md', 'mid.md')
    }

    It 'a plain glob without globstar still works' {
        $names = @(Expand-EraIncludePath -Entry 'sub/*.md' -RepoRoot $script:Root |
                    ForEach-Object { Split-Path $_ -Leaf })
        $names | Should -Contain 'mid.md'
    }

    It 'a literal path is still returned literally' {
        $got = @(Expand-EraIncludePath -Entry 'root.md' -RepoRoot $script:Root)
        @($got).Count | Should -Be 1
        (Split-Path $got[0] -Leaf) | Should -Be 'root.md'
    }
}

Describe 'The broad-path manifest baseline covers nested files' -Tag Unit {
    BeforeEach {
        $script:Root = Join-Path $env:TEMP "era-globman-$(New-Guid)"
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'sub\deep') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'root.md')          -Value 'r' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:Root 'sub\deep\deep.md') -Value 'v1' -Encoding UTF8
        $script:ReviewDir = Join-Path $script:Root '.external-reviews\t'
        New-Item -ItemType Directory -Path $script:ReviewDir -Force | Out-Null
        $script:Bundle = Join-Path $script:ReviewDir 'b.xml'
        Set-Content -LiteralPath $script:Bundle -Value 'x' -Encoding UTF8
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'source_hashes includes a nested file the broad globs bundle' {
        $mp = Write-ReviewManifest -ReviewDir $script:ReviewDir -Round 1 -TopicSlug 't' `
            -Files @($script:Bundle) -SourceFiles @('**/*.md') -RepoRoot $script:Root
        $keys = @((Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json).source_hashes.PSObject.Properties.Name)
        $keys | Should -Contain 'sub/deep/deep.md'
        $keys | Should -Contain 'root.md'
    }

    It 'a nested edit registers as Changed round-over-round' {
        Write-ReviewManifest -ReviewDir $script:ReviewDir -Round 1 -TopicSlug 't' `
            -Files @($script:Bundle) -SourceFiles @('**/*.md') -RepoRoot $script:Root | Out-Null

        Set-Content -LiteralPath (Join-Path $script:Root 'sub\deep\deep.md') -Value 'v2-CHANGED' -Encoding UTF8

        $diff = Get-ReviewDiff -ReviewDir $script:ReviewDir -PriorRound 1 `
            -CurrentFiles @('**/*.md') -RepoRoot $script:Root

        # Pre-fix this file was in neither the baseline nor the current set, so
        # an edit to it was invisible: the delta reported nothing changed.
        $diff.Changed | Should -Contain 'sub/deep/deep.md'
    }

    It 'an untouched file reports Unchanged, not Added' {
        # The sharper lock on the second defect. Get-ReviewDiff indexed
        # source_hashes by the GLOB strings in `sources` rather than by the
        # concrete path keys it actually contains, so the prior baseline came
        # back empty and EVERY file classified as Added on every round --
        # including files nobody had touched. A test that only checks Changed
        # would still pass with an empty baseline if the file were listed as
        # Added instead, so assert the negative too.
        Write-ReviewManifest -ReviewDir $script:ReviewDir -Round 1 -TopicSlug 't' `
            -Files @($script:Bundle) -SourceFiles @('**/*.md') -RepoRoot $script:Root | Out-Null

        Set-Content -LiteralPath (Join-Path $script:Root 'sub\deep\deep.md') -Value 'v2-CHANGED' -Encoding UTF8

        $diff = Get-ReviewDiff -ReviewDir $script:ReviewDir -PriorRound 1 `
            -CurrentFiles @('**/*.md') -RepoRoot $script:Root

        $diff.Unchanged | Should -Contain 'root.md'
        $diff.Added     | Should -Not -Contain 'root.md'
    }
}
