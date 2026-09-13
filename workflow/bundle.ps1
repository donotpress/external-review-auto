<#
 Module: bundle -- repomix, delivery planning, diff, metadata and manifest writers.
 Part of the workflow.ps1 split (see docs/specs/2026-09-12-era-module-boundaries.md).
 Dot-sourced by workflow.ps1; never loaded directly (no independent state).
#>

function Expand-EraIncludePath {
    <#
    .SYNOPSIS
        Expand one include-list entry to concrete file paths, wildcard-safely.

    .DESCRIPTION
        `[` and `]` are wildcard metacharacters to every PowerShell provider
        cmdlet that binds -Path. An include entry that is a LITERAL path must
        therefore be probed with -LiteralPath, or a file that plainly exists —
        `src/app/[id]/page.tsx`, i.e. any Next.js dynamic route — reports "not
        found", is silently dropped from the manifest's hash baseline, and can
        then never register as changed in any later round's delta.

        Entries that contain '*' or '?' are genuine patterns and keep the
        wildcard-expanding -Path. That '[*?]' test is the same one both former
        call sites already used to decide glob-ness; this function exists so the
        rule lives in exactly one place.

        KNOWN RESIDUAL LIMITATION: a pattern whose DIRECTORY part contains
        brackets (e.g. 'src/app/[id]/*.tsx') still expands the brackets as a
        character class. Fixing that means escaping the brackets while leaving
        the intended '*' alone, and PowerShell offers no primitive for it —
        [WildcardPattern]::Escape() escapes every metacharacter including the
        '*' you meant. Literal entries, the overwhelmingly common case, are
        correct. Do not "simplify" this to a single -Path branch.

    .PARAMETER Entry
        The include entry as written (relative, possibly a glob).

    .PARAMETER RepoRoot
        Absolute repo root the entry is resolved against.

    .OUTPUTS
        [string[]] — absolute paths that exist. Empty if nothing matched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    # --- globstar ----------------------------------------------------------
    # '**/' is minimatch's "every depth, including this one", and that is the
    # meaning repomix applies when it bundles. PowerShell has NO globstar --
    # '**' is just two '*' -- so handing the same string to Get-ChildItem -Path
    # asks a different question and gets a different answer. Measured on a
    # root.md / sub/mid.md / sub/deep/deep.md tree:
    #
    #   -Path <root>\**\*.md -File -Recurse    -> root.md   only
    #   -Path <root>\**\*.md -File             -> mid.md    only
    #   -LiteralPath <root> -Filter *.md -Rec  -> all three
    #
    # era's broad-audit path is built entirely from '**/*.ext' globs
    # (era.ps1:991), so pre-fix repomix bundled every matching file at every
    # depth while the manifest hashed whatever that first line happened to
    # return. Everything else was uploaded but never hashed, so it could never
    # register as changed and the round-over-round delta was blind to it.
    #
    # -Filter is the fast form (the FileSystem provider pushes it down), but on
    # volumes with 8.3 name generation it can over-match (*.md catching .mdx),
    # so the -like pass makes the result deterministic regardless of volume
    # settings. Keep both: -Filter for speed, -like for correctness.
    if ($Entry -match '^(.*?)\*\*[\\/](.+)$') {
        $prefix = $matches[1]
        $leaf   = $matches[2]
        # Only a trailing filename pattern is handled here. A '**' with further
        # path structure after it ('**/sub/*.ts') needs real glob machinery;
        # fall through to the generic branch rather than answer it wrongly.
        if ($leaf -notmatch '[\\/]') {
            $base = if ($prefix) { Join-Path $RepoRoot ($prefix -replace '[\\/]+$', '') } else { $RepoRoot }
            if (-not (Test-Path -LiteralPath $base -PathType Container)) { return @() }
            return @(Get-ChildItem -LiteralPath $base -Filter $leaf -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $leaf } |
                ForEach-Object { $_.FullName })
        }
    }

    $resolved = Join-Path $RepoRoot $Entry
    if ($Entry -match '[*?]') {
        if (-not (Test-Path -Path $resolved)) { return @() }
        return @(Get-ChildItem -Path $resolved -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }
    if (-not (Test-Path -LiteralPath $resolved)) { return @() }
    # A literal entry may still name a directory (include lists accept both);
    # enumerate it so directory entries contribute their files, not a hash of
    # the directory node, which Get-FileHash cannot produce.
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        return @(Get-ChildItem -LiteralPath $resolved -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }
    return @($resolved)
}

function Get-EraVendorIgnorePatterns {
    <#
    .SYNOPSIS
        The static "never a review subject" patterns, in repomix's own spelling.

    .DESCRIPTION
        One definition, because three walks need it at three different points in
        era's control flow. The full repomix set is these PLUS the per-round
        artifact patterns from Get-EraReviewArtifactIgnorePatterns, which cannot
        be computed until staging is resolved -- but Get-ReviewDiff runs BEFORE
        that and only needs these (it carries its own .external-reviews guard).

        '**/' prefixes are load-bearing: a bare '<dir>/**' is ROOT-ANCHORED in
        repomix (measured 1.12.0 -- 'node_modules/**' still bundles
        packages/p/node_modules/d/a.md). Only node_modules changes real output;
        the other two are spelled alike so sibling patterns behave alike.

        The browser-profile patterns must live HERE and cannot live in a repo's
        own .repomixignore (measured 2026-08-31 against repomix 1.12.0, on
        ebay-quantity-monitor with headful Chrome running). Two distinct reasons:

          1. A live Chrome profile holds directories the owning process LOCKS --
             e.g. <profile>/CertificateRevocation/<n> -- and repomix aborts the
             whole run on them: 'PermissionError: Permission denied while
             scanning directory'. Exit 1, nothing dispatched.
          2. .repomixignore CANNOT prevent that. repomix feeds it to globby as
             ignoreFiles ('**/.repomixignore', fileSearch.js
             getIgnoreFilePatterns), and globby must GLOB for that file before it
             can read it -- so the locked directory is walked while looking for
             the very file that would have excluded it. Only 'ignore'
             (customPatterns, i.e. this list) prunes traversal. A repo that added
             .repomixignore to fix this crash kept crashing.

        They are also a privacy control: a profile dir carries live session
        cookies and auth tokens, and era uploads its bundle to a third party.

        '.era-origin' (bare: root-only by construction) is the staging recipe's
        provenance receipt. Repomix runs with useGitignore=false, so the
        .gitignore entry the recipe writes cannot keep it out of a bundle --
        only this list can. It names an origin path and SHA: review material
        for nobody, worthless to a reviewer, and it must never be hashed into
        a manifest baseline either.
    #>
    [CmdletBinding()]
    param()
    return @('**/node_modules/**', '**/.git/**', '**/__pycache__/**', '*.pyc', '*.duckdb', 'validation_results/**/*.db',
             '**/puppeteer_user_data/**', '**/chrome_user_data/**', '**/chrome-profile/**', '.era-origin')
}

function Get-EraIgnoreSets {
    <#
    .SYNOPSIS
        Parse repomix-style ignore patterns into the three sets every era walk
        needs. Pair with Test-EraPathIgnored.

    .DESCRIPTION
        Extracted from Measure-EraBroadScope 2026-08-11 so that the manifest
        baseline, the diff walk and the scale gate apply ONE definition of
        "repomix will not bundle this".

        Round-5 (opus) blocker 1: $repomixIgnorePatterns reached
        Measure-EraBroadScope and the repomix config but NOT Write-ReviewManifest
        or Get-ReviewDiff, which filtered only `.external-reviews`. On the broad
        path the manifest therefore hashed node_modules/**/*.md as sources, the
        next round's diff called them changed, era assigned them to
        $effectiveInclude, and repomix's ignore list beat its include list --
        producing a mis-scoped bundle or an "empty bundle" error blaming
        -IncludeFiles.

        Semantics deliberately match repomix 1.12.0, per the measurement already
        recorded in Measure-EraBroadScope: a bare 'node_modules/**' is anchored
        at the root and does NOT match packages/p/node_modules/d/a.md, while
        '**/node_modules/**' matches at any depth. Pruning every directory merely
        NAMED node_modules under-counted a monorepo by orders of magnitude.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$IgnorePatterns = @())
    $cmp = [System.StringComparer]::OrdinalIgnoreCase
    $sets = @{
        SkipDirs     = [System.Collections.Generic.HashSet[string]]::new($cmp)
        SkipDirNames = [System.Collections.Generic.HashSet[string]]::new($cmp)
        SkipExts     = [System.Collections.Generic.HashSet[string]]::new($cmp)
        # 'dir/**/*.ext' -- a directory AND an extension together. It cannot be
        # decomposed into the buckets above without over-ignoring: as a bare dir
        # it would swallow every other file under it, as a bare ext it would
        # swallow that extension repo-wide. Round-6 (opus) measured this as the
        # 1 of 6 shipped patterns the parser silently dropped.
        SkipDirExt   = [System.Collections.Generic.List[hashtable]]::new()
        # 'dir/*.*' -- files DIRECTLY in a directory, NOT recursively. era emits
        # this for its own round artifacts ('<base>/<slug>/*.*'), and the
        # non-recursion is the entire point: 'round-N-external/' underneath must
        # survive, because that holds the staged review SUBJECTS. Round-7 (opus
        # finding 5 / gemini blocker 3) measured this as silently dropped.
        SkipDirFiles = [System.Collections.Generic.HashSet[string]]::new($cmp)
        # A bare path with no wildcard at all -- 'a/b'. repomix reads it as both
        # "this exact path" and "everything under it". era emits it for unrelated
        # topics and for prior rounds' staging dirs. Also silently dropped.
        SkipExact    = [System.Collections.Generic.HashSet[string]]::new($cmp)
        # What this parser could NOT read. A silently-discarded ignore pattern is
        # precisely how this bug class reproduces -- three of the five patterns
        # era generates for a staging round were being dropped without a word --
        # so misses are now reported rather than swallowed.
        Unparsed     = [System.Collections.Generic.List[string]]::new()
    }
    foreach ($p in @($IgnorePatterns)) {
        $n = "$p" -replace '\\', '/'
        if ($n -match '^\*\*/([^*/]+)/\*\*$')          { [void]$sets.SkipDirNames.Add($matches[1]); continue }
        if ($n -match '^([^*]+)/\*\*/\*(\.[^*/]+)$')     { $sets.SkipDirExt.Add(@{ Dir = $matches[1].TrimEnd('/'); Ext = $matches[2] }); continue }
        if ($n -match '^([^*]+)/\*\*$')                  { [void]$sets.SkipDirs.Add($matches[1].TrimEnd('/')); continue }
        if ($n -match '^([^*]+)/\*\.\*$')                { [void]$sets.SkipDirFiles.Add($matches[1].TrimEnd('/')); continue }
        if ($n -match '^\*(\.[^*/]+)$')                  { [void]$sets.SkipExts.Add($matches[1]); continue }
        # Last: no wildcard anywhere. Both readings apply, as repomix applies them.
        if ($n -notmatch '\*' -and $n.Trim()) {
            $bare = $n.TrimEnd('/')
            [void]$sets.SkipExact.Add($bare)
            [void]$sets.SkipDirs.Add($bare)
            continue
        }
        [void]$sets.Unparsed.Add("$p")
        Write-Host "[era] WARNING: ignore pattern '$p' was not understood by the manifest/diff walk; it will NOT be applied there. repomix may still honour it, which makes the two layers disagree."
    }
    return $sets
}

function Test-EraIncludeEntryEscapesRoot {
    <#
    .SYNOPSIS
        Would this -IncludeFiles entry reach outside $Root? Works for GLOBS,
        which cannot be resolved and were therefore skipped entirely.

    .DESCRIPTION
        era's traversal guard exempted any entry containing '*' or '?', because
        Resolve-Path -LiteralPath cannot resolve a glob. That is fail-OPEN: it
        skipped precisely the entries it could not evaluate. Interim-round
        (gemini) blocker 1, confirmed by measurement:

            entry '../*.md'  ->  traversal BLOCKED? False

        and repomix honours it. Run directly with include ['../<dir>/*.md']
        against a sibling directory holding a marker file:

            bundle files: 1
              ../era-outside-<guid>/SECRET-OUTSIDE.md
            CONTAINS THE OUT-OF-ROOT SECRET? : True

        So the content is uploaded to the reviewer APIs while
        Write-ReviewManifest filters out-of-root paths OUT of source_hashes --
        the round transmits what it does not record, and era prints "path
        traversal blocked" while not blocking it.

        A glob cannot be resolved, but its LITERAL PREFIX can: everything up to
        the first wildcard is an ordinary path, and if that escapes the root then
        every file the pattern can match escapes it too. GetFullPath normalises
        the '..' segments without touching the disk, so this works on patterns
        that match nothing yet.

        Comparison is on the normalised full path with a trailing separator, so
        'C:/repo-secrets' does not count as inside 'C:/repo'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Entry,
        [Parameter(Mandatory)][string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Entry)) { return $false }
    $e = $Entry -replace '\\', '/'
    # Everything before the first wildcard is literal.
    $literal = ($e -split '[*?]')[0]
    # Keep only the directory part: a trailing partial filename is harmless, and
    # 'src/foo' would otherwise be treated as a directory that must exist.
    if ($literal -notmatch '/$') { $literal = ($literal -replace '[^/]*$', '') }

    $rootFull = [System.IO.Path]::GetFullPath((($Root -replace '\\', '/').TrimEnd('/')) + '/')
    try {
        $target = if ([System.IO.Path]::IsPathRooted($literal)) { $literal }
                  else { [System.IO.Path]::Combine($rootFull, $literal) }
        $targetFull = [System.IO.Path]::GetFullPath($target)
    } catch { return $true }   # unparseable -> refuse, do not fail open

    if ($targetFull -notmatch '[\\/]$') { $targetFull += [System.IO.Path]::DirectorySeparatorChar }
    return -not $targetFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-EraStagingInPlay {
    <#
    .SYNOPSIS
        Does this round stage out-of-repo review subjects? True when
        -IncludeFiles names an ABSOLUTE path OUTSIDE the repo root.

    .DESCRIPTION
        Extracted from era.ps1 so ONE definition answers it. It is now consulted
        twice -- once by the -Diff early-return path, to warn that a previous
        round's staged subjects are about to be excluded, and once by the ignore
        patterns, to decide whether to cut the round-N-external carve-out. Two
        inline copies of this loop is exactly the shape that produced the
        {{PREVIOUS_ROUND}} blocker.

        Wildcards are skipped: a glob is not a staging instruction, and
        Test-EraIncludeEntryEscapesRoot owns the question of whether one escapes.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][AllowNull()][string[]]$IncludeFiles,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    foreach ($e in @($IncludeFiles)) {
        $entry = "$e"
        if (-not $entry) { continue }
        if ($entry -match '[*?\[\]]') { continue }
        if (-not [System.IO.Path]::IsPathRooted($entry)) { continue }
        if (-not (Test-EraPathInsideRoot -Path ([System.IO.Path]::GetFullPath($entry)) -Root $RepoRoot)) {
            return $true
        }
    }
    return $false
}

function Get-EraStagedSubjectWarning {
    <#
    .SYNOPSIS
        Warning text when a -Diff round is about to exclude the out-of-repo
        review subjects a previous round staged. $null when it is not.

    .DESCRIPTION
        Interim-round (gemini) blocker 2, measured:

          Get-EraReviewArtifactIgnorePatterns without -AllowStaging
            -> '.external-reviews/**'                     (blanket, no carve-out)
          Test-EraPathIgnored '.external-reviews/t/round-2-external/subject.ps1'
            -> $true    (with -AllowStaging: $false)

        P6 staging copies out-of-repo subjects under
        .external-reviews/<slug>/round-N-external/ so repomix can reach them.
        era's $stagingInPlay is true only when -IncludeFiles holds an ABSOLUTE
        path OUTSIDE the repo root, and it reads the ORIGINAL parameter -- not
        the diff result. So `era -Diff` without re-passing that path gets the
        blanket ignore, the prior round's staged paths read as Deleted, and a
        round whose only change was the staged subject stops at "only deletions;
        nothing to review". Correct arithmetic, useless outcome, no clue why.

        NOT fixed by auto-enabling the carve-out. Staging genuinely did not run
        this round, so there is nothing under the CURRENT round-N-external to
        carve out for, and inventing one would re-admit the PRIOR round's stale
        copies that were deliberately excluded. The subject also may have
        changed on disk since, and era would be bundling a stale snapshot while
        implying it is current.

        So: say what is happening and name the lever.

    .PARAMETER DeletedPaths
        $diffResult.Deleted -- repo-relative paths the walk no longer sees.

    .PARAMETER StagingInPlay
        era's $stagingInPlay for THIS round.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$DeletedPaths = @(),
        [bool]$StagingInPlay
    )
    if ($StagingInPlay) { return $null }
    # round-N-external ONLY. A deleted round-N-prompt.md is era's own output,
    # not a review subject, and warning about it would be noise.
    $staged = @($DeletedPaths | Where-Object { ($_ -replace '\\', '/') -match '/round-\d+-external/' })
    if ($staged.Count -eq 0) { return $null }
    $sample = (@($staged | Select-Object -First 3) -join ', ')
    return ("[era] WARNING: $($staged.Count) staged out-of-repo review subject(s) from a previous round " +
            "are excluded from this -Diff round ($sample). Staging only runs when -IncludeFiles names the " +
            "original absolute path, and this round did not, so repomix cannot see them. Re-pass " +
            "-IncludeFiles with those paths to review them again, or omit -Diff for a full re-bundle.")
}

