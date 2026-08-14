<#
.SYNOPSIS
    Core workflow for /external-review-auto. Dot-sourced by SKILL.md
    invocations and by runtimes/era.ps1 standalone shell entry.
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
    #>
    [CmdletBinding()]
    param()
    return @('**/node_modules/**', '**/.git/**', '**/__pycache__/**', '*.pyc', '*.duckdb', 'validation_results/**/*.db')
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
    }
    foreach ($p in @($IgnorePatterns)) {
        $n = "$p" -replace '\\', '/'
        if ($n -match '^\*\*/([^*/]+)/\*\*$') { [void]$sets.SkipDirNames.Add($matches[1]); continue }
        if ($n -match '^([^*]+)/\*\*$')       { [void]$sets.SkipDirs.Add($matches[1].TrimEnd('/')); continue }
        if ($n -match '^\*(\.[^*/]+)$')       { [void]$sets.SkipExts.Add($matches[1]); continue }
    }
    return $sets
}

function Test-EraPathIgnored {
    <#
    .SYNOPSIS
        Would repomix refuse to bundle this repo-relative path? See
        Get-EraIgnoreSets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RelPath,
        [Parameter(Mandatory)][hashtable]$Sets
    )
    if ([string]::IsNullOrWhiteSpace($RelPath)) { return $false }
    $n = ($RelPath -replace '\\', '/').TrimStart('./')
    if ($Sets.SkipExts.Count -gt 0) {
        $ext = [System.IO.Path]::GetExtension($n)
        if ($ext -and $Sets.SkipExts.Contains($ext)) { return $true }
    }
    $segs = @($n -split '/')
    # Directory segments only -- the last element is the file name.
    for ($i = 0; $i -lt ($segs.Count - 1); $i++) {
        if ($Sets.SkipDirNames.Contains($segs[$i])) { return $true }
    }
    if ($Sets.SkipDirs.Count -gt 0) {
        for ($i = 0; $i -lt ($segs.Count - 1); $i++) {
            $prefix = ($segs[0..$i] -join '/')
            if ($Sets.SkipDirs.Contains($prefix)) { return $true }
        }
    }
    return $false
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
            if ($normCp -match '(^|/)\.external-reviews(/|$)' -and $normCp -notmatch '/round-\d+-external/') { continue }
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
        [Parameter(Mandatory)][int]$PreviousRound
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
        $substitution = $substitution.Substring(0, $maxChars) +
            "`n`n[... previous round truncated: $dropped of $($substitution.Length + 0) chars omitted." +
            " Raise ERA_PREVIOUS_ROUND_MAX_CHARS to carry more.]"
    }

    return $substitution
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

    if (-not (Test-Path -LiteralPath $PromptFile)) { return }
    $promptText = Get-Content -LiteralPath $PromptFile -Raw
    if ($promptText -notmatch '\{\{PREVIOUS_ROUND\}\}') { return }

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
    $newText = [regex]::Replace($promptText, '(?<!`)\{\{PREVIOUS_ROUND\}\}(?!`)', [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        return $substitution
    })
    Set-Content -LiteralPath $PromptFile -Value $newText -Encoding UTF8
}

function Stop-EraAdapterChild {
    <#
    .SYNOPSIS
        Tree-kill the native process an adapter recorded in its PID file.

    .DESCRIPTION
        THIS EXISTS BECAUSE Stop-Job CANNOT DO IT. Measured directly: a
        ThreadJob sitting inside Process.WaitForExit() cannot be interrupted, so
        Stop-Job BLOCKS INDEFINITELY (observed still blocked after minutes) and
        the native child stays alive the whole time.

        That is why the dispatcher's old budget was TimeoutSec+30 and never
        less: by the time it fired, the adapter's OWN timeout had already
        thrown, tree-killed its child and returned, so the job was no longer
        blocked and Stop-Job completed instantly. Any attempt to abandon a
        reviewer EARLIER has to kill the child itself -- killing the job first
        deadlocks the dispatcher.

        So the order is: kill the CHILD, the adapter's WaitForExit returns, its
        own finally block runs (agy.ps1:443, claude.ps1:160, opencode.ps1:352
        all tree-kill defensively there), the job completes on its own, and only
        then is Stop-Job cheap.

    .OUTPUTS
        [bool] — $true if a live process was found and killed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PidFile
    )
    if (-not $PidFile -or -not (Test-Path -LiteralPath $PidFile)) { return $false }
    $raw = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue)
    if (-not $raw) { return $false }
    $childPid = 0
    if (-not [int]::TryParse($raw.Trim(), [ref]$childPid) -or $childPid -le 0) { return $false }
    $proc = Get-Process -Id $childPid -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    try {
        # $true = tree-kill. The launchers are shims (agy.cmd -> node,
        # claude -> node, opencode -> node); a bare Kill() orphans the child.
        $proc.Kill($true)
        $null = $proc.WaitForExit(10000)
        return $true
    } catch {
        return $false
    }
}

function Test-EraStragglerExpired {
    <#
    .SYNOPSIS
        Decide whether the dispatcher should stop waiting for outstanding jobs.

    .DESCRIPTION
        Pure decision function, extracted so the policy is testable without
        spawning real jobs. Returns '' to keep waiting, or the reason to stop:

            'budget' — the absolute dispatch budget is spent (old behaviour)
            'grace'  — a LONE straggler outlived its grace period

        WHY A GRACE PERIOD, AND WHY THIS SIZE.
        The dispatcher used to block on Wait-Job across all jobs, so one hung
        member held the round for the entire scaled budget (up to 1830s) even
        with everyone else finished. But cutting stragglers off cheaply is
        actively harmful: the slowest reviewer is often the most valuable one
        (measured on round 1 of the era-grade panel, opus took 374s and produced
        19,869 bytes while gemini took 50s and produced 10,658).

        So the grace is sized from the measured healthy spread. Per-reviewer
        wall-clock across four real rounds, slowest minus second-slowest:

            round 1:   8.0s      round 2: 135.8s
            round 3: 115.7s      round 4:  78.9s

        Healthy stragglers trail by at most ~136s. The 300s default is ~2.2x
        that, so it would not have fired in any observed round, while still
        reclaiming ~25 minutes when a member genuinely hangs. Raise it with
        ERA_STRAGGLER_GRACE_SEC, or set 0 to restore wait-for-the-full-budget.

        The grace applies ONLY when exactly one job is outstanding. With two or
        more still running the round is legitimately still working, and there is
        no straggler to single out.

    .OUTPUTS
        [string] — '' | 'budget' | 'grace'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ElapsedSec,
        [Parameter(Mandatory)][int]$Outstanding,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][int]$BudgetSec,
        [int]$GraceSec = 300,
        [int]$LoneSinceSec = -1
    )
    if ($ElapsedSec -ge $BudgetSec) { return 'budget' }
    if ($GraceSec -le 0)            { return '' }   # explicitly disabled
    if ($Total -lt 2)               { return '' }   # solo run: nothing to straggle behind
    if ($Outstanding -ne 1)         { return '' }   # still a real panel in flight
    if ($LoneSinceSec -lt 0)        { return '' }   # grace clock not started
    if (($ElapsedSec - $LoneSinceSec) -ge $GraceSec) { return 'grace' }
    return ''
}

