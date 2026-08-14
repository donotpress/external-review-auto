# The manifest baseline and the diff walk must ignore what repomix ignores.
#
# Round-5 (opus), BLOCKER 1, verified before fixing:
#
#   $repomixIgnorePatterns (era.ps1:1313 — **/node_modules/**, **/.git/**,
#   **/__pycache__/**, *.pyc, *.duckdb, + artifact patterns) is passed to
#   Measure-EraBroadScope and written into the repomix config, but NEVER to
#   Write-ReviewManifest or Get-ReviewDiff. Those two filter only
#   `.external-reviews`.
#
# On the broad path the default globs are '**/*.md', '**/*.json', '**/*.ts' …,
# and Expand-EraIncludePath genuinely recurses the whole tree. So:
#
#   round 1  the manifest hashes node_modules/**/*.md as "sources"
#   round 2  Get-ReviewDiff sees them as Added/Changed
#            $effectiveInclude = $diffResult.BundleFiles  (era.ps1)
#            repomix's ignore list beats its include list
#   result   a bundle scoped to whatever REAL files also changed — or, if only
#            ignored files changed, "Bundle is empty" blaming -IncludeFiles
#
# The manifest is also the round's provenance record, and it currently claims a
# superset of what was actually reviewed.
#
# The fix is one rule, one definition: Measure-EraBroadScope already carries a
# pattern matcher fitted to repomix 1.12.0's exact semantics (root-relative
# dirs, not bare names — a bare 'node_modules/**' does NOT match
# packages/p/node_modules/d/a.md). That matcher is extracted here and used by
# all three walks rather than reimplemented per caller.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/IgnoreParity.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'workflow.ps1')
    $script:Patterns = @('**/node_modules/**', '**/.git/**', '**/__pycache__/**', '*.pyc', 'validation_results/**')
}

Describe 'Get-EraIgnoreSets / Test-EraPathIgnored' -Tag Unit {
    BeforeAll { $script:Sets = Get-EraIgnoreSets -IgnorePatterns $script:Patterns }

    It 'ignores a nested node_modules at any depth' {
        Test-EraPathIgnored -RelPath 'node_modules/pkg/readme.md'            -Sets $script:Sets | Should -BeTrue
        Test-EraPathIgnored -RelPath 'packages/p/node_modules/d/a.md'        -Sets $script:Sets | Should -BeTrue
    }

    It 'ignores an extension pattern anywhere' {
        Test-EraPathIgnored -RelPath 'src/thing.pyc'      -Sets $script:Sets | Should -BeTrue
        Test-EraPathIgnored -RelPath 'deep/nest/x.pyc'    -Sets $script:Sets | Should -BeTrue
    }

    It 'ignores a rooted directory pattern only at the root' {
        Test-EraPathIgnored -RelPath 'validation_results/a.db'        -Sets $script:Sets | Should -BeTrue
        Test-EraPathIgnored -RelPath 'sub/validation_results/a.db'    -Sets $script:Sets | Should -BeFalse -Because 'a rooted pattern is anchored, matching repomix'
    }

    It 'keeps real source files' {
        foreach ($p in @('workflow.ps1','docs/design.md','src/app/main.ts','a/b/c/readme.md')) {
            Test-EraPathIgnored -RelPath $p -Sets $script:Sets | Should -BeFalse -Because "$p is a review subject"
        }
    }

    It 'is direction-agnostic about slashes' {
        Test-EraPathIgnored -RelPath 'packages\p\node_modules\d\a.md' -Sets $script:Sets | Should -BeTrue
    }

    It 'ignores nothing when given no patterns' {
        $empty = Get-EraIgnoreSets -IgnorePatterns @()
        Test-EraPathIgnored -RelPath 'node_modules/pkg/readme.md' -Sets $empty | Should -BeFalse
    }
}