function Get-ReviewDiff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$PriorRound,
        [Parameter(Mandatory)][string[]]$CurrentFiles,
        [Parameter(Mandatory)][string]$RepoRoot,
        # What repomix will refuse to bundle. Without this the diff reports
        # vendored files as changed and era feeds them to repomix as the include
        # set -- see Get-EraIgnoreSets. Defaults to empty for back-compat.
        [string[]]$IgnorePatterns = @()
    )
    $ignoreSets = Get-EraIgnoreSets -IgnorePatterns $IgnorePatterns
    $priorManifestPath = Join-Path $ReviewDir "round-$PriorRound-manifest.json"
    if (-not (Test-Path -LiteralPath $priorManifestPath)) { return $null }

    $priorManifest = Get-Content -Raw -LiteralPath $priorManifestPath | ConvertFrom-Json
    $priorHashes = @{}
    if ($priorManifest.source_hashes) {
        # Read source_hashes DIRECTLY. It was previously indexed via
        # $priorManifest.sources -- but `sources` is the include list AS
        # WRITTEN (globs) while `source_hashes` is keyed by CONCRETE relative
        # path, so on the broad path every lookup was
        #   source_hashes['**/*.md']   -> $null
        # and $priorHashes came out empty. With an empty baseline every current
        # file classifies as Added, so the round-over-round delta reported
        # nothing Changed and nothing Unchanged, every round, forever.
        #
        # Measured after fixing the globstar expansion but before this: editing
        # sub/deep/deep.md gave
        #   Added: sub/deep/deep.md, root.md   Changed: (none)   Unchanged: (none)
        # — root.md was untouched and still reported as new.
        #
        # This stayed invisible on the -IncludeFiles path because there
        # `sources` holds literal paths, so it coincided with the hash keys.
        # Only the glob path diverged, which is the documented broad-audit mode.
        foreach ($p in $priorManifest.source_hashes.PSObject.Properties) {
            if ($p.Name -and $null -ne $p.Value) { $priorHashes[$p.Name] = "$($p.Value)" }
        }
    } else {
        foreach ($f in $priorManifest.files) {
            if ($f.path -and $f.sha256) { $priorHashes[$f.path] = $f.sha256 }
        }
    }

    $currentHashes = @{}
    foreach ($f in $CurrentFiles) {
        # Resolve globs to concrete paths for hashing. Wildcard-safety for
        # literal bracketed paths lives in Expand-EraIncludePath — see there.
        foreach ($cp in (Expand-EraIncludePath -Entry $f -RepoRoot $RepoRoot)) {
            # SECURITY: block path traversal — skip files outside repo root
            if (-not (Test-EraPathInsideRoot -Path $cp -Root $RepoRoot)) { continue }
            # Never hash era's own review artifacts into the baseline: on the
            # broad path the include list is globs, so this recursion used to
            # sweep up .external-reviews and every later round saw it changed.
            #
            # EXCEPT round-N-external/, which is P6 staging — out-of-repo files
            # the caller explicitly asked to review, mirrored under the review
            # dir because repomix can only bundle beneath repoRoot. Those are
            # review SUBJECTS, not era output. The repomix ignore layer already
            # draws exactly this line (Get-EraReviewArtifactIgnorePatterns carves
            # round-N-external/** out of the blanket .external-reviews/**), so a
            # blanket skip here made the two layers disagree: the file was
            # uploaded and then never hashed, and no later round could see it
            # change. Two layers, one rule.
            $normCp = $cp -replace '\\', '/'
            if (Test-EraOwnReviewArtifact -Path $normCp) { continue }
            # ...and anything repomix itself would refuse to bundle. Compare on
            # the REPO-RELATIVE path: a rooted pattern like 'dist/**' is anchored
            # at the repo root, and testing it against an absolute path would
            # silently never match.
            $rootNorm = ($RepoRoot -replace '\\', '/').TrimEnd('/')
            $relCp = if ($normCp.StartsWith($rootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
                $normCp.Substring($rootNorm.Length).TrimStart('/')
            } else { $normCp }
            if (Test-EraPathIgnored -RelPath $relCp -Sets $ignoreSets) { continue }
            $relPath = $cp.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            $currentHashes[$relPath] = (Get-FileHash -LiteralPath $cp -Algorithm SHA256).Hash.ToLower()
        }
    }

    $added = @()
    $changed = @()
    $unchanged = @()
    $deleted = @()

    # Compare using concrete paths (expanded from globs in the hash-building loop)
    $allCurrentKeys = @($currentHashes.Keys)
    foreach ($f in $allCurrentKeys) {
        if (-not $priorHashes.ContainsKey($f)) {
            $added += $f
        } elseif ($priorHashes[$f] -ne $currentHashes[$f]) {
            $changed += $f
        } else {
            $unchanged += $f
        }
    }
    # Also mark prior files not in current list as deleted
    foreach ($f in $priorHashes.Keys) {
        if (-not $currentHashes.ContainsKey($f) -and $deleted -notcontains $f) {
            $deleted += $f
        }
    }

    return @{
        Added      = $added
        Changed    = $changed
        Unchanged  = $unchanged
        Deleted    = $deleted
        BundleFiles = @($added + $changed | Where-Object { $_ -notin $deleted })
    }
}

function Get-EraDiffPreviousReviewBlock {
    <#
    .SYNOPSIS
        The <previous_review> block for a -Diff prompt -- empty when the caller's
        prompt already carried the previous round itself.

    .DESCRIPTION
        Round-6 finding, a regression from 4e6f6c4.
        Invoke-PromptTokenSubstitution has ALREADY expanded {{PREVIOUS_ROUND}}
        into the prompt file by the time the -Diff block runs. The diff block
        then built <previous_review> from a SECOND Get-EraPreviousRoundText call
        and Merge-EraDiffPrompt concatenated the two. Before 4e6f6c4 the
        duplicate was canonical (one review) + panel (three); afterwards it was
        panel + panel. Each call caps independently at 80,000 chars, so the
        ceiling was 160 KB of duplicated prior-round text -- uploaded once per
        reviewer.

        Detect it on a real artifact:
            (Select-String -Path round-N-prompt.md -Pattern '^### Reviewer: ' `
                -AllMatches).Matches.Count
        Three for a three-model panel; six means it is carried twice.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$PreviousText,
        [bool]$AlreadyInPrompt
    )
    if ($AlreadyInPrompt) { return '' }
    if ([string]::IsNullOrWhiteSpace($PreviousText)) { return '' }
    return "<previous_review>`n$PreviousText`n</previous_review>`n"
}

function Merge-EraDiffPrompt {
    <#
    .SYNOPSIS
        Combine the generated -Diff prompt with whatever prompt already exists,
        without discarding caller-supplied content.

    .DESCRIPTION
        The -Diff branch used to gate this on $script:UserSuppliedPromptOverride,
        which answers "did the caller pass -PromptOverrideFile?" -- a narrower
        question than the one it needed. Three things put caller content in that
        file and only one was checked:

          -PromptOverrideFile   explicit, or auto-detected pending-prompt.md
          -ConversationFile     injected via placeholder, or appended as
                                '## Session context'
          -SpecReview           generates a prompt and assigns the LOCAL
                                $PromptOverrideFile, never the script flag

        So `-Diff -ConversationFile` silently dropped the session context, and
        `-SpecReview -Diff` silently dropped the spec-review prompt. Both found by
        the round-5 panel; the round-4 fix comment on that branch even lists
        "-ConversationFile injection" among the things it protects.

        NOT "always prepend": the diff template is self-contained, carrying its
        own '## Output format' and instructions. Prepending it to the untouched
        generic default would hand the reviewer two conflicting output formats.
        Replace only when the existing prompt is that generic default.

        Diff context goes FIRST -- stable caller context reads better after the
        delta the reviewer must react to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DiffPrompt,
        [AllowNull()][AllowEmptyString()][string]$ExistingPrompt,
        [bool]$ExistingCarriesCallerContent
    )
    if (-not $ExistingCarriesCallerContent) { return $DiffPrompt }
    if ([string]::IsNullOrWhiteSpace($ExistingPrompt)) { return $DiffPrompt }
    return ($DiffPrompt + "`n`n---`n`n" + $ExistingPrompt)
}

function Get-EraPreviousRoundText {
    <#
    .SYNOPSIS
        The previous round's review text, aggregated across every reviewer,
        in-flight-aware and length-capped. One definition, two consumers.

    .DESCRIPTION
        Extracted 2026-08-11. {{PREVIOUS_ROUND}} aggregated every per-preset
        response; the -Diff template built <previous_review> from
        round-N-response.md alone -- the CANONICAL, i.e. whichever single
        reviewer happened to be promoted. So a -Diff follow-up on the shipped
        three-model panel carried one review and silently dropped two. Flagged in
        round 4, still open at round 5.

        Two mechanisms answered the same question and one of them was worse.

        The glob is 'round-N-*-response.md'. Rejected answers are deliberately
        written as 'round-N-<preset>-response.rejected.md' by
        Copy-PrimaryResponseAlias so they cannot match -- that is the whole point
        of the naming, do not "tidy" it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$PreviousRound,
        # Optional out-flag: set when truncation dropped a critical section.
        # The diff branch fails closed to a full bundle on it (truncated
        # findings are worse than no findings: a reviewer cannot verify what
        # it cannot see, and silence reads as convergence).
        [ref]$CriticalsDropped
    )
    $previousN    = $PreviousRound
    $responseFile = Join-Path $ReviewDir "round-$previousN-response.md"
    $claimFile    = Join-Path $ReviewDir "round-$previousN-claim.json"

    $inFlight  = Test-Path -LiteralPath $claimFile
    $perPreset = @()
    if (-not $inFlight) {
        $perPreset = @(Get-ChildItem -LiteralPath $ReviewDir -Filter "round-$previousN-*-response.md" -File -ErrorAction SilentlyContinue |
            Sort-Object Name)
    }
    if ($inFlight) {
        $substitution  = "[Round $previousN is in flight; not yet available]"
    } elseif ($perPreset.Count -gt 0) {
        $sections = foreach ($f in $perPreset) {
            if ($f.Name -match "^round-$previousN-(.+)-response\.md$") { $preset = $matches[1] } else { $preset = $f.BaseName }
            "### Reviewer: $preset`n`n" + (Get-Content -LiteralPath $f.FullName -Raw)
        }
        $substitution = "## Previous round's review (round $previousN, $($perPreset.Count) reviewer(s))`n`n" +
                        ($sections -join "`n`n---`n`n")
    } elseif (Test-Path -LiteralPath $responseFile) {
        # Single-reviewer rounds have no suffixed files; the canonical is their
        # only artifact. Reachable only when $inFlight is false — see above.
        $previousText  = Get-Content -LiteralPath $responseFile -Raw
        $substitution  = "## Previous round's review (round $previousN)`n`n$previousText"
    } else {
        $substitution  = "[Round $previousN response not found]"
    }

    # --- Cap the carried-forward round -------------------------------------
    # Uncapped, this grows with the panel: the shipped three-reviewer default
    # measured 40,400 bytes carried into round 2 (gemini 10,658 + opus 19,869 +
    # deepseek 9,873), and nothing bounded it. The cap is deliberately set well
    # above that so a normal round is never touched — truncating real review
    # content to save tokens would trade away the thing the panel is for. It
    # exists to bound the tail, not to trim the common case.
    #
    # Truncation keeps the HEAD of the substitution: reviewers put the grade,
    # the verdict and the blocker list at the top, so the head is the part the
    # next round actually needs.
    $maxChars = 80000
    if ($env:ERA_PREVIOUS_ROUND_MAX_CHARS) {
        $parsed = 0
        if ([int]::TryParse($env:ERA_PREVIOUS_ROUND_MAX_CHARS, [ref]$parsed) -and $parsed -gt 0) {
            $maxChars = $parsed
        }
    }
    if ($substitution.Length -gt $maxChars) {
        $dropped = $substitution.Length - $maxChars
        Write-Host "[era] Previous round is $($substitution.Length) chars; truncating to $maxChars (raise with ERA_PREVIOUS_ROUND_MAX_CHARS)."
        if ($CriticalsDropped -and $substitution -match '(?im)^##\s*critical') {
            $kept = $substitution.Substring(0, $maxChars)
            if ($kept -notmatch '(?im)^##\s*critical') {
                $CriticalsDropped.Value = $true
            }
        }
        $substitution = $substitution.Substring(0, $maxChars) +
            "`n`n[... previous round truncated: $dropped of $($substitution.Length + 0) chars omitted." +
            " Raise ERA_PREVIOUS_ROUND_MAX_CHARS to carry more.]"
    }

    return $substitution
}

function Test-EraFollowUpRound {
    <#
    .SYNOPSIS
        Should this round go differential? Pure truth table, one call site.
    .DESCRIPTION
        The default flip (2026-09-12): round >= 2 with a usable prior goes
        differential unless -FullBundle forces full. Explicit -Diff flows
        through the same helper -- one code path, not two (pinned by test).
        -FullBundle is the close-out mechanism: verdict rounds that must see
        everything pass it. Prior usability is computed, not assumed (see
        Test-EraPriorRoundUsable): void/missing priors fall back to full.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Round,
        [bool]$FullBundlePresent = $false,
        [bool]$PriorUsable = $false
    )
    if ($Round -lt 2) { return $false }
    if ($FullBundlePresent) { return $false }
    # Explicit -Diff and the default flip converge here by design: once the
    # prior is usable, both want the delta path through the same code below.
    # An unusable prior fails closed to full either way.
    return [bool]$PriorUsable
}

function Test-EraPriorRoundUsable {
    <#
    .SYNOPSIS
        Did the prior round deliver anything to carry forward? Pure predicate.
    .DESCRIPTION
        Usable = prior manifest present AND >=1 usable response artifact
        (round-P-*-response.md excluding rejected/demoted, or the canonical
        round-P-response.md for solo rounds). Manifest alone is a plan with
        no reviews; responses alone (no manifest) may be a crashed partial;
        rejected-only is explicitly demoted content. All three fall back to
        a full bundle with a log line -- reviewing a delta against nothing
        is how findings silently vanish.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$PriorRound
    )
    if (-not (Test-Path -LiteralPath (Join-Path $ReviewDir "round-$PriorRound-manifest.json"))) { return $false }
    $arts = @(Get-ChildItem -LiteralPath $ReviewDir -Filter "round-$PriorRound-*-response.md" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.rejected.md' })
    if (@($arts).Count -gt 0) { return $true }
    return [bool](Test-Path -LiteralPath (Join-Path $ReviewDir "round-$PriorRound-response.md"))
}

function Invoke-PromptTokenSubstitution {
    <#
    .SYNOPSIS
        Substitute {{PREVIOUS_ROUND}} in a prompt file with the prior round's response.

    .DESCRIPTION
        If the prompt file at $PromptFile contains the literal token {{PREVIOUS_ROUND}},
        this function replaces it with the previous round's review text, built by
        Get-EraPreviousRoundText -- EVERY reviewer's response aggregated, not
        just the promoted round-($RoundN-1)-response.md.

        Callers in era.ps1 invoke this AFTER the prompt file is finalized (copied or
        written from template) and BEFORE repomix runs (the bundle picks up the prompt
        via instructionFilePath at bundle time).

        Three outcomes, in this precedence order:
            - round-(N-1)-claim.json exists (in-flight): a [in flight] note, and
              NO round N-1 content is carried forward from any source. This is
              checked first and outranks both branches below.
            - round-(N-1) responses exist (per-preset files, else the canonical
              round-(N-1)-response.md): substituted with a fenced header.
            - Neither exists: substituted with a [not found] note.

        If {{PREVIOUS_ROUND}} is absent from the prompt, no action is taken (callers
        that manually summarize the previous round are unaffected).

    .OUTPUTS
        [bool] -- $true iff a token was actually substituted, i.e. the prompt file
        NOW CARRIES the previous round's text. $false when the file is missing,
        when there is no token, or when the only occurrences are BACKTICKED
        mentions (which are deliberately not substitution sites -- see below).

        This return value is the ONLY correct way to answer "does this prompt
        already carry the previous round?", because the token is consumed here and
        cannot be detected afterwards. era.ps1 feeds it straight to
        Get-EraDiffPreviousReviewBlock. It used to ask its own unguarded regex
        instead, which said "yes" for a backticked mention that this function had
        correctly left alone -- so the -Diff block was suppressed and the
        follow-up round dispatched with no prior review at all (round-7 blocker 1,
        a regression from ab17ea0). Do not reintroduce a second copy of the rule.

    .PARAMETER PromptFile
        Absolute path to the prompt file to transform in place.

    .PARAMETER ReviewDir
        Per-topic directory (e.g. .external-reviews/my-topic/) containing round-N-* files.

    .PARAMETER RoundN
        Current round number. The function looks for round-($RoundN-1)-* files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PromptFile,
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$RoundN
    )

    # ONE definition of "is there a substitutable token here", used by the
    # early-out below AND by the Replace at the bottom. Round-7 (opus) blocker 1:
    # era.ps1 used to keep its OWN, unguarded copy of this rule to decide whether
    # to suppress the -Diff <previous_review> block, and the two disagreed on
    # exactly the case the guard exists for -- a backticked mention. See the
    # comment above the Replace, and the return contract in .OUTPUTS.
    $tokenPattern = '(?<!`)\{\{PREVIOUS_ROUND\}\}(?!`)'

    if (-not (Test-Path -LiteralPath $PromptFile)) { return $false }
    $promptText = Get-Content -LiteralPath $PromptFile -Raw
    if ($promptText -notmatch $tokenPattern) { return $false }

    $previousN    = $RoundN - 1
    $responseFile = Join-Path $ReviewDir "round-$previousN-response.md"
    $claimFile    = Join-Path $ReviewDir "round-$previousN-claim.json"

    # Carry the WHOLE panel forward, not just the promoted model (2026-08-09).
    # Only the canonical file used to be substituted, so on a three-reviewer
    # round two of the three reviews were silently discarded between rounds --
    # the panel exists precisely because one reviewer is a single point of
    # failure. Per-preset files are preferred when present; the canonical is the
    # fallback for single-reviewer rounds, which have no suffixed files.
    #
    # The in-flight check comes FIRST. It used to sit after the aggregation, so a
    # round still running yielded whichever reviewers had already finished,
    # presented as though it were the complete panel.
    #
    # It also gates EVERY content branch, not just the per-preset glob. It used
    # to gate only $perPreset, so a round holding a live claim while a canonical
    # round-N-response.md existed fell through to the canonical branch below and
    # was handed to round N+1 as a finished review — the same "partial round
    # presented as complete" failure, reached by the other door. Measured before
    # the fix: the canonical body was inlined under "## Previous round's review
    # (round N)" with no in-flight note at all.
    #
    # A live claim is the ONLY authority on in-flight-ness here. The manifest is
    # NOT a completion signal — era.ps1 writes round-N-manifest.json pre-dispatch
    # (era.ps1:1398), before any reviewer returns — so "claim + manifest" must
    # never be read as "finished". Do not add that shortcut. An orphaned claim
    # from a hard kill is reclaimed by Reserve-ReviewRound's 24h TTL; until then
    # withholding content is the safe direction, because a hard-killed round's
    # responses are partial by construction.
    #
    # The glob is 'round-N-*-response.md'. Rejected answers are deliberately
    # written as 'round-N-<preset>-response.rejected.md' by
    # Copy-PrimaryResponseAlias so they cannot match here — that is the whole
    # point of the naming, do not "tidy" it.
    $substitution = Get-EraPreviousRoundText -ReviewDir $ReviewDir -PreviousRound $previousN

    # Use [regex]::Replace with a MatchEvaluator delegate so the replacement text
    # is treated as a literal string (no $ or \ interpretation). This is the only
    # safe approach when replacement content may contain arbitrary text from a
    # reviewer response (file paths with backslashes, $ in PowerShell snippets, etc.)
    #
    # A BACKTICKED occurrence is a MENTION, not a substitution site. A prompt that
    # discusses this feature writes `{{PREVIOUS_ROUND}}` in an inline code span,
    # and expanding those is not a cosmetic problem — measured on the real
    # round-2 artifact, the source prompt named the token twice that way and the
    # result was 85,457 bytes: the entire panel inlined TWICE (2 x 40,400) plus
    # 4,657 bytes of actual prompt, with both sentences destroyed mid-clause.
    # One of them was "**Attack `{{PREVIOUS_ROUND}}` aggregation.**" — the
    # instruction asking reviewers to examine this code path was itself eaten by
    # this code path, and three reviewers were billed to read the wreckage.
    #
    # Known limitation: this recognises inline code spans only. A token inside a
    # fenced ``` block is still expanded; fixing that needs a real Markdown
    # parse, and the inline-span form is the one that occurs in practice.
    $newText = [regex]::Replace($promptText, $tokenPattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        return $substitution
    })
    Set-Content -LiteralPath $PromptFile -Value $newText -Encoding UTF8
    # $true means the prompt NOW CARRIES the previous round. Only this function
    # can answer that -- the token is gone by the time anyone else can look, and
    # asking a second regex is what produced round-7's blocker 1.
    return $true
}