function Get-NextReviewRound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir
    )
    if (-not (Test-Path -LiteralPath $ReviewDir)) { return 1 }
    $prior = Get-ChildItem -LiteralPath $ReviewDir -Filter 'round-*-manifest.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^round-(\d+)-manifest\.json$' } |
        ForEach-Object { [int]$matches[1] } |
        Sort-Object -Descending |
        Select-Object -First 1
    if (-not $prior) { return 1 }
    return $prior + 1
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
        $GitState
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
        round          = $Round
        topic_slug     = $TopicSlug
        timestamp      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        previous_round = $PreviousRound
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
                if ($normCp -match '(^|/)\.external-reviews(/|$)' -and $normCp -notmatch '/round-\d+-external/') { continue }
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

function Acquire-ReviewLock {
    # No-op. Per-topic locking replaced by per-round atomic reservation via
    # Reserve-ReviewRound. Kept for backwards compatibility with any caller
    # that dot-sources workflow.ps1 directly.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReviewDir)
}

function Release-ReviewLock {
    # No-op. See Acquire-ReviewLock.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReviewDir)
}

function Reserve-ReviewRound {
    <#
    .SYNOPSIS
        Atomically reserve the next available round number for a topic directory.

    .DESCRIPTION
        Scans <reviewDir>/round-*-manifest.json and round-*-claim.json to find
        the highest existing round N, then attempts to create
        round-(N+1)-claim.json with FileMode.CreateNew (atomic on NTFS/ext4).

        If another concurrent process beats us (CreateNew throws IOException),
        we increment N and retry immediately — no sleep. Cap at 50 retries to
        guard against a hostile directory.

        The claim file contains { pid, started, reviewer } and is deleted by
        the caller on successful completion.  If the process is killed mid-run
        the claim file is orphaned (known limitation; documented in SKILL.md).

    .PARAMETER ReviewDir
        The per-topic directory (e.g. .external-reviews/my-topic/).

    .PARAMETER Reviewer
        Reviewer preset string, stored in the claim file for diagnostics.

    .OUTPUTS
        [int] — the round number this process owns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [string]$Reviewer = ''
    )

    # Ensure $ReviewDir exists before any File::Open(...,CreateNew) attempts.
    # Without this, a first-ever reservation against a non-existent topic dir
    # throws DirectoryNotFoundException (which inherits from IOException, so
    # the catch tries 50 times in a tight loop before throwing a misleading
    # "failed to claim a round number" error). Both reviewers found this.
    if (-not (Test-Path -LiteralPath $ReviewDir)) {
        try {
            $null = New-Item -ItemType Directory -Path $ReviewDir -Force -ErrorAction Stop
        } catch {
            # Surface a genuine creation failure (e.g. permissions) immediately with
            # a clear message instead of swallowing it and falling through to the
            # CreateNew loop, which would spin 50x on DirectoryNotFound and throw a
            # misleading "failed to claim a round number" error (round-3 nit).
            throw "Reserve-ReviewRound: cannot create review dir '$ReviewDir': $($_.Exception.Message)"
        }
    }

    # --- Orphaned claim file TTL cleanup (R6 fix) ---
    # Remove claim files older than 24h so a hard-killed process (Ctrl-C, OOM)
    # does not permanently block that round number for the topic. The claim file
    # is the atomic reservation marker; a live process that created it within the
    # last 24h is assumed to be genuinely in-flight. A stale claim older than 24h
    # is assumed orphaned (no healthy dispatch runs that long) and is reclaimed.
    $claimTTL = [TimeSpan]::FromHours(24)
    $now = [DateTime]::UtcNow
    Get-ChildItem -LiteralPath $ReviewDir -Filter 'round-*-claim.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^round-(\d+)-claim\.json$' } |
        ForEach-Object {
            if (($now - $_.LastWriteTimeUtc) -gt $claimTTL) {
                Write-Host "[era] Reclaiming orphaned claim file: $($_.Name) (last modified $($_.LastWriteTimeUtc))."
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }

    $maxRetries = 50
    $attempt = 0
    $claimContent = @{
        pid      = $PID
        started  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        reviewer = $Reviewer
    } | ConvertTo-Json -Compress

    while ($attempt -lt $maxRetries) {
        # Find the highest round number already committed (manifest) or claimed
        $highestManifest = Get-ChildItem -LiteralPath $ReviewDir -Filter 'round-*-manifest.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^round-(\d+)-manifest\.json$' } |
            ForEach-Object { [int]($_.Name -replace '^round-(\d+)-manifest\.json$','$1') } |
            Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
        $highestClaim = Get-ChildItem -LiteralPath $ReviewDir -Filter 'round-*-claim.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^round-(\d+)-claim\.json$' } |
            ForEach-Object { [int]($_.Name -replace '^round-(\d+)-claim\.json$','$1') } |
            Measure-Object -Maximum | Select-Object -ExpandProperty Maximum

        $highest = [Math]::Max(
            $(if ($null -eq $highestManifest) { 0 } else { $highestManifest }),
            $(if ($null -eq $highestClaim)    { 0 } else { $highestClaim })
        )
        $candidate = $highest + 1

        $claimPath = Join-Path $ReviewDir "round-$candidate-claim.json"
        try {
            $fs = [System.IO.File]::Open($claimPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $writer = [System.IO.StreamWriter]::new($fs)
                $writer.Write($claimContent)
            } finally {
                $writer.Dispose()
                $fs.Dispose()
            }
            # We own round $candidate
            return [int]$candidate
        } catch [System.IO.IOException] {
            # Another process claimed this round concurrently; retry immediately
            $attempt++
        }
    }

    throw "Reserve-ReviewRound: failed to claim a round number after $maxRetries attempts in '$ReviewDir'. Directory may be in an inconsistent state."
}

function Get-ForceMode {
    $force = $env:ERA_FORCE -and `
             $env:ERA_FORCE -ne '0' -and `
             $env:ERA_FORCE -ne 'false'
    return [bool]$force -or `
           ($host.Name -notmatch 'ConsoleHost|Visual Studio') -or `
           (-not [Environment]::UserInteractive)
}

function ConvertTo-EraNativePath {
    <# Rewrite a leading Git-Bash/MSYS drive prefix (/c/foo) to native Windows
       (C:/foo) so -IncludeFiles works when invoked from bash on Windows. Pure,
       idempotent; non-MSYS and relative paths pass through unchanged. #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    # Windows only — on Linux, /c/lib/x is a legitimate absolute path, not an MSYS drive.
    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) { return $Path }
    if ($Path -match '^/([A-Za-z])/(.*)$') { return "$($Matches[1].ToUpper()):/$($Matches[2])" }
    return $Path
}

function Resolve-EraAuthJsonKeys {
    <#
      For each requested api_key_env that is NOT already set in the process env,
      source the key from opencode's auth.json (subscription providers only) and
      set it in the PROCESS env so the existing env-based adapters + availability
      checks work unchanged. Additive + safe: only fills empties, only known
      providers, never overwrites an existing env var.
    #>
    param(
        [string[]]$ApiKeyEnvs,
        [string]$AuthPath = (Join-Path $HOME '.local/share/opencode/auth.json')
    )
    $map = @{ 'OPENCODE_API_KEY' = 'opencode-go'; 'MINIMAX_API_KEY' = 'minimax'; 'NVIDIA_API_KEY' = 'nvidia' }
    if (-not (Test-Path -LiteralPath $AuthPath)) { return }
    $auth = Get-Content -LiteralPath $AuthPath -Raw | ConvertFrom-Json
    foreach ($envName in ($ApiKeyEnvs | Where-Object { $_ } | Select-Object -Unique)) {
        if ([Environment]::GetEnvironmentVariable($envName)) { continue }
        $prov = $map[$envName]
        if (-not $prov) { continue }
        $entry = $auth.$prov
        if ($entry -and $entry.type -eq 'api' -and $entry.key) {
            [Environment]::SetEnvironmentVariable($envName, $entry.key)  # process scope only
        }
    }
}

