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

    It 'handles the dir/**/*.ext shape — the 1 of 6 shipped patterns that did not parse' {
        # Round-6 (opus): "closed for 5 of 6 shipped patterns". Measured:
        # 'validation_results/**/*.db' has a suffix after /** so it matched none
        # of the three parse shapes and was silently dropped. Dormant, because
        # .db is in no default include glob -- but the parser was quietly lying
        # about what it enforced.
        $sets = Get-EraIgnoreSets -IgnorePatterns @('validation_results/**/*.db')
        Test-EraPathIgnored -RelPath 'validation_results/a.db'         -Sets $sets | Should -BeTrue
        Test-EraPathIgnored -RelPath 'validation_results/deep/b.db'    -Sets $sets | Should -BeTrue
        # ...but only that extension, and only under that directory.
        Test-EraPathIgnored -RelPath 'validation_results/notes.md'     -Sets $sets | Should -BeFalse
        Test-EraPathIgnored -RelPath 'elsewhere/a.db'                  -Sets $sets | Should -BeFalse
    }

    It 'every shipped vendor pattern is now recognised by the parser' {
        $pats = @(Get-EraVendorIgnorePatterns)
        $sets = Get-EraIgnoreSets -IgnorePatterns $pats
        $sets.ContainsKey('SkipDirExt') | Should -BeTrue -Because 'the dir/**/*.ext shape needs its own bucket'
        $recognised = $sets.SkipDirNames.Count + $sets.SkipDirs.Count + $sets.SkipExts.Count + $sets.SkipDirExt.Count
        $recognised | Should -Be $pats.Count -Because 'a pattern the parser drops is protection that does not exist'
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

Describe 'a -Diff round can never hand repomix an empty include list' -Tag Unit {
    # Round-7 blocker 1, found by opus in round 6 and independently by gemini in
    # round 7. VERIFIED, including the part opus could not run:
    #
    #   repomix with include:[] bundled 6 files from a 5-file tree -- i.e. the
    #   WHOLE REPOSITORY. It is not "no files", it is "no filter".
    #
    # Reachable because era.ps1's early return required BundleFiles.Count -eq 0
    # AND Deleted.Count -eq 0. Deletions-only therefore proceeded with
    # $effectiveInclude = @(), which went straight into the repomix config --
    # while Measure-EraBroadScope, measuring that same empty list, reported
    # "files: 0" and the scale gate waved it through. A full-repo upload with
    # the consent gate reporting zero.
    #
    # 70093f3 (mine) MANUFACTURES the trigger: the prior round's manifest was
    # written before the ignore filter existed, so it holds node_modules paths;
    # the filtered walk now skips them and classifies every one as Deleted. The
    # first post-upgrade -Diff round with no real edits has Deleted in the
    # thousands and BundleFiles at zero.

    BeforeAll { $script:EraSrc = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtimes/era.ps1') }

    It 'stops a deletions-only diff round instead of bundling for it' {
        # The early return must not require Deleted to be empty too.
        $script:EraSrc | Should -Not -Match '\$diffResult\.BundleFiles\.Count -eq 0 -and \$diffResult\.Deleted\.Count -eq 0'
        $script:EraSrc | Should -Match '\$diffResult\.BundleFiles\.Count -eq 0'
    }

    It 'carries a hard guard before the repomix config is written' {
        # Belt and braces: any future path that empties the list is caught too,
        # rather than silently becoming a repo-wide bundle.
        $guard  = $script:EraSrc.IndexOf('@($effectiveInclude).Count -eq 0')
        $config = $script:EraSrc.IndexOf('include = $effectiveInclude')
        $guard  | Should -BeGreaterThan 0 -Because 'an empty include list is a repo-wide bundle, not an empty one'
        $config | Should -BeGreaterThan 0
        $guard  | Should -BeLessThan $config
    }
}

Describe 'a leading dot survives normalisation — root-level dot-directories' -Tag Unit {
    # Round-7: found by MEASUREMENT while adjudicating opus finding 5 / gemini
    # blocker 3. Neither reviewer named this; both attributed the ignore gap
    # purely to a missing pattern SHAPE. The deeper bug is that patterns which
    # parse perfectly still never match.
    #
    # Test-EraPathIgnored normalised with .TrimStart('./'), and .NET treats that
    # argument as a SET OF CHARACTERS, not a prefix. So every leading '.' was
    # eaten:
    #
    #   '.external-reviews/t/x.md'.TrimStart('./')  ->  'external-reviews/t/x.md'
    #   '.venv/lib/x.py'.TrimStart('./')            ->  'venv/lib/x.py'
    #
    # Measured consequence: '**/.git/**' is a SHIPPED vendor ignore pattern, it
    # parses into SkipDirNames correctly, and it returned $false for '.git/config'
    # -- so the manifest and diff walks were free to hash .git. Nested paths were
    # unaffected ('sub/.venv/...' keeps its dot), which is why this survived.
    #
    # The intent was to strip a leading './' PREFIX. That is what it does now.

    It 'ignores a root-level .git via the shipped **/.git/** pattern' {
        $s = Get-EraIgnoreSets -IgnorePatterns @('**/.git/**')
        Test-EraPathIgnored -RelPath '.git/config' -Sets $s | Should -BeTrue
        Test-EraPathIgnored -RelPath '.git/refs/heads/master' -Sets $s | Should -BeTrue
    }

    It 'ignores a root-level dot-dir named by a rooted pattern' {
        $s = Get-EraIgnoreSets -IgnorePatterns @('.venv/**')
        Test-EraPathIgnored -RelPath '.venv/lib/site.py' -Sets $s | Should -BeTrue
    }

    It 'still ignored the NESTED case before this fix, which is why it went unnoticed' {
        $s = Get-EraIgnoreSets -IgnorePatterns @('**/.venv/**')
        Test-EraPathIgnored -RelPath 'sub/.venv/lib/x.py' -Sets $s | Should -BeTrue
    }

    It 'still strips a leading ./ prefix, which is what TrimStart was there for' {
        $s = Get-EraIgnoreSets -IgnorePatterns @('src/**')
        Test-EraPathIgnored -RelPath './src/a.ps1' -Sets $s | Should -BeTrue
    }

    It 'does not ignore an undotted sibling by accident' {
        $s = Get-EraIgnoreSets -IgnorePatterns @('**/.git/**')
        Test-EraPathIgnored -RelPath 'gitignore-docs/readme.md' -Sets $s | Should -BeFalse
        Test-EraPathIgnored -RelPath 'src/git/config' -Sets $s | Should -BeFalse
    }
}

Describe 'every pattern era generates is understood, and the rest say so' -Tag Unit {
    # Round-7 (opus) finding 5 / gemini blocker 3. Get-EraIgnoreSets silently
    # discarded any pattern it did not recognise, and THREE of the five shapes
    # era itself generates for a staging round were unrecognised:
    #
    #   .external-reviews/othertopic          bare path, no wildcard
    #   .external-reviews/t/*.*               files directly in a dir
    #   .external-reviews/t/round-1-external  bare path, no wildcard
    #
    # Adjudication of the two reviewers' claims, both measured:
    #
    #   gemini's stated impact -- era's own round-N-prompt.md hashed into the
    #   manifest -- is WRONG. The hardcoded '.external-reviews' guards at
    #   Get-ReviewDiff and Write-ReviewManifest mask it. Measured: the manifest
    #   did NOT contain it.
    #
    #   opus's narrower residual is RIGHT. Those guards deliberately ADMIT
    #   '/round-N-external/' (staged review subjects are the thing being
    #   reviewed), so a PRIOR round's staging dir was admitted by the guard and
    #   then not ignored by the sets. Measured: the manifest DID hash
    #   '.external-reviews/t/round-1-external/stale-subject.ps1'.
    #
    # A silently-dropped ignore pattern is precisely how this bug class
    # reproduces, so the parser now reports what it could not understand.

    BeforeAll {
        $script:Stg = Join-Path ([System.IO.Path]::GetTempPath()) ("era-ign-" + [guid]::NewGuid())
        New-Item -ItemType Directory (Join-Path $script:Stg '.external-reviews/t/round-2-external') -Force | Out-Null
        New-Item -ItemType Directory (Join-Path $script:Stg '.external-reviews/t/round-1-external') -Force | Out-Null
        New-Item -ItemType Directory (Join-Path $script:Stg '.external-reviews/othertopic') -Force | Out-Null
        $script:Gen = Get-EraReviewArtifactIgnorePatterns -RepoRoot $script:Stg -TopicSlug 't' -Round 2 -AllowStaging
        $script:GenSets = Get-EraIgnoreSets -IgnorePatterns $script:Gen
    }
    AfterAll { Remove-Item -LiteralPath $script:Stg -Recurse -Force -ErrorAction SilentlyContinue }

    It 'understands every pattern era generates for a staging round' {
        $script:Gen.Count | Should -BeGreaterThan 0
        # ContainsKey first: without it this assertion passes vacuously when the
        # bucket does not exist at all, which is exactly the state it was written
        # against.
        $script:GenSets.ContainsKey('Unparsed') | Should -BeTrue -Because 'the parser must report its own misses'
        @($script:GenSets.Unparsed) | Should -BeNullOrEmpty -Because "era must not emit shapes its own walk cannot read: $($script:GenSets.Unparsed -join ', ')"
    }

    It 'ignores this topic''s own round artifacts via <base>/<slug>/*.*' {
        Test-EraPathIgnored -RelPath '.external-reviews/t/round-1-prompt.md' -Sets $script:GenSets | Should -BeTrue
        Test-EraPathIgnored -RelPath '.external-reviews/t/round-1-manifest.json' -Sets $script:GenSets | Should -BeTrue
    }

    It 'but <slug>/*.* is NOT recursive, so the current round''s staging survives' {
        # This is the whole reason the pattern is written '*.*' and not '**'.
        # round-N-external holds the review SUBJECTS staged from outside the
        # repo. Ignoring them would bundle nothing and hash nothing.
        Test-EraPathIgnored -RelPath '.external-reviews/t/round-2-external/subject.ps1' -Sets $script:GenSets |
            Should -BeFalse -Because 'the current round''s staged subjects are the review, not era output'
    }

    It 'ignores a PRIOR round''s staging dir — opus finding 5, measured open' {
        Test-EraPathIgnored -RelPath '.external-reviews/t/round-1-external/stale-subject.ps1' -Sets $script:GenSets |
            Should -BeTrue -Because 'the hardcoded guard admits round-N-external; only the ignore sets can exclude the stale ones'
    }

    It 'ignores an unrelated topic named as a bare path' {
        Test-EraPathIgnored -RelPath '.external-reviews/othertopic/round-1-prompt.md' -Sets $script:GenSets | Should -BeTrue
        Test-EraPathIgnored -RelPath '.external-reviews/othertopic' -Sets $script:GenSets | Should -BeTrue
    }

    It 'reports a shape it genuinely cannot read rather than dropping it' {
        $s = Get-EraIgnoreSets -IgnorePatterns @('a/*/b/**', 'dist/**')
        @($s.Unparsed) | Should -Contain 'a/*/b/**'
        Test-EraPathIgnored -RelPath 'dist/x.js' -Sets $s | Should -BeTrue -Because 'the readable ones still work'
    }
}