function Write-ReviewManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$Round,
        [Parameter(Mandatory)][string]$TopicSlug,
        [Nullable[int]]$PreviousRound,
        [Parameter(Mandatory)][string[]]$Files,
        [string[]]$SourceFiles,
        [string]$RepoRoot,
        # What repomix will refuse to bundle. The manifest is the round's
        # provenance record; without this it claims a superset of what was
        # actually reviewed -- see Get-EraIgnoreSets.
        [string[]]$IgnorePatterns = @(),
        # HEAD sha / branch / dirty list at dispatch time, from
        # era.ps1's Get-EraGitState. Null outside a git work tree.
        $GitState,
        # WHICH REVIEWERS THIS ROUND ASKED FOR.
        #
        # The manifest is the round's provenance record, and it recorded git
        # state, sources, files and hashes but NOT this -- so "was reviewer X
        # dispatched?" was not answerable from the artifacts at all. On
        # 2026-08-26 that produced a wrong claim in a published release note:
        # a round had been invoked with an explicit short -Reviewer list, the
        # missing reviewer was read months-later as evidence of a silent panel
        # degradation, and there was nothing on disk to check it against.
        #
        # REQUESTED, not approved and not successful: the cost prompt can drop
        # reviewers and dispatch can lose them, and both of those are already
        # visible in round-N-metadata.json. What was missing is the intent.
        [string[]]$ReviewersRequested = @()
    )
    $ignoreSets = Get-EraIgnoreSets -IgnorePatterns $IgnorePatterns
    $arr = New-Object System.Collections.ArrayList
    foreach ($f in $Files) {
        # -LiteralPath avoids PowerShell wildcard expansion when paths contain
        # square brackets (common in Next.js dynamic routing, e.g.
        # `src/app/[id]/page.tsx`). Without it, Get-FileHash with default -Path
        # throws on such files. This matches the pattern at line 121 / 35.
        # status field removed: it was hardcoded to 'new' for all files in all
        # rounds, which mis-implied delta semantics that don't exist here.
        # source_hashes (below) is the authoritative diff signal.
        [void]$arr.Add(@{
            path   = $f
            sha256 = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
        })
    }
    $manifest = @{
        round               = $Round
        topic_slug          = $TopicSlug
        timestamp           = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        previous_round      = $PreviousRound
        reviewers_requested = @($ReviewersRequested)
        files          = $arr.ToArray()
    }
    # Anchor the round to a COMMIT. Without this there is no way, after the
    # fact, to say which code a round actually saw — and rounds get cited as
    # evidence in commit messages, where "reviewed in round N" reads as a claim
    # about a specific tree. `git_clean=false` means the bundle contained work
    # that was in no commit, so the round covers no reproducible range.
    if ($GitState) {
        $manifest.git_head   = $GitState.Head
        $manifest.git_branch = $GitState.Branch
        $manifest.git_clean  = ($GitState.Dirty.Count -eq 0)
        $manifest.git_dirty  = [array]$GitState.Dirty
    }
    # A STAGED ROUND'S git_head IS A STAGING SHA, resolvable nowhere. era does
    # not stage (see the UNC refusal in era.ps1 and its ruling), but when the
    # caller stages using the recipe era printed, the recipe leaves .era-origin
    # naming the tree the copy came from. Reading it is what keeps a staged
    # round citable: without it the manifest anchors to a commit that exists
    # only in a temp directory, and says git_clean=true while doing it.
    # .era-origin is gitignored by that same recipe (provenance, not review
    # material) and excluded from bundles by Get-EraVendorIgnorePatterns, so it
    # never reaches a reviewer; era reads it from the working directory here.
    $originFile = if ($RepoRoot) { Join-Path $RepoRoot '.era-origin' } else { $null }
    if ($originFile -and (Test-Path -LiteralPath $originFile)) {
        $manifest.staged = $true
        foreach ($line in (Get-Content -LiteralPath $originFile -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*origin_(repo|head|branch|dirty)\s*:\s*(.+?)\s*$') {
                $manifest["staged_from_$($Matches[1])"] = $Matches[2]
            }
        }
        # THE CALLER WROTE .era-origin, SO CHECK IT. Recording an unverified
        # SHA would replace "anchored to a commit that exists nowhere" with
        # "anchored to a commit we did not look for", which is not an
        # improvement. One subprocess turns the caller's assertion into a
        # measurement. Failure is data, never fatal: a gone repo, an
        # unreadable one, or a missing git all leave resolvable=false (or the
        # field unset when there was nothing to check), and the manifest is
        # otherwise exactly as it is today.
        try {
            if ((Get-Command git -ErrorAction SilentlyContinue) -and $manifest.staged_from_repo -and $manifest.staged_from_head) {
                $null = & git -C $manifest.staged_from_repo cat-file -e "$($manifest.staged_from_head)^{commit}" 2>&1
                $manifest.staged_from_resolvable = ($LASTEXITCODE -eq 0)
            }
        } catch {}
    }
    if ($SourceFiles -and $RepoRoot) {
        $manifest.sources = [array]$SourceFiles
        $manifest.source_hashes = @{}
        foreach ($s in $SourceFiles) {
            # Wildcard-safety for literal bracketed paths lives in
            # Expand-EraIncludePath — see there. A source silently missing from
            # source_hashes can never register as changed, so the round-over-round
            # delta stays permanently blind to it; that is what the old
            # Test-Path -Path did to every Next.js dynamic route.
            foreach ($cp in (Expand-EraIncludePath -Entry $s -RepoRoot $RepoRoot)) {
                # SECURITY: block path traversal — skip files outside repo root
                if (-not (Test-EraPathInsideRoot -Path $cp -Root $RepoRoot)) { continue }
                # Never hash era's own review artifacts into the baseline: on
                # the broad path the include list is globs, so this recursion
                # used to sweep up .external-reviews and every later round saw
                # those artifacts as changed.
                $normCp = $cp -replace '\\', '/'
                if (Test-EraOwnReviewArtifact -Path $normCp) { continue }
            # ...and anything repomix itself would refuse to bundle. Compare on
            # the REPO-RELATIVE path: a rooted pattern like 'dist/**' is anchored
            # at the repo root, and testing it against an absolute path would
            # silently never match.
            $rootNorm = ($RepoRoot -replace '\\', '/').TrimEnd('/')
            $relCp = if ($normCp.StartsWith($rootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
                $normCp.Substring($rootNorm.Length).TrimStart('/')
            } else { $normCp }
            if (Test-EraPathIgnored -RelPath $relCp -Sets $ignoreSets) { continue }
                $relPath = $cp.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
                $manifest.source_hashes[$relPath] = (Get-FileHash -LiteralPath $cp -Algorithm SHA256).Hash.ToLower()
            }
        }
    }
    $outPath = Join-Path $ReviewDir "round-$Round-manifest.json"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outPath -Encoding utf8
    return $outPath
}

function Get-EraTruncatedText {
    <#
    .SYNOPSIS
        Caps captured subprocess output before it goes into an exception message.

    .DESCRIPTION
        era.ps1 interpolated the whole of repomix's captured output into its
        failure exception. The 2026-08-09 run that started collecting 72,378
        files emitted a 16.9 MB log, so the "error message" was 16.9 MB of
        bundle chatter — unreadable, and expensive to move around. Keep the head
        (where the actual failure usually is) and say how much was dropped.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [int]$MaxChars = 4000
    )
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    # Clamp: this runs while BUILDING an exception message, so a bad budget must
    # not throw an ArgumentOutOfRangeException over the top of the real error.
    if ($MaxChars -lt 0) { $MaxChars = 0 }
    if ($Text.Length -le $MaxChars) { return $Text }
    # Head AND tail: a subprocess usually explains itself at the start, but the
    # fatal line is just as often the last thing it wrote before dying.
    $headLen = [int][Math]::Ceiling($MaxChars * 0.6)
    $tailLen = $MaxChars - $headLen
    $result = ($Text.Substring(0, $headLen) +
        "`n... [truncated: $($Text.Length) chars total, showing first $headLen and last $tailLen] ...`n" +
        $Text.Substring($Text.Length - $tailLen))
    # Just past the budget the marker costs more than it saves; never hand back
    # something longer than what we were given.
    if ($result.Length -ge $Text.Length) { return $Text }
    return $result
}

function Test-EraRepomixCompleted {
    <#
    .SYNOPSIS
        Did a timed-out repomix run actually finish packing? Pure predicate.
    .DESCRIPTION
        MEASURED 2026-09-11 (ebook-pipeline round 3, first attempt): era threw
        "repomix timed out after 300s" while the partial output showed every
        phase through "Packing completed successfully!" -- the node process
        hung at EXIT, after the bundle was written. The retry bundled fine in
        seconds, so the round died for nothing.

        Adopt requires ALL of: the completion banner in the partial output, a
        bundle file that exists, is non-empty, and is newer than the repomix
        start, AND a well-formed tail. The tail check is load-bearing: the
        banner prints BEFORE the output flush, so a kill between the two
        leaves banner + fresh + non-empty on a TRUNCATED file -- adopting it
        would review a fragment in silence (the same silent-truncation class
        as the opencode 50 KiB cap). The marker is the closing
        `</instruction>` block: era always sets instructionFilePath on its
        repomix configs, so every era bundle ends with caller instructions,
        and a file without that tail did not finish writing.
    .OUTPUTS
        [bool].
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$PartialOutput,
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][datetime]$SinceUtc
    )
    if ([string]::IsNullOrEmpty($PartialOutput)) { return $false }
    if ($PartialOutput -notlike '*Packing completed successfully*') { return $false }
    try {
        $item = Get-Item -LiteralPath $BundlePath -ErrorAction Stop
        if ($item.Length -le 0) { return $false }
        if ($item.LastWriteTimeUtc -lt $SinceUtc) { return $false }
        # Tail check: read only the last 2 KB (never the whole bundle -- this
        # runs on the already-timed-out path and must stay cheap).
        $tailBytes = [Math]::Min(2048, $item.Length)
        $stream = [System.IO.File]::Open($BundlePath, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $buf = New-Object byte[] $tailBytes
            $null = $stream.Seek(-$tailBytes, [System.IO.SeekOrigin]::End)
            $read = 0
            while ($read -lt $tailBytes) {
                $n = $stream.Read($buf, $read, $tailBytes - $read)
                if ($n -le 0) { break }
                $read += $n
            }
            $tail = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $stream.Dispose() }
        if ($tail -notlike '*</instruction>*') { return $false }
    } catch { return $false }
    return $true
}