function Get-ResponseFilenameSuffix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ReviewerList,
        [Parameter(Mandatory)][string]$Preset
    )
    # Single-reviewer runs always produce clean `round-N-response.md` regardless
    # of preset. Previously this only worked for 'gemini'; any other single-
    # reviewer run got `round-N-<preset>-response.md`, breaking downstream
    # scripts expecting a unified filename.
    if ($ReviewerList.Count -eq 1) { return '' }
    return "-$Preset"
}

function Get-PerReviewerCap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Pricing,
        [double]$CheapCap = 2.0,
        [double]$ExpensiveCap = 10.0
    )
    if ($Pricing.input_per_m -ge 10.0) { return $ExpensiveCap }
    return $CheapCap
}

function Test-AggregateCostCap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$TotalEstCost,
        [double]$AggregateCap = 15.0
    )
    return ($TotalEstCost -gt $AggregateCap)
}

function Invoke-CostPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ReviewerList,
        [Parameter(Mandatory)][hashtable]$PerReviewerCosts,
        [Parameter(Mandatory)][double]$AggregateCost,
        [Parameter(Mandatory)][hashtable]$PerReviewerCaps,
        [Parameter(Mandatory)][double]$AggregateCap = 15.0
    )
    if (Get-ForceMode) { return $ReviewerList }

    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $ReviewerList) {
        $cost = $PerReviewerCosts[$r]
        $cap  = $PerReviewerCaps[$r]
        # PowerShell coerces $null -le N to $true (treats null as 0), which
        # silently bypasses the cap for any reviewer missing a cost estimate.
        # Treat null as infinite so the user is explicitly prompted.
        if ($null -eq $cost) { $cost = [double]::PositiveInfinity }
        if ($null -eq $cap) { $cap = 0.0 }
        if ($cost -le $cap) { $kept.Add($r); continue }
        $resp = Read-Host "Reviewer '$r' exceeds cap (`$$cost > `$$cap). Continue? [y/N/d=drop]"
        switch ($resp.ToLower()) {
            'y' { $kept.Add($r) }
            'd' { }
            default { throw "User aborted at per-reviewer cap for '$r'." }
        }
    }
    $survivorAgg = ($kept | ForEach-Object { $PerReviewerCosts[$_] } | Measure-Object -Sum).Sum
    # Measure-Object -Sum over an empty set yields $null, which cannot bind to
    # Test-AggregateCostCap's [double]. Coerce here; the comparison was already
    # false for $null, so behaviour is unchanged.
    if ($null -eq $survivorAgg) { $survivorAgg = 0.0 }
    # Use the shared predicate rather than repeating it. It was defined and
    # called from nowhere -- two copies of one rule is how they drift apart.
    if (Test-AggregateCostCap -TotalEstCost $survivorAgg -AggregateCap $AggregateCap) {
        $resp = Read-Host "Total estimated cost across $($kept.Count) reviewer(s) is `$$survivorAgg (> `$$AggregateCap). Continue? [y/N]"
        if ($resp.ToLower() -ne 'y') {
            throw "User aborted at aggregate cap."
        }
    }
    return $kept.ToArray()
}

function Test-EraBackendAvailable {
    <# Is a preset's backend usable right now? CLI backends need the binary on PATH;
       REST backends need their API-key env var set. Resolvers injectable for tests. #>
    [CmdletBinding()]
    param(
        [string]$Backend,
        [string]$ApiKeyEnv,
        [scriptblock]$CommandExists = { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) },
        [scriptblock]$EnvValue      = { param($n) [Environment]::GetEnvironmentVariable($n) }
    )
    switch ($Backend) {
        'agy'          { return [bool](& $CommandExists 'agy') }
        'claude'       { return [bool](& $CommandExists 'claude') }
        'opencode'     { return [bool](& $CommandExists 'opencode') }
        'geminiapi'    { return [bool](& $EnvValue 'GEMINI_API_KEY') }
        'anthropic'    { return [bool](& $EnvValue 'ANTHROPIC_API_KEY') }
        'openaicompat' { if (-not $ApiKeyEnv) { return $false }; return [bool](& $EnvValue $ApiKeyEnv) }
        default        { return $false }
    }
}

function Get-EraReviewerList {
    <# Pure: rows of selectable reviewer presets with live readiness. Resolvers
       injectable for tests (mirrors Get-EraDoctorReport). #>
    [CmdletBinding()]
    param(
        $Registry,
        [string]$Default,
        [scriptblock]$CommandExists = { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) },
        [scriptblock]$EnvValue      = { param($n) [Environment]::GetEnvironmentVariable($n) }
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $Registry.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        $b = $p.Value.backend
        if (-not $b) { continue }
        $ready = Test-EraBackendAvailable -Backend $b -ApiKeyEnv $p.Value.api_key_env `
            -CommandExists $CommandExists -EnvValue $EnvValue
        $req = switch ($b) {
            'agy'          { 'agy CLI' }
            'claude'       { 'claude CLI' }
            'opencode'     { 'opencode CLI' }
            'geminiapi'    { 'GEMINI_API_KEY' }
            'anthropic'    { 'ANTHROPIC_API_KEY' }
            'openaicompat' { "$($p.Value.api_key_env)" }
            default        { '' }
        }
        $rows.Add([pscustomobject]@{
            preset = $p.Name; backend = $b; ready = [bool]$ready
            model = "$($p.Value.model_id)"; requirement = $req
            is_default = ($p.Name -eq $Default)
        })
    }
    return $rows.ToArray()
}

function Format-EraReviewerList {
    <# Render Get-EraReviewerList rows grouped by backend. Pure. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Rows, [string]$Default)
    $order = @('agy','claude','opencode','openaicompat','geminiapi','anthropic')
    $label = @{ agy='agy (Gemini, subscription)'; claude='claude CLI (subscription)';
        opencode='opencode (TUI)'; openaicompat='REST / opencode HTTP (API key or auth.json)';
        geminiapi='Gemini REST (API key)'; anthropic='Anthropic REST (API key)' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Reviewers ([x] = ready now)'); $lines.Add('')
    $allBackends = @($order) + @($Rows | Select-Object -ExpandProperty backend) | Select-Object -Unique
    foreach ($b in $allBackends) {
        $group = @($Rows | Where-Object { $_.backend -eq $b })
        if (-not $group) { continue }
        $head = $label[$b]; if (-not $head) { $head = $b }
        $lines.Add($head)
        foreach ($r in $group) {
            $mark = if ($r.ready) { '[x]' } else { '[ ]' }
            $line = "  $mark $($r.preset)"
            if ($r.model)      { $line += "  ($($r.model))" }
            if ($r.is_default) { $line += '  [default]' }
            if (-not $r.ready -and $r.requirement) { $line += "  -> needs $($r.requirement)" }
            $lines.Add($line)
        }
        $lines.Add('')
    }
    $defLabel = if ($Default) { $Default } else { '(none ready)' }
    $lines.Add("Default: $defLabel   .   change: /era set default <name>")
    return ($lines -join "`n")
}