Describe 'the manifest and the diff walk honour the same patterns' -Tag Unit {
    BeforeEach {
        $script:Repo = Join-Path ([System.IO.Path]::GetTempPath()) ("era-ip-" + [guid]::NewGuid())
        foreach ($d in @('', 'src', 'node_modules/pkg', 'docs')) {
            New-Item -ItemType Directory -Path (Join-Path $script:Repo $d) -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $script:Repo 'docs/real.md')             -Value 'real source'
        Set-Content -LiteralPath (Join-Path $script:Repo 'src/app.ts')               -Value 'real source'
        Set-Content -LiteralPath (Join-Path $script:Repo 'node_modules/pkg/dep.md')  -Value 'vendored'
        $script:Dir = Join-Path $script:Repo '.external-reviews/t'
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        # -Files must be real: Write-ReviewManifest hashes them. era passes the
        # bundle and the prompt here.
        $script:Bundle = Join-Path $script:Dir 'round-1-bundle.xml'
        Set-Content -LiteralPath $script:Bundle -Value '<files/>'
    }
    AfterEach { Remove-Item $script:Repo -Recurse -Force -ErrorAction SilentlyContinue }

    It 'Write-ReviewManifest does not hash ignored files as sources' {
        Write-ReviewManifest -ReviewDir $script:Dir -Round 1 -TopicSlug 't' `
            -Files @($script:Bundle) -SourceFiles @('**/*.md', '**/*.ts') -RepoRoot $script:Repo `
            -IgnorePatterns $script:Patterns
        $m = Get-Content -Raw (Join-Path $script:Dir 'round-1-manifest.json') | ConvertFrom-Json
        # NOTE: .sources is the raw GLOB list ('**/*.md'); the expanded paths --
        # the actual baseline, and what Get-ReviewDiff compares against -- live
        # in .source_hashes.
        $hashed = @($m.source_hashes.PSObject.Properties.Name) -join ' '
        $hashed | Should -Match 'real\.md'
        $hashed | Should -Not -Match 'node_modules' -Because 'source_hashes is the baseline the next round diffs against'
    }

    It 'Get-ReviewDiff does not report ignored files as changed' {
        # Round 1 baseline, ignoring node_modules.
        Write-ReviewManifest -ReviewDir $script:Dir -Round 1 -TopicSlug 't' `
            -Files @($script:Bundle) -SourceFiles @('**/*.md', '**/*.ts') -RepoRoot $script:Repo `
            -IgnorePatterns $script:Patterns
        # A vendored file changes; a real one does not.
        Set-Content -LiteralPath (Join-Path $script:Repo 'node_modules/pkg/dep.md') -Value 'vendored CHANGED'
        $d = Get-ReviewDiff -ReviewDir $script:Dir -PriorRound 1 `
            -CurrentFiles @('**/*.md', '**/*.ts') -RepoRoot $script:Repo `
            -IgnorePatterns $script:Patterns
        (@($d.BundleFiles) -join ' ') | Should -Not -Match 'node_modules' -Because 'era.ps1 assigns BundleFiles to $effectiveInclude, and repomix will refuse them'
    }

    It 'a REAL change is still detected (non-vacuity)' {
        Write-ReviewManifest -ReviewDir $script:Dir -Round 1 -TopicSlug 't' `
            -Files @($script:Bundle) -SourceFiles @('**/*.md', '**/*.ts') -RepoRoot $script:Repo `
            -IgnorePatterns $script:Patterns
        Set-Content -LiteralPath (Join-Path $script:Repo 'docs/real.md') -Value 'real source CHANGED'
        $d = Get-ReviewDiff -ReviewDir $script:Dir -PriorRound 1 `
            -CurrentFiles @('**/*.md', '**/*.ts') -RepoRoot $script:Repo `
            -IgnorePatterns $script:Patterns
        (@($d.BundleFiles) -join ' ') | Should -Match 'real\.md'
    }
}

Describe 'era.ps1 passes the repomix patterns to both walks' -Tag Unit {
    BeforeAll { $script:EraSrc = Get-Content -Raw (Join-Path $script:Root 'runtimes/era.ps1') }

    It 'Get-ReviewDiff receives -IgnorePatterns' {
        $script:EraSrc | Should -Match 'Get-ReviewDiff[^\r\n]*[\s\S]{0,200}?-IgnorePatterns'
    }
    It 'Write-ReviewManifest receives -IgnorePatterns' {
        $script:EraSrc | Should -Match 'Write-ReviewManifest[^\r\n]*[\s\S]{0,400}?-IgnorePatterns'
    }
    It 'Measure-EraBroadScope shares the extracted matcher rather than parsing patterns itself' {
        $wf = Get-Content -Raw (Join-Path $script:Root 'workflow.ps1')
        $i = $wf.IndexOf('function Measure-EraBroadScope')
        $body = $wf.Substring($i, 4000)
        $body | Should -Match 'Get-EraIgnoreSets'
    }
}