function Measure-EraBroadScope {
    <#
    .SYNOPSIS
        Bounded enumeration of what the repo-wide default globs would actually
        bundle, so era can announce the scope BEFORE repomix runs.

    .DESCRIPTION
        Omitting -IncludeFiles selects the documented broad audit. era used to
        say nothing about what that meant: on a large repo repomix began
        collecting 72,378 files and died ~18 minutes later with
        ERR_IPC_CHANNEL_CLOSED after a 16.9 MB log.

        Deliberately NOT `git ls-files`. The repomix config sets
        useGitignore=$false, so the include set is a SUPERSET of tracked files —
        git would under-report precisely the case that hurts (a repo whose
        .gitignore is the only thing keeping a build tree out of the bundle).

        Stops as soon as the count passes -Limit and reports Truncated, so the
        cost of measuring a runaway repo is bounded. Directory pruning uses the
        same ignore patterns handed to repomix, so 'node_modules/**' and
        '.external-reviews/**' are skipped rather than walked.

        The result is an ESTIMATE for a consent prompt, not a bundle manifest:
        only the two ignore shapes that matter here ('<dir>/**' and '*.<ext>')
        are honoured, and repomix remains the authority on what is bundled.
        Matching is PowerShell -like, which has no brace expansion — a custom
        ERA_DEFAULT_GLOBS entry such as '**/*.{js,ts}' would therefore be
        under-counted. None of the shipped default globs use braces.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Include,
        [string[]]$IgnorePatterns = @(),
        [int]$Limit = 5000,
        # The file limit alone does NOT bound the walk: directories holding no
        # matching files never increment the counter, so a junction/symlink loop
        # — or just a pathological tree — would enumerate forever.
        [int]$MaxDirs = 20000
    )
    $cmp = [System.StringComparer]::OrdinalIgnoreCase
    # Root-RELATIVE directory paths, not bare names. Measured against repomix
    # 1.12.0: a bare 'node_modules/**' is anchored at cwd and does NOT match
    # packages/p/node_modules/d/a.md — repomix bundles that file. Pruning every
    # directory merely NAMED node_modules under-counted a monorepo by orders of
    # magnitude, which is worse than no gate at all: the notice is evidence the
    # user trusts.
    # Two shapes, matching repomix exactly:
    #   '<dir>/**'      -> root-anchored; prune that one relative path
    #   '**/<dir>/**'   -> any depth;     prune any directory with that leaf name
    # Nothing used to assert this parser understood the list era hands repomix,
    # which is how the original under-count shipped. See the contract test in
    # tests/IgnorePatternDepth.Tests.ps1.
    # One definition of the ignore rule, shared with Write-ReviewManifest and
    # Get-ReviewDiff. See Get-EraIgnoreSets.
    $ignoreSets   = Get-EraIgnoreSets -IgnorePatterns $IgnorePatterns
    $skipDirs     = $ignoreSets.SkipDirs
    $skipDirNames = $ignoreSets.SkipDirNames
    $skipExts     = $ignoreSets.SkipExts

    # Split includes into leaf matches ('**/*.md' -> '*.md', the shape every
    # shipped default glob uses) and full-relative-path matches for anything
    # else a caller set via ERA_DEFAULT_GLOBS.
    $leafPatterns = [System.Collections.Generic.List[string]]::new()
    $pathPatterns = [System.Collections.Generic.List[string]]::new()
    $unmatchable  = $false
    foreach ($p in @($Include)) {
        $n = "$p" -replace '\\', '/'
        # PowerShell -like understands only *, ? and [...]. globby also does brace
        # alternation ('**/*.{ts,tsx}') and extglob, and ERA_DEFAULT_GLOBS is
        # documented as a repomix glob list, so those are legitimate input. Report
        # them as unmeasured rather than silently matching nothing and handing the
        # gate a confident zero while repomix bundles the whole tree.
        if ($n -match '[{}]' -or $n -match '[+@!?]\(') { $unmatchable = $true; continue }
        if ($n.StartsWith('**/') -and -not $n.Substring(3).Contains('/')) {
            $leafPatterns.Add($n.Substring(3))
        } else {
            $pathPatterns.Add(($n -replace '\*\*/', '*'))
        }
    }
    if ($unmatchable) {
        return @{ FileCount = 0; Bytes = [long]0; Truncated = $true; Reason = 'unmatchable-glob' }
    }

    $root = [System.IO.Path]::GetFullPath($RepoRoot)
    $count = 0
    $bytes = [long]0
    $truncated = $false

    $dirsSeen = 0
    $reason = ''
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($root)
    while ($stack.Count -gt 0 -and -not $truncated) {
        $dir = $stack.Pop()
        $dirsSeen++
        if ($dirsSeen -gt $MaxDirs) {
            # Bailing early means the count is INCOMPLETE, which must read as
            # truncated so the consent gate refuses rather than waving through a
            # repo we failed to measure.
            $truncated = $true
            $reason = 'dir-budget'
            break
        }
        try { $subDirs = @([System.IO.Directory]::EnumerateDirectories($dir)) } catch { $subDirs = @() }
        foreach ($s in $subDirs) {
            if ($skipDirNames.Contains([System.IO.Path]::GetFileName($s))) { continue }
            $subRel = ($s.Substring($root.Length).TrimStart('\', '/')) -replace '\\', '/'
            if ($skipDirs.Contains($subRel)) { continue }
            # Never descend a reparse point: a junction back to an ancestor is a
            # cycle, and a junction elsewhere is not part of this repo's tree.
            try {
                if (([System.IO.File]::GetAttributes($s) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            } catch { continue }
            $stack.Push($s)
        }
        try { $files = [System.IO.Directory]::EnumerateFiles($dir) } catch { $files = @() }
        foreach ($f in $files) {
            $ext = [System.IO.Path]::GetExtension($f)
            if ($ext -and $skipExts.Contains($ext)) { continue }
            $leaf = [System.IO.Path]::GetFileName($f)
            $hit = $false
            foreach ($lp in $leafPatterns) { if ($leaf -like $lp) { $hit = $true; break } }
            if (-not $hit -and $pathPatterns.Count -gt 0) {
                $rel = ($f.Substring($root.Length).TrimStart('\', '/')) -replace '\\', '/'
                foreach ($pp in $pathPatterns) { if ($rel -like $pp) { $hit = $true; break } }
            }
            if (-not $hit) { continue }
            $count++
            try { $bytes += ([System.IO.FileInfo]::new($f)).Length } catch { }
            if ($count -gt $Limit) { $truncated = $true; $reason = 'file-limit'; break }
        }
    }
    return @{ FileCount = $count; Bytes = $bytes; Truncated = $truncated; Reason = $reason }
}

function Test-EraBroadScopeAllowed {
    <#
    .SYNOPSIS
        Consent decision for a broad bundle. $true = proceed, $false = refuse.

    .DESCRIPTION
        A truncated enumeration always refuses: an unknown count is not a safe
        count, and truncation means the repo is already past the bound we were
        willing to measure. -Force is the documented override.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Scope,
        [Parameter(Mandatory)][int]$MaxFiles,
        [Parameter(Mandatory)][long]$MaxBytes,
        [switch]$Force
    )
    if ($Force) { return $true }
    if ($Scope.Truncated) { return $false }
    if ([int]$Scope.FileCount -gt $MaxFiles) { return $false }
    if ([long]$Scope.Bytes -gt $MaxBytes) { return $false }
    return $true
}

function Format-EraBroadScopeNotice {
    <#
    .SYNOPSIS
        The human-readable "here is what you are about to upload" block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Scope,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$Reviewers = @(),
        [int]$Limit = 5000
    )
    # A4: when the walk was cut short by the directory budget (or an unmatchable
    # glob), the accumulated byte total can be an arbitrarily small fraction of
    # the tree. Printing "> 12.3 MB" there invites the trust the gate exists to
    # withhold, so say plainly that it was not measured.
    $mb = [Math]::Round(([long]$Scope.Bytes) / 1MB, 1)
    $partialWalk = $Scope.Truncated -and $Scope.Reason -ne 'file-limit'
    $countText = if ($partialWalk) { 'unmeasured (walk bounded)' }
                 elseif ($Scope.Truncated) { ">$Limit" }
                 else { '{0:N0}' -f [int]$Scope.FileCount }
    $sizeText  = if ($partialWalk) { 'unmeasured' }
                 elseif ($Scope.Truncated) { "> $mb MB" }
                 else { "$mb MB" }
    $lines = @(
        "[era] BROAD BUNDLE — no -IncludeFiles was given, so the repo-wide default globs apply."
        "[era]   repo root : $RepoRoot"
        "[era]   files     : $countText"
        "[era]   size      : $sizeText (approx, pre-bundle)"
        "[era]   gitignore : NOT honoured (useGitignore=false) — ignored files are bundled too"
        # "requested" not "sending to" (A7): the cost prompt downstream can still
        # drop reviewers, so this list is what was asked for, not what was agreed.
        "[era]   requested : $(if ($Reviewers) { $Reviewers -join ', ' } else { '(none resolved)' }) (before cost approval)"
    )
    return ($lines -join "`n")
}

function Get-EraReviewArtifactIgnorePatterns {
    <#
    .SYNOPSIS
        repomix ignore patterns that keep era's OWN review artifacts out of the
        bundle it is about to upload.

    .DESCRIPTION
        era writes every round under .external-reviews/<slug>/: the prompt, the
        reviewer responses, the manifest and metadata (which carry Stderr), and
        the staged copies of any out-of-repo -IncludeFiles. The repomix config
        sets useGitignore=$false and useDefaultPatterns=$false, so nothing else
        excludes that tree -- and the default globs ('**/*.md', '**/*.json', ...)
        match all of it. Without these patterns, round N re-transmits round N-1
        to a third-party API.

        Two shapes, because repomix's ignore beats its include (measured against
        repomix 1.12.0 -- an explicitly-listed file is still dropped if a
        customPattern matches it, and '!negation' patterns are not honoured):

          -AllowStaging absent  -> a single blanket '.external-reviews/**'.
          -AllowStaging present -> the same exclusion with a hole cut for THIS
             round's round-<N>-external/ staging dir, which holds files the
             caller explicitly asked to review (era.ps1 P6 staging). A blanket
             pattern would silently drop them from the bundle.

        The carve-out ignores current-topic round artifacts by SHAPE
        ('<slug>/*.*' -- every round-N-*.md/.json/.xml file sits directly in the
        topic dir and has an extension, while the staging dir 'round-N-external'
        has none), so artifacts written after this call (the round's own
        config.json) are still excluded. Sibling directories are enumerated
        because they must be matched by name to spare the one we keep.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$TopicSlug,
        [Parameter(Mandatory)][int]$Round,
        [switch]$AllowStaging
    )
    $base = '.external-reviews'
    $blanket = @("$base/**")
    if (-not $AllowStaging) { return $blanket }

    $absBase = Join-Path $RepoRoot $base
    if (-not (Test-Path -LiteralPath $absBase)) { return $blanket }

    $patterns = [System.Collections.Generic.List[string]]::new()

    # Every unrelated topic goes wholesale.
    foreach ($child in @(Get-ChildItem -LiteralPath $absBase -Force -ErrorAction SilentlyContinue)) {
        if ($child.Name -eq $TopicSlug) { continue }
        $patterns.Add("$base/$($child.Name)")
        $patterns.Add("$base/$($child.Name)/**")
    }

    # This topic's own round artifacts, matched by shape so files created after
    # this enumeration are covered too.
    $patterns.Add("$base/$TopicSlug/*.*")

    # Sibling directories inside this topic -- prior rounds' staging dirs -- go
    # too; only the current round's survives.
    $keepDir  = "round-$Round-external"
    $absTopic = Join-Path $absBase $TopicSlug
    if (Test-Path -LiteralPath $absTopic) {
        foreach ($child in @(Get-ChildItem -LiteralPath $absTopic -Force -Directory -ErrorAction SilentlyContinue)) {
            if ($child.Name -eq $keepDir) { continue }
            $patterns.Add("$base/$TopicSlug/$($child.Name)")
            $patterns.Add("$base/$TopicSlug/$($child.Name)/**")
        }
    }
    return @($patterns)
}

function Test-SlugPerRoundPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExternalReviewsDir,
        [Parameter(Mandatory)][string]$TopicSlug
    )
    if (-not (Test-Path -LiteralPath $ExternalReviewsDir)) { return $null }
    $escaped = [regex]::Escape($TopicSlug)
    $siblings = Get-ChildItem -Directory -LiteralPath $ExternalReviewsDir |
        Where-Object { $_.Name -match "^${escaped}-(r|round)\d+$" } |
        ForEach-Object { $_.Name }
    if ($siblings.Count -gt 0) {
        $list = $siblings -join ', '
        return "[era] WARNING: Found related topics ($list) — this looks like a new topic per round instead of iterating within one topic. Reuse the same -TopicSlug and let era.ps1 handle round numbering."
    }
    return $null
}

function Test-ConvergenceDivergence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$Round,
        [Parameter(Mandatory)][int]$CurrentResponseChars
    )
    $warnings = @()
    if ($env:ERA_CONVERGENCE_WARNINGS -eq '0') { return $warnings }

    # Signal A: round count
    if ($Round -ge 5) {
        $warnings += "[era] WARNING: Round $Round — typical convergence is 2-4 rounds for focused specs, 5-8 for complex reviews. If criticals aren't decreasing, consider stopping."
    }

    # Helper: read prior round metadata safely
    function _ReadMeta([string]$path) {
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        try { return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { return $null }
    }

    # Signal B: response size vs round 1
    if ($Round -gt 1) {
        $r1 = _ReadMeta (Join-Path $ReviewDir 'round-1-metadata.json')
        if ($r1) {
            $r1Chars = ($r1.reviewers | Where-Object { $_.content_ok -eq $true } | Select-Object -First 1).response_chars
            if ($r1Chars -and $r1Chars -gt 0) {
                $growth = [math]::Round((($CurrentResponseChars - $r1Chars) / $r1Chars) * 100)
                if ($growth -gt 20) {
                    $warnings += "[era] WARNING: Response size grew ${growth}% since round 1 ($r1Chars -> $CurrentResponseChars chars). Reviewer may be finding new issues from spec expansion rather than converging."
                }
            }
        }
    }

    # Signal C: response size vs prior round
    if ($Round -gt 2) {
        $prior = _ReadMeta (Join-Path $ReviewDir "round-$($Round - 1)-metadata.json")
        if ($prior) {
            $priorChars = ($prior.reviewers | Where-Object { $_.content_ok -eq $true } | Select-Object -First 1).response_chars
            if ($priorChars -and $priorChars -gt 0) {
                $growth = [math]::Round((($CurrentResponseChars - $priorChars) / $priorChars) * 100)
                if ($growth -gt 10) {
                    $warnings += "[era] WARNING: Response size grew ${growth}% since round $($Round - 1). Reviews should get shorter as issues are fixed."
                }
            }
        }
    }

    return $warnings
}

# --- Per-backend bundle-delivery preflight (2026-08-31) ---------------------
# Three consecutive 4-seat panels delivered 2 seats. Both causes were the same
# shape: the bundle was larger than the reviewer's delivery channel could carry,
# and NOTHING checked that before dispatch.
#
#   claude   : the bundle is INLINED via stdin. At 2,396,233 bytes the CLI
#              answered "Prompt is too long" and exited 1.
#   opencode : the bundle is ATTACHED via -f, and opencode silently truncates an
#              attached file at exactly 50 KiB. Above that era used to switch to
#              an agentic Read-tool prompt, which hangs (see backends/opencode.ps1).
#
# era's only pre-dispatch scale gate was the BROAD-bundle ceiling, which is
# (a) 10 MB — ~200x looser than the tightest backend it dispatches to, (b) a
# measure of PRE-BUNDLE SOURCE bytes rather than the bundle itself, and (c) only
# armed when no -IncludeFiles was passed. All three failing rounds were curated
# -IncludeFiles rounds, so the gate was not even loaded, let alone fired.
#
# This is the missing check: the ACTUAL bundle, against the ACTUAL limit of each
# seat's ACTUAL delivery channel.

function Get-EraBackendDelivery {
    <#
    .SYNOPSIS
        How does this backend physically get the bundle to the model, and what is
        the largest bundle that channel can carry?

        Returns @{ Mode; LimitBytes; LimitTokens; Basis } — a $null limit means
        "not bounded by this channel, or not measured"; those are reported but
        never refused, because inventing a ceiling is how you refuse a round that
        would have worked.

    .DESCRIPTION
        Modes:
          attach     opencode `-f`: the file is read by the CLI into the message.
          stdin      claude `--print`: the bytes are piped in as the prompt.
          inline-api the REST adapters: the bytes go in the request body.
          disk-read  agy: the model opens the file itself with its own tools.
                     VERIFIED 2026-09-02, because for two releases the adapter's
                     own prompt contradicted this line by telling the model "Do
                     NOT open, read, fetch, list, or run anything" (opus F12).
                     A bundle whose only content was a random sentinel absent
                     from the prompt came back as "SENTINEL=ZQ7X-39CEB86379E6 /
                     HOW=... viewing sentinel-bundle.xml on disk using the
                     view_file tool". This classification was right; the prompt
                     was wrong, and has been fixed. See
                     docs/assessments/2026-09-02-agy-disk-read-contradiction.md.

        A preset may override either limit via `max_bundle_bytes` /
        `max_bundle_tokens` in backends/_registry.json, so a newly measured
        ceiling is DATA, not a code change.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Backend,
        [hashtable]$ModelInfo = @{},
        # opencode is the one backend whose MODE depends on the bundle: at or under
        # 51,200 bytes it attaches, above that it reads the file with its own Read
        # tool. Reporting 'attach' for a read-tool round would make the summary lie
        # about the thing it exists to explain.
        [long]$BundleBytes = 0,
        # ERA_OPENCODE_READ_TOOL, resolved to 'attach' | 'read-tool' | $null.
        # WITHOUT THIS the plan decided mode from size alone while the adapter
        # honoured the env var, so ERA_OPENCODE_READ_TOOL=0 on a 300 KB bundle gave:
        # plan says read-tool / limit 1,048,576 / FITS, summary prints
        # via=read-tool, metadata records delivery_mode='read-tool' -- while the
        # model actually saw the first 50 KiB and returned a well-formed review of
        # 17% of the bundle. That is the exact silent-truncation failure the cap
        # exists to prevent, reachable through a documented escape hatch and
        # invisible to every new safeguard. All four seats of the 2026-08-31 panel
        # flagged it independently.
        [string]$ForcedOpencodeMode
    )
    $d = switch ($Backend) {
        'opencode' {
            $ocReadTool = if ($ForcedOpencodeMode -eq 'read-tool') { $true }
                          elseif ($ForcedOpencodeMode -eq 'attach') { $false }
                          else { $BundleBytes -gt 51200 }
            if ($ocReadTool) {
                @{ Mode = 'read-tool'; LimitBytes = 1048576; LimitTokens = $null; Kind = 'chosen'; TokensNotTunable = $true
                   # Verified end-to-end 2026-08-31 with canaries planted at 25/50/75%
                   # depth and reported back before the review, on both default
                   # opencode seats: 109,066 B (57s), 314,720 B (85s), 668,389 B
                   # (256s) -- full coverage every time. muse-spark has separately
                   # carried 2,396,233 B. 1 MB sits between measured and known-once.
                   # It is intermittent in a way not yet explained -- see
                   # backends/opencode.ps1 for the failure list and the concurrency
                   # hypothesis.
                   Basis = 'over the 51,200-byte attach cap opencode reads the bundle with its own Read tool; verified to 668,389 bytes on both seats 2026-08-31, ceiling set at 1,048,576' }
            } else {
                @{ Mode = 'attach'; LimitBytes = 51200; LimitTokens = $null; Kind = 'measured'; LimitFixed = $true; TokensNotTunable = $true
               # MEASURED, twice. 2026-08-03: DeepSeek V4 Flash reported its input
               # ending at line 1169 of a 9,234-line bundle; `head -1169` of that
               # file is 51,191 bytes and line 1170 crosses 51,200. 2026-08-31: a
               # 13,433-byte bundle returned a 7,957-byte review while a
               # 73,000-byte bundle on the same seat, same prompt, stalled out.
                   Basis = 'opencode silently truncates an attached file at exactly 50 KiB (measured 2026-08-03, re-confirmed 2026-08-31), so this is the cap for ATTACH delivery only' }
            }
        }
        'claude' {
            # MEASURED 2026-08-31 by bisection against the live CLI, replacing a
            # derived 150,000 that was ~4x too tight and was refusing rounds that
            # work. Method: slices of a real 2,396,233-byte bundle (3.369 bytes per
            # repomix token) piped to `claude --print --model claude-opus-5`, with a
            # unique CANARY appended at the very END of each slice and the prompt
            # asking only for the canary back. Echoing it proves the TAIL reached
            # the model -- "OK" would only have proved the request was ACCEPTED, and
            # `--autocompact` defaults to on, so a silently-compacted prompt is
            # exactly the failure this gate exists to prevent.
            #
            #   600,000 tok / 2,021,400 B   canary returned -- full prompt seen, 68s
            #   630,000 tok / 2,122,470 B   "Prompt is too long",  7s
            #   660,000 tok / 2,223,540 B   "Prompt is too long",  6s
            #   700,000 tok / 2,358,300 B   "Prompt is too long",  6s
            #   711,253 tok (the real 2026-08-30 round) "Prompt is too long"
            #
            # So the CLI ceiling is >=600,000 and <630,000 repomix tokens. It is NOT
            # the model's 1M API window -- `claude --print` gets appreciably less.
            # Rejection happens BEFORE inference (6s and unbilled, against 68s for
            # the accepted probe), which is what made bisecting affordable.
            #
            # 550,000 leaves ~8% under the measured accept point for the CLI's own
            # system prompt and tool definitions, which repomix's count cannot see.
            @{ Mode = 'stdin'; LimitBytes = $null; LimitTokens = 550000; Kind = 'measured'
               Basis = 'bundle is piped into `claude --print` as the prompt; measured 2026-08-31, the CLI accepts 600,000 and rejects 630,000 repomix tokens (550,000 keeps headroom for CLI overhead repomix cannot count)' }
        }
        'anthropic' {
            # NO ENFORCEABLE LIMIT, deliberately. This carried 750,000 tokens
            # "derived from a 1M window less ~25%" -- the identical derivation this
            # same release documents as having been ~4x wrong for the claude CLI,
            # and a direct violation of this function's own stated policy that an
            # unmeasured channel reports unknown and is NEVER refused. The claude
            # bisection is the evidence that the CLI/API relationship is not
            # derivable, so an invented number here is both unfalsifiable and live.
            # It stays $null until somebody measures it the way claude was measured.
            @{ Mode = 'inline-api'; LimitBytes = $null; LimitTokens = $null; Kind = 'derived'
               Basis = 'bundle is placed in the Messages API request body; this adapter''s real ceiling has not been measured (no API key on this host), so it is not enforced' }
        }
        'agy' {
            @{ Mode = 'disk-read'; LimitBytes = $null; LimitTokens = $null; Kind = 'none'
               Basis = 'agy opens the bundle from disk with its own tools (verified 2026-09-02 by sentinel probe); the channel imposes no size limit' }
        }
        default {
            # geminiapi / openaicompat and anything added later. The bytes go in a
            # request body, so a limit EXISTS — it is simply provider-specific and
            # unmeasured here. Say "unknown" rather than guess.
            @{ Mode = 'inline-api'; LimitBytes = $null; LimitTokens = $null; Kind = 'none'
               Basis = 'bundle is placed in the API request body; this provider''s context limit has not been measured' }
        }
    }
    # Registry overrides win: a measured number beats a derived one.
    # Registry overrides win: a measured number beats a derived one.
    # `if ($ModelInfo.max_bundle_bytes)` was wrong twice over -- 0 is FALSY, so a
    # deliberate "this channel can carry nothing" was silently ignored, and a
    # non-numeric value threw a raw cast error instead of era's clean preflight
    # shape (the same lesson ERA_BROAD_MAX_FILES already learned). Parse, don't cast.
    if (-not $d.ContainsKey('Kind')) { $d.Kind = 'none' }
    if ($ModelInfo) {
        foreach ($spec in @(@{ Key='max_bundle_bytes'; Field='LimitBytes' }, @{ Key='max_bundle_tokens'; Field='LimitTokens' })) {
            # A FIXED limit is a property of the TRANSPORT, not a tunable of the
            # preset, and a registry key must not appear to move it. opencode's
            # 51,200 attach cap is where opencode itself truncates; no registry
            # value changes that, and the adapter correctly overrides only its
            # read-tool ceiling (opencode.ps1). Before this guard the plan applied
            # the override to whichever mode was active, so on an attach round the
            # two disagreed about the same registry key -- D3's exact shape,
            # surviving D3's fix. The harmful direction is an override BELOW
            # 51,200: the plan refuses a round the adapter would have delivered,
            # which is the expensive error (it removes capability and looks like
            # correct behaviour). Found by the 2026-09-01 design panel.
            # OPENCODE IS BYTE-BOUNDED, AND max_bundle_tokens ON IT REFUSES IN THE
            # EXPENSIVE DIRECTION. The override loop applied the token key to every
            # backend, and Get-OpencodeDeliveryLimits reads only max_bundle_bytes --
            # so a token ceiling on an opencode preset made the PLAN refuse a round
            # the ADAPTER would have delivered. That is the error this function's
            # own docstring calls out ("inventing a ceiling is how you refuse a
            # round that would have worked"), reached through a registry key, and
            # it is D3's shape a third time: the same asymmetry the attach cap had
            # and then max_bundle_tokens had on claude, now one backend over.
            #
            # Both opencode seats of the 2026-09-01 twin-sweep panel named it
            # independently, and the 2026-09-01 audit panel had predicted the
            # class. Ignored with a NOTE that names the key which DOES work here.
            if ($spec.Field -eq 'LimitTokens' -and $d.TokensNotTunable) {
                if ($null -ne $ModelInfo[$spec.Key] -and "$($ModelInfo[$spec.Key])" -ne '') {
                    Write-Host "[era] NOTE: registry max_bundle_tokens is ignored for $Backend '$($d.Mode)' delivery — this channel is bounded in BYTES and no $Backend adapter reads a token ceiling, so enforcing one here would refuse rounds that work. Use max_bundle_bytes."
                }
                continue
            }
            if ($spec.Field -eq 'LimitBytes' -and $d.LimitFixed) {
                if ($null -ne $ModelInfo[$spec.Key] -and "$($ModelInfo[$spec.Key])" -ne '') {
                    Write-Host "[era] NOTE: registry max_bundle_bytes is ignored for $Backend '$($d.Mode)' delivery — $($d.LimitBytes) is where the transport itself truncates, not a preset tunable."
                }
                continue
            }
            $raw = $ModelInfo[$spec.Key]
            if ($null -eq $raw -or "$raw" -eq '') { continue }
            $parsed = [long]0
            if ([long]::TryParse("$raw", [ref]$parsed) -and $parsed -ge 0) {
                # RAISING a MEASURED ceiling replaces an experiment with a guess,
                # and the enforcement then lives downstream where it costs money:
                # no adapter reads max_bundle_tokens at all, so a raised token
                # ceiling means the plan says "fits" and the claude CLI answers
                # "Prompt is too long" AFTER the round is paid for on every other
                # seat. Lowering is always safe and stays quiet.
                #
                # Predicted by the 2026-09-01 audit panel as "the next plan/adapter
                # drift", and it was right: the same asymmetry the opencode attach
                # cap had, one backend over.
                $prev = $d[$spec.Field]
                if ($d.Kind -eq 'measured' -and $null -ne $prev -and $parsed -gt [long]$prev) {
                    # "nothing downstream enforces it" was too broad: the
                    # opencode adapter DOES honour max_bundle_bytes on its
                    # read-tool ceiling. It is true of max_bundle_tokens, which no
                    # adapter reads at all. Say which case this is.
                    $enforcement = if ($spec.Key -eq 'max_bundle_tokens') {
                        'no adapter reads a token ceiling at all'
                    } else {
                        'the adapter may or may not honour the new number'
                    }
                    Write-Host "[era] WARNING: registry $($spec.Key)=$parsed RAISES a measured ceiling of $prev for $Backend. The measurement is the thing that knows, and $enforcement, so an over-limit round can fail after it has been paid for. Lower it, or re-measure and update the basis."
                }
                $d[$spec.Field] = $parsed
                $d.Basis = "registry $($spec.Key)"
                # An operator-supplied number is a deliberate choice, and a chosen
                # ceiling is allowed to refuse. It is not a DERIVED one.
                $d.Kind  = 'chosen'
            } else {
                Write-Host "[era] WARNING: registry $($spec.Key)='$raw' is not a non-negative number; keeping the built-in limit."
            }
        }
    }
    return $d
}