function Resolve-EraAgyFallback {
    <# Pick a non-agy fallback reviewer when an agy capture fails. Honors an explicit
       $env:ERA_AGY_FALLBACK preset if it is valid, non-agy, and available; otherwise
       the first available non-agy preset by preference. Excludes presets already in
       the run and ALL agy-backed presets. Returns $null if none available. Resolvers
       injectable for tests. #>
    [CmdletBinding()]
    param(
        $Registry,
        [string]$Override,
        [string[]]$Exclude = @(),
        [string[]]$Preference = @('gemini-api','deepseek-http','sonnet','haiku','minimax-http','nvidia','gemini-api-pro'),
        [scriptblock]$CommandExists = { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) },
        [scriptblock]$EnvValue      = { param($n) [Environment]::GetEnvironmentVariable($n) }
    )
    $isUsable = {
        param($p)
        $e = $Registry[$p]
        if (-not $e -or -not $e.backend) { return $false }
        if ($e.backend -eq 'agy') { return $false }
        if ($Exclude -contains $p) { return $false }
        return [bool](Test-EraBackendAvailable -Backend $e.backend -ApiKeyEnv $e.api_key_env `
            -CommandExists $CommandExists -EnvValue $EnvValue)
    }
    if ($Override -and $Override -ne 'off' -and $Override -ne '0' -and (& $isUsable $Override)) {
        return $Override
    }
    foreach ($p in $Preference) {
        if (& $isUsable $p) { return $p }
    }
    return $null
}

function Resolve-DefaultReviewer {
    <#
    .SYNOPSIS
        Pick the first AVAILABLE reviewer preset by preference (live-detected), so a
        bare /era adapts to what the user has installed instead of blindly defaulting
        to agy and erroring. Returns the preset name, or $null if none is available.
    .DESCRIPTION
        Availability is detected live (PATH / env var) every call — no cached state
        file to go stale when a CLI is installed/removed. The preference order is
        overridable (era.ps1 prepends $env:ERA_DEFAULT_REVIEWER).
    #>
    [CmdletBinding()]
    param(
        $Registry,
        [string[]]$Preference = @('gemini-pro-low', 'sonnet', 'deepseek', 'gemini-api'),
        [scriptblock]$CommandExists = { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) },
        [scriptblock]$EnvValue      = { param($n) [Environment]::GetEnvironmentVariable($n) }
    )
    foreach ($preset in $Preference) {
        $entry = $Registry.$preset
        if (-not $entry -or -not $entry.backend) { continue }
        if (Test-EraBackendAvailable -Backend $entry.backend -ApiKeyEnv $entry.api_key_env `
                -CommandExists $CommandExists -EnvValue $EnvValue) {
            return $preset
        }
    }
    return $null
}

function Get-EraDoctorReport {
    <#
    .SYNOPSIS
        Preflight: gather a structured prereq report (core deps + per-backend
        requirements derived from the registry). No side effects, no install.
    .DESCRIPTION
        Resolvers are injectable (CommandExists / ModuleExists / EnvValue) so the
        whole check set is unit-testable without touching the real PATH/modules/env.
        Each row: @{ name; category('core'|'backend'); required; ok; detail; fix; unlocks }.
    #>
    [CmdletBinding()]
    param(
        $Registry,
        [scriptblock]$CommandExists = { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) },
        [scriptblock]$ModuleExists  = { param($n) [bool](Get-Module -ListAvailable -Name $n -ErrorAction SilentlyContinue) },
        [scriptblock]$EnvValue      = { param($n) [Environment]::GetEnvironmentVariable($n) }
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    $row = {
        param($name, $category, $required, $ok, $detail, $fix, $unlocks)
        $rows.Add([pscustomobject]@{
            name = $name; category = $category; required = [bool]$required
            ok = [bool]$ok; detail = $detail; fix = $fix; unlocks = $unlocks
        })
    }

    # --- Core prerequisites ---
    & $row 'PowerShell 7+' 'core' $true ($PSVersionTable.PSVersion.Major -ge 7) "v$($PSVersionTable.PSVersion)" 'winget install Microsoft.PowerShell  (macOS: brew install powershell)' $null
    & $row 'ThreadJob module' 'core' $true (& $ModuleExists 'ThreadJob') $null 'Install-Module -Name ThreadJob -Force -Scope CurrentUser' $null
    & $row 'repomix' 'core' $true (& $CommandExists 'repomix') $null 'npm install -g repomix' $null
    & $row 'git (optional: -AutoDetect / -Diff)' 'core' $false (& $CommandExists 'git') $null 'install git from https://git-scm.com (optional)' $null

    # --- Backend requirements (distinct, derived from the registry presets) ---
    $cliFor = @{ agy = 'agy'; claude = 'claude'; opencode = 'opencode' }
    $envFor = @{ geminiapi = 'GEMINI_API_KEY'; anthropic = 'ANTHROPIC_API_KEY' }
    $seen = [ordered]@{}   # requirement-key -> @{ kind; name; presets }
    foreach ($p in $Registry.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        $backend = $p.Value.backend
        if (-not $backend) { continue }
        $kind = $null; $reqName = $null
        if ($cliFor.ContainsKey($backend))      { $kind = 'cli'; $reqName = $cliFor[$backend] }
        elseif ($envFor.ContainsKey($backend))  { $kind = 'env'; $reqName = $envFor[$backend] }
        elseif ($backend -eq 'openaicompat')    { $kind = 'env'; $reqName = $p.Value.api_key_env }
        if (-not $kind -or -not $reqName) { continue }
        $key = "${kind}:${reqName}"
        if (-not $seen.Contains($key)) { $seen[$key] = @{ kind = $kind; name = $reqName; presets = [System.Collections.Generic.List[string]]::new() } }
        $seen[$key].presets.Add($p.Name)
    }
    foreach ($key in $seen.Keys) {
        $req = $seen[$key]
        $unlocks = (@($req.presets) -join ', ')
        if ($req.kind -eq 'cli') {
            & $row "$($req.name) CLI" 'backend' $false (& $CommandExists $req.name) $null "install the $($req.name) CLI and sign in (CLI presets reuse your existing login)" $unlocks
        } else {
            & $row $req.name 'backend' $false ([bool](& $EnvValue $req.name)) $null "set `$env:$($req.name) (get a key from the provider console)" $unlocks
        }
    }
    return $rows.ToArray()
}

function Format-EraDoctorReport {
    <# Render a Get-EraDoctorReport result as a human report + readiness verdict.
       Ready == all required core checks pass AND >=1 backend is available. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Checks)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('=== /era preflight (Doctor) ===')
    $lines.Add('')
    foreach ($c in $Checks) {
        $mark = if ($c.ok) { '[ OK ]' } elseif ($c.required) { '[MISS]' } else { '[ -- ]' }
        $line = "$mark $($c.name)"
        if ($c.detail)  { $line += "  ($($c.detail))" }
        if ($c.unlocks) { $line += "  -> unlocks: $($c.unlocks)" }
        $lines.Add($line)
        if (-not $c.ok -and $c.fix) { $lines.Add("        fix: $($c.fix)") }
    }
    $coreReq = @($Checks | Where-Object { $_.category -eq 'core' -and $_.required })
    $coreOk  = ($coreReq.Count -gt 0) -and (@($coreReq | Where-Object { $_.ok }).Count -eq $coreReq.Count)
    $working = @($Checks | Where-Object { $_.category -eq 'backend' -and $_.ok })
    $lines.Add('')
    if ($coreOk -and $working.Count -ge 1) {
        $lines.Add("READY. Core prereqs present; $($working.Count) backend(s) available: $((@($working | ForEach-Object { $_.name }) -join ', '))")
    } else {
        $need = @()
        if (-not $coreOk)          { $need += 'the [MISS] core prereq(s) above' }
        if ($working.Count -lt 1)  { $need += 'at least one backend (install a CLI or set an API key above)' }
        $lines.Add("NOT READY -- need: $($need -join '; ')")
    }
    return ($lines -join "`n")
}