function Get-EraBundleDeliveryPlan {
    <#
    .SYNOPSIS
        For each selected reviewer: how the bundle reaches it, and whether this
        bundle can possibly fit. Returns
        @{ Seats = @(...); OverCount; TightestBytes; Lines }.

    .DESCRIPTION
        Pure — no I/O, no dispatch — so it is cheap to call before the cost prompt
        and trivial to test. Each seat is
        @{ Preset; Backend; Mode; LimitBytes; LimitTokens; Ok; Reason; Basis }.

        `Ok = $false` means THIS SEAT CANNOT SUCCEED, not "might be slow". A seat
        whose channel has no measured limit is always Ok — an unmeasured ceiling
        must not become a refusal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ReviewerList,
        [Parameter(Mandatory)][hashtable]$Registry,
        [Parameter(Mandatory)][long]$BundleBytes,
        [int]$BundleTokens = 0
    )
    # Resolve the opencode delivery override ONCE, here, so every seat's predicted
    # mode matches what the adapter will actually do.
    $forcedOc = $null
    if ($env:ERA_OPENCODE_READ_TOOL) {
        $forcedOc = if ($env:ERA_OPENCODE_READ_TOOL -eq '0' -or $env:ERA_OPENCODE_READ_TOOL -eq 'false') { 'attach' } else { 'read-tool' }
    }
    $seats = foreach ($r in $ReviewerList) {
        $info = $Registry[$r]
        $backend = if ($info) { "$($info.backend)" } else { 'unknown' }
        $infoHash = @{}
        if ($info) { foreach ($k in @('max_bundle_bytes','max_bundle_tokens')) { if ($null -ne $info.$k) { $infoHash[$k] = $info.$k } } }
        $d = Get-EraBackendDelivery -Backend $backend -ModelInfo $infoHash -BundleBytes $BundleBytes -ForcedOpencodeMode $forcedOc

        # --- A DERIVED CEILING MAY NOT REFUSE (2026-09-01) --------------------
        # This rule already existed, in prose, in two places -- and had no
        # enforcement. `anthropic` once carried an enforceable 750,000 tokens
        # derived as "a 1M window less ~25%": the identical derivation that made
        # the claude ceiling 4x too tight, and a direct violation of this
        # function's own documented policy that an unmeasured channel is never
        # refused. It was fixed by hand, and nothing stopped the next one.
        #
        # So the policy is now a mechanism. `Kind` records HOW a limit was
        # arrived at, and only these may refuse:
        #
        #   measured  someone ran the experiment (51,200; the 600k/630k bracket)
        #   chosen    a deliberate policy number, including an operator's own
        #             registry override -- a choice is allowed to bind
        #
        # A `derived` limit -- inferred from a model's advertised window, a vendor
        # doc, or an analogy -- WARNS and lets the round proceed. Refusing on a
        # number nobody validated is how a gate removes capability while looking
        # like it is working, which is the expensive direction of this whole
        # subsystem. Measure it or do not enforce it.
        $ok = $true
        $reason = $null
        # Whitelist, not blacklist. This read `-eq 'derived'`, so any Kind that was
        # neither measured nor chosen -- 'none', or anything added later -- could
        # refuse a round while the comment above promised it could not. Unreachable
        # today (a 'none' channel carries no limit to exceed), and left that way on
        # purpose: the next Kind added should be advisory until someone decides
        # otherwise, not enforcing by default.
        $advisoryOnly = ($d.Kind -ne 'measured' -and $d.Kind -ne 'chosen')
        if ($null -ne $d.LimitBytes -and $BundleBytes -gt [long]$d.LimitBytes) {
            $ok = $false
            $reason = "bundle is $('{0:N0}' -f $BundleBytes) bytes; the $($d.Mode) channel carries at most $('{0:N0}' -f [long]$d.LimitBytes)"
        }
        elseif ($null -ne $d.LimitTokens -and $BundleTokens -gt [int]$d.LimitTokens) {
            $ok = $false
            $reason = "bundle is $('{0:N0}' -f $BundleTokens) tokens; the $($d.Mode) channel carries at most $('{0:N0}' -f [int]$d.LimitTokens)"
        }
        if (-not $ok -and $advisoryOnly) {
            Write-Host "[era] WARNING: $r would exceed a DERIVED ceiling ($reason). Dispatching anyway — a limit nobody measured does not get to refuse a round. Measure it and record it as 'measured', or leave it unenforced."
            $ok = $true
            $reason = $null
        }
        [pscustomobject]@{
            Preset = $r; Backend = $backend; Mode = $d.Mode
            LimitBytes = $d.LimitBytes; LimitTokens = $d.LimitTokens
            Ok = $ok; Reason = $reason; Basis = $d.Basis; Kind = $d.Kind
        }
    }
    $seats = @($seats)
    $overs = @($seats | Where-Object { -not $_.Ok })
    $byteLimits = @($seats | Where-Object { $null -ne $_.LimitBytes } | ForEach-Object { [long]$_.LimitBytes })
    $tightest = if ($byteLimits.Count) { ($byteLimits | Measure-Object -Minimum).Minimum } else { $null }

    $pad = ((@($seats.Preset) | Measure-Object -Property Length -Maximum).Maximum)
    if (-not $pad) { $pad = 12 }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("[era] Bundle delivery — $('{0:N0}' -f $BundleBytes) bytes / $('{0:N0}' -f $BundleTokens) tokens:")
    foreach ($s in $seats) {
        $limitText = if ($null -ne $s.LimitBytes)       { "limit $('{0:N0}' -f [long]$s.LimitBytes) bytes" }
                     elseif ($null -ne $s.LimitTokens)  { "limit $('{0:N0}' -f [int]$s.LimitTokens) tokens" }
                     else                               { 'no measured limit' }
        $verdict = if ($s.Ok) { 'fits' } else { 'CANNOT FIT' }
        $lines.Add(("[era]   {0}  via {1,-10} {2,-28} {3}" -f $s.Preset.PadRight($pad), $s.Mode, $limitText, $verdict))
    }
    return @{
        Seats = $seats; OverCount = $overs.Count; TightestBytes = $tightest
        Lines = @($lines)
    }
}

function Get-EraDeliveryModeMap {
    <#
    .SYNOPSIS
        Flatten a delivery plan to preset -> mode, for the round summary and the
        round metadata. A seat's delivery mode is the first thing you need to
        know when it fails, and it used to be readable only from backend source.
    #>
    [CmdletBinding()]
    param([hashtable]$Plan)
    $map = @{}
    if ($Plan -and $Plan.Seats) { foreach ($s in $Plan.Seats) { $map[$s.Preset] = $s.Mode } }
    return $map
}

# --- Citation grounding (2026-09-01) ----------------------------------------
# A reviewer reported muse-spark citing buy-routes.js:5891, :5360 and :3612 in a
# 2,834-line file, across two separate rounds. Its prose findings were often
# correct and twice genuinely novel -- the CITATIONS are what could not be
# trusted. That is the worst shape for a defect claim: a specific, checkable-
# looking reference that sends the reader to a line which does not exist, and a
# reader who checks one and finds nothing tends to discount the whole review.
#
# era already has everything needed to check this. The bundle is on disk, it is
# line-numbered, and a citation is `path:line`. So check it and say so, rather
# than asking every reader to.
#
# Advisory ONLY. A bad citation does not fail the round: the finding it decorates
# may still be real (measured: it repeatedly was), and demoting a usable review
# over a formatting fault would trade a real defect for a tidy artifact -- the
# exact trade this codebase's detector history says not to make.

function Get-EraBundleLineCounts {
    <#
    .SYNOPSIS
        path -> highest line number present, read from a repomix XML bundle.
        Returns an empty map if the bundle is unreadable or not line-numbered.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BundlePath)
    $counts = @{}
    if (-not (Test-Path -LiteralPath $BundlePath)) {
        Write-Host "[era] WARNING: citation grounding skipped -- no bundle at '$BundlePath'."
        return $counts
    }
    # [System.IO.File] resolves a RELATIVE path against the PROCESS working
    # directory, which Set-Location does not change. So Test-Path could succeed
    # (PowerShell-aware) while ReadLines below threw FileNotFound, and the catch
    # returned an empty map -- citation checking silently doing nothing, with
    # nothing saying so. Measured: relative path -> 0 files, absolute -> 6.
    # era itself always passes an absolute path, so this never fired in
    # production; it was one read error away from disabling the feature in
    # silence, which is the same fail-open shape as the token-count gate.
    $BundlePath = (Resolve-Path -LiteralPath $BundlePath).Path
    $current = $null
    try {
        foreach ($line in [System.IO.File]::ReadLines($BundlePath)) {
            if ($line -match '^<file path="([^"]+)">') { $current = $matches[1]; $counts[$current] = 0; continue }
            if ($line -match '^</file>') { $current = $null; continue }
            if ($current -and $line -match '^\s*(\d+):') {
                $n = [int]$matches[1]
                if ($n -gt $counts[$current]) { $counts[$current] = $n }
            }
        }
    } catch {
        # A read failure must not look like "this bundle has no files".
        Write-Host "[era] WARNING: citation grounding skipped -- could not read the bundle ($($_.Exception.Message))."
        return @{}
    }
    if ($counts.Count -eq 0) {
        Write-Host "[era] NOTE: citation grounding found no line-numbered files in the bundle; citations will not be checked this round."
    }
    return $counts
}

function Get-EraBundleFileSpans {
    <#
    .SYNOPSIS
        path -> @{ Lines; Start; End } for every file in a repomix XML bundle,
        where Start/End are BUNDLE-ABSOLUTE line numbers of the `<file>` and
        `</file>` markers.

    .DESCRIPTION
        THE SECOND COORDINATE SYSTEM, which nothing in this repo knew existed.

        A bundle prints per-file line numbers (`  471: $x = 1`), and every check
        era performs assumed a reviewer cites those. A seat on the READ-TOOL
        delivery path does not read the bundle through era -- it opens the file
        itself with its own Read tool, and that tool reports BUNDLE-ABSOLUTE line
        numbers. Some models cite what their tool told them.

        Measured over the ARCHIVE: 1,570 citations from 62 SEAT-RESPONSES across
        25 rounds -- every per-preset response whose round still has a bundle,
        each distinct `file:line` counted once per response, basename-unique
        files only. Months, five models. 128 of the 155 past end-of-file (83%)
        land inside that file's bundle span; 27 resolve in neither frame.

        THE POPULATION IS PART OF THE NUMBER. The blinded seat of the v2.8.2
        panel re-ran this against the same archive and got 498/67 -- because it
        counted rounds rather than seat-responses. Neither is wrong; a bare
        "1,570 citations" is. They were
        never inventions. (The fix was built on a 20-arm slice of one afternoon
        giving 79%; the archive figure supersedes it.) Spot-checked by hand:

            runtimes/resolve-model.ps1:1780   span 1611..1845  -> prints "169:",
            which is the `Sort-Object TierRank/SettingsValue` line the finding
            citing it was actually about.

        The translation is exact and needs no heuristic: for a file whose header
        sits at bundle line Start, bundle line B is in-file line (B - Start).

        This is separate from Get-EraBundleLineCounts rather than folded into it
        because that function's return shape (path -> int) is consumed in several
        places and by the -BlindSeat line-preservation test.

        WHAT THIS CANNOT SEE, AND IT IS NOT SMALL. The two frames OVERLAP. For a
        file whose span starts at S with N printed lines, every bundle coordinate
        in S+1..min(End,N) is also a valid in-file line number for the same file,
        so a citation there is ambiguous and no arithmetic resolves it -- the
        classifier accepts it as in-file and it silently points at the wrong line.
        Only citations PAST end-of-file are unambiguous, and those are the only
        ones this ever sees.

        RE-DERIVED 2026-09-02, BOTH WAYS, because the `L?` above changed what
        this function can see and every figure below was measured without it.
        Same scanner, same archive, the only difference the regex:

                              checked   flagged   frame   frame/flagged   overlap
          without `L?`          1,578       155     128           82.6%   211 (13.4%)
          with    `L?`          1,642       178     151           84.8%   218 (13.3%)

        The first row reproduces the published v2.8.2 figures (1,570 / 155 / 128
        / 83% / 203 / 12.9%) to within eight citations, which is the corpus
        boundary and not a disagreement. The second row is what the checker sees
        now. THE CONCLUSIONS DO NOT MOVE: the share of flagged citations that are
        a coordinate frame rather than a fabrication goes 83% -> 85%, and the
        blind spot stays at 13%. What moves is the absolute counts, upward, and
        every "N of 1,570" written before this date is a pre-`L?` number.

        Measured over the same 62-round archive: 203 of 1,570 citations (12.9%)
        sit in that overlap. So "83% of flagged citations were the wrong frame"
        is a rate over the FLAGGED set and must not be read as "83% of frame
        errors are now handled" -- the in-range half is invisible, to this code
        and to the measurement that motivated it.

        Raised by the opus seat of the v2.8.2 panel, which called the 83% "a
        coincidence rate over an already-flagged set". It is right. Resolving the
        overlap would need the cited line's CONTENT checked against what the
        finding says about it, which is a different and much larger instrument.

        HOW BIG IS THE BLIND SPOT, REALLY: SMALLER THAN 12.9%. The frame is a
        property of the SEAT, not of the citation, so the overlap can be bounded
        by asking whether a response uses the bundle frame anywhere it IS
        visible. Measured over the same archive:

            203 ambiguous citations in 62 seat-responses
             40 in the 17 responses that demonstrably use the bundle frame   <- suspect
            163 in the 45 responses that never use it                        <- almost certainly in-file

        So the at-risk population is ~40 of 1,570 (2.5%), not 203 (12.9%), and
        even those are suspect rather than known wrong. That is why no inference
        machinery was built: it would resolve at most a fifth of an already small
        blind spot, into an advisory on an advisory. (The bound is itself inferred
        from the visible half -- a response that used the frame ONLY inside the
        overlap is undetectable by construction -- so 12.9% remains the honest
        ceiling and 2.5% the honest estimate.)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BundlePath)
    $spans = @{}
    if (-not (Test-Path -LiteralPath $BundlePath)) {
        Write-Host "[era] WARNING: citation frame check skipped -- no bundle at '$BundlePath'."
        return $spans
    }
    $BundlePath = (Resolve-Path -LiteralPath $BundlePath).Path
    $current = $null; $n = 0
    try {
        foreach ($line in [System.IO.File]::ReadLines($BundlePath)) {
            $n++
            if ($line -match '^<file path="([^"]+)">') { $current = $matches[1]; $spans[$current] = @{ Lines = 0; Start = $n; End = 0 }; continue }
            if ($line -match '^</file>') { if ($current) { $spans[$current].End = $n }; $current = $null; continue }
            if ($current -and $line -match '^\s*(\d+):') {
                $k = [int]$matches[1]
                if ($k -gt $spans[$current].Lines) { $spans[$current].Lines = $k }
            }
        }
    } catch {
        Write-Host "[era] WARNING: citation frame check skipped -- could not read the bundle ($($_.Exception.Message))."
        return @{}
    }
    return $spans
}