function Test-ReviewerListAgainstRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ReviewerList,
        [Parameter(Mandatory)][hashtable]$Registry
    )
    foreach ($r in $ReviewerList) {
        if (-not $Registry.ContainsKey($r)) {
            throw "Unknown reviewer preset: $r"
        }
    }
}

function Test-BackendCliAvailable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CliName)
    if (-not (Get-Command $CliName -ErrorAction SilentlyContinue)) {
        throw "Backend CLI '$CliName' is not on PATH."
    }
}

function Test-ThreadJobAvailable {
    $module = Get-Module -Name ThreadJob -ListAvailable -ErrorAction SilentlyContinue
    if (-not $module) {
        throw "ThreadJob module is required. Install with: Install-Module -Name ThreadJob -Force -Scope CurrentUser"
    }
}

# The concurrent-agy guard was removed: agy now selects its model per-process
# via --model (no shared settings.json swap, no global mutex), so two+ agy
# reviewers in one process no longer race. Each ThreadJob passes its own model.

function Resolve-AgyDefaultModelToken {
    <#
    Resolve THIS reviewer's default agy --model token from its OWN preset
    family/tier, keyed on the _agy_model_map. This is the no-hint DEFAULT only;
    an explicit -Model/-AgyModelHint/-ResolvedAgyModel override still wins
    upstream/in the adapter.

    Why per-reviewer: a heterogeneous agy batch (e.g. gemini,gemini-pro-low)
    MUST yield two distinct --model tokens. Resolving a single batch-level token
    from the first agy reviewer collapsed the batch to one model (spec §4 Fix 1).

    $AgyModelMap is the hashtable form of registry._agy_model_map
    (family-key -> tier object with .settings_value). Returns $null when the
    family/tier is missing or not an agy preset.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$AgyModelMap,
        [string]$Family,
        [string]$Tier
    )
    if (-not $AgyModelMap -or -not $Family -or -not $Tier) { return $null }
    if (-not $AgyModelMap.ContainsKey($Family)) { return $null }
    $famNode = $AgyModelMap[$Family]
    if (-not $famNode) { return $null }
    $tierNode = $famNode.$Tier
    if (-not $tierNode -or -not $tierNode.settings_value) { return $null }
    return $tierNode.settings_value
}

function Invoke-ReviewerDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ReviewerList,
        # Reviewer set used ONLY for response-filename suffix calculation (multi vs
        # single -> round-N-<preset>-response.md vs round-N-response.md). Defaults to
        # $ReviewerList; the agy-fallback re-dispatch passes the COMBINED list so the
        # fallback's file doesn't clobber round-N-response.md in a multi-reviewer run.
        [string[]]$SuffixReviewerList,
        [Parameter(Mandatory)][hashtable]$Registry,
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$Round,
        [int]$TimeoutSec = 600,
        [string]$SkillRootOverride,
        [string]$AgyModelHint,
        # Explicit batch-level agy model token (settings_value). When set (e.g. a
        # user-resolved -Model hint that mapped to an agy token), it overrides the
        # per-reviewer default for EVERY agy reviewer -- the user asked for a
        # specific model. Leave $null to let each agy reviewer derive its own
        # default from its preset family/tier (see -AgyModelMap below).
        [string]$ResolvedAgyModel,
        # registry._agy_model_map in hashtable form (family-key -> tier object).
        # Used to resolve each agy reviewer's DEFAULT --model token from its own
        # agy_model_family/agy_model_tier so a heterogeneous agy batch
        # (gemini,gemini-pro-low) does NOT collapse to one model. Only consulted
        # when there is no explicit -AgyModelHint and no -ResolvedAgyModel.
        [hashtable]$AgyModelMap = @{},
        [hashtable]$ModelOverrides = @{},
        [hashtable]$ProviderOverrides = @{},
        # Bundle size in tokens (from repomix). Used to scale TimeoutSec and
        # Wait-Job timeout: reasoning-heavy models on large bundles need 8+ min
        # of silent thinking before first output. Without scaling, a 100k-token
        # bundle on Pro `max` would be killed mid-think. Conservative formula:
        # 20ms per token => ~50 tok/sec, well below first-token rate for Flash
        # but realistic for max-variant reasoning models.
        [int]$BundleTokens = 0
    )
    Test-ThreadJobAvailable

    # Bundle-size-aware TimeoutSec scaling. Keeps the default 600s for small
    # bundles but grows linearly past ~30k tokens. The adapter sees this scaled
    # value and uses it for both stall and timeout checks; Wait-Job below uses
    # it + 30s margin so the adapter has room to throw cleanly before the
    # dispatcher kills the ThreadJob (which would leak native subprocesses).
    # Cap at 1800s (30 min) so a very large bundle doesn't tie up a threadpool
    # slot for an unbounded period — the adapter's own stall detector kills
    # stuck processes much earlier.
    $bundleScaledSec  = [int]($BundleTokens * 0.02)  # 20ms per token
    $effectiveTimeoutSec = [Math]::Min([Math]::Max($TimeoutSec, $bundleScaledSec), 1800)
    if ($effectiveTimeoutSec -gt $TimeoutSec) {
        Write-Host "[dispatch] Scaled TimeoutSec ${TimeoutSec}s -> ${effectiveTimeoutSec}s for ${BundleTokens}-token bundle."
        $TimeoutSec = $effectiveTimeoutSec
    }
    $skillRoot = if ($SkillRootOverride) { $SkillRootOverride } else { $PSScriptRoot }
    $dispatched = foreach ($r in $ReviewerList) {
        $modelInfo = @{} + $Registry[$r]
        $modelInfo.preset = $r
        # Apply model override if present
        if ($ModelOverrides.ContainsKey($r)) {
            $modelInfo.model_id = $ModelOverrides[$r]
        }
        $suffixList = if ($SuffixReviewerList) { $SuffixReviewerList } else { $ReviewerList }
        $suffix = Get-ResponseFilenameSuffix -ReviewerList $suffixList -Preset $r
        $respPath = Join-Path $ReviewDir "round-$Round$suffix-response.md"
        # Where this reviewer's adapter records its native child PID, so the
        # dispatcher can tree-kill it if the reviewer has to be abandoned early.
        # See Stop-EraAdapterChild for why Stop-Job cannot do this.
        $pidPath  = "$respPath.pid"
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
        $adapterPath = Join-Path $skillRoot "backends/$($modelInfo.backend).ps1"
        $fnName = "Invoke-$((Get-Culture).TextInfo.ToTitleCase($modelInfo.backend))Review"
        $opencodeProvider = if ($ProviderOverrides.ContainsKey($r)) { $ProviderOverrides[$r] } else { $null }
        # Only the agy adapter declares -ResolvedAgyModel. Pass it only for agy
        # reviewers so claude/opencode adapters don't choke on an unknown param.
        # Per-reviewer default resolution: an explicit batch -ResolvedAgyModel
        # (from a user -Model hint) still wins for every agy reviewer; otherwise
        # each agy reviewer derives its OWN default from its preset family/tier so
        # a heterogeneous batch keeps distinct --model tokens (spec §4 Fix 1).
        $resolvedAgyModelForReviewer = if ($modelInfo.backend -eq 'agy') {
            if ($ResolvedAgyModel) {
                $ResolvedAgyModel
            } else {
                Resolve-AgyDefaultModelToken -AgyModelMap $AgyModelMap `
                    -Family $modelInfo.agy_model_family -Tier $modelInfo.agy_model_tier
            }
        } else { $null }
        $job = Start-ThreadJob -Name "review-$r" -ThrottleLimit 4 -ScriptBlock {
            param($adapterPath, $bp, $pp, $rp, $mi, $to, $fnName, $agyHint, $modelOverride, $opencodeProvider, $resolvedAgyModel, $pidFile)
            try {
                . $adapterPath
                $commonArgs = @{
                    BundlePath       = $bp
                    PromptPath       = $pp
                    ResponsePath     = $rp
                    ModelInfo        = $mi
                    TimeoutSec       = $to
                    AgyModelHint     = $agyHint
                    ModelOverride    = $modelOverride
                    OpencodeProvider = $opencodeProvider
                }
                # -ResolvedAgyModel is agy-only; only splat it when the adapter
                # supports it (its param block declares it).
                if ((Get-Command $fnName).Parameters.ContainsKey('ResolvedAgyModel')) {
                    $commonArgs['ResolvedAgyModel'] = $resolvedAgyModel
                }
                # -PidFile is declared only by the adapters that spawn a native
                # child (agy/claude/opencode). The REST adapters have no child to
                # kill, so they never declare it and never get it.
                if ((Get-Command $fnName).Parameters.ContainsKey('PidFile')) {
                    $commonArgs['PidFile'] = $pidFile
                }
                $h = & $fnName @commonArgs
                # An adapter -- or any module it dot-sources -- can emit to the
                # SUCCESS stream, which makes $h an ARRAY rather than the result
                # hashtable. Select the structured result BEFORE stamping Preset
                # onto it.
                #
                # Measured 2026-08-10: assigning to a property of an array (or of
                # a bare string) throws "The property 'Preset' cannot be found on
                # this object", the catch below converts the whole reviewer into
                # an "Adapter exception", and the dispatcher's own "filter to the
                # last hashtable" defence at collection time can then NEVER run,
                # because the job never returns the array it was meant to filter.
                # The 'no-structured-output' branch was unreachable for the same
                # reason. One stray Write-Output anywhere in an adapter's load
                # path was enough to turn a good review into a failure.
                # NOTE the FULLY-QUALIFIED type. `$_ -is [pscustomobject]` is
                # True for EVERY pipeline item -- including a bare string --
                # because Where-Object binds $_ as a PSObject-wrapped value.
                # Measured 2026-08-10: scalar `'x' -is [pscustomobject]` is
                # False, but the same test inside Where-Object is True, so the
                # accelerator form is a filter that filters nothing.
                $h = @($h) |
                    Where-Object { $_ -is [hashtable] -or $_ -is [System.Management.Automation.PSCustomObject] } |
                    Select-Object -Last 1
                # $null here means the adapter produced nothing structured; the
                # collection path turns an empty job result into
                # Error='no-structured-output', which is the honest label.
                if ($h) { $h.Preset = $mi.preset }
                return $h
            } catch {
                # Bug 2 fix: never let the adapter's exception silently kill the ThreadJob --
                # the dispatcher synthesizes empty metadata in that case. Always return a
                # structured hashtable so downstream metadata + UI see the real failure.
                return @{
                    Preset            = $mi.preset
                    ExitCode          = -1
                    Response          = $null
                    CaptureMethod     = 'error'
                    InputTokens       = $null
                    OutputTokens      = 0
                    WallClockSec      = 0
                    Warnings          = @("Adapter exception: $($_.Exception.Message)")
                    Error             = $_.Exception.Message
                    Stderr            = "$_"
                    TruncationWarning = $null
                }
            }
        } -ArgumentList @($adapterPath, $BundlePath, $PromptPath, $respPath, $modelInfo, $TimeoutSec, $fnName, $AgyModelHint, $ModelOverrides[$r], $opencodeProvider, $resolvedAgyModelForReviewer, $pidPath)
        [pscustomobject]@{ Job = $job; Preset = $r; ResponsePath = $respPath; PidPath = $pidPath }
    }

    $allJobs = $dispatched | ForEach-Object { $_.Job }
    # Dispatcher timeout = adapter timeout + 30s margin. Without the margin, the
    # adapter's own stall/timeout throw races with Wait-Job's Stop-Job kill --
    # the adapter loses, leaving its native subprocesses (opencode.exe, agy.cmd,
    # claude.exe) as orphaned zombies because Stop-Job only kills the thread,
    # not the thread's children. The margin lets the adapter's own throw fire
    # cleanly, which kills its native process before this Stop-Job touches it.
    #
    # This used to be a single blocking wait across the whole job array, which
    # returns only when ALL jobs finish. One hung member therefore held the
    # round for the full scaled budget -- up to 1830s -- even with every other
    # reviewer long since done.
    # It is now a poll loop so a LONE straggler gets a bounded grace period
    # instead of the entire remaining budget. See Test-EraStragglerExpired for
    # why the grace default is what it is.
    $graceSec = 300
    if ($env:ERA_STRAGGLER_GRACE_SEC) {
        $g = 0
        if ([int]::TryParse($env:ERA_STRAGGLER_GRACE_SEC, [ref]$g) -and $g -ge 0) { $graceSec = $g }
    }
    $budgetSec  = $TimeoutSec + 30
    $sw         = [System.Diagnostics.Stopwatch]::StartNew()
    $loneSince  = -1
    $stopReason = ''
    $doneStates = @('Completed', 'Failed', 'Stopped')
    while ($true) {
        $outstanding = @($allJobs | Where-Object { $_.State -notin $doneStates }).Count
        if ($outstanding -eq 0) { break }
        $elapsed = [int]$sw.Elapsed.TotalSeconds
        if ($outstanding -eq 1 -and $loneSince -lt 0 -and @($allJobs).Count -ge 2) {
            $loneSince = $elapsed
            Write-Host "[dispatch] One reviewer still running at ${elapsed}s; allowing ${graceSec}s grace before abandoning it (ERA_STRAGGLER_GRACE_SEC)."
        }
        $stopReason = Test-EraStragglerExpired -ElapsedSec $elapsed -Outstanding $outstanding `
            -Total @($allJobs).Count -BudgetSec $budgetSec -GraceSec $graceSec -LoneSinceSec $loneSince
        if ($stopReason -eq 'grace') {
            # DO NOT Stop-Job here. Measured: a ThreadJob blocked inside
            # Process.WaitForExit() cannot be interrupted, so Stop-Job blocks
            # indefinitely and hangs the dispatcher while the child keeps
            # running. Kill the CHILD; the adapter's WaitForExit then returns,
            # its finally tree-kills defensively, and the job ends by itself.
            $straggler = @($dispatched | Where-Object { $_.Job.State -notin $doneStates })[0]
            $killed = $false
            if ($straggler) { $killed = Stop-EraAdapterChild -PidFile $straggler.PidPath }
            if ($killed) {
                Write-Host "[dispatch] Abandoned straggler '$($straggler.Preset)' after ${graceSec}s grace: tree-killed its child process."
                $unwindBy = (Get-Date).AddSeconds(20)
                while ($straggler.Job.State -notin $doneStates -and (Get-Date) -lt $unwindBy) {
                    Start-Sleep -Milliseconds 200
                }
                break
            }
            # No killable child (a REST adapter, or the PID was never recorded).
            # Abandoning would mean Stop-Job on a possibly-blocked job, which is
            # exactly the hang above, so fall back to the ONLY safe behaviour:
            # wait for the adapter's own timeout, as the +30s budget margin
            # was always designed to do. Disable the grace so this cannot spin.
            $who = if ($straggler) { $straggler.Preset } else { 'unknown' }
            Write-Host "[dispatch] Straggler '$who' has no killable child; waiting out its own timeout instead (grace disabled for this round)."
            $graceSec   = 0
            $stopReason = ''
        }
        elseif ($stopReason) { break }
        Start-Sleep -Milliseconds 500
    }

    $results = @{}
    foreach ($d in $dispatched) {
        try {
            if ($d.Job.State -ne 'Completed') {
                Stop-Job -Job $d.Job -ErrorAction SilentlyContinue
                $why = if ($stopReason -eq 'grace') {
                    "Abandoned after ${graceSec}s grace as the last outstanding reviewer" +
                    " (every other panel member had finished). Raise ERA_STRAGGLER_GRACE_SEC to wait longer."
                } else {
                    "Timed out after $TimeoutSec seconds (global)."
                }
                $results[$d.Preset] = @{
                    Preset = $d.Preset; ExitCode = -1; Response = $null
                    Warnings = @($why)
                    Error = 'timeout'
                }
            } else {
                # Receive-Job returns whatever the ThreadJob script block wrote
                # to the success stream. If an adapter or dot-sourced module
                # emitted any debug/info output via Write-Output (or implicit
                # output from an expression), it ends up here as additional
                # array elements alongside the final structured hashtable.
                # Filter to the last hashtable/PSCustomObject to be defensive.
                $rawJobOutput = Receive-Job -Job $d.Job -ErrorAction Stop
                # Fully-qualified type, for the reason documented at the
                # in-job filter above: `-is [pscustomobject]` matches every
                # pipeline item, so this "filter to the last hashtable" kept
                # everything and Select -Last 1 then returned whatever the
                # adapter happened to emit LAST -- trailing junk beat the real
                # result, and 'no-structured-output' was unreachable.
                $h = $rawJobOutput |
                    Where-Object { $_ -is [hashtable] -or $_ -is [System.Management.Automation.PSCustomObject] } |
                    Select-Object -Last 1
                if (-not $h) {
                    $h = @{
                        Preset = $d.Preset; ExitCode = -1; Response = $null
                        Warnings = @("Receive-Job returned no hashtable; raw output (first 500 chars): " + (("$rawJobOutput")[0..499] -join ''))
                        Error = 'no-structured-output'
                    }
                }
                $results[$d.Preset] = $h
            }
        } catch {
            $results[$d.Preset] = @{
                Preset = $d.Preset; ExitCode = -1; Response = $null
                Warnings = @("Adapter threw: $_")
                Error = "$_"
            }
        } finally {
            Remove-Job -Job $d.Job -Force -ErrorAction SilentlyContinue
        }
    }
    return $results
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

function Get-EraRecoverableFailures {
    <#
    .SYNOPSIS
        Which reviewers failed in a way the ONE bounded fallback re-dispatch can
        plausibly recover? Returns their preset names, de-duplicated.

    .DESCRIPTION
        The trigger used to be inline in era.ps1 and read:

            $failedAgy      = backend -eq 'agy'  AND ExitCode -ne 0
            $failedContract = Error   -eq 'response-contract'

        Its comment said the widening existed so that "a REST or opencode
        reviewer that returned off-contract output" no longer "spent the whole
        round with zero usable result and no recovery". Measured 2026-08-10, the
        intent was not met in the DEFAULT configuration: no shipped prompt
        carries an `era-require` marker (the contract is deliberately opt-in), so
        `response-contract` never fires on a default run and the only live
        trigger was `backend -eq 'agy'`. Everything else spent the round
        unrecovered -- including case (b) of the 2026-08-09 void round, where
        deepseek-flash failed after reading the bundle and nothing re-dispatched.

        Recoverable now means an HONEST CAPTURE FAILURE on any backend: the call
        completed and what came back was not a review. A second attempt can
        plausibly fix that.

        NOT recoverable: a free-text adapter exception (network fault, bad model
        id, auth, rate limit). Re-dispatching those doubles the latency and the
        bill for something a retry cannot fix -- the same reasoning the claude
        adapter already applies to its WSL credential retry.

        Widening WHAT is recoverable does not widen HOW MANY re-dispatches run:
        the caller is still bounded to one, still prices it against the
        per-reviewer cap, and still contract-checks the fallback's own answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReviewerList,
        [Parameter(Mandatory)][hashtable]$Results,
        [Parameter(Mandatory)][hashtable]$Registry
    )
    # Every error code an adapter sets deliberately to mean "this ran, and what
    # came back was not a review". Free-text exception messages are excluded by
    # construction: they never equal one of these.
    $recoverable = @('response-contract', 'agentic-narration-capture', 'prompt-echo')

    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $ReviewerList) {
        $res = $Results[$r]
        if (-not $res -or $res.ExitCode -eq 0) { continue }
        # agy stays recoverable on ANY failure: its capture is transcript-scraped
        # and historically flaky in ways that are not error-coded.
        $isAgy = $Registry[$r] -and $Registry[$r].backend -eq 'agy'
        if ($isAgy -or ($res.Error -and $recoverable -contains $res.Error)) {
            if (-not $out.Contains($r)) { $out.Add($r) }
        }
    }
    return @($out)
}