function Test-EraResponseCitations {
    <#
    .SYNOPSIS
        Check `path:line` citations in a review against the bundle it reviewed.
        Returns @{ Checked; OutOfRange; BundleCoordinate; Unresolved; Lines }.

        BundleCoordinate is the citation that names the right file and a line
        number from the BUNDLE's frame rather than the file's -- resolvable, and
        reported translated. See Get-EraBundleFileSpans for the measurement.

    .DESCRIPTION
        OutOfRange is the load-bearing one: the file IS in the bundle and the
        cited line is past its end, so the citation cannot be real. Unresolved
        (a path not in the bundle) is reported separately and much more quietly --
        a reviewer may legitimately name a file it was told about rather than one
        it was given, and basename collisions across directories are common.

        Matching is by BASENAME. Reviewers cite `buy-routes.js:5891` as often as
        the full repo-relative path, and a basename that is unique in the bundle
        is unambiguous. A basename appearing at more than one path is skipped
        rather than guessed -- an over-eager checker that cries wolf on a correct
        citation is worse than no checker.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Response,
        [Parameter(Mandatory)][hashtable]$LineCounts,
        # From Get-EraBundleFileSpans. Optional, and everything behaves exactly as
        # before without it -- but with it, a citation past end-of-file that lands
        # inside the named file's BUNDLE span is reported as a coordinate-frame
        # mismatch and translated, instead of being called a fabrication. That was
        # 79% of every "fabricated" citation this checker has ever reported.
        [hashtable]$FileSpans = @{}
    )
    $result = @{ Checked = 0; OutOfRange = @(); BundleCoordinate = @(); Unresolved = @(); Lines = @() }
    if (-not $Response -or $LineCounts.Count -eq 0) { return $result }

    # basename -> line count, only where the basename is UNIQUE in the bundle.
    $byBase = @{}
    foreach ($p in $LineCounts.Keys) {
        $b = ($p -split '[\\/]')[-1]
        if ($byBase.ContainsKey($b)) { $byBase[$b] = $null } else { $byBase[$b] = $LineCounts[$p] }
    }

    # basename -> span, on the same unique-basename rule.
    $spanByBase = @{}
    foreach ($p in $FileSpans.Keys) {
        $b = ($p -split '[\\/]')[-1]
        if ($spanByBase.ContainsKey($b)) { $spanByBase[$b] = $null } else { $spanByBase[$b] = $FileSpans[$p] }
    }

    $bad = [System.Collections.Generic.List[string]]::new()
    $frame = [System.Collections.Generic.List[string]]::new()
    $unk = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    # `:L207` AS WELL AS `:207`. Some models write GitHub anchor form -- and it is
    # not a random preference: EVERY L-form citation in the 108-response archive
    # came from an agy seat (`gemini`, `gemini-pro-high`), the seats on the
    # disk-read path, which are the ones most prone to the coordinate-frame error
    # in the first place. So the checker was blindest exactly where it was needed.
    #
    # MEASURED over the whole archive, accepting `L?`:
    #
    #   seat              checked          flagged past-EOF   of those, frame
    #   gemini            190 -> 248       11 -> 28           11 -> 28
    #   gemini-pro-high    16 ->  22       16 -> 22           11 -> 17
    #
    # 138 citations were invisible; 7 distinct responses scored Checked=0 and were
    # indistinguishable from a clean review. Every newly flagged citation on the
    # `gemini` seat is a frame error (28 of 28) and NOT ONE is a new fabrication
    # report -- gemini-pro-high's non-frame residue stays at 5 either way. So the
    # v2.8.2 measurement that established the frame problem was undercounting
    # the `gemini` seat's FLAGGED citations by ~61% (11 of the 28 that exist),
    # through the checker's own regex rather than through the models. SCOPED
    # PROPERLY, which the first cut of this comment was not: 61% is that ONE
    # seat. Both agy seats together go 27 -> 50, an undercount of ~46%. Citations
    # CHECKED were low by ~23% on `gemini` (190 of 248).
    #
    # WHAT THIS WIDENING COSTS, stated because both the gemini and muse-spark
    # seats of the 2026-09-02 panel raised it and neither could name an instance:
    # `L?` makes prose like "see notes.md:L10 for the permalink" a citation. That
    # class is NOT new -- `notes.md:10` was already matched -- but the anchor form
    # is a second spelling of it, and a bundled file cited that way past its end
    # would be reported as out-of-range. Zero such cases exist in the 108-response
    # archive (no seat gained a single new non-frame flag), which is evidence
    # about this corpus and not a proof about the next one. The checker is
    # advisory by design and an Unresolved path is reported quietly, so the cost
    # of the failure it can now make is bounded at one advisory line.
    #
    # THE DEDUPE KEY IS path + line NUMBER, so `only.js:L12` and `only.js:12`
    # collapse to one citation. Both seats flagged that as potentially conflating
    # two coordinate frames. Measured across the archive: 4 collisions, in one
    # distinct response, and all four are the link-text/anchor pair carrying the
    # SAME number (`workflow.ps1:146` beside `workflow.ps1:L146`) -- exactly the
    # case where merging is correct. Where the two frames genuinely differ, the
    # numbers differ and no collision occurs. Left as is, with the count.
    foreach ($m in [regex]::Matches($Response, '(?<path>[A-Za-z0-9_.\-/\\]+\.[A-Za-z0-9]{1,8}):L?(?<line>\d{1,7})\b')) {
        $cited = $m.Groups['path'].Value
        $lineNo = [int]$m.Groups['line'].Value
        $key = "$cited`:$lineNo"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $base = ($cited -split '[\\/]')[-1]
        if (-not $byBase.ContainsKey($base)) { $unk.Add($key); continue }
        $max = $byBase[$base]
        if ($null -eq $max) { continue }   # ambiguous basename -- do not guess
        $result.Checked++
        if ($lineNo -le $max) { continue }
        # Past end-of-file. Before calling it invented, ask whether it is the
        # bundle's own frame: the read-tool delivery path hands the model a file
        # whose line numbers ARE bundle-absolute, and some models cite those.
        $sp = if ($spanByBase.ContainsKey($base)) { $spanByBase[$base] } else { $null }
        if ($sp -and $sp.Start -gt 0 -and $sp.End -gt 0 -and $lineNo -gt $sp.Start -and $lineNo -lt $sp.End) {
            $inFile = $lineNo - $sp.Start
            # Echo the path the reviewer wrote, so the translated citation can be
            # pasted straight into an editor.
            $frame.Add("$key -> $cited`:$inFile (bundle line $lineNo; the file has $max lines)")
        } else {
            $bad.Add("$key (file has $max lines)")
        }
    }
    $result.OutOfRange       = @($bad)
    $result.BundleCoordinate = @($frame)
    $result.Unresolved       = @($unk)

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($result.BundleCoordinate.Count -gt 0) {
        # NOT a fabrication, and saying so matters: the seat this used to accuse
        # most loudly was pointing at the right code in the bundle's own frame.
        $lines.Add("  $($result.BundleCoordinate.Count) of $($result.Checked) citation(s) use BUNDLE line numbers rather than the file's own — resolvable, not invented (a read-tool seat cites what its Read tool reported). Translated:")
        foreach ($f in ($result.BundleCoordinate | Select-Object -First 6)) { $lines.Add("    $f") }
        if ($result.BundleCoordinate.Count -gt 6) { $lines.Add("    ... and $($result.BundleCoordinate.Count - 6) more") }
    }
    if ($result.OutOfRange.Count -gt 0) {
        $lines.Add("  $($result.OutOfRange.Count) of $($result.Checked) checkable citation(s) point past the end of the cited file:")
        foreach ($b in ($result.OutOfRange | Select-Object -First 6)) { $lines.Add("    $b") }
        if ($result.OutOfRange.Count -gt 6) { $lines.Add("    ... and $($result.OutOfRange.Count - 6) more") }
        $lines.Add("  The findings may still be real — treat the line numbers, not the reasoning, as unreliable.")
    }
    $result.Lines = @($lines)
    return $result
}

# --- Comment-stripped bundle for one seat (2026-09-01) -----------------------
# Proposed by opus in the design panel, and the only idea in that round that no
# other seat raised.
#
# THE ARGUMENT. This codebase's comments are unusually strong -- non-obvious
# decisions carry the measurement that produced them -- and that is exactly why a
# WRONG one is dangerous: it is persuasive. The 150,000-token ceiling that was 4x
# too tight came with a confident explanation of its own derivation, and every
# reviewer that read it inherited that premise before forming its own. A bare
# `150000` invites "where did this number come from?"; an explained `150000`
# suppresses the question. That is not a reviewer weakness -- it is the comment
# doing its job.
#
# So: give ONE seat the code with the narrative removed. It attacks premise
# blindness directly, costs one seat per round, and unlike a coverage probe it
# does not mutate the artifact the OTHER seats review.
#
# WHY NOT repomix's own --remove-comments. Checked against 1.12.0: its
# StripCommentsManipulator covers 33 extensions and `.ps1` is not among them
# (core/file/fileManipulate.js). This skill is almost entirely PowerShell, so the
# native option is a no-op on precisely the files that matter here.
#
# LINE NUMBERS ARE PRESERVED, deliberately and load-bearingly. Deleting comment
# lines would shift every line after them, and era now validates `file:line`
# citations against the bundle -- so a stripped seat would have every citation
# flagged as fabricated. The comment TEXT goes; the numbered line stays.

function Remove-EraBundleComments {
    <#
    .SYNOPSIS
        Copy a repomix XML bundle with whole-line comments blanked, preserving
        every line number and the file structure. Returns the output path.

    .DESCRIPTION
        Only lines whose FIRST non-whitespace character begins a comment are
        blanked. A trailing comment after code survives -- stripping those needs a
        real parser, and mangling a `#` inside a string literal would corrupt the
        code under review, which is a worse failure than leaving a comment.

        Block comments are tracked per file, for PowerShell, the C family, CSS,
        SQL, Python triple-quotes and HTML/Markdown. The exact delimiter pairs are
        in $blockPairs below rather than written out here: a literal PowerShell
        block-comment terminator inside this very docstring closes it early, which
        it duly did on the first attempt. Coverage is deliberately partial, and
        this says so rather than the code pretending otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $lineMarkers = @{
        '.ps1'='#'; '.psm1'='#'; '.psd1'='#'; '.py'='#'; '.sh'='#'; '.bash'='#'; '.rb'='#'
        '.yml'='#'; '.yaml'='#'; '.toml'='#'; '.r'='#'; '.pl'='#'
        '.js'='//'; '.ts'='//'; '.jsx'='//'; '.tsx'='//'; '.go'='//'; '.java'='//'; '.c'='//'
        '.cpp'='//'; '.h'='//'; '.hpp'='//'; '.cs'='//'; '.rs'='//'; '.kt'='//'; '.swift'='//'
        '.php'='//'; '.sol'='//'; '.dart'='//'; '.scala'='//'
        '.sql'='--'; '.lua'='--'
    }
    $blockPairs = @{
        '.ps1'=@('<#','#>'); '.psm1'=@('<#','#>')
        '.js'=@('/*','*/'); '.ts'=@('/*','*/'); '.jsx'=@('/*','*/'); '.tsx'=@('/*','*/')
        '.go'=@('/*','*/'); '.java'=@('/*','*/'); '.c'=@('/*','*/'); '.cpp'=@('/*','*/')
        '.h'=@('/*','*/'); '.hpp'=@('/*','*/'); '.cs'=@('/*','*/'); '.rs'=@('/*','*/')
        '.css'=@('/*','*/'); '.scss'=@('/*','*/'); '.less'=@('/*','*/'); '.sql'=@('/*','*/')
        '.md'=@('<!--','-->'); '.html'=@('<!--','-->'); '.xml'=@('<!--','-->'); '.vue'=@('<!--','-->')
    }
    # SAME RESOLUTION THE CITATION READER DOES, and for the same reason.
    # Get-EraBundleLineCounts got this eleven lines up the file after a fail-open
    # was found in it; this function reads the same bundle with the same API and
    # was left as it was. [System.IO.File] resolves a RELATIVE path against the
    # PROCESS working directory, which Set-Location / Push-Location do not
    # change -- and era.ps1 does Push-Location $repoRoot. era itself always
    # passes absolute paths, so this has never fired in production; it is the
    # twin, not a new bug, and it is fixed here so the pair stops disagreeing.
    # $OutputPath does not exist yet, so it cannot use Resolve-Path.
    #
    # THIS THROWS WHERE Get-EraBundleLineCounts WARNS, deliberately, and the two
    # sit eleven lines apart with one root cause -- so the asymmetry is stated
    # rather than left to look like an oversight (raised by the blinded seat of
    # the twin-sweep panel). Citation grounding is ADVISORY: losing it degrades a
    # round that is otherwise fine, so it warns and carries on. The stripped
    # bundle is the INDEPENDENT VARIABLE of an A/B: producing it silently wrong,
    # or not at all while the round proceeds, does not degrade the experiment, it
    # invalidates it. This runs after repomix and before any dispatch, so a
    # refusal here costs nothing.
    if (-not (Test-Path -LiteralPath $BundlePath)) {
        throw ("Remove-EraBundleComments: no bundle at '$BundlePath', so the -BlindSeat arm cannot be built. " +
               "Refusing rather than dispatching an unblinded round that would be recorded as blinded. " +
               "Nothing was dispatched and nothing was spent.")
    }
    $BundlePath = (Resolve-Path -LiteralPath $BundlePath).Path
    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

    $stripped = 0
    $out = [System.Collections.Generic.List[string]]::new()
    $ext = ''; $inBlock = $false; $blockEnd = $null

    foreach ($line in [System.IO.File]::ReadLines($BundlePath)) {
        if ($line -match '^<file path="([^"]+)">') {
            $ext = [System.IO.Path]::GetExtension($matches[1]).ToLowerInvariant()
            $inBlock = $false; $blockEnd = $null
            $out.Add($line); continue
        }
        if ($line -match '^</file>') { $inBlock = $false; $out.Add($line); continue }

        # Content lines are `  <n>: <text>`; anything else is bundle scaffolding.
        if (-not ($line -match '^(\s*)(\d+):(.*)$')) { $out.Add($line); continue }
        $prefix = "$($matches[1])$($matches[2]):"
        $body   = $matches[3]
        $trim   = $body.TrimStart()

        if ($inBlock) {
            # THE MIRROR OF THE v2.6.1 BUG. That fix stopped a block OPENER with
            # code after the closer being treated as a comment line. This is the
            # same shape at the other end: a line that CLOSES a block and then
            # carries code -- `*/ doSomething();` -- was blanked wholesale,
            # deleting the code. Found by the first panel pointed at this file,
            # which is also how the opener case was found.
            $closeAt = if ($blockEnd) { $body.IndexOf($blockEnd) } else { -1 }
            if ($closeAt -ge 0) {
                $inBlock = $false
                $tail = $body.Substring($closeAt + $blockEnd.Length)
                $blockEnd = $null
                if ($tail.Trim()) { $stripped++; $out.Add($prefix + $tail); continue }
            }
            $stripped++
            $out.Add($prefix); continue
        }
        $isComment = $false
        $lm = $lineMarkers[$ext]
        if ($lm -and $trim.StartsWith($lm)) { $isComment = $true }
        $bp = $blockPairs[$ext]
        if (-not $isComment -and $bp -and $trim.StartsWith($bp[0])) {
            $after = $trim.Substring($bp[0].Length)
            $closeAt = $after.IndexOf($bp[1])
            if ($closeAt -lt 0) {
                # Opens a block that runs past this line.
                $isComment = $true; $inBlock = $true; $blockEnd = $bp[1]
            }
            elseif ($after.Substring($closeAt + $bp[1].Length).Trim()) {
                # OPENS AND CLOSES ON THIS LINE, WITH CODE AFTER THE CLOSER. Not a
                # comment line at all -- blanking it deletes real code.
                #
                # Caught by using the feature: `-BlindSeat` on a real JS server
                # blanked three lines of the form
                #
                #     /** @type {*} */ (this.browserManager.browserInstance).isConnected()
                #
                # leaving `x &&` dangling above a `) {`, and the blinded reviewer
                # opened its review by saying the expression was unreadable. An
                # inline type annotation is a block comment whose whole purpose is
                # to sit in front of code on the same line.
                #
                # This is the failure the docstring already warned about for the
                # LINE-marker case (a `#` inside a string) and did not guard for
                # the BLOCK-opener case. Leaving the line whole keeps a fragment of
                # narrative in the bundle, which is the safe direction: a surviving
                # comment weakens the experiment, a deleted expression corrupts the
                # code under review.
                $isComment = $false
            }
            else {
                # Opens and closes with nothing after it -- a real comment line.
                $isComment = $true
            }
        }
        # PYTHON TRIPLE-QUOTES ARE DELIBERATELY NOT HANDLED.
        #
        # They were, and it deleted code. A line scanner cannot tell an OPENING
        # docstring delimiter from a CLOSING one, and the common shape
        #
        #     x = """some
        #     multi-line string"""
        #
        # opens on a line that does NOT start with the delimiter and closes on one
        # that does -- so the closer was read as an opener, started a phantom
        # block, and everything after it was blanked until the next quote. Three
        # reviewers flagged it independently.
        #
        # Distinguishing them needs a parser that tracks string state, which is
        # far more machinery than this filter should carry. A `#` comment in a
        # .py file is still stripped; a docstring survives. A surviving comment
        # weakens the experiment, a deleted expression corrupts the code under
        # review, and only one of those is acceptable.
        if ($isComment) { $stripped++; $out.Add($prefix) } else { $out.Add($line) }
    }
    [System.IO.File]::WriteAllLines($OutputPath, $out)
    Write-Host "[era] Comment-stripped bundle: $stripped comment line(s) blanked, line numbers preserved -> $([System.IO.Path]::GetFileName($OutputPath))"
    return $OutputPath
}