function Get-EraVoidRoundReport {
    <#
    .SYNOPSIS
        Did this round produce ANY usable review? Returns
        @{ IsVoid; UsableCount; Lines } — Lines is the per-reviewer breakdown.

    .DESCRIPTION
        A round could burn the full budget, write artifacts, and exit 0 having
        produced nothing a caller could read. Measured 2026-08-09 on the shipped
        three-model panel, all three void in the same run:

          opus (claude CLI)      exceeded its slice of the budget; no response file.
          deepseek-flash (opencode) failed after reading the bundle; no response file.
          gemini-pro-high (agy)  truncated at its output cap, answer demoted to
                                 round-1-gemini-pro-high-response.rejected.md,
                                 and the adapter still reported ContentOk=$true
                                 with error=null.

        era exited 0. On a single-reviewer dispatch that state reads as
        "reviewed, no findings" when nothing was reviewed.

        Judged on the artifact, for the reasons in Test-EraReviewerArtifact.
        Call AFTER Copy-PrimaryResponseAlias (so rejects are already demoted)
        and AFTER Write-ReviewMetadata (so the telemetry survives the exit).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$Round,
        [Parameter(Mandatory)][hashtable]$Results,
        [int]$RequestedCount = 0
    )
    $lines = [System.Collections.Generic.List[string]]::new()

    if ($Results.Count -eq 0) {
        # Nothing was dispatched. The usual cause is the user dropping every
        # reviewer at the cost prompt (Invoke-CostPrompt returns an empty list),
        # which is their call -- but it still produced no review, so say so
        # plainly and make clear no money changed hands.
        $lines.Add($(if ($RequestedCount -gt 0) {
            "  0 of $RequestedCount reviewer(s) were approved at the cost prompt. Nothing was dispatched and nothing was spent."
        } else {
            "  No reviewers were dispatched."
        }))
        return @{ IsVoid = $true; UsableCount = 0; Lines = @($lines) }
    }

    $pad = ((@($Results.Keys) | Measure-Object -Property Length -Maximum).Maximum)
    if (-not $pad) { $pad = 12 }

    $usable = 0
    foreach ($preset in (@($Results.Keys) | Sort-Object)) {
        $r = $Results[$preset]
        $hasArtifact = Test-EraReviewerArtifact -ReviewDir $ReviewDir -Round $Round `
            -Preset $preset -ReviewerCount $Results.Count
        if ($r -and $r.ExitCode -eq 0 -and $hasArtifact) { $usable++; continue }

        $why = if ($r.Error) { $r.Error }
               elseif ($r.RetryReason) { $r.RetryReason }
               else { 'no error reported' }
        $rejected = "round-$Round-$preset-response.rejected.md"
        $detail = if (Test-Path -LiteralPath (Join-Path $ReviewDir $rejected)) { "answer demoted to $rejected" }
                  elseif (-not $hasArtifact) { 'no response file' }
                  else { 'response present but not accepted' }
        if ($r.TruncationWarning) { $detail += '; truncated' }
        $exitStr = if ($null -ne $r.ExitCode) { $r.ExitCode } else { 'n/a' }
        $lines.Add(("  {0}  exit={1}  {2}; {3}" -f $preset.PadRight($pad), $exitStr, $why, $detail))
    }
    return @{ IsVoid = ($usable -eq 0); UsableCount = $usable; Lines = @($lines) }
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
        [string[]]$IncludeFilesList = @(),
        [int]$BundleFileCount = 0,
        [int]$TopicRoundCount = 0
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
                response_chars = if ($r.Response) { $r.Response.Length } else { 0 }
                bundle_tokens = $BundleTokens
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
                response_chars = $respLen
                bundle_tokens = $BundleTokens
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
        convergence_warnings = @($ConvergenceWarnings)
        reviewers = @($reviewerEntries)
    }
    $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReviewDir "round-$Round-metadata.json") -Encoding utf8
}

function ConvertTo-EraContractNormalized {
    <#
    .SYNOPSIS
        Normalise text for decoration-tolerant contract matching.

    .DESCRIPTION
        Measured on the 2026-08-09 panel: deepseek-flash answered '**P1: DO**'
        while gemini and opus answered 'P1: DO'. A literal check would have
        failed the sharpest response in the panel, so strip markdown decoration
        before comparing.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text -replace '[*`_#]', ''
    $t = $t -replace '\s+', ' '
    return $t.Trim().ToLowerInvariant()
}

function Get-EraResponseContract {
    <#
    .SYNOPSIS
        Read a prompt's declared response contract.

    .DESCRIPTION
        A prompt declares what its answer must contain with a marker line:

            <!-- era-require: ORDER:, DROP-ENTIRELY:, MISSING: -->

        The contract travels WITH the prompt, so a -PromptOverrideFile carries
        its own and no extra parameter is needed. No marker means lenient --
        exactly the behaviour before this existed, so existing callers are
        untouched.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$PromptText)
    if ([string]::IsNullOrEmpty($PromptText)) { return @() }
    # (?s) so the marker may WRAP across lines. Without it, `.` stopped at the
    # newline, `\s*-->` could not match, and the marker did not match AT ALL --
    # a wrapped contract vanished silently and the round ran ungated. An editor
    # hard-wrapping a long token list must not disarm the gate.
    #
    # The quantifier stays lazy and the `-->` terminator stays required, so
    # crossing newlines cannot let one marker swallow the rest of the document.
    # First marker wins (-match returns one hit); both are pinned by tests.
    if ($PromptText -notmatch '(?ims)<!--\s*era-require:\s*(.+?)\s*-->') { return @() }
    # Trim() covers the newlines and indentation a wrapped list introduces.
    return @($matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-ResponseContract {
    <#
    .SYNOPSIS
        Does a reviewer's response contain everything the prompt required?

    .DESCRIPTION
        Nothing verified that an answer matched the request: adapters checked
        non-empty text plus a finish reason, then returned ExitCode=0. A reviewer
        returned zero of ten requested verdicts three times and each was recorded
        as a normal success -- and the promoted response feeds the NEXT round's
        prompt, so a bad round poisons its successor.

        Uses .Contains() rather than -like, so a required token containing '[' or
        '*' is matched literally instead of being read as a glob.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Response,
        [AllowNull()][string[]]$Required
    )
    $req = @($Required | Where-Object { $_ })
    if ($req.Count -eq 0) { return @{ Ok = $true; Missing = @() } }

    $haystack = ConvertTo-EraContractNormalized -Text $Response
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $req) {
        $needle = ConvertTo-EraContractNormalized -Text $r
        if (-not $needle) { continue }
        if (-not $haystack.Contains($needle)) { $missing.Add($r) }
    }
    return @{ Ok = ($missing.Count -eq 0); Missing = @($missing) }
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

function Assert-EraResponseContract {
    <#
    .SYNOPSIS
        Apply a response contract across a dispatch result set, in place.
        Returns the number of results newly marked as failing.

    .DESCRIPTION
        Marks a violation exactly the way opencode marks a bad agentic capture
        (ExitCode=-1 + ContentOk=$false), so every existing consumer already
        behaves correctly: Copy-PrimaryResponseAlias skips it, the metadata
        writer records content_ok=false, and the agy fallback re-dispatches. The
        response file stays on disk -- it is evidence, not garbage; only its
        promotion to canonical is withheld.

        Results that already failed are skipped, so their original error is
        preserved and the function is idempotent. That matters because era calls
        it TWICE: once before the agy fallback, so a contract failure can trigger
        a re-dispatch, and once after, because otherwise the fallback's own
        answer is never checked.

        That second call is not hypothetical. Measured 2026-08-09 on a live
        dispatch: a failing agy reviewer triggered a fallback to gemini-api,
        whose answer was written as round-1-response.md with content_ok=true
        while missing the required token -- the exact failure mode this feature
        exists to prevent, occurring inside the feature itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Results,
        [AllowNull()][string[]]$Required
    )
    $req = @($Required | Where-Object { $_ })
    if ($req.Count -eq 0) { return 0 }

    $failed = 0
    foreach ($k in @($Results.Keys)) {
        $res = $Results[$k]
        if (-not $res -or $res.ExitCode -ne 0) { continue }
        $verdict = Test-ResponseContract -Response $res.Response -Required $req
        if ($verdict.Ok) { continue }
        $miss = ($verdict.Missing -join ', ')
        Write-Host "[era] $k FAILED the response contract; missing: $miss"
        $res.ExitCode    = -1
        $res.ContentOk   = $false
        $res.Error       = 'response-contract'
        $res.RetryReason = "response-contract: missing $miss"
        $res.Warnings    = @($res.Warnings) + "Response contract failed; missing: $miss"
        $Results[$k] = $res
        $failed++
    }
    return $failed
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