function Resolve-EraRepomixCommand {
    <#
    .SYNOPSIS
        Turn a resolved `repomix` command into something Start-Process can spawn
        under a killable handle.

    .DESCRIPTION
        This is the reason repomix kept using Start-ThreadJob: on Windows npm
        installs shims, and `Get-Command repomix` resolves to repomix.ps1 (an
        ExternalScript), which CreateProcess cannot execute. Measured on this box
        the npm directory holds all three of `repomix`, `repomix.cmd` and
        `repomix.ps1`, so preferring the sibling .cmd avoids nesting a second
        pwsh just to reach node.

        Pure function -- takes the already-resolved source and command type so it
        can be unit-tested without an install.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [string]$CommandType = 'Application'
    )
    $ext = [System.IO.Path]::GetExtension($Source)

    if ($ext -in @('.cmd', '.bat')) {
        return @{ FilePath = $env:ComSpec; Arguments = @('/c', $Source) }
    }

    # Extension-driven, NOT CommandType-driven. A reviewer claimed POSIX shims
    # were routed through `pwsh -File`; measured, they are not, because their
    # CommandType is Application. But ORing on CommandType would have misrouted
    # an ExternalScript that is not a .ps1 — on Linux that is a plain shell
    # script and must run directly. Require the extension.
    if ($ext -eq '.ps1') {
        # Prefer a sibling .cmd: one less process, and no pwsh startup cost.
        $sibling = Join-Path (Split-Path -Parent $Source) 'repomix.cmd'
        if ($env:ComSpec -and (Test-Path -LiteralPath $sibling)) {
            return @{ FilePath = $env:ComSpec; Arguments = @('/c', $sibling) }
        }
        $pwshPath = (Get-Process -Id $PID).Path
        if (-not $pwshPath) { $pwshPath = 'pwsh' }
        return @{ FilePath = $pwshPath; Arguments = @('-NoProfile', '-File', $Source) }
    }

    # A real executable (or a POSIX shim) runs directly.
    return @{ FilePath = $Source; Arguments = @() }
}

function Invoke-EraTrackedProcess {
    <#
    .SYNOPSIS
        Run a child process under a handle we can tree-kill, capturing output to
        files so a timeout still yields diagnostics.

    .DESCRIPTION
        Replaces Start-ThreadJob + Wait-Job + Stop-Job for native children.
        Stop-Job ends the THREAD; the spawned process keeps running. The adapters
        already use Process.Kill($true) for exactly this reason -- an invariant
        tests/ProcessTreeKill.Tests.ps1 asserts across agy/claude/opencode.

        Output is redirected to temp files rather than buffered in the child, so
        on a timeout the partial output is on disk and readable. The old
        Receive-Job drain could never return anything: the ThreadJob body
        captured everything into a local and emitted nothing until completion.

        Returns @{ Output; ExitCode; TimedOut; ProcessId; StdOutPath }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [int]$TimeoutSec = 300
    )
    $stamp = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    $outPath = Join-Path ([System.IO.Path]::GetTempPath()) "era-proc-$stamp.out"
    $errPath = Join-Path ([System.IO.Path]::GetTempPath()) "era-proc-$stamp.err"

    $startArgs = @{
        FilePath               = $FilePath
        WorkingDirectory       = $WorkingDirectory
        NoNewWindow            = $true
        PassThru               = $true
        RedirectStandardOutput = $outPath
        RedirectStandardError  = $errPath
    }
    # Quote anything containing whitespace. Start-Process joins -ArgumentList
    # with spaces WITHOUT quoting, so a config path or npm prefix containing a
    # space silently split into two arguments and broke the child process.
    if ($Arguments -and $Arguments.Count -gt 0) {
        $quoted = @($Arguments | ForEach-Object {
            $a = "$_"
            if ($a -match '\s' -and $a -notmatch '^".*"$') { '"' + $a + '"' } else { $a }
        })
        # cmd.exe needs special handling: it strips the OUTERMOST quote pair of
        # everything after /c. With two quoted arguments -- the real repomix
        # shape, `cmd /c "<shim>" -c "<config>"` -- that mangles the command into
        # an unrecognised program. Measured directly. `/s` plus a single outer
        # quote pair tells cmd to strip exactly that pair and use the rest
        # verbatim. A one-quoted-argument test passes either way, which is how
        # this shipped broken.
        # Only when there is MORE than one argument after /c. A single argument
        # is already a complete command string ("ping -n 30 127.0.0.1"); wrapping
        # that again produces ""ping -n 30 ..."" and cmd tries to execute a
        # program with that literal name.
        if ($env:ComSpec -and $FilePath -eq $env:ComSpec -and $quoted.Count -gt 2 -and $quoted[0] -eq '/c') {
            $inner = ($quoted[1..($quoted.Count - 1)] -join ' ')
            $quoted = @('/s', '/c', '"' + $inner + '"')
        }
        $startArgs['ArgumentList'] = $quoted
    }

    $proc = Start-Process @startArgs
    $procId = $proc.Id
    $timedOut = $false
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        # $true = tree-kill. Killing only the parent would leave node running,
        # which is the whole defect this replaces.
        try { $proc.Kill($true) } catch { }
        try { $null = $proc.WaitForExit(10000) } catch { }
    }

    $readBoth = {
        param($o, $e)
        $t = ''
        foreach ($p in @($o, $e)) {
            if (Test-Path -LiteralPath $p) {
                $c = Get-Content -Raw -LiteralPath $p -ErrorAction SilentlyContinue
                if ($c) { $t += $c }
            }
        }
        return $t
    }
    $output = & $readBoth $outPath $errPath

    $exitCode = if ($timedOut) { -1 } else { try { $proc.ExitCode } catch { -1 } }

    Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue

    return @{
        Output     = $output
        ExitCode   = $exitCode
        TimedOut   = $timedOut
        ProcessId  = $procId
        StdOutPath = $outPath
    }
}

function Invoke-EraRepomix {
    <#
    .SYNOPSIS
        Run repomix against a config under a killable handle.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [int]$TimeoutSec = 300
    )
    $cmd = Get-Command repomix -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return @{ Output = ''; ExitCode = -1; TimedOut = $false; ProcessId = 0
                  Error = 'repomix not found (is it installed? try: npm install -g repomix)' }
    }
    $resolved = Resolve-EraRepomixCommand -Source $cmd.Source -CommandType "$($cmd.CommandType)"
    return Invoke-EraTrackedProcess -FilePath $resolved.FilePath `
        -Arguments (@($resolved.Arguments) + @('-c', $ConfigPath)) `
        -WorkingDirectory $RepoRoot -TimeoutSec $TimeoutSec
}

function Get-EraPorcelainPaths {
    <#
    .SYNOPSIS
        Changed-file paths from `git status`, parsed correctly.

    .DESCRIPTION
        The old parse stripped three characters and kept the remainder, so a
        rename 'R  old -> new' yielded the non-path 'old -> new', and
        core.quotePath wrapped non-ASCII names in quotes that survived into the
        path. Both then failed Test-Path with a confusing "paths not found".

        --porcelain -z emits NUL-terminated records with no quoting and no
        escaping. Measured on this box, a rename emits TWO fields, destination
        first:
            [R  new.md]  [old.md]  [?? probe.ps1]  [?? untracked.md]
        So for an R or C status, skip the following field -- it is the source
        path, which no longer exists and would fail Test-Path downstream.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @() }

    Push-Location $RepoRoot
    try {
        $raw = (& git status --porcelain -z 2>$null) -join ''
    } catch {
        return @()
    } finally {
        Pop-Location
    }
    if ([string]::IsNullOrEmpty($raw)) { return @() }

    $fields = @($raw -split "`0" | Where-Object { $_ -ne '' })
    $paths  = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $fields.Count; $i++) {
        $rec = $fields[$i]
        if ($rec.Length -lt 4) { continue }
        $xy   = $rec.Substring(0, 2)
        $path = $rec.Substring(3).Trim()
        if ($path) { $paths.Add($path) }
        # Rename/copy records carry a second field: the source path.
        if ($xy -match '[RC]') { $i++ }
    }
    return @($paths)
}

function Test-EraPathInsideRoot {
    <#
    .SYNOPSIS
        Boundary-aware containment test: is $Path the same as, or beneath, $Root?

    .DESCRIPTION
        Replaces `$p.StartsWith($root, OrdinalIgnoreCase)`, which has no
        directory-separator boundary. Measured 2026-08-09: with repo root
        C:\a\era-p6, the SIBLING C:\a\era-p6-ext\outside.md tested as inside and
        was relativized to '-ext/outside.md', which then failed Test-Path. The
        old guard failed closed, so the harm was silent loss of an explicitly
        requested file rather than exfiltration.

        Pure string comparison after normalisation -- no filesystem access, so it
        works for paths that do not exist yet.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }

    function Get-Normalized([string]$p) {
        $n = $p
        try { $n = [System.IO.Path]::GetFullPath($p) } catch { }
        return ($n -replace '\\', '/').TrimEnd('/')
    }

    $normPath = Get-Normalized $Path
    $normRoot = Get-Normalized $Root
    if ($normRoot.Length -eq 0) { return $false }

    if ([string]::Equals($normPath, $normRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $normPath.StartsWith($normRoot + '/', [System.StringComparison]::OrdinalIgnoreCase)
}

function Write-ReviewMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$Round,
        [Parameter(Mandatory)][string]$TopicSlug,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][hashtable]$Results,
        [Parameter(Mandatory)][hashtable]$Registry,
        [Parameter(Mandatory)][int]$BundleTokens,
        # Per-preset model overrides resolved by era.ps1 (-Model hint).
        # When present, the metadata records the resolved model_id rather than
        # the preset's registry default -- otherwise cost dashboards and audit
        # logs lie about which model actually ran.
        [hashtable]$ModelOverrides = @{},
        [string[]]$ConvergenceWarnings = @(),
        # Cap breaches noticed before dispatch. Advisory (see Get-EraCostReport),
        # so they must survive into the record even though nothing blocked.
        [string[]]$CostWarnings = @(),
        # Citations that point past the end of the file they name. Advisory, but
        # they belong in the round's own telemetry: they were console-only, so the
        # one durable record of a reviewer inventing line numbers was a line in a
        # terminal that nobody keeps.
        [string[]]$CitationWarnings = @(),
        # The Compare-EraSeatContainment verdict for this round, or $null when
        # the caller ran no check. Console-only was where citation_warnings
        # started too, and the reason given for moving them applies unchanged:
        # a seat writing to the repo under review must not have its only record
        # be a line in a terminal that nobody keeps.
        $SeatContainment = $null,
        [string[]]$IncludeFilesList = @(),
        [int]$BundleFileCount = 0,
        [int]$TopicRoundCount = 0,
        # preset -> delivery mode, from Get-EraBundleDeliveryPlan. Recorded per
        # reviewer so a post-mortem can answer "how did the bundle reach this
        # seat" from the round's own telemetry instead of from backend source.
        [hashtable]$DeliveryModes = @{},
        # Size of the bundle actually shipped. bundle_tokens was recorded and
        # bundle BYTES were not, which is the unit two of the four channels are
        # actually limited in.
        [long]$BundleBytes = 0,
        # preset -> alternate bundle path, from -BlindSeat. THE ARM LABEL OF THE
        # EXPERIMENT. Which seat read the comment-stripped bundle existed only in
        # a console line and in the prose of the assessment that scored it, so a
        # later reader could not check a round's arms against its own record --
        # and nothing stopped the sighted arm being scored as the blind one.
        # Same failure as the citation warnings, which were console-only until
        # v2.6 recorded them.
        [hashtable]$BundleOverrides = @{}
    )
    $reviewerEntries = foreach ($preset in $Results.Keys) {
        $r = $Results[$preset]
        $reg = $Registry[$preset]
        # Use resolved override model_id if present; pricing falls back to the
        # preset default (per-model pricing would need its own lookup table).
        # When override is in play, mark pricing as "estimated_from_preset".
        $effectiveModelId = if ($ModelOverrides.ContainsKey($preset) -and $ModelOverrides[$preset]) { $ModelOverrides[$preset] } else { $reg.model_id }
        $pricingNote = if ($ModelOverrides.ContainsKey($preset) -and $ModelOverrides[$preset]) { 'estimated_from_preset_default' } else { 'preset_default' }
        # Fix 4 honest-metadata fields. Default safely for non-agy backends
        # (which never set them): content_ok mirrors a clean exit, no retries.
        $adapterOk = if ($null -ne $r.ContentOk) { [bool]$r.ContentOk } else { ($r.ExitCode -eq 0) }

        # --- content_ok must be grounded in the ARTIFACT (2026-08-10) --------
        # $adapterOk alone lied in two measured ways:
        #
        #  * Only agy and opencode ever set ContentOk, so for every REST backend
        #    content_ok meant "the HTTP call worked", not "we got a review".
        #  * agy's clean-capture return (backends/agy.ps1:706-721) sets
        #    ContentOk=$true UNCONDITIONALLY while passing the agy PROCESS exit
        #    code straight through. _SpawnAndCaptureOnce reads the answer from
        #    the transcript independently of process exit and reports
        #    ExitCode=-1 whenever the process had to be killed at the hard
        #    deadline (agy.ps1:462) -- so a readable-but-doomed capture returns
        #    ExitCode=-1 WITH ContentOk=$true and no Error key at all.
        #
        # Measured live 2026-08-09: gemini-pro-high truncated at its output cap,
        # its answer (the prompt, echoed back) was demoted by
        # Copy-PrimaryResponseAlias to round-1-gemini-pro-high-response.rejected.md,
        # no round-1-response.md was promoted -- and this writer still recorded
        # content_ok=true, error=null. On a single-reviewer dispatch that reads
        # as "reviewed, no findings" when nothing was reviewed.
        #
        # The reliable signal is the artifact: a reviewer produced a review iff
        # its response file is on disk under a name {{PREVIOUS_ROUND}} will
        # actually read. Copy-PrimaryResponseAlias runs BEFORE this writer and
        # has already renamed every rejected answer to *.rejected.md, so a plain
        # Test-Path asks exactly the right question -- and it covers backends
        # that exit 0 without ever writing a file, which no ExitCode check can.
        $blindRec = Get-EraSeatBlindRecord -Preset $preset -BundleOverrides $BundleOverrides
        $artifactOk = Test-EraReviewerArtifact -ReviewDir $ReviewDir -Round $Round `
            -Preset $preset -ReviewerCount $Results.Count
        $contentOk = $adapterOk -and ($r.ExitCode -eq 0) -and $artifactOk

        # Never downgrade silently -- the whole point is that the disagreement
        # was invisible. Name it in warnings, where the round's own telemetry
        # already lives.
        $entryWarnings = @($r.Warnings | Where-Object { $_ })
        if ($adapterOk -and -not $contentOk) {
            $why = if (-not $artifactOk) { "no readable response artifact on disk" }
                   else { "adapter exit code $($r.ExitCode)" }
            $entryWarnings += "content_ok downgraded to false: the adapter reported a usable capture but $why."
        }
        $captureStrategy = $r.CaptureStrategy   # may be $null for non-agy
        $retryCount  = if ($null -ne $r.RetryCount) { [int]$r.RetryCount } else { 0 }
        $retryReason = $r.RetryReason            # may be $null
        # Preserve the discarded first attempt (agy retry) for the audit trail.
        $firstAttempt = $r.FirstAttempt          # hashtable or $null
        if ($r.ExitCode -eq 0) {
            $estIn  = [Math]::Round(($BundleTokens / 1000000.0) * $reg.pricing.input_per_m, 4)
            $estOut = [Math]::Round(($r.OutputTokens / 1000000.0) * $reg.pricing.output_per_m, 4)
            # On a successful retry, the discarded first attempt still spent
            # ~bundle input tokens. Add its est_cost_total_usd to the round total
            # so cap-accounting isn't understated (R3-Opus-I5).
            $firstAttemptCost = if ($firstAttempt -and $firstAttempt.est_cost_total_usd) { [double]$firstAttempt.est_cost_total_usd } else { 0.0 }
            $entry = @{
                preset = $preset; backend = $reg.backend; model = $effectiveModelId
                pricing_source = $pricingNote
                capture_method = $r.CaptureMethod
                capture_strategy = $captureStrategy
                content_ok = $contentOk
                retry_count = $retryCount
                retry_reason = $retryReason
                exit_code = $r.ExitCode
                wall_clock_sec = $r.WallClockSec
                first_byte_sec = $r.FirstByteSec
                response_chars = if ($r.Response) { $r.Response.Length } else { 0 }
                bundle_tokens = $BundleTokens
                delivery_mode = $(if ($DeliveryModes.ContainsKey($preset)) { $DeliveryModes[$preset] } else { $null })
                blinded = $blindRec.Blinded
                delivery_bundle = $blindRec.Bundle
                delivery_bundle_sha256 = $blindRec.Sha256
                est_output_tokens = $r.OutputTokens
                est_cost_input_usd = $estIn
                est_cost_output_usd = $estOut
                est_cost_total_usd = [Math]::Round($estIn + $estOut + $firstAttemptCost, 4)
                truncation_warning = $r.TruncationWarning
                warnings = @($entryWarnings)
                error = $null
            }
            if ($firstAttempt) { $entry.first_attempt = $firstAttempt }
            $entry
        } else {
            # Preserve real adapter values even on failure -- only the fields
            # that genuinely don't apply on failure (cost estimates) are zeroed.
            # Previously this branch hardcoded zeros for wall_clock_sec /
            # response_chars / bundle_tokens, which masked real failure data
            # (e.g. agy ran for 14s and returned 122 chars but metadata showed
            # all zeros, making it look like nothing happened).
            $respLen = if ($r.Response) { $r.Response.Length } else { 0 }
            $captureMethod = if ($r.CaptureMethod) { $r.CaptureMethod } else { 'error' }
            # An agentic-narration failure still burned ~bundle input tokens on
            # each attempt (the discarded first attempt is in $firstAttempt). Carry
            # that real spend through so a failed retry isn't shown as $0.
            $firstAttemptCost = if ($firstAttempt -and $firstAttempt.est_cost_total_usd) { [double]$firstAttempt.est_cost_total_usd } else { 0.0 }
            # C5.2: include the final attempt's input cost in failure metadata.
            # When retryCount>0 the first attempt and final attempt are distinct
            # dispatches — both spent input tokens. When retryCount==0 (cap-skip
            # or single-attempt failure) the first attempt IS the final attempt,
            # so its $firstAttemptCost already covers the input spend.
            $estIn = [Math]::Round(($BundleTokens / 1000000.0) * $reg.pricing.input_per_m, 4)
            # ...but only when there IS a first attempt to have covered it. A
            # response-contract failure has retryCount==0 and no $firstAttempt
            # record, so this reported $0.00 for a call that was fully paid for.
            # Flagged by all three round-3 reviewers.
            $finalInputCost = if ($retryCount -gt 0 -or -not $firstAttempt) { $estIn } else { 0.0 }
            $entry = @{
                preset = $preset; backend = $reg.backend; model = $effectiveModelId
                pricing_source = $pricingNote
                capture_method = $captureMethod
                capture_strategy = $captureStrategy
                content_ok = $contentOk
                retry_count = $retryCount
                retry_reason = $retryReason
                exit_code = $r.ExitCode
                wall_clock_sec = if ($null -ne $r.WallClockSec) { $r.WallClockSec } else { 0 }
                first_byte_sec = $r.FirstByteSec
                response_chars = $respLen
                bundle_tokens = $BundleTokens
                delivery_mode = $(if ($DeliveryModes.ContainsKey($preset)) { $DeliveryModes[$preset] } else { $null })
                blinded = $blindRec.Blinded
                delivery_bundle = $blindRec.Bundle
                delivery_bundle_sha256 = $blindRec.Sha256
                est_output_tokens = if ($null -ne $r.OutputTokens) { $r.OutputTokens } else { 0 }
                est_cost_input_usd = $finalInputCost
                est_cost_output_usd = 0
                est_cost_total_usd = [Math]::Round($firstAttemptCost + $finalInputCost, 4)
                truncation_warning = $r.TruncationWarning
                warnings = @($entryWarnings)
                error = $r.Error
            }
            if ($firstAttempt) { $entry.first_attempt = $firstAttempt }
            $entry
        }
    }
    $meta = @{
        round = $Round
        timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        topic_slug = $TopicSlug
        mode = $Mode
        topic_round_count = $TopicRoundCount
        include_files = @($IncludeFilesList)
        bundle_file_count = $BundleFileCount
        bundle_bytes = $BundleBytes
        convergence_warnings = @($ConvergenceWarnings)
        cost_warnings = @($CostWarnings)
        citation_warnings = @($CitationWarnings)
        # ALWAYS PRESENT, and 'unmeasured' when nothing was checked -- the same
        # rule, for the same reason, as blind_seat below. An absent key would
        # make "era could not read the tree" indistinguishable from "this writer
        # predates the check", and a verdict of 'contained' would be worse than
        # either: a fact about the instrument published as a fact about the repo.
        seat_containment = $(
            if ($null -eq $SeatContainment) {
                @{ verdict = 'unmeasured'; new_dirty = @(); head_moved = $false
                   before_head = $null; after_head = $null
                   reason = 'the caller ran no containment check' }
            } else {
                @{ verdict     = $SeatContainment.Verdict
                   new_dirty   = @($SeatContainment.NewDirty)
                   head_moved  = [bool]$SeatContainment.HeadMoved
                   before_head = $SeatContainment.BeforeHead
                   after_head  = $SeatContainment.AfterHead
                   reason      = $SeatContainment.Reason }
            }
        )
        # Always present, even as $null: "no seat was blinded" and "this writer
        # predates the field" are different facts, and a scorer reading a
        # directory of rounds has to be able to tell them apart.
        #
        # RESTRICTED TO SEATS THIS ROUND ACTUALLY HAS A RESULT FOR. The override
        # map is keyed by INTENT and can name a preset that never ran: when the
        # blinded seat fails recoverably, Get-EraFallbackBundleOverrides copies
        # the whole map and adds the fallback's preset, so an unfiltered join
        # reads "gemini-api,muse-spark" and a scorer cannot tell which one read
        # the stripped bundle -- the one question this field exists to answer.
        # Found by the blinded seat of the panel run on the change that added it.
        blind_seat = $(
            $b = @($BundleOverrides.Keys |
                    Where-Object { $Results.ContainsKey($_) -and (Get-EraSeatBlindRecord -Preset $_ -BundleOverrides $BundleOverrides).Blinded } |
                    Sort-Object)
            if ($b.Count -eq 1) { $b[0] } elseif ($b.Count -gt 1) { $b -join ',' } else { $null }
        )
        reviewers = @($reviewerEntries)
    }
    $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReviewDir "round-$Round-metadata.json") -Encoding utf8
}

function Get-EraSeatBlindRecord {
    <#
    .SYNOPSIS
        The metadata fields describing this seat's bundle override:
        @{ Blinded; Bundle; Sha256 }.

    .DESCRIPTION
        ONE definition of "is this seat blinded, and with what", because
        Write-ReviewMetadata was open-coding
        `$BundleOverrides.ContainsKey($p) -and $BundleOverrides[$p]` five times
        across two branches -- which is precisely the shape the sweep this
        function belongs to exists to remove. Raised by the opus seat of that
        sweep's own panel.

        THE HASH IS THE POINT, not the filename. era.ps1 asserts in a comment
        that the stripped copy is "byte-comparable to what every other seat
        sees", and nothing recorded enough to check it: Write-ReviewManifest
        hashes the round's bundle and prompt and runs BEFORE the blind bundle is
        built, so that file was never hashed anywhere. A leaf filename is not
        evidence of content, which is what the A/B's control rests on.

        A missing file records $null rather than an empty or invented hash: an
        unhashable artifact and an unhashed one are different facts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Preset,
        [hashtable]$BundleOverrides = @{}
    )
    $path = if ($BundleOverrides.ContainsKey($Preset)) { $BundleOverrides[$Preset] } else { $null }
    if (-not $path) { return @{ Blinded = $false; Bundle = $null; Sha256 = $null } }
    $sha = $null
    try { $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower() } catch { $sha = $null }
    return @{ Blinded = $true; Bundle = (Split-Path -Leaf $path); Sha256 = $sha }
}

function Copy-PrimaryResponseAlias {
    <#
    .SYNOPSIS
        Copy the FIRST SUCCESSFUL reviewer's response to the unified
        round-N-response.md so downstream consumers always find one canonical
        file, regardless of which reviewers ran (Fix 4 / R1-I2).

    .DESCRIPTION
        Preference order for "primary" (R3-Gemini-nit2 / R4-nit — first SUCCESSFUL
        in preference order, NOT first present):
        SUPERSEDED 2026-08-09. The order was: exact 'gemini', then any
        gemini-containing preset, then the approved list. That vendor hardcode
        dated from when gemini was the only reviewer; on the shipped three-model
        panel it promoted the cheapest model's answer regardless of substance,
        and the promoted answer is what feeds round N+1 via {{PREVIOUS_ROUND}}.

        Now: the FIRST SUCCESSFUL reviewer in the caller's own $ReviewerList
        order. Default behaviour is unchanged, since the shipped panel lists
        gemini first anyway.

        Single-reviewer runs are NOT exempt. The adapter writes
        round-N-response.md directly, so there is nothing to promote — but a
        FAILED response must not be left there as canonical, because round N+1
        reads it. It is demoted to round-N-<preset>-response.md (evidence is
        kept) and the canonical is removed.

        "Successful" means ExitCode -eq 0 (a content_ok=false agentic capture is
        ExitCode=-1, so it is correctly excluded). Single-reviewer runs already
        write round-N-response.md directly (no $Preset suffix), so this is a no-op
        for them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$Round,
        [Parameter(Mandatory)][string[]]$ReviewerList,
        [Parameter(Mandatory)][hashtable]$Results
    )
    $isOk = {
        param($p)
        $res = $Results[$p]
        $res -and ($res.ExitCode -eq 0)
    }

    # SINGLE-REVIEWER RUNS ARE NOT EXEMPT (2026-08-09). This used to return
    # early for one reviewer, because the adapter writes round-N-response.md
    # directly and there was nothing to promote. But that also meant a FAILED
    # response stayed canonical -- and the canonical file feeds round N+1 via
    # {{PREVIOUS_ROUND}}. All three reviewers of the graded panel independently
    # named this the #1 blocker, on the very configuration the docs tell people
    # to drop to. Demote it: keep the answer as evidence under its preset name,
    # and leave no canonical behind.
    # The demoted name must NOT match 'round-N-*-response.md', because
    # Invoke-PromptTokenSubstitution globs exactly that shape to build the next
    # round's context. The first version of this fix demoted to
    # round-N-<preset>-response.md and thereby fed the rejected answer straight
    # back into round N+1 — relocating the poison instead of removing it. Caught
    # by all three reviewers of the round-2 graded panel.
    $rejectedName = { param($p) "round-$Round-$p-response.rejected.md" }

    if ($ReviewerList.Count -le 1) {
        $solo = @($ReviewerList)[0]
        if (-not $solo -or (& $isOk $solo)) { return }
        $canonical = Join-Path $ReviewDir "round-$Round-response.md"
        if (-not (Test-Path -LiteralPath $canonical)) { return }
        $evidence = Join-Path $ReviewDir (& $rejectedName $solo)
        Move-Item -LiteralPath $canonical -Destination $evidence -Force -ErrorAction SilentlyContinue
        # Symmetric with the panel path below. This Move IS the boundary keeping
        # a rejected answer out of round N+1; if it fails (lock, permissions) the
        # canonical survives, still matches the {{PREVIOUS_ROUND}} glob, and
        # poisons the next round -- silently, until now. Needs an I/O failure to
        # bite, which is why round 5 called it a door rather than a blocker.
        if (Test-Path -LiteralPath $canonical) {
            Write-Host "[era] WARNING: could not demote $canonical; round N+1 may read a rejected response."
        }
        return
    }

    # Candidate order is the CALLER's order (2026-08-09). It used to put 'gemini'
    # first unconditionally, a leftover from when gemini was the only reviewer.
    # On the shipped three-model panel that made the canonical answer always the
    # cheapest model regardless of substance -- measured: gemini 10,658 bytes
    # promoted over opus's 19,869 -- and only that answer reached round N+1.
    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $ReviewerList) {
        if (-not $ordered.Contains($r)) { $ordered.Add($r) }
    }

    # Demote EVERY failed panel member's own file, not just the canonical. The
    # first version only renamed the canonical, so on the shipped three-model
    # default each failed reviewer's round-N-<preset>-response.md survived,
    # still matched the {{PREVIOUS_ROUND}} glob, and carried off-contract content
    # into the next round — the round-2 blocker, unfixed on the configuration
    # that actually ships. Caught unanimously again in round 3.
    foreach ($r in $ReviewerList) {
        if (& $isOk $r) { continue }
        $failedFile = Join-Path $ReviewDir "round-$Round-$r-response.md"
        if (Test-Path -LiteralPath $failedFile) {
            $target = Join-Path $ReviewDir (& $rejectedName $r)
            Move-Item -LiteralPath $failedFile -Destination $target -Force -ErrorAction SilentlyContinue
            # This Move IS the boundary that keeps rejected content out of round
            # N+1 — a silently swallowed failure reopens the exact hole. Say so.
            if (Test-Path -LiteralPath $failedFile) {
                Write-Host "[era] WARNING: could not demote $failedFile; round N+1 may read a rejected response."
            }
        }
    }

    $primary = $null
    foreach ($cand in $ordered) {
        if (& $isOk $cand) { $primary = $cand; break }
    }
    if (-not $primary) {
        # Nobody passed. The canonical must not survive as if it were a good
        # review — but never DESTROY it: on a panel where no per-preset file was
        # written it is the only copy. Rename it to the rejected shape, which the
        # {{PREVIOUS_ROUND}} glob deliberately does not match.
        $stale = Join-Path $ReviewDir "round-$Round-response.md"
        if (Test-Path -LiteralPath $stale) {
            $first = @($ReviewerList)[0]
            if (-not $first) { $first = 'unknown' }
            Move-Item -LiteralPath $stale -Destination (Join-Path $ReviewDir (& $rejectedName $first)) `
                -Force -ErrorAction SilentlyContinue
        }
        return
    }

    $src = Join-Path $ReviewDir "round-$Round-$primary-response.md"
    $dst = Join-Path $ReviewDir "round-$Round-response.md"
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
}

function Copy-GeminiResponseAlias {
    # One-release backward-compat wrapper. Maps the old single-result signature
    # onto Copy-PrimaryResponseAlias (-Results). Prefer Copy-PrimaryResponseAlias
    # directly; this exists so any pre-upgrade caller keeps working.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$Round,
        [Parameter(Mandatory)][string[]]$ReviewerList,
        [Parameter(Mandatory)][hashtable]$GeminiResult
    )
    Copy-PrimaryResponseAlias -ReviewDir $ReviewDir -Round $Round `
        -ReviewerList $ReviewerList -Results @{ gemini = $GeminiResult }
}

function Test-EraReviewerArtifact {
    <#
    .SYNOPSIS
        Did this reviewer leave a readable answer on disk for this round?

    .DESCRIPTION
        The single source of truth for "this reviewer produced a review".
        Everything else lies:

          * ContentOk is set only by agy and opencode, and agy's clean-capture
            return sets it $true even when the agy process was killed at the
            hard deadline (backends/agy.ps1:598-602 decides from the response
            TEXT and never consults $result.ExitCode).
          * ExitCode -eq 0 does not imply an answer reached disk -- it only says
            the call returned.

        A readable answer is one under a name Invoke-PromptTokenSubstitution's
        'round-N-*-response.md' glob will actually pick up. Copy-PrimaryResponseAlias
        deliberately renames every rejected answer to *.rejected.md precisely so
        it CANNOT match that glob, so a plain Test-Path is the right question.

        The unsuffixed round-N-response.md counts only for a genuine solo
        dispatch (Get-ResponseFilenameSuffix omits the suffix there). Once a
        second reviewer exists the unsuffixed name belongs to whoever was
        promoted, and it is never legitimately the original reviewer's -- a
        fallback is dispatched only because that reviewer already failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$Round,
        [Parameter(Mandatory)][string]$Preset,
        [Parameter(Mandatory)][int]$ReviewerCount
    )
    if (Test-Path -LiteralPath (Join-Path $ReviewDir "round-$Round-$Preset-response.md")) { return $true }
    if ($ReviewerCount -le 1) {
        return [bool](Test-Path -LiteralPath (Join-Path $ReviewDir "round-$Round-response.md"))
    }
    return $false
}

function Get-EraSeatBundle {
    <#
    .SYNOPSIS
        Which bundle does this seat review? The override map if it names this
        preset, otherwise the round's normal bundle.

    .DESCRIPTION
        Extracted from Invoke-ReviewerDispatch so the fallback path can be tested
        against the SAME lookup the dispatcher performs, rather than against a
        copy of it in a test. The map is keyed by PRESET NAME, which is the whole
        subtlety: see Get-EraFallbackBundleOverrides.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Preset,
        [hashtable]$BundleOverrides = @{},
        [Parameter(Mandatory)][string]$BundlePath
    )
    if ($BundleOverrides.ContainsKey($Preset) -and $BundleOverrides[$Preset]) { return $BundleOverrides[$Preset] }
    return $BundlePath
}

function Get-EraFallbackBundleOverrides {
    <#
    .SYNOPSIS
        The override map to hand the agy fallback re-dispatch, plus the line to
        print about it. Returns @{ Overrides; Note }.

    .DESCRIPTION
        THE FIX THAT DID NOT FIX ANYTHING. e5d465e reported that the fallback
        re-dispatch never received -BundleOverrides, so a blinded seat's
        replacement silently got the SIGHTED bundle, and it added the parameter
        to the call.

        That cannot work. The map is keyed by preset name (Get-EraSeatBundle),
        the fallback dispatches under its own preset name, and era.ps1 picks that
        name with Resolve-EraAgyFallback -Exclude (every requested and approved
        seat) -- so the fallback preset is GUARANTEED to be absent from a map
        built out of this round's seats. The map was threaded into a lookup whose
        key can never be present, and the behaviour did not change.

        It shipped with a source-assertion test that the parameter EXISTS, which
        passes against exactly that wiring.

        So: re-key it. If the blinded seat is among the seats this fallback is
        replacing, the fallback inherits its comment-stripped bundle -- which is
        what -BlindSeat was asked for. If it is not, the fallback reviews the
        normal bundle. Either way it is SAID, because the round summary was
        otherwise reporting a blinded seat that had not been blinded.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$BundleOverrides = @{},
        [Parameter(Mandatory)][string]$FallbackPreset,
        [string]$BlindSeat,
        # The seats whose failure triggered this fallback.
        [string[]]$Replacing = @()
    )
    $out = @{}
    foreach ($k in $BundleOverrides.Keys) { $out[$k] = $BundleOverrides[$k] }
    $note = $null
    if ($BlindSeat -and $BundleOverrides.ContainsKey($BlindSeat) -and $BundleOverrides[$BlindSeat]) {
        if ($Replacing -contains $BlindSeat) {
            $out[$FallbackPreset] = $BundleOverrides[$BlindSeat]
            $note = "[era] fallback '$FallbackPreset' inherits the comment-stripped bundle from the blinded seat '$BlindSeat' it replaces."
        } else {
            $note = "[era] fallback '$FallbackPreset' reviews the NORMAL bundle; the blinded seat '$BlindSeat' is not among the seats it replaces."
        }
    }
    return @{ Overrides = $out; Note = $note }
}

