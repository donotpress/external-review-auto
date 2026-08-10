#!/usr/bin/env pwsh
#Requires -Version 7.0
# pwsh 7+ is required (and assumed throughout): ThreadJob orchestration and the
# adapters' Process.Kill($true) tree-kill are .NET Core 3.0+ / PS7 APIs. Enforcing
# it here fails fast with a clear message under Windows PowerShell 5.1 instead of
# silently swallowing a missing-method exception mid-dispatch.
<#
.SYNOPSIS
    Single entry point for /external-review-auto.

.DESCRIPTION
    Bundles repo files with repomix, dispatches to one or more reviewer backends
    (agy, Claude CLI, opencode, REST adapters), and writes structured output to
    .external-reviews/<TopicSlug>/round-N-*.

    Round-number reservation (parallel-safe):
        Each invocation calls Reserve-ReviewRound, which atomically creates
        round-(N+1)-claim.json via FileMode.CreateNew.  Two concurrent processes
        against the same topic get different round numbers (N and N+1).  The
        claim file is deleted on successful completion; an aborted run leaves it
        orphaned (known limitation -- delete manually if needed).

    Multi-reviewer single-process (-Reviewer gemini,deepseek):
        One round number is reserved for the whole batch; reviewers run in
        parallel ThreadJobs inside this process.

    Multi-reviewer multi-process (separate era.ps1 invocations):
        Each process reserves its own round number independently.  Spawn them
        in PS background jobs and Wait-Job for N independent notifications.
#>
[CmdletBinding()]
param(
    [string]$TopicSlug,
    [ValidateSet('spec', 'assessment')][string]$Mode = 'spec',
    # [string[]] (was [string]) so unquoted `-Reviewer gemini,deepseek` parses
    # cleanly via PowerShell's native array coercion. Quoted single-string form
    # `-Reviewer 'gemini,deepseek'` still works because of the comma-split below.
    #
    # Default = a THREE-reviewer panel across three independent backends
    # (2026-08-02): Gemini 3.6 Flash via agy, Claude Opus 5 via the claude CLI,
    # DeepSeek V4 Flash via opencode. Cross-vendor by design — round 11 had
    # Gemini 3.1 Pro (High) review the wrong subject entirely (it followed the
    # topic slug instead of the round context) while Flash found a real shipped
    # regression, so a single reviewer is a single point of failure regardless of
    # which one you pick.
    #
    # Supersedes the single 'gemini-pro-low' default from Fix 5. That note said
    # bare 'gemini' (then 3.5 Flash) was the LEAST reliable preset — 67% ok over
    # 57 runs — versus Pro (Low) at ~94%. Two things change the calculus: the
    # Flash slot is now 3.6, and with three reviewers one flaky member degrades
    # the panel instead of losing the round.
    #
    # COST: roughly $0.3/$1.2 (Flash) + $15/$75 (Opus) + $0.28/$0.42 (DeepSeek)
    # per M in/out. Opus dominates — a bare /era is now materially more expensive
    # than the old single-Flash default. Per-reviewer cap stays $2. Drop to one
    # with an explicit -Reviewer, e.g. `-Reviewer gemini`.
    #
    # Opus runs on the SUBSCRIPTION claude CLI, not opus-api: ANTHROPIC_API_KEY
    # is not set on this box, so the -api presets cannot run at all.
    #
    # This literal is only a parse-time placeholder — a param default cannot call
    # the shared helper. It is REPLACED below with Get-EraDefaultReviewer once
    # $skillRoot exists, so config/defaults.json stays the single source of truth
    # and this list can never silently disagree with resolve.ps1.
    [string[]]$Reviewer = @('gemini', 'opus', 'deepseek-flash'),
    [string]$AgyModel,
    [string]$Model,
    [string]$Provider,
    [ValidateSet('', 'update-models', 'doctor', 'list', 'set-default', 'review-this', 'suggest')][string]$Command = '',
    # -Doctor: preflight only. Prints a consolidated prereq/backend status report
    # (pwsh, ThreadJob, repomix, each backend CLI/API key) and exits without
    # dispatching a review. Never installs anything — it reports the fix commands.
    [switch]$Doctor,
    [switch]$Force,
    # -ForceBroadScope: consent to a repo-wide bundle that exceeds the scale
    # ceiling. Deliberately SEPARATE from -Force, which means "skip the COST
    # prompt" (SKILL.md) and which the skill's own normative dispatch line passes
    # on every call. Folding the two together would leave the scale gate inert
    # for the only caller this skill documents — an agent dispatching
    # non-interactively — which is how the 72,378-file run happened.
    # ERA_BROAD_FORCE=1 is the env equivalent for CI.
    [switch]$ForceBroadScope,
    # -AllowDirtyTree: dispatch even though the working tree has uncommitted
    # changes. Deliberately SEPARATE from -Force for the same reason as
    # -ForceBroadScope: -Force means "skip the COST prompt" and the skill's own
    # normative dispatch line passes it on every call, so folding them together
    # would leave this gate inert for the only caller the skill documents.
    #
    # WHY THE GATE EXISTS. A review bundles the WORKING TREE, but the round is
    # reasoned about as "commits X..Y". When the tree is dirty those are
    # different things: the reviewer sees uncommitted edits, the author later
    # commits them, and the resulting commit was never reviewed by the round
    # that appears to cover it. That produced an unreviewed layer THREE TIMES in
    # one session, purely from ordering. ERA_ALLOW_DIRTY=1 is the env equivalent.
    [switch]$AllowDirtyTree,
    [string[]]$IncludeFiles,
    [string]$PromptOverrideFile,
    # 2026-06-10 hardening P2: typed channel for the calling agent's
    # conversation distillation (goal, findings, claims to refute — see
    # SKILL.md "Conversation context hand-off"). Read into the prompt, never
    # bundled, so absolute paths outside the repo are fine. Injected into
    # {{CONVERSATION_CONTEXT}} when the prompt has the placeholder; appended
    # as '## Session context' to generated/template prompts otherwise; with a
    # user-supplied -PromptOverrideFile it is honored ONLY via the
    # placeholder (else warned + ignored).
    [string]$ConversationFile,
    # NOTE: -Full was previously declared but never read by any code path.
    # Removed in 2026-05-27 cleanup. Use -Diff to opt into diff-bundling on
    # round 2+; absence of -Diff produces the full bundle (default behavior).
    [switch]$Diff,
    # PR 4: -AutoDetect derives candidate -IncludeFiles from git status + HEAD~1.
    # Additive with -IncludeFiles: if both are passed, the resulting list is the
    # union. Intended for human callers; LLM callers should use -IncludeFiles
    # explicitly. Requires git on PATH and a git work tree.
    [switch]$AutoDetect,
    # PR 5: -SpecReview <spec_path> — one-flag spec review preset.
    # Auto-fills the spec-review prompt template, bundles the spec file, and
    # optionally auto-includes related files from the spec's frontmatter.
    # Mutually exclusive with -PromptOverrideFile.
    # Additive with -IncludeFiles (spec + related + user-extras).
    [string]$SpecReview
)
$ErrorActionPreference = 'Stop'

# 2026-06-10 hardening P5.1: accept comma-joined -IncludeFiles ("a.py,b.py").
# `pwsh -File era.ps1 -IncludeFiles @(...)` flattens the array into positional
# args (the 2nd element binds to -Mode and errors); the comma-string form is
# the portable alternative for non-PowerShell-native callers.
#
# 2026-08-09: key this off $PSBoundParameters, not truthiness. PowerShell unwraps
# a single-element array, so -IncludeFiles "" is FALSY and indistinguishable from
# omission — and omission is the documented repo-wide broad-audit mode. A caller
# whose shell handed us an empty string therefore got "bundle everything"
# (72,378 files, one crashed repomix, a 16.9 MB log). Record the raw value for
# the error message; the refusal itself lives below, after Stop-EraWithError is
# defined. Same idiom already used for -PromptOverrideFile and -Reviewer.
$script:UserSuppliedIncludeFiles = $PSBoundParameters.ContainsKey('IncludeFiles')
$script:RawIncludeFiles = if ($script:UserSuppliedIncludeFiles) { (@($IncludeFiles) -join ',') } else { '' }
if ($script:UserSuppliedIncludeFiles) {
    $IncludeFiles = @($IncludeFiles |
        ForEach-Object { "$_" -split ',' } |
        ForEach-Object { $_.Trim().Trim('"', "'") } |
        Where-Object { $_ })
}

# 2026-06-10 hardening P2: remember whether -PromptOverrideFile came from the
# USER (vs being set later by the -SpecReview generator or pending-prompt
# auto-detect) — user-supplied prompts only honor -ConversationFile via an
# explicit {{CONVERSATION_CONTEXT}} placeholder.
$script:UserSuppliedPromptOverride = $PSBoundParameters.ContainsKey('PromptOverrideFile')

$skillRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $skillRoot 'workflow.ps1')
# Layer-2 model-hint resolver (extracted from this script in PR-D / D.0 so the
# contract test can call Resolve-ModelFromHint directly without forking pwsh).
. (Join-Path $PSScriptRoot 'resolve-model.ps1')
# Shared default-reviewer resolution — the SAME helper resolve.ps1 uses, so the
# two layers cannot drift apart (they previously carried separate defaults with
# different parsing). See runtimes/_era-defaults.ps1.
. (Join-Path $PSScriptRoot '_era-defaults.ps1')

# Normalize Git-Bash/MSYS drive paths (/c/Users/x -> C:/Users/x) in -IncludeFiles so
# callers shelling from bash on Windows don't trip the out-of-repo file check.
# (After workflow.ps1 is dot-sourced so ConvertTo-EraNativePath is available.)
if ($IncludeFiles) { $IncludeFiles = @($IncludeFiles | ForEach-Object { ConvertTo-EraNativePath $_ }) }

if ($Force) { $env:ERA_FORCE = '1' }

function Stop-EraWithError {
    # Clean single-line preflight error for known user mistakes (bad -IncludeFiles,
    # empty bundle) — no raw PowerShell exception/stack. era.ps1 always runs as a
    # script (never dot-sourced); tests invoke it out-of-process, so exit is safe.
    param([string]$Message)
    Write-Host "[era] ERROR: $Message"
    exit 1
}

# --- Doctor preflight: report prereq + backend status, then exit (no dispatch) ---
if ($Doctor) {
    $rawRegistry = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'backends/_registry.json') | ConvertFrom-Json
    Write-Host (Format-EraDoctorReport -Checks (Get-EraDoctorReport -Registry $rawRegistry))
    # 2026-06-10 P5.3: the /era alias SKILL.md directs callers here — verify
    # this skill root actually has the runtimes the alias promises.
    $aliasOk = (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'resolve.ps1')) -and
               (Test-Path -LiteralPath (Join-Path $skillRoot 'backends/_registry.json'))
    Write-Host ("[{0}] era-alias skill-root resolution (runtimes/resolve.ps1 + backends/_registry.json reachable from {1})" -f ($(if ($aliasOk) { ' OK ' } else { 'FAIL' })), $skillRoot)
    return
}

# --- Explicit -IncludeFiles that resolves to nothing is a caller bug ----------
# Placed after the -Doctor block so preflight still runs, and after
# Stop-EraWithError is defined. The normaliser above can MANUFACTURE this case
# from non-empty input: -IncludeFiles "," is truthy, but splitting on ',' and
# dropping blanks reduces it to @(). Note the asymmetry this repairs — zero
# files MATCHED is already fatal ("Bundle is empty" below); zero files SPECIFIED
# used to become everything.
if ($script:UserSuppliedIncludeFiles -and @($IncludeFiles).Count -eq 0) {
    Stop-EraWithError ("-IncludeFiles was supplied but resolved to zero paths (raw value: '{0}'). " -f $script:RawIncludeFiles +
        "Refusing to silently upgrade that to a repo-wide bundle. Omit -IncludeFiles entirely if you " +
        "want the documented broad audit. Common cause: in bash `&` binds looser than `&&`, so " +
        "`FILES=... && era ... &` leaves the assignment in a subshell and the next dispatch receives " +
        "an empty string — export the variable on its own line instead.")
}

# Guard the git call: under $ErrorActionPreference='Stop', `& git` throws a raw
# "term 'git' is not recognized" when git isn't on PATH (no .git in cwd). Only invoke
# git when it exists; otherwise fall back to cwd (line below). repomix still bundles
# explicit -IncludeFiles from a non-git directory.
$repoRoot = if (Test-Path -LiteralPath ".git") { (Get-Location).Path }
            elseif (Get-Command git -ErrorAction SilentlyContinue) { $(& git rev-parse --show-toplevel 2>$null) }
            else { $null }
if (-not $repoRoot) { $repoRoot = (Get-Location).Path }

function Get-EraGitState {
    <#
    .SYNOPSIS
        HEAD sha, branch and uncommitted-file list for $RepoRoot, or $null when
        this is not a git work tree / git is unavailable.
    .DESCRIPTION
        Stamped into the round manifest so a review round is anchored to a
        COMMIT rather than to "whatever the tree happened to contain". Without
        it there is no way, after the fact, to tell which code a given round
        actually saw — and rounds are cited as evidence in commit messages.

        `--porcelain` omits ignored files, so era's own artifacts under
        .external-reviews (gitignored in every repo that uses it) do not count
        as dirt. Untracked-but-not-ignored files DO count: a new source file the
        reviewer reads and the author then commits is exactly the unreviewed
        layer this is meant to catch.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) { return $null }

    $head = & git -C $RepoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $head) { return $null }
    $branch = & git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null
    $porcelain = @(& git -C $RepoRoot status --porcelain 2>$null | Where-Object { $_ })

    return [pscustomobject]@{
        Head   = $head.Trim()
        Branch = if ($branch) { $branch.Trim() } else { '(unknown)' }
        Dirty  = $porcelain
    }
}

$eraGitState = Get-EraGitState -RepoRoot $repoRoot

function Get-SpecGlob {
    <#
    .SYNOPSIS
        Returns the glob for auto-detecting design spec files, configurable via
        ERA_SPEC_GLOB env var. Defaults to the superpowers convention.
    #>
    if ($env:ERA_SPEC_GLOB) {
        return [string]$env:ERA_SPEC_GLOB
    }
    return 'docs/superpowers/specs/*-design.md'
}

# --- Crash recovery: restore agy settings.json from prior aborted run ---
# DEPRECATED (self-deprecating, keep ONE release): agy model selection no longer
# swaps settings.json -- it passes --model per-process (concurrent-safe). No new
# .era-backup files are created. This block remains for one release purely to
# restore any pre-upgrade orphaned backup left by a crash BEFORE the upgrade
# (otherwise such a user would be stuck on the wrong interactive model forever).
# Safe to delete once all installs have run a post-upgrade era at least once.
# See references/troubleshooting.md ("agy settings.json .era-backup").
$agyBackupPath = Join-Path $HOME '.gemini/antigravity-cli/settings.json.era-backup'
if (Test-Path -LiteralPath $agyBackupPath) {
    $agySettingsPath = Join-Path $HOME '.gemini/antigravity-cli/settings.json'
    try {
        Copy-Item -LiteralPath $agyBackupPath -Destination $agySettingsPath -Force
        Remove-Item -LiteralPath $agyBackupPath -Force -ErrorAction SilentlyContinue
        Write-Host "[era] Restored agy settings from prior interrupted session."
    } catch {
        # Restore FAILED -- KEEP the backup so a later run can retry. Deleting it
        # here (the old behavior) permanently lost the user's pre-crash settings
        # whenever Copy-Item failed (e.g. file lock / permissions) — round-5 fix.
        Write-Host "[era] WARNING: could not restore agy settings from backup ($($_.Exception.Message)); leaving '$agyBackupPath' in place to retry next run."
    }
}

# --- Crash recovery: restore opencode model.json from prior aborted run ---
# Mirror of the agy pattern. The opencode backend writes a disk backup to
# model.json.era-backup BEFORE mutating model.json. If a prior dispatch crashed
# (Ctrl-C, OOM, Stop-Process) before the in-memory restore could run, this
# block recovers the user's interactive opencode state at the next era launch.
$opencodeBackupPath = Join-Path $HOME '.local/state/opencode/model.json.era-backup'
if (Test-Path -LiteralPath $opencodeBackupPath) {
    $opencodeStatePath = Join-Path $HOME '.local/state/opencode/model.json'
    try {
        Copy-Item -LiteralPath $opencodeBackupPath -Destination $opencodeStatePath -Force
        Remove-Item -LiteralPath $opencodeBackupPath -Force -ErrorAction SilentlyContinue
        Write-Host "[era] Restored opencode model.json from prior interrupted session."
    } catch {
        # Restore FAILED -- KEEP the backup so a later run can retry, rather than
        # deleting the user's pre-crash model.json state (round-5 fix; mirror of agy).
        Write-Host "[era] WARNING: could not restore opencode model.json from backup ($($_.Exception.Message)); leaving '$opencodeBackupPath' in place to retry next run."
    }
}

# --- update-models command ---
if ($Command -eq 'update-models') {
    . (Join-Path $skillRoot 'runtimes/update-models.ps1')
    Invoke-UpdateModels -SkillRoot $skillRoot
    return
}

# --- doctor command (same as -Doctor switch, reachable via Command flag) ---
if ($Command -eq 'doctor') {
    $rawRegistry = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'backends/_registry.json') | ConvertFrom-Json
    Write-Host (Format-EraDoctorReport -Checks (Get-EraDoctorReport -Registry $rawRegistry))
    return
}

# --- list command: show selectable reviewers + readiness (/era models) -------
if ($Command -eq 'list') {
    $rawRegistry = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'backends/_registry.json') | ConvertFrom-Json
    $listEnvs = @($rawRegistry.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } |
        ForEach-Object { $_.Value.api_key_env })
    Resolve-EraAuthJsonKeys -ApiKeyEnvs $listEnvs
    # Report what a bare /era will ACTUALLY run. `$Reviewer`'s own default is the
    # panel, and it wins unless ERA_DEFAULT_REVIEWER overrides it — so reading
    # only the env var (or only Resolve-DefaultReviewer) printed a single preset
    # while the real default was three, which reads as "my change didn't take".
    # Read the SAME source a bare /era uses, so `list` can never advertise a
    # default that differs from what actually dispatches.
    $listDefault = (Get-EraDefaultReviewer -SkillRoot $skillRoot) -join ', '
    $listRows = Get-EraReviewerList -Registry $rawRegistry -Default $listDefault
    Write-Host (Format-EraReviewerList -Rows $listRows -Default $listDefault)
    return
}

# --- set-default command: persist ERA_DEFAULT_REVIEWER -----------------------
if ($Command -eq 'set-default') {
    # Accepts ONE preset or a PANEL. It used to hard-error on more than one, which
    # made a multi-reviewer default un-settable through the supported path.
    $presets = @($Reviewer | ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    if (-not $presets) {
        throw "set-default requires at least one reviewer preset. Got: $Reviewer"
    }
    # Validate every preset against the registry before writing anything.
    $rawRegistry = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'backends/_registry.json') | ConvertFrom-Json
    $validPresets = @($rawRegistry.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object { $_.Name })
    $unknown = @($presets | Where-Object { $_ -notin $validPresets })
    if ($unknown) {
        throw "Unknown reviewer preset(s): $($unknown -join ', '). Valid presets: $($validPresets -join ', ')"
    }

    # Persist to the CONFIG FILE, not an environment variable. An env var is
    # per-process and inherited: setting it at Windows User scope leaves every
    # already-running shell (and everything they spawn) on the OLD value, and
    # PowerShell / WSL / opencode / agy each read a different store. The file is
    # located from $PSScriptRoot, so all of them see the same default.
    $written = Set-EraDefaultReviewer -SkillRoot $skillRoot -Reviewer $presets

    # A stale env var would out-rank the file we just wrote, so clear it in this
    # process and drop the persisted copy that older versions used to set.
    $env:ERA_DEFAULT_REVIEWER = $null
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        try { [Environment]::SetEnvironmentVariable('ERA_DEFAULT_REVIEWER', $null, 'User') } catch { }
    }

    $label = if ($presets.Count -gt 1) { "panel: $($presets -join ', ')" } else { "'$($presets[0])'" }
    Write-Host "[era] Default reviewer set to $label."
    Write-Host "[era] Written to $written — read identically from Claude Code, PowerShell, WSL, opencode and agy."
    if ($presets.Count -gt 1) {
        Write-Host "[era] A bare /era will dispatch all $($presets.Count) simultaneously."
    }
    Write-Host "[era] To change: '/era set default to <name>' (or edit that file)."
    return
}

# --- review-this command: auto-detect context and dispatch --------------------
if ($Command -eq 'review-this') {
    Write-Host "[era] Detecting review context..."
    $detectedTopic = $null
    $detectedFiles = @()
    $detectedSpec = $null

    # 1. Check for newest spec file
    $specFiles = Get-ChildItem (Join-Path $repoRoot (Get-SpecGlob)) -ErrorAction SilentlyContinue
    if ($specFiles) {
        $newestSpec = $specFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $detectedSpec = $newestSpec.FullName
        $detectedTopic = $newestSpec.BaseName -replace '^\d{4}-\d{2}-\d{2}-', '' -replace '-design$', ''
        Write-Host "[era] Found spec: $($newestSpec.Name) -> topic '$detectedTopic'"
    }

    # 2. Check git for recent changes
    $gitAvailable = (Get-Command git -ErrorAction SilentlyContinue) -ne $null
    $recentFiles = @()
    if ($gitAvailable) {
        $isGitWorkTree = $null -ne (& git rev-parse --is-inside-work-tree 2>$null)
        if ($isGitWorkTree) {
            $uncommitted = @(Get-EraPorcelainPaths -RepoRoot $repoRoot)
            $recentCommit = @(& git diff --name-only HEAD~1..HEAD 2>$null | Where-Object { $_ })
            $recentFiles = @($uncommitted + $recentCommit) | Sort-Object -Unique | Where-Object { $_ -and $_.Trim() -ne '' }
            if ($recentFiles.Count -gt 0) {
                Write-Host "[era] Found $($recentFiles.Count) changed file(s) from git."
            }
        }
    }

    # 3. Decide what to do
    if ($detectedSpec) {
        Write-Host "[era] Dispatching spec review for '$detectedTopic'..."
        # Set flags and continue to normal dispatch flow
        $SpecReview = $detectedSpec
    } elseif ($recentFiles.Count -gt 0) {
        Write-Host "[era] Dispatching review of $($recentFiles.Count) changed file(s)..."
        $IncludeFiles = $recentFiles
        if (-not $TopicSlug) {
            # Timestamped slug (2026-06-10 P2.3): a fixed 'review-this' slug
            # collides across unrelated sessions in .external-reviews/. NEVER
            # derive the slug from a -ConversationFile filename (temp names
            # like session.md collide even worse).
            $TopicSlug = 'review-this-' + (Get-Date -Format 'yyyyMMdd-HHmm')
        }
        $Force = $true  # auto-dispatch, no cost prompt
    } elseif ($ConversationFile) {
        # 2026-06-10 P2.3: conversation-context-only review — no spec, no git
        # changes, but the caller supplied session context. Degraded mode (no
        # source bundle) is warned per SKILL.md; the caller should normally
        # also pass -IncludeFiles.
        Write-Host "[era] WARNING: review-this with -ConversationFile but no spec/changed files — dispatching context-only (degraded: no source bundle)."
        if (-not $TopicSlug) {
            $TopicSlug = 'review-this-' + (Get-Date -Format 'yyyyMMdd-HHmm')
        }
        $Force = $true
    } else {
        Write-Host "[era] No spec files or recent git changes found."
        Write-Host "[era] Pass -TopicSlug and -IncludeFiles explicitly, or run from a repo with recent activity."
        return
    }
}

# --- suggest command: scan repo and recommend review targets ------------------
if ($Command -eq 'suggest') {
    Write-Host "[era] Scanning for review targets..."
    $suggestions = [System.Collections.Generic.List[string]]::new()

    # 1. Spec files
    $specFiles = Get-ChildItem (Join-Path $repoRoot (Get-SpecGlob)) -ErrorAction SilentlyContinue
    if ($specFiles) {
        $suggestions.Add("=== Specs (review with: /era review spec <name>) ===")
        foreach ($s in ($specFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 10)) {
            $slug = $s.BaseName -replace '^\d{4}-\d{2}-\d{2}-', '' -replace '-design$', ''
            $age = [math]::Round(((Get-Date) - $s.LastWriteTime).TotalDays, 1)
            $suggestions.Add("  $slug  ($age days old)")
        }
    }

    # 2. Recent git changes
    $gitAvailable = (Get-Command git -ErrorAction SilentlyContinue) -ne $null
    if ($gitAvailable) {
        $isGitWorkTree = $null -ne (& git rev-parse --is-inside-work-tree 2>$null)
        if ($isGitWorkTree) {
            $recentFiles = @(& git diff --name-only HEAD~3..HEAD 2>$null | Where-Object { $_ })
            if ($recentFiles.Count -gt 0) {
                $suggestions.Add("")
                $suggestions.Add("=== Recent commits (review with: /era review this) ===")
                $logEntries = & git log --oneline -5 2>$null
                foreach ($entry in $logEntries) { $suggestions.Add("  $entry") }
            }
        }
    }

    # 3. Existing review topics
    $reviewDir = Join-Path $repoRoot '.external-reviews'
    if (Test-Path -LiteralPath $reviewDir) {
        $topics = Get-ChildItem -LiteralPath $reviewDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'test' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 10
        if ($topics) {
            $suggestions.Add("")
            $suggestions.Add("=== Existing review topics ===")
            foreach ($t in $topics) {
                $rounds = @(Get-ChildItem -LiteralPath $t.FullName -Filter 'round-*-response.md' -ErrorAction SilentlyContinue).Count
                $age = [math]::Round(((Get-Date) - $t.LastWriteTime).TotalDays, 1)
                $suggestions.Add("  $($t.Name)  ($rounds rounds, last: $age days ago)")
            }
        }
    }

    if ($suggestions.Count -eq 0) {
        Write-Host "[era] No review targets found. Run from a repo with specs or recent git activity."
    } else {
        Write-Host ($suggestions -join "`n")
    }
    return
}

# --- PR 5: -SpecReview preset ---
if ($SpecReview) {
    # Mutual exclusion check
    if ($PromptOverrideFile) {
        throw "-SpecReview and -PromptOverrideFile are mutually exclusive. -SpecReview generates the prompt from a template; -PromptOverrideFile uses your prompt verbatim. Pick one."
    }
    if (-not (Test-Path -LiteralPath $SpecReview)) {
        throw "-SpecReview: spec file not found: $SpecReview"
    }
    $specReviewPath = (Resolve-Path -LiteralPath $SpecReview).Path

    # Auto-derive -TopicSlug from spec filename if not provided
    if (-not $TopicSlug) {
        $specBaseName = [System.IO.Path]::GetFileNameWithoutExtension($specReviewPath)
        $TopicSlug = $specBaseName -replace '^\d{4}-\d{2}-\d{2}-', '' -replace '-design$', ''
        Write-Host "[era] -SpecReview: derived TopicSlug '$TopicSlug' from spec filename."
    }

    # Parse frontmatter for related files (YAML `related_files:` list or `Related: ` lines)
    # Fix 8a: strip surrounding single/double quotes from EVERY parsed path. A
    # YAML-quoted entry like `- "backends/agy.ps1"` would otherwise keep its quotes
    # and fail Test-Path, crashing the dispatch. Three accepted forms below:
    #   block-list   :  related_files:\n  - a.ps1\n  - "b.ps1"
    #   inline-list  :  related_files: ["a.ps1","b.ps1"]
    #   inline Related: line anywhere in the doc:  Related: "a.ps1", 'b.ps1'
    $specContent = Get-Content -LiteralPath $specReviewPath -Raw
    $relatedFiles = @()
    # YAML frontmatter block (between --- markers)
    if ($specContent -match '^---\s*\n([\s\S]*?)\n---') {
        $yamlBlock = $matches[1]
        # Block-list form: a `related_files:` key followed by indented `- ` items.
        if ($yamlBlock -match '(?m)^related_files:\s*\n((?:\s+-\s+.+\n?)*)') {
            $listBlock = $matches[1]
            $relatedFiles += @($listBlock -split '\n' | Where-Object { $_ -match '^\s+-\s+(.+)' } | ForEach-Object { ($_ -replace '^\s+-\s+', '').Trim().Trim('"', "'") })
        }
        # Inline-list form: `related_files: ["a.ps1","b.ps1"]` (valid YAML flow seq).
        # Non-greedy [^\]]+ stops at the first closing bracket on the same line.
        if ($yamlBlock -match '(?m)^related_files:\s*\[([^\]]+)\]') {
            $inlineList = $matches[1]
            $relatedFiles += @($inlineList -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
        }
    }
    # Plain `Related: path1, path2` lines anywhere in the doc
    $specContent -split '\n' | Where-Object { $_ -match '^Related:\s+(.+)' } | ForEach-Object {
        $relatedFiles += @($matches[1] -split ',\s*' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
    }

    # Build IncludeFiles: spec + related + any user-supplied extras (additive)
    $specRelPath = $specReviewPath
    # Make relative to repoRoot if inside the repo
    if (Test-EraPathInsideRoot -Path $specReviewPath -Root $repoRoot) {
        $specRelPath = $specReviewPath.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
    }
    $specIncludeFiles = @($specRelPath) + @($relatedFiles | Where-Object { $_ })
    $IncludeFiles = @($specIncludeFiles; $IncludeFiles) | Sort-Object -Unique | Where-Object { $_ }

    # Generate the spec-review prompt from the SKILL.md template
    $specTitle = $TopicSlug -replace '-', ' '
    $specPromptContent = @"
# External Review Prompt — $specTitle

You are reviewing a design spec. The spec is included in the attached bundle.

Every other file in the bundle is **existing code** the implementation will touch or that provides necessary context for the design decisions.

The spec and all source files are fully included in the attached bundle. Review ONLY what is in the bundle. Do NOT attempt to open, view, fetch, or read any file outside the bundle.

## What to review

Please assess the spec for the following, in priority order. **Be specific** — point to file paths, line numbers, exact functions.

### 1. Correctness — does the design actually solve the problem?
### 2. Race conditions / concurrency
### 3. Compatibility with existing code paths and conventions
### 4. Persistence / migration plumbing (only if applicable; skip if not)
### 5. Edge cases the spec missed
### 6. Testability — are the proposed tests sufficient?
### 7. Anything else wrong, missing, or under-specified.

Cite locations as file:line using the line numbers shown in the bundle; if unsure of a number, cite the function/symbol name instead of guessing.

## Output format

``````
## Critical issues (must fix before implementation)
1. <file:line> — <issue> — <suggested fix>

## Important issues (should fix)
1. ...

## Minor / nits
1. ...

## Things the spec got right (briefly, so I know what's solid)
1. ...

## Open questions for the author
1. ...
``````

Be terse. Don't pad. If a section is empty, write "(none)".
"@

    # Write prompt to a temp path in the topic dir; era.ps1 will copy it to
    # the correct round-N-prompt.md via the -PromptOverrideFile path.
    $tmpTopicDir = Join-Path $repoRoot ".external-reviews/$TopicSlug"
    New-Item -ItemType Directory -Path $tmpTopicDir -Force -ErrorAction SilentlyContinue | Out-Null
    $tmpPromptPath = Join-Path $tmpTopicDir 'spec-review-generated-prompt.md'
    Set-Content -LiteralPath $tmpPromptPath -Value $specPromptContent -Encoding UTF8
    $PromptOverrideFile = $tmpPromptPath
    Write-Host "[era] -SpecReview: generated spec-review prompt at $tmpPromptPath"
    if ($relatedFiles.Count -gt 0) {
        Write-Host "[era] -SpecReview: auto-included related files from frontmatter: $($relatedFiles -join ', ')"
    }
}

# --- Normal review workflow starts here ---
$reviewerList = @($Reviewer -split ',' | ForEach-Object { $_.Trim().ToLower() })

$registry = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'backends/_registry.json') | ConvertFrom-Json

# --- Adaptive default reviewer (only when -Reviewer was NOT explicitly passed) ---
# Don't blindly default to agy and error out if it isn't installed. Detect what's
# available live (CLI on PATH / API key set) and pick the first usable backend by
# preference. Override the order with $env:ERA_DEFAULT_REVIEWER. An explicit
# -Reviewer is always respected as-is (and still errors if its backend is missing).
if (-not $PSBoundParameters.ContainsKey('Reviewer')) {
    # Re-resolve from the shared helper (env override -> config/defaults.json ->
    # shipped panel). This is what makes the param-default literal above inert:
    # whatever the file says wins, from any shell.
    $reviewerList = @(Get-EraDefaultReviewer -SkillRoot $skillRoot)

    $defaultPref = @($reviewerList)
    # Backends to fall back through if the configured default's backend is absent.
    $defaultPref += @('gemini-pro-low', 'sonnet', 'deepseek', 'gemini-api')
    $autoReviewer = Resolve-DefaultReviewer -Registry $registry -Preference $defaultPref
    if (-not $autoReviewer) {
        throw @"
No review backend is available. /era needs at least ONE of:
  - the agy, claude, or opencode CLI on PATH (reuses your existing login), OR
  - an API key: GEMINI_API_KEY / ANTHROPIC_API_KEY / DEEPSEEK_API_KEY / MINIMAX_API_KEY.
Run 'pwsh runtimes/era.ps1 -Doctor' for a full status report with fix commands.
"@
    }
    # Only collapse to the auto-selected single reviewer when the default really
    # IS a single reviewer. The default is now a three-backend panel, and this
    # branch used to rewrite $reviewerList to @($autoReviewer) unconditionally —
    # which would silently run one reviewer while reporting a panel, the exact
    # failure mode the panel exists to avoid.
    #
    # Keeping the guard for the single-default case preserves the original
    # intent: don't hard-fail when the default's backend isn't installed.
    # A multi-reviewer default is left intact; any member whose backend is
    # missing fails loudly on its own dispatch, which is what we want to see.
    $defaultIsPanel = $reviewerList.Count -gt 1
    if ($autoReviewer -ne $reviewerList[0] -and -not $defaultIsPanel) {
        Write-Host "[era] No -Reviewer specified; auto-selected '$autoReviewer' based on what's installed. Pass -Reviewer or set `$env:ERA_DEFAULT_REVIEWER to choose; run -Doctor for status."
        $reviewerList = @($autoReviewer)
    }
    elseif ($defaultIsPanel) {
        Write-Host "[era] No -Reviewer specified; using the default panel: $($reviewerList -join ', '). Pass -Reviewer <name> for a single reviewer."
    }
}
$registryHash = @{}
$modelOverrides = @{}
$providerOverrides = @{}
$resolvedAgyHint = $null
$registry.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object {
    $registryHash[$_.Name] = @{
        backend = $_.Value.backend
        model_id = $_.Value.model_id
        # Preserve agy family/tier so $ModelInfo carries them into the adapter:
        # Fix 7's tier-based stall floor keys on agy_model_family (-match 'pro'),
        # and the default --model settings_value lookup uses both.
        agy_model_family = $_.Value.agy_model_family
        agy_model_tier = $_.Value.agy_model_tier
        # REST fields (openaicompat/anthropic): without these, dispatch's
        # $modelInfo = @{} + $Registry[$r] loses the endpoint+key and the adapter
        # throws "requires ModelInfo.api_base". (era.ps1 passes $registryHash to
        # Invoke-ReviewerDispatch, not the raw registry.)
        api_base = $_.Value.api_base
        api_key_env = $_.Value.api_key_env
        api_key_header = $_.Value.api_key_header
        max_tokens = $_.Value.max_tokens
        pricing = @{ input_per_m = $_.Value.pricing.input_per_m; output_per_m = $_.Value.pricing.output_per_m }
        supports_file_read = $_.Value.supports_file_read
        supports_streaming = $_.Value.supports_streaming
        notes = $_.Value.notes
    }
}

# Opt-in: route the opencode reviewer aliases over direct HTTP instead of the TUI.
if ($env:ERA_USE_HTTP_OPENCODE) {
    $httpMap = @{ 'deepseek' = 'deepseek-http'; 'minimax' = 'minimax-http' }
    $reviewerList = @($reviewerList | ForEach-Object { if ($httpMap.ContainsKey($_)) { $httpMap[$_] } else { $_ } })
    Write-Host "[era] ERA_USE_HTTP_OPENCODE set -> using HTTP presets for opencode reviewers: $($reviewerList -join ', ')"
}
# Fill any opencode-subscription api_key_env (OPENCODE/MINIMAX/NVIDIA) from auth.json
# when not already in the process env, so the env-based REST adapter + checks work.
Resolve-EraAuthJsonKeys -ApiKeyEnvs (@($reviewerList | ForEach-Object { $registryHash[$_].api_key_env }))

Test-ReviewerListAgainstRegistry -ReviewerList $reviewerList -Registry $registryHash
# REST-only backends don't shell out to a CLI -- skip the PATH check for them.
$script:RestOnlyBackends = @('geminiapi', 'anthropic', 'openaicompat')
foreach ($r in $reviewerList) {
    $backend = $registryHash[$r].backend
    if ($backend -notin $script:RestOnlyBackends) {
        Test-BackendCliAvailable -CliName $backend
    }
}

# --- Model hint resolution ---
if ($Model) {
    # Layer-2 two-pass (exact-then-substring) resolution is now in the
    # dot-sourced Resolve-ModelFromHint (PR-D / D.0). Behavior is identical;
    # the function returns the resolved model_id + provider (or $null).
    $hintResolution = Resolve-ModelFromHint -Hint $Model -Registry $registry
    $resolvedModelId = if ($hintResolution) { $hintResolution.ModelId } else { $null }
    $resolvedProvider = if ($hintResolution) { $hintResolution.Provider } else { $null }

    if ($resolvedModelId) {
        # Track which reviewers actually accepted the override and which were
        # skipped. Previously this loop silently ate cross-backend mismatches
        # (e.g. -Reviewer deepseek -Model "gemini 3.5 flash" resolves to provider
        # 'agy' which deepseek's opencode backend can't accept, and the override
        # was silently dropped while the success line still printed).
        $appliedTo  = @()
        $skippedFor = @()
        foreach ($r in $reviewerList) {
            $backend = $registryHash[$r].backend
            if ($backend -eq $resolvedProvider -or ($resolvedProvider -eq 'agy' -and $backend -eq 'agy') -or ($backend -eq 'opencode' -and $resolvedProvider -ne 'claude' -and $resolvedProvider -ne 'agy')) {
                $modelOverrides[$r] = $resolvedModelId
                $appliedTo += $r
                if ($resolvedProvider -eq 'agy') {
                    $resolvedAgyHint = $resolvedModelId
                } elseif ($resolvedProvider -eq 'nvidia' -or $resolvedProvider -eq 'minimax' -or $resolvedProvider -eq 'opencode-go') {
                    $providerOverrides[$r] = $resolvedProvider
                }
            } else {
                $skippedFor += "$r(backend=$backend)"
            }
        }
        if ($appliedTo.Count -gt 0 -and $skippedFor.Count -eq 0) {
            Write-Host "[era] Model hint '$Model' -> resolved to '$resolvedModelId' (provider: $resolvedProvider); applied to: $($appliedTo -join ', ')"
        } elseif ($appliedTo.Count -gt 0 -and $skippedFor.Count -gt 0) {
            Write-Host "[era] Model hint '$Model' -> resolved to '$resolvedModelId' (provider: $resolvedProvider); applied to: $($appliedTo -join ', '); SKIPPED for $($skippedFor -join ', ') (backend mismatch -- those reviewers run with their registry defaults)."
        } else {
            Write-Host "[era] WARNING: Model hint '$Model' resolved to '$resolvedModelId' (provider: $resolvedProvider) but NO reviewer in [$($reviewerList -join ', ')] uses a compatible backend. Override IGNORED -- all reviewers will run with their registry defaults. Skipped for: $($skippedFor -join ', '). To force the resolved model, either change `-Reviewer` to one whose backend matches '$resolvedProvider', or use a more provider-specific hint (e.g. include the provider slug)."
        }
        if ($Provider) {
            $providerOverrides[$reviewerList[0]] = $Provider
            Write-Host "[era] Provider override: $Provider"
        }
    } else {
        Write-Host "[era] WARNING: Model hint '$Model' did not resolve to a known model."
    }
}

if (-not $TopicSlug) {
    $specFiles = Get-ChildItem (Join-Path $repoRoot (Get-SpecGlob)) -ErrorAction SilentlyContinue
    if ($specFiles) {
        $spec = $specFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $TopicSlug = $spec.BaseName -replace '^\d{4}-\d{2}-\d{2}-', '' -replace '-design$', ''
    } else {
        if (Get-ForceMode) {
            throw "No TopicSlug provided and no spec file auto-detected. In non-interactive mode, pass -TopicSlug explicitly."
        }
        $TopicSlug = Read-Host "No spec found. Enter a topic slug for this review"
        if (-not $TopicSlug) { throw "No topic slug provided." }
    }
}
# Sanitize slug: strip path separators, parent-refs, and special chars
$TopicSlug = $TopicSlug -replace '[/\\]', '-' -replace '\.\.', '' -replace '[^a-zA-Z0-9_-]', ''
if (-not $TopicSlug) { throw "Topic slug is empty after sanitization. Use a valid slug (letters, numbers, hyphens, underscores)." }
# --- Dirty-working-tree gate (2026-08-10) ---------------------------------
# A review bundles the WORKING TREE but is reasoned about, cited and
# committed as "round N covers commits X..Y". On a dirty tree those are
# different things, and the gap is invisible afterwards: the reviewer reads
# uncommitted edits, the author commits them, and the commit that lands was
# never covered by the round whose findings its message quotes. That created
# an unreviewed layer three times in a single session, purely from ordering.
#
# Refusal, not a warning: a warning printed into a non-interactive agent's
# stdout is not a decision point. -Force does NOT bypass this (see
# -AllowDirtyTree). Skipped entirely outside a git work tree.
if ($eraGitState -and $eraGitState.Dirty.Count -gt 0) {
    $dirtyAllowed = $AllowDirtyTree.IsPresent -or ($env:ERA_ALLOW_DIRTY -eq '1')
    $preview = ($eraGitState.Dirty | Select-Object -First 15) -join "`n           "
    if (-not $dirtyAllowed) {
        Write-Host ""
        Write-Host "[era] REFUSING TO DISPATCH — the working tree has uncommitted changes." -ForegroundColor Red
        Write-Host "[era]   branch : $($eraGitState.Branch)"
        Write-Host "[era]   HEAD   : $($eraGitState.Head)"
        Write-Host "[era]   dirty  : $($eraGitState.Dirty.Count) path(s)"
        Write-Host "           $preview"
        Write-Host ""
        Write-Host "[era] The bundle would contain code that is not in any commit, so the round"
        Write-Host "[era] cannot be anchored to the range it will be cited as covering."
        Write-Host "[era] Commit (or stash) first, or pass -AllowDirtyTree / ERA_ALLOW_DIRTY=1"
        Write-Host "[era] if you deliberately want the uncommitted state reviewed."
        exit 1
    }
    $dirtyMsg = "[era] WARNING: dispatching over a DIRTY tree ($($eraGitState.Dirty.Count) path(s)); " +
                "the manifest records them, but this round covers no single commit."
    Write-Host $dirtyMsg -ForegroundColor Yellow
}

$reviewDir = Join-Path $repoRoot ".external-reviews/$TopicSlug"
New-Item -ItemType Directory -Path $reviewDir -Force -ErrorAction SilentlyContinue | Out-Null

# Auto-detect pending-prompt.md in the topic dir if the user didn't pass
# -PromptOverrideFile explicitly. The file naming convention strongly suggests
# auto-pickup; previously it was silently ignored unless the path was passed
# via -PromptOverrideFile. If both are provided, the explicit arg wins.
if (-not $PromptOverrideFile) {
    $pendingPromptPath = Join-Path $reviewDir 'pending-prompt.md'
    if (Test-Path -LiteralPath $pendingPromptPath) {
        $PromptOverrideFile = $pendingPromptPath
        # Pre-written prompt = user-authored for -ConversationFile purposes
        # (honored only via {{CONVERSATION_CONTEXT}} placeholder).
        $script:UserSuppliedPromptOverride = $true
        Write-Host "[era] Auto-detected pending-prompt.md in topic dir; using it as prompt override."
    }
}

$round = Reserve-ReviewRound -ReviewDir $reviewDir -Reviewer ($reviewerList -join ',')
$claimPath = Join-Path $reviewDir "round-$round-claim.json"
try {

    $promptPath = Join-Path $reviewDir "round-$round-prompt.md"
    $bundlePath = Join-Path $reviewDir "round-$round-bundle.xml"
    $configPath = Join-Path $reviewDir "round-$round-config.json"

    $specFile = $null
    $specFile = Get-ChildItem (Join-Path $repoRoot (Get-SpecGlob)) -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match $TopicSlug } | Select-Object -First 1

    $promptTitle = if ($specFile) { $specFile.BaseName -replace '^\d{4}-\d{2}-\d{2}-', '' -replace '-design$', '' } else { $TopicSlug }

    $promptTemplate = if ($Mode -eq 'assessment') {
        @"
# External Review - {{TOPIC_TITLE}}

You are reviewing {{TOPIC_TITLE}}.

## Context

The attached bundle contains the subject under review along with surrounding context files.

All source files are fully included in the attached bundle. Review ONLY what is in the bundle. Do NOT attempt to open, view, fetch, or read any file outside the bundle.

## What to review

1. **Correctness** -- are the claims / implementation accurate?
2. **Completeness** -- what's missing?
3. **Edge cases** -- what could break?
4. **Actionability** -- are the suggestions well-targeted?

Cite locations as file:line using the line numbers shown in the bundle; if unsure of a number, cite the function/symbol name instead of guessing.

## Output format

```
## Critical issues
1. ...

## What is correct
1. ...

## What's missing or under-weighted
1. ...

## Suggestions
1. ...

## Final verdict
<one sentence>
```

Be terse. If a section is empty, write "(none)".
"@
    } else {
        @"
# External Review Prompt - {{TOPIC_TITLE}}

You are reviewing the attached codebase bundle. Provide structured feedback.

All source files are fully included in the attached bundle. Review ONLY what is in the bundle. Do NOT attempt to open, view, fetch, or read any file outside the bundle.

Cite locations as file:line using the line numbers shown in the bundle; if unsure of a number, cite the function/symbol name instead of guessing.

## Output format

```
## Critical issues
1. ...

## Important issues
1. ...

## Minor / nits
1. ...

## What looks good
1. ...

## Open questions
1. ...
```

Be terse. If a section is empty, write "(none)".
"@
    }

    if ($PromptOverrideFile) {
        if (-not (Test-Path -LiteralPath $PromptOverrideFile)) { throw "Prompt override file not found: $PromptOverrideFile" }
        $srcResolved = (Resolve-Path -LiteralPath $PromptOverrideFile).Path
        $dstResolved = if (Test-Path -LiteralPath $promptPath) { (Resolve-Path -LiteralPath $promptPath).Path } else { $null }
        if ($null -ne $dstResolved -and $srcResolved -eq $dstResolved) {
            Write-Host "[era] Prompt already at target path, skipping copy"
        } else {
            Copy-Item -LiteralPath $PromptOverrideFile -Destination $promptPath -Force
            Write-Host "[era] Using pre-written prompt from $PromptOverrideFile"
        }
    } elseif (-not (Test-Path -LiteralPath $promptPath)) {
        # [regex]::Replace + MatchEvaluator, NOT -replace: PowerShell's -replace
        # treats the replacement as a regex substitution string, so '$&', "$'"
        # and '$`' in the title are EXPANDED rather than inserted literally.
        # $promptTitle comes from a spec FILENAME here ($TopicSlug is sanitised
        # to [a-zA-Z0-9_-] at line 721, so it cannot carry them), and '$' is
        # legal in a filename. Measured on the raw form:
        #   title 'a$&b'  -> 'a{{TOPIC_TITLE}}b'   (token reinserted)
        #   title "a$'b"  -> splices the whole SUFFIX of the prompt in
        #   title 'a$`b'  -> splices the whole PREFIX of the prompt in
        # The last two duplicate real instruction text into the title position.
        # workflow.ps1's {{PREVIOUS_ROUND}} substitution already documents this
        # as "the only safe approach"; this call site had not followed it.
        $rendered = [regex]::Replace($promptTemplate, [regex]::Escape('{{TOPIC_TITLE}}'),
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $promptTitle })
        $rendered | Set-Content -LiteralPath $promptPath -Encoding utf8
    }

    # --- -ConversationFile injection (2026-06-10 hardening P2) ---
    # Runs on the FINALIZED prompt file, BEFORE {{PREVIOUS_ROUND}} substitution
    # so '## Session context' precedes the previous-round block (stable context
    # first, then the delta the reviewer must react to).
    if ($ConversationFile) {
        if (-not (Test-Path -LiteralPath $ConversationFile)) { throw "Conversation file not found: $ConversationFile" }
        $convText = (Get-Content -Raw -LiteralPath $ConversationFile).TrimEnd()
        $promptText = Get-Content -Raw -LiteralPath $promptPath
        if ($promptText -match '\{\{CONVERSATION_CONTEXT\}\}') {
            # .Replace = literal (no regex metacharacter surprises in $convText)
            $promptText = $promptText.Replace('{{CONVERSATION_CONTEXT}}', $convText)
            Set-Content -LiteralPath $promptPath -Value $promptText -Encoding utf8
            Write-Host "[era] -ConversationFile: injected into {{CONVERSATION_CONTEXT}} placeholder."
        } elseif ($script:UserSuppliedPromptOverride) {
            # Hard error (smoke-review round 1): silently dropping session
            # context recreates the folklore problem -ConversationFile exists
            # to fix. Add {{CONVERSATION_CONTEXT}} to the override, or drop
            # one of the two flags.
            throw "-ConversationFile was passed but the supplied -PromptOverrideFile has no {{CONVERSATION_CONTEXT}} placeholder. Add the placeholder or omit one flag."
        } else {
            $section = "## Session context`n`n$convText`n`n"
            $marker = '## Output format'
            $idx = $promptText.IndexOf($marker)
            if ($idx -ge 0) {
                # Insert before the Output-format heading (string surgery, no
                # regex — the marker text also appears in template literals).
                $promptText = $promptText.Substring(0, $idx) + $section + $promptText.Substring($idx)
            } else {
                $promptText = $promptText.TrimEnd() + "`n`n" + $section
            }
            Set-Content -LiteralPath $promptPath -Value $promptText -Encoding utf8
            Write-Host "[era] -ConversationFile: appended as '## Session context'."
        }
    } else {
        # Degraded mode (P2.2): a dangling placeholder must not reach the
        # reviewer verbatim.
        $promptText = Get-Content -Raw -LiteralPath $promptPath
        if ($promptText -match '\{\{CONVERSATION_CONTEXT\}\}') {
            Write-Host "[era] WARNING: prompt has {{CONVERSATION_CONTEXT}} but no -ConversationFile was passed (degraded mode — see SKILL.md conversation hand-off)."
            $promptText = $promptText.Replace('{{CONVERSATION_CONTEXT}}', '(none provided)')
            Set-Content -LiteralPath $promptPath -Value $promptText -Encoding utf8
        }
    }

    # --- {{PREVIOUS_ROUND}} template token substitution (PR 3) ---
    # If the finalized prompt contains {{PREVIOUS_ROUND}}, replace it with the
    # prior round's response text. Must run AFTER the prompt file is finalized
    # and BEFORE repomix (which reads the prompt via instructionFilePath).
    Invoke-PromptTokenSubstitution -PromptFile $promptPath -ReviewDir $reviewDir -RoundN $round

    # --- PR 4: -AutoDetect — derive candidate files from git status + HEAD~1 ---
    if ($AutoDetect.IsPresent) {
        $gitAvailable = (Get-Command git -ErrorAction SilentlyContinue) -ne $null
        if (-not $gitAvailable) {
            throw "ERROR: -AutoDetect requires git on PATH. Pass -IncludeFiles explicitly instead."
        }
        $isGitWorkTree = $null -ne (& git rev-parse --is-inside-work-tree 2>$null)
        if (-not $isGitWorkTree) {
            throw "ERROR: -AutoDetect requires a git work tree. The current directory ($((Get-Location).Path)) is not inside a git repository. Pass -IncludeFiles explicitly instead."
        }

        # Uncommitted changes (both staged and unstaged)
        $uncommitted = @(Get-EraPorcelainPaths -RepoRoot $repoRoot)

        # Files changed in the most-recent commit (HEAD~1..HEAD).
        # Use HEAD~1 only (not HEAD~5) — narrower window avoids pulling in unrelated work.
        $recentCommit = @(& git diff --name-only HEAD~1..HEAD 2>$null |
            Where-Object { $_ })

        # Drop era's OWN artifact tree (2026-08-09). Round reservation writes
        # .external-reviews/<slug>/round-N-claim.json and -prompt.md BEFORE this
        # block runs, so `git status --porcelain` reports '.external-reviews/' as
        # untracked and it became a candidate — on a clean tree, the ONLY
        # candidate. era then proposed its own review history for review.
        $autoCandidates = @($uncommitted + $recentCommit) |
            Sort-Object -Unique |
            Where-Object { $_ -and $_.Trim() -ne '' } |
            Where-Object { ($_ -replace '\\', '/') -notmatch '(^|/)\.external-reviews(/|$)' }

        if ($autoCandidates.Count -eq 0) {
            # 2026-08-09: this used to print an advisory and fall through — onto
            # the same repo-wide default globs the empty -IncludeFiles bug hit.
            # -AutoDetect is an explicit "review what I changed"; answering it
            # with "review everything" is the same silent widening. Refuse, but
            # ONLY when we would actually land on the broad path: an explicit
            # -IncludeFiles or a spec-mode spec file still narrows the run, and
            # those branches are chosen below at "Determine effective include".
            # Filter before counting: with -IncludeFiles omitted the param is
            # $null, and @($null).Count is 1, not 0 — which reads as "an include
            # list exists" and silently disarms this guard.
            $narrowingIncludes = @($IncludeFiles | Where-Object { $_ })
            $wouldFallBackToBroad = ($narrowingIncludes.Count -eq 0) -and
                                    -not ($Mode -eq 'spec' -and $specFile)
            if ($wouldFallBackToBroad) {
                Stop-EraWithError ("-AutoDetect found no uncommitted or recent-commit files, and nothing " +
                    "else narrows this run. Refusing to fall back to a repo-wide bundle — pass " +
                    "-IncludeFiles explicitly, or omit -AutoDetect to request the broad audit deliberately.")
            }
            Write-Host "[era] -AutoDetect: no uncommitted or recent-commit files found; continuing with the existing include list."
        } else {
            if (-not (Get-ForceMode) -and -not $Force) {
                Write-Host "[era] -AutoDetect candidate files:"
                $autoCandidates | ForEach-Object { Write-Host "  $_" }
                $confirm = Read-Host "Proceed with these files? [y/N]"
                if ($confirm -notmatch '^[Yy]$') {
                    throw "Aborted by user at -AutoDetect confirmation."
                }
            }
            # Additive with any explicit -IncludeFiles
            $IncludeFiles = @($IncludeFiles; $autoCandidates) | Sort-Object -Unique | Where-Object { $_ }
        }
    }

    # --- Expand comma-strings in -IncludeFiles BEFORE building effective include ---
    # Fix (PR 2 D): Passing -IncludeFiles "a,b,c" (a single quoted string with commas)
    # is the natural result of Windows command-line parsing on Windows via the Bash
    # tool. Split any element containing a comma into separate paths.
    if ($IncludeFiles -and $IncludeFiles.Count -gt 0) {
        $expanded = @(
            $IncludeFiles | ForEach-Object {
                if ($_ -match ',') {
                    @($_ -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                } else { $_ }
            }
        )
        if ($expanded.Count -gt $IncludeFiles.Count) {
            Write-Host "[era] -IncludeFiles: expanded $($IncludeFiles.Count) element(s) with embedded commas into $($expanded.Count) path(s)."
            $IncludeFiles = $expanded
        }
    }

    # --- Determine effective include list ---
    $effectiveInclude = @()
    # Initialized explicitly (A6): only the else-branch below assigns it, and the
    # gate reads it. Correct today because there is no Set-StrictMode in this
    # repo, but that is a tripwire for whoever adds one.
    $usedDefaultGlobs = $false
    if ($IncludeFiles) { $effectiveInclude = [array]$IncludeFiles }
    elseif ($Mode -eq 'spec' -and $specFile) {
        $relativeSpecPath = $specFile.FullName.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        $effectiveInclude = @($relativeSpecPath)
    } else {
        # Default globs: configurable via ERA_DEFAULT_GLOBS (comma-separated).
        # When unset, ships with a broad default covering scripts, config, docs,
        # and common compiled-lang source so the skill works out of the box on
        # most repos without -IncludeFiles. Narrow with the env var if the
        # default is too broad for your repo.
        $defaultGlobs = if ($env:ERA_DEFAULT_GLOBS) {
            @($env:ERA_DEFAULT_GLOBS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } else {
            @(
                '**/*.md', '**/*.yaml', '**/*.yml', '**/*.json', '**/*.toml', '**/*.cfg', '**/*.ini',
                '**/*.ps1', '**/*.psm1', '**/*.psd1',
                '**/*.py', '**/*.pyi',
                '**/*.ts', '**/*.tsx', '**/*.js', '**/*.jsx', '**/*.mjs', '**/*.cjs',
                '**/*.go',
                '**/*.rs',
                '**/*.java', '**/*.kt', '**/*.kts',
                '**/*.c', '**/*.h', '**/*.cpp', '**/*.hpp', '**/*.cc', '**/*.cxx',
                '**/*.rb',
                '**/*.php',
                '**/*.swift',
                '**/*.scala', '**/*.sc',
                '**/*.sh', '**/*.bash', '**/*.zsh',
                '**/*.sql',
                '**/*.tf', '**/*.tfvars',
                '**/Dockerfile', '**/Makefile', '**/CMakeLists.txt',
                '**/*.graphql', '**/*.gql',
                '**/*.proto'
            )
        }
        $effectiveInclude = $defaultGlobs
        # This — and only this — is the broad repo-wide path. The consent gate
        # below keys off it; the spec-file and explicit -IncludeFiles branches
        # above are already narrow by construction.
        $usedDefaultGlobs = $true
    }

    # --- Diff mode for round 2+ ---
    $priorRound = $round - 1
    # Fix (PR 2 B): $Diff is a [switch] param. Never assign a local variable named
    # $diff (case-insensitive in PS) — assigning a hashtable to $diff would try to
    # coerce a System.Collections.Hashtable into the [switch] param type, producing
    # "Cannot convert 'System.Collections.Hashtable' to 'SwitchParameter'".
    # Use $diffResult for the local to preserve the param binding.
    $isFollowUp = $priorRound -ge 1 -and $Diff.IsPresent
    if ($isFollowUp) {
        Write-Host "[era] Round $round (diff against round $priorRound)..."
        $diffResult = Get-ReviewDiff -ReviewDir $reviewDir -PriorRound $priorRound -CurrentFiles $effectiveInclude -RepoRoot $repoRoot
        if ($diffResult -and $diffResult.BundleFiles.Count -eq 0 -and $diffResult.Deleted.Count -eq 0) {
            Write-Host "[era] No files changed since round $priorRound. Use -Full to force full re-bundle."
            return
        }
        if ($diffResult) {
            $effectiveInclude = [array]$diffResult.BundleFiles
            $priorResponsePath = Join-Path $reviewDir "round-$priorRound-response.md"
            $priorResponse = if (Test-Path -LiteralPath $priorResponsePath) { Get-Content -Raw -LiteralPath $priorResponsePath } else { $null }
            $changesSummary = @()
            if ($diffResult.Added) { $changesSummary += "Added: $($diffResult.Added -join ', ')" }
            if ($diffResult.Changed) { $changesSummary += "Changed: $($diffResult.Changed -join ', ')" }
            if ($diffResult.Deleted) { $changesSummary += "Deleted: $($diffResult.Deleted -join ', ')" }
            $diffPrompt = @"
# Follow-up Review - $TopicSlug, Round $round

<previous_review>
$($priorResponse)
</previous_review>

## What changed since round $priorRound

$($changesSummary -join "`n")

Only changed files are attached below.

## What to review

1. Whether the changes correctly address the prior review's feedback.
2. New issues introduced by the changes.
3. Any remaining issues.

Cite locations as file:line using the line numbers shown in the bundle; if unsure of a number, cite the function/symbol name instead of guessing.

## Output format

```
## Critical issues (must fix)
...

## Important issues (should fix)
...

## Minor / nits
...

## Things the fix got right (briefly)
...
```

Be terse. If a section is empty, write "(none)".
"@
            # Do NOT clobber a caller-supplied prompt. This used to overwrite
            # $promptPath outright, so -Diff silently discarded
            # -PromptOverrideFile, -ConversationFile injection, AND any
            # <!-- era-require --> marker — turning the response contract off
            # exactly when a follow-up round most needs it. Prepend the diff
            # context instead and keep the caller's prompt intact.
            if ($script:UserSuppliedPromptOverride) {
                $existingPrompt = Get-Content -Raw -LiteralPath $promptPath -ErrorAction SilentlyContinue
                ($diffPrompt + "`n`n---`n`n" + $existingPrompt) | Set-Content -LiteralPath $promptPath -Encoding utf8
            } else {
                $diffPrompt | Set-Content -LiteralPath $promptPath -Encoding utf8
            }
            Write-Host "[era] Diff bundle: $($diffResult.BundleFiles.Count) changed, $($diffResult.Deleted.Count) deleted"
        }
    }

    # --- AgyModel hint resolution (supplements -Model flag; does not reset it) ---
    if ($AgyModel) {
        $hint = $AgyModel.Trim()
        $hintNorm = $hint.ToLower() -replace '[^\w\s]', '' -replace '\s+', ' '
        # A hint that normalises to EMPTY must not match. '-match ""' is true for
        # every string, so '-Model ".*"' (or any punctuation-only hint) silently
        # matched the FIRST candidate instead of failing. Measured:
        #   hint '.*' -> norm '' -> 'gemini 36 flash high' -match '' = True
        # Silently dispatching an arbitrary model is worse than not resolving.
        if (-not $hintNorm.Trim()) { $hintNorm = $null }
        $agyMap = @{}
        if ($registry._agy_model_map) {
            $registry._agy_model_map.PSObject.Properties | ForEach-Object {
                $agyMap[$_.Name] = $_.Value
            }
        }

        $candidates = @()
        foreach ($familyKey in $agyMap.Keys) {
            $family = $agyMap[$familyKey]
            foreach ($tierKey in $family.PSObject.Properties.Name) {
                $entry = $family.$tierKey
                $displayNorm = $entry.display.ToLower() -replace '[^\w\s]', '' -replace '\s+', ' '
                if ($displayNorm -match $hintNorm -or $hintNorm -match $displayNorm) {
                    $tierRank = if ($tierKey -eq 'high') { 3 } elseif ($tierKey -eq 'medium') { 2 } else { 1 }
                    $candidates += @{ Display = $entry.display; TierKey = $tierKey; TierRank = $tierRank }
                }
            }
        }
        if ($candidates.Count -gt 0) {
            $best = $candidates | Sort-Object TierRank -Descending | Select-Object -First 1
            $resolvedAgyHint = $best.Display
            Write-Host "[era] AgyModel hint '$hint' -> resolved to '$resolvedAgyHint' (tier: $($best.TierKey))"
        } else {
            Write-Host "[era] WARNING: AgyModel hint '$hint' did not resolve. Using current agy model."
        }
    }

    # --- Keep era's own review artifacts out of the bundle (2026-08-09) --------
    # .external-reviews/ was never excluded, so on the default-glob path every
    # prior round's prompt/response/manifest (Stderr included) and every staged
    # ~/.claude copy was re-uploaded to the reviewer API. See
    # Get-EraReviewArtifactIgnorePatterns in workflow.ps1.
    #
    # repomix's ignore beats its include, so the blanket pattern would also drop
    # the P6 staged files below (:1089) — which are exactly what the caller asked
    # to review. Detect that case here, using the same test the staging block
    # applies, and ask for the carve-out shape instead.
    $stagingInPlay = $false
    if ($IncludeFiles -and $IncludeFiles.Count -gt 0) {
        foreach ($e in $IncludeFiles) {
            $entry = "$e"
            if ($entry -match '[*?\[\]]') { continue }
            if (-not [System.IO.Path]::IsPathRooted($entry)) { continue }
            if (-not (Test-EraPathInsideRoot -Path ([System.IO.Path]::GetFullPath($entry)) -Root $repoRoot)) {
                $stagingInPlay = $true
                break
            }
        }
    }
    $artifactIgnore = Get-EraReviewArtifactIgnorePatterns -RepoRoot $repoRoot `
        -TopicSlug $TopicSlug -Round $round -AllowStaging:$stagingInPlay
    # Hoisted so the broad-scope gate below can measure against the SAME ignore
    # set repomix will use, while the config itself is built after staging.
    # '**/' prefixes because a bare '<dir>/**' is ROOT-ANCHORED in repomix
    # (measured 1.12.0: 'node_modules/**' still bundles
    # packages/p/node_modules/d/a.md). repomix's own defaults spell these the
    # same way. Only node_modules changes real output; the other two are aligned
    # so sibling patterns that look alike behave alike.
    # NOTE: '.external-reviews/**' arrives via $artifactIgnore and stays
    # deliberately ROOT-anchored -- era's artifact dir is always at the repo
    # root, and the staging carve-out enumerates root-relative siblings.
    $repomixIgnorePatterns = @('**/node_modules/**', '**/.git/**', '**/__pycache__/**', '*.pyc', '*.duckdb', 'validation_results/**/*.db') + $artifactIgnore


    # --- Broad-bundle consent gate (2026-08-09) -------------------------------
    # The broad path never announced its scope and had no ceiling, so a repo-wide
    # run on a big tree became an 18-minute repomix crash instead of an immediate
    # "that's 72,378 files, are you sure?". Enumerate what the globs actually
    # resolve to — bounded, and NOT via `git ls-files`, since useGitignore=$false
    # makes the include set a superset of tracked files — then print it and
    # refuse above the ceiling unless -Force.
    if ($usedDefaultGlobs) {
        $broadLimit = 5000
        # TryParse, not a hard cast: ERA_BROAD_MAX_FILES=none is a natural attempt
        # to disable the ceiling and used to produce a raw PowerShell cast error
        # instead of era's clean single-line preflight shape.
        $broadMaxFiles = 1000
        if ($env:ERA_BROAD_MAX_FILES) {
            $parsedFiles = 0
            if ([int]::TryParse($env:ERA_BROAD_MAX_FILES, [ref]$parsedFiles)) { $broadMaxFiles = $parsedFiles }
            else { Write-Host "[era] WARNING: ERA_BROAD_MAX_FILES='$($env:ERA_BROAD_MAX_FILES)' is not a number; using $broadMaxFiles." }
        }
        $broadMaxBytes = [long]10MB
        if ($env:ERA_BROAD_MAX_BYTES) {
            $parsedBytes = [long]0
            if ([long]::TryParse($env:ERA_BROAD_MAX_BYTES, [ref]$parsedBytes)) { $broadMaxBytes = $parsedBytes }
            else { Write-Host "[era] WARNING: ERA_BROAD_MAX_BYTES='$($env:ERA_BROAD_MAX_BYTES)' is not a number; using $broadMaxBytes." }
        }
        $broadScope = Measure-EraBroadScope -RepoRoot $repoRoot -Include $effectiveInclude `
            -IgnorePatterns $repomixIgnorePatterns -Limit $broadLimit
        Write-Host (Format-EraBroadScopeNotice -Scope $broadScope -RepoRoot $repoRoot `
            -Reviewers $reviewerList -Limit $broadLimit)
        # NOT $Force: that is cost consent, and the documented dispatch line always
        # passes it. Scale consent needs its own deliberate signal.
        $broadForce = $ForceBroadScope.IsPresent -or ($env:ERA_BROAD_FORCE -eq '1')
        if (-not (Test-EraBroadScopeAllowed -Scope $broadScope -MaxFiles $broadMaxFiles `
                    -MaxBytes $broadMaxBytes -Force:$broadForce)) {
            Stop-EraWithError ("Refusing this broad bundle: it exceeds the ceiling of $broadMaxFiles files / " +
                "$([Math]::Round($broadMaxBytes / 1MB, 1)) MB (raise with ERA_BROAD_MAX_FILES / " +
                "ERA_BROAD_MAX_BYTES). Pass -IncludeFiles to scope the review, or -ForceBroadScope " +
                "(or ERA_BROAD_FORCE=1) to send it anyway. Note -Force does NOT bypass this — it only " +
                "skips the cost prompt.")
        }
    }

    # --- 2026-06-10 hardening P6: out-of-repo -IncludeFiles staging ----------
    # repomix can only bundle under repoRoot. An ABSOLUTE path outside the repo
    # is explicit caller intent (e.g. skill sources under ~/.claude), so stage
    # a copy into the round's artifact dir, mirroring the source path so bundle
    # citations still identify the real file:
    #   C:\Users\<you>\.claude\skills\era\SKILL.md
    #     -> .external-reviews/<slug>/round-N-external/HOME/.claude/skills/era/SKILL.md
    # Staged copies persist as round artifacts (same reproducibility contract
    # as round-N-bundle.xml). RELATIVE traversal (..\..) stays blocked below —
    # that shape is accidental, not intent. Files only; out-of-repo dirs/globs
    # throw (pass individual files).
    $includeRewrites = @{}
    if ($IncludeFiles -and $IncludeFiles.Count -gt 0) {
        $IncludeFiles = @($IncludeFiles | ForEach-Object {
            $entry = "$_"
            if ($entry -match '[*?\[\]]') { return $entry }   # globs are in-repo by definition
            if (-not [System.IO.Path]::IsPathRooted($entry)) { return $entry }
            $full = [System.IO.Path]::GetFullPath($entry)
            if (Test-EraPathInsideRoot -Path $full -Root $repoRoot) {
                # Absolute but inside the repo — relativize for repomix.
                $relIn = ($full.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/')
                # Same reason as the staged case below: $effectiveInclude must
                # learn about this rewrite or repomix keeps the absolute path.
                $includeRewrites[$entry] = $relIn
                return $relIn
            }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                Stop-EraWithError "out-of-repo -IncludeFiles entry must be an existing FILE (dirs/globs unsupported): $entry"
            }
            # Privacy: bundles are sent to external reviewer APIs - never
            # embed the user's home path (Users/<name>). Home-rooted files
            # mirror under 'HOME/'; non-home paths keep the drive-stripped
            # mirror.
            $homeFull = [System.IO.Path]::GetFullPath($HOME)
            if (Test-EraPathInsideRoot -Path $full -Root $homeFull) {
                $mirror = 'HOME/' + (($full.Substring($homeFull.Length).TrimStart('\', '/')) -replace '\\', '/')
            } else {
                $mirror = (($full -replace ':', '') -replace '\\', '/').TrimStart('/')
            }
            $stagedAbs = Join-Path $reviewDir "round-$round-external/$mirror"
            New-Item -ItemType Directory -Path (Split-Path -Parent $stagedAbs) -Force | Out-Null
            Copy-Item -LiteralPath $full -Destination $stagedAbs -Force
            $stagedRel = ($stagedAbs.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/')
            Write-Host "[era] Staged out-of-repo file for bundling: $full -> $stagedRel"
            $includeRewrites[$entry] = $stagedRel
            return $stagedRel
        })
    }

    # --- Carry the staging rewrite into the repomix include list (2026-08-09) ---
    # This block rebinds $IncludeFiles, but repomix reads $effectiveInclude, which
    # was frozen from $IncludeFiles further up. So the config still named the raw
    # ABSOLUTE out-of-repo path, which matches nothing under the repo root: era
    # staged the file, printed "Staged out-of-repo file for bundling", passed path
    # validation and recorded it in the manifest -- and the bundle never contained
    # it. Measured, not inferred. The empty-bundle guard cannot catch it, because
    # the bundle is not empty whenever any other file was requested.
    #
    # Remap entry-by-entry rather than reassigning $effectiveInclude wholesale, so
    # diff mode (which replaces it with the changed-file list) and spec mode are
    # left alone.
    if ($includeRewrites.Count -gt 0) {
        $effectiveInclude = @($effectiveInclude | ForEach-Object {
            if ($includeRewrites.ContainsKey("$_")) { $includeRewrites["$_"] } else { $_ }
        })
    }

    # --- repomix config (built AFTER staging, see above) ----------------------
    $configData = @{
        # showLineNumbers (2026-06-10 hardening P4): reviewers fabricate
        # bundle-relative line numbers on large bundles — observed on BOTH
        # correct and incorrect claims. True per-file numbers in the bundle +
        # the citation instruction in the prompt templates kill the artifact.
        output = @{ filePath = $bundlePath; style = 'xml'; showLineNumbers = $true; instructionFilePath = $promptPath; headerText = if ($isFollowUp) { "Diff bundle for $TopicSlug round $round (delta from round $priorRound)" } else { "Full bundle for $TopicSlug round $round" } }
        include = $effectiveInclude
        ignore = @{
            useGitignore = $false
            useDefaultPatterns = $false
            customPatterns = $repomixIgnorePatterns
        }
    }
    $configJson = $configData | ConvertTo-Json -Depth 10
    $configJson | Set-Content -LiteralPath $configPath -Encoding utf8

    # Fix (PR 2 C): Validate -IncludeFiles paths against Test-Path BEFORE invoking
    # repomix. repomix runs 3+ seconds before returning an empty bundle for typo'd
    # or out-of-repo paths. Validate relative to repoRoot (same root repomix uses).
    # SECURITY: Also block path traversal (e.g. ../../../../.ssh/id_rsa) that would
    # cause repomix to bundle out-of-repo sensitive files and send them to APIs.
    if ($IncludeFiles -and $IncludeFiles.Count -gt 0) {
        Push-Location -LiteralPath $repoRoot
        try {
            # Literal-OR-glob. An entry may legitimately be either, and the two
            # need opposite parameters: '[' and ']' are wildcard metacharacters,
            # so Test-Path -Path reports a real file like 'src/app/[id]/page.tsx'
            # (any Next.js dynamic route) as missing, while -LiteralPath reports
            # a genuine glob like 'src/**/*.ts' as missing. Accepting either
            # keeps both shapes working and can only ever be more permissive
            # than the old single -Path check, never less.
            $missing = @($IncludeFiles | Where-Object {
                -not (Test-Path -LiteralPath $_) -and -not (Test-Path -Path $_)
            })
            if ($missing) {
                Stop-EraWithError "-IncludeFiles paths not found relative to repo root ($repoRoot): $($missing -join ', ')"
            }
            # Path traversal guard: every resolved path must stay inside repoRoot.
            # Skip GENUINE globs (* and ?) only — those match inside the repo
            # tree by definition, and Resolve-Path on a wildcard returns a
            # collection rather than a single PathInfo.
            #
            # '[' and ']' are NOT globs here and are no longer exempt. They are
            # ordinary characters in real filenames (every Next.js dynamic route
            # has them), and exempting them let a bracketed RELATIVE traversal
            # skip this check completely. Measured before the fix:
            #     ../secret.md      -> traversal blocked? True
            #     ../secret[1].md   -> traversal blocked? False
            # Absolute out-of-repo paths are a different, deliberate flow (P6
            # staging rewrites them above); relative traversal is what this
            # guard still exists to stop, and that was the hole.
            #
            # -LiteralPath so a bracketed name resolves to itself instead of
            # being read as a character class and silently resolving to nothing
            # (which would return $false here — fail-open, the wrong direction).
            $traversal = @($IncludeFiles | Where-Object {
                if ($_ -match '[*?]') { return $false }
                $resolved = (Resolve-Path -LiteralPath $_ -ErrorAction SilentlyContinue).Path
                if (-not $resolved) { return $false }
                -not (Test-EraPathInsideRoot -Path $resolved -Root $repoRoot)
            })
            if ($traversal) {
                Stop-EraWithError "-IncludeFiles paths escape the repo root (path traversal blocked): $($traversal -join ', ')"
            }
        } finally {
            Pop-Location
        }
    }

    # Convergence: slug-per-round anti-pattern detection (pre-dispatch)
    $externalReviewsDir = Join-Path $repoRoot '.external-reviews'
    $slugWarning = Test-SlugPerRoundPattern -ExternalReviewsDir $externalReviewsDir -TopicSlug $TopicSlug
    if ($slugWarning) { Write-Host $slugWarning }

    Write-Host "Running repomix..."
    $repomixTimeoutSec = 300
    # Run repomix under a handle we can TREE-KILL. This was Start-ThreadJob +
    # Wait-Job + Stop-Job, which ends the THREAD but not the native node process
    # repomix spawns — so a timeout left it running, burning CPU and disk. The
    # adapters have always used Process.Kill($true) for exactly this problem, an
    # invariant tests/ProcessTreeKill.Tests.ps1 asserts across agy/claude/
    # opencode; repomix was the one place that did not, because npm resolves it
    # to a .ps1 shim that CreateProcess cannot execute. Resolve-EraRepomixCommand
    # handles that by preferring the sibling .cmd.
    #
    # Output is redirected to files, so partial output SURVIVES a timeout. The
    # Receive-Job drain this replaces could never return anything: the ThreadJob
    # body buffered everything into a local until completion.
    $repomixRun = Invoke-EraRepomix -ConfigPath $configPath -RepoRoot $repoRoot -TimeoutSec $repomixTimeoutSec
    if ($repomixRun.TimedOut) {
        $partialText = Get-EraTruncatedText -Text $repomixRun.Output -MaxChars 4000
        throw ("repomix timed out after ${repomixTimeoutSec}s (process tree killed)." +
            $(if ($partialText) { " Partial output:`n$partialText" } else { " No output was captured before the timeout." }))
    }
    if ($repomixRun.Error) { throw $repomixRun.Error }
    $repomixResult = $repomixRun.Output
    $repomixExitCode = $repomixRun.ExitCode
    if ($repomixExitCode -ne 0) {
        # Truncate: this interpolated the entire capture, which was 16.9 MB on
        # the run that started collecting 72,378 files.
        throw ("repomix failed with exit code $repomixExitCode`:`n" + (Get-EraTruncatedText -Text $repomixResult -MaxChars 4000))
    }

    $tokenCount = 0
    $repomixText = $repomixResult
    if ($repomixText -match 'Total Tokens:\s*([0-9,]+)') {
        $tokenCount = [int]($matches[1] -replace ',', '')
    } elseif ($repomixText -match '([0-9,]+)\s*tokens') {
        $tokenCount = [int]($matches[1] -replace ',', '')
    }
    Write-Host "Bundle ready. Tokens: $tokenCount"

    # Validate the bundle actually contains files. repomix produces a structurally
    # valid XML even when no files matched (e.g. -IncludeFiles with paths outside
    # the repo root, or a typo in the glob) -- in that case the model receives
    # an empty <files> section and responds with "no files to review", wasting
    # the dispatch round. Count <file ... > opening tags (note trailing space to
    # avoid matching the outer <files> wrapper).
    $bundleContent = if (Test-Path -LiteralPath $bundlePath) { Get-Content -Raw -LiteralPath $bundlePath -ErrorAction SilentlyContinue } else { '' }
    $fileTagCount = ([regex]::Matches($bundleContent, '<file\s+[^>]*>')).Count
    if ($fileTagCount -eq 0) {
        $includeHint = if ($IncludeFiles -and $IncludeFiles.Count -gt 0) {
            "`n`nYou passed -IncludeFiles: $($IncludeFiles -join ', ')`nrepomix only includes files INSIDE the repo root ($repoRoot). Absolute paths outside the repo, tilde-prefixed paths that didn't expand, and typo'd globs all silently produce an empty bundle.`n`nFix: use paths relative to '$repoRoot', or run `/era` from a directory whose repo root contains the files you want to bundle."
        } else {
            "`n`nNo -IncludeFiles was passed, so this is unusual. Check that the repo root ($repoRoot) actually contains files matching repomix's default globs, or pass -IncludeFiles explicitly."
        }
        Stop-EraWithError "Bundle is empty -- repomix matched 0 files.$includeHint"
    }

    $bundleBytes = if (Test-Path -LiteralPath $bundlePath) { (Get-Item -LiteralPath $bundlePath).Length } else { 0 }

    $perReviewerCosts = @{}
    $perReviewerCaps = @{}
    foreach ($r in $reviewerList) {
        $pricing = $registryHash[$r].pricing
        $estOutputTokens = [int][Math]::Min([Math]::Ceiling($tokenCount * 0.3), 50000)
        $perReviewerCosts[$r] = [Math]::Round(($tokenCount / 1000000.0) * $pricing.input_per_m + ($estOutputTokens / 1000000.0) * $pricing.output_per_m, 4)
        $perReviewerCaps[$r] = Get-PerReviewerCap -Pricing $pricing
    }
    $aggregateCost = ($perReviewerCosts.Values | Measure-Object -Sum).Sum
    $approvedList = Invoke-CostPrompt -ReviewerList $reviewerList -PerReviewerCosts $perReviewerCosts -PerReviewerCaps $perReviewerCaps -AggregateCost $aggregateCost -AggregateCap 15.0

    Write-ReviewManifest -ReviewDir $reviewDir -Round $round -TopicSlug $TopicSlug -PreviousRound $(if ($isFollowUp) { $priorRound } else { $null }) -Files @($bundlePath, $promptPath) -SourceFiles $effectiveInclude -RepoRoot $repoRoot -GitState $eraGitState

    Write-Host "Round $round. Reviewer(s): $($approvedList -join ', ')."

    # --- Default agy --model token (R2-C1 + R4-Gemini-C1; per-reviewer fix) ---
    # The default agy --model token is now resolved PER REVIEWER inside
    # Invoke-ReviewerDispatch from each reviewer's own agy_model_family/tier, so
    # a heterogeneous agy batch (e.g. gemini,gemini-pro-low) keeps distinct
    # --model tokens instead of collapsing to the first agy reviewer's model
    # (spec §4 Fix 1). We hand the dispatcher the _agy_model_map (hashtable form)
    # to do that lookup. An explicit -Model hint that resolved to an agy token
    # still wins via -AgyModelHint, so $resolvedAgyHint flows through unchanged.
    $agyModelMap = @{}
    if ($registry._agy_model_map) {
        $registry._agy_model_map.PSObject.Properties | ForEach-Object {
            $agyModelMap[$_.Name] = $_.Value
        }
    }

    $results = Invoke-ReviewerDispatch -ReviewerList $approvedList `
        -Registry $registryHash -BundlePath $bundlePath -PromptPath $promptPath `
        -ReviewDir $reviewDir -Round $round -AgyModelHint $resolvedAgyHint `
        -AgyModelMap $agyModelMap `
        -ModelOverrides $modelOverrides -ProviderOverrides $providerOverrides `
        -BundleTokens $tokenCount

    # --- Response contract (P1) ---------------------------------------------
    # Nothing verified that an answer matched the request: adapters check
    # non-empty text plus a finish reason, then return ExitCode=0, and
    # Copy-PrimaryResponseAlias promotes on ExitCode alone. A reviewer returned
    # zero of ten requested verdicts three times, each recorded as a success --
    # and the promoted file feeds Invoke-PromptTokenSubstitution into round N+1,
    # so a bad round poisons the next one.
    #
    # A failure is marked exactly the way opencode marks a bad agentic capture
    # (ExitCode=-1 + ContentOk=$false), so every existing consumer already does
    # the right thing: the alias skips it, the metadata writer records
    # content_ok=false, and the agy fallback below re-dispatches. The response
    # file stays on disk -- it is evidence, not garbage; only its promotion to
    # canonical is withheld.
    #
    # Runs BEFORE the fallback block so a contract failure can trigger it. It is
    # applied AGAIN after that block (see below) — otherwise the fallback's own
    # answer is never checked.
    $contractRequired = @(Get-EraResponseContract -PromptText (Get-Content -Raw -LiteralPath $promptPath -ErrorAction SilentlyContinue))
    if ($contractRequired.Count -gt 0) {
        Write-Host "[era] Response contract: $($contractRequired -join ', ')"
        $null = Assert-EraResponseContract -Results $results -Required $contractRequired
    }

    # --- Item #1 (v1.10): agy auto-fallback on capture failure ---
    # When an agy reviewer fails to produce a usable review (ExitCode != 0) even after
    # its in-adapter retry, re-dispatch to a non-agy fallback so a flaky default
    # reviewer doesn't yield an empty round. Triggers ONLY on an actual agy failure
    # (healthy runs are byte-identical). Disable with ERA_AGY_FALLBACK=off.
    if ($env:ERA_AGY_FALLBACK -ne 'off' -and $env:ERA_AGY_FALLBACK -ne '0') {
        # Recoverable = a flaky agy capture (the original case) OR a response
        # that failed the contract on ANY backend (2026-08-09). The trigger used
        # to require backend -eq 'agy', so a REST or opencode reviewer that
        # returned off-contract output spent the whole round with zero usable
        # result and no recovery — flagged by two of three round-2 reviewers.
        # Still bounded to ONE fallback dispatch, and the fallback's own answer
        # is contract-checked below.
        $failedAgy = @($approvedList | Where-Object {
            $registryHash[$_].backend -eq 'agy' -and $results[$_] -and $results[$_].ExitCode -ne 0
        })
        $failedContract = @($approvedList | Where-Object {
            $results[$_] -and $results[$_].Error -eq 'response-contract'
        })
        $failedRecoverable = @(@($failedAgy) + @($failedContract) | Sort-Object -Unique)
        if ($failedRecoverable.Count -gt 0) {
            # Hydrate subscription keys so opencode/nvidia fallbacks register as available.
            Resolve-EraAuthJsonKeys -ApiKeyEnvs @($registryHash.Keys | ForEach-Object { $registryHash[$_].api_key_env })
            # Exclude the FULL requested list, not just the approved one. A
            # reviewer the user dropped at the cost prompt is absent from
            # $approvedList, so excluding only that list let the fallback
            # resurrect the very reviewer they had just declined to pay for.
            $fallbackExclude = @(@($reviewerList) + @($approvedList) | Sort-Object -Unique)
            $fallbackPreset = Resolve-EraAgyFallback -Registry $registryHash -Override $env:ERA_AGY_FALLBACK -Exclude $fallbackExclude
            if ($fallbackPreset) {
                # Price it. The fallback used to be dispatched with no costing at
                # all: it never went through Invoke-CostPrompt, so it was an
                # unbudgeted full-bundle upload that no cap could stop. Named by
                # all three reviewers across rounds 2-4.
                $fbPricing = $registryHash[$fallbackPreset].pricing
                $fbEstOut  = [int][Math]::Min([Math]::Ceiling($tokenCount * 0.3), 50000)
                $fbCost    = [Math]::Round(($tokenCount / 1000000.0) * $fbPricing.input_per_m +
                                           ($fbEstOut / 1000000.0) * $fbPricing.output_per_m, 4)
                $fbCap     = Get-PerReviewerCap -Pricing $fbPricing
                if ($fbCost -gt $fbCap) {
                    Write-Host ("[era] Fallback '{0}' would cost ~`${1}, over its `${2} cap — skipping. " -f $fallbackPreset, $fbCost, $fbCap) +
                               "The round keeps its honest failure telemetry."
                    $fallbackPreset = $null
                } else {
                    Write-Host ("[era] Fallback '{0}' estimated ~`${1} (cap `${2})." -f $fallbackPreset, $fbCost, $fbCap)
                }
            }
            if ($fallbackPreset) {
                $why = if ($failedContract.Count -gt 0) { 'reviewer(s) failed' } else { 'agy capture failed' }
                Write-Host "[era] $why ($($failedRecoverable -join ', ')) -> falling back to '$fallbackPreset'."
                $fbResults = Invoke-ReviewerDispatch -ReviewerList @($fallbackPreset) `
                    -SuffixReviewerList @($approvedList + $fallbackPreset) `
                    -Registry $registryHash -BundlePath $bundlePath -PromptPath $promptPath `
                    -ReviewDir $reviewDir -Round $round -AgyModelMap $agyModelMap `
                    -ModelOverrides $modelOverrides -ProviderOverrides $providerOverrides `
                    -BundleTokens $tokenCount
                # Add the fallback under its OWN preset key (correct backend/pricing in
                # metadata); keep the failed agy entry for honest failure telemetry.
                foreach ($k in $fbResults.Keys) { $results[$k] = $fbResults[$k] }
                $approvedList = @($approvedList + $fallbackPreset)
            } else {
                Write-Host "[era] agy capture failed and no non-agy fallback is available; leaving the result as-is."
            }
        }
    }

    # Re-apply the contract to anything the fallback just added. Measured
    # 2026-08-09: a failing agy reviewer triggered a re-dispatch to gemini-api,
    # and that fallback's answer went straight to round-1-response.md with
    # content_ok=true while missing the required token — the very failure this
    # feature exists to catch, inside the feature itself. Assert- is idempotent
    # (already-failed results are skipped), so this is free when nothing changed.
    if ($contractRequired.Count -gt 0) {
        $null = Assert-EraResponseContract -Results $results -Required $contractRequired
    }

    # Unified response alias (Fix 4 / R3-Gemini-C4): copy the FIRST SUCCESSFUL
    # reviewer's response to round-N-response.md UNCONDITIONALLY. The old
    # `if ($results['gemini'])` gate broke under the non-gemini default
    # (gemini-pro-low) since that key is null. Copy-PrimaryResponseAlias picks
    # the primary by preference order (gemini > *gemini* > first successful).
    Copy-PrimaryResponseAlias -ReviewDir $reviewDir -Round $round `
        -ReviewerList $approvedList -Results $results

    # Convergence: compute warnings + metadata enrichment
    # Filter on ExitCode, not ContentOk: only agy and opencode ever set that key,
    # so a REST-only run selected nothing. And no adapter sets ResponseChars at
    # all -- the length is computed later in the metadata writer -- so this was
    # always 0 and two of the three convergence signals could never fire.
    # A contract-failed reviewer is ExitCode=-1, so it is correctly excluded.
    $primaryResult = @($results.Values) | Where-Object { $_.ExitCode -eq 0 } | Select-Object -First 1
    $currentResponseChars = if ($primaryResult -and $primaryResult.Response) { $primaryResult.Response.Length } else { 0 }
    $convergenceWarnings = @(Test-ConvergenceDivergence -ReviewDir $reviewDir -Round $round -CurrentResponseChars $currentResponseChars)
    if ($slugWarning) { $convergenceWarnings = @($slugWarning) + $convergenceWarnings }
    foreach ($w in ($convergenceWarnings | Where-Object { $_ -and $_ -ne $slugWarning })) { Write-Host $w }

    $topicRoundCount = @(Get-ChildItem -LiteralPath $reviewDir -Filter 'round-*-metadata.json' -ErrorAction SilentlyContinue).Count + 1
    $bundleFileCount = 0
    $manifestPath = Join-Path $reviewDir "round-$round-manifest.json"
    if (Test-Path -LiteralPath $manifestPath) {
        try { $bundleFileCount = @((Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json).sources).Count } catch {}
    }

    Write-ReviewMetadata -ReviewDir $reviewDir -Round $round -TopicSlug $TopicSlug `
        -Mode $Mode -Results $results -Registry $registryHash -BundleTokens $tokenCount `
        -ModelOverrides $modelOverrides -ConvergenceWarnings $convergenceWarnings `
        -IncludeFilesList @($IncludeFiles) -BundleFileCount $bundleFileCount `
        -TopicRoundCount $topicRoundCount

    # --- Void-round gate (2026-08-10) ----------------------------------------
    # A round could burn the whole budget, write artifacts, and still exit 0
    # having produced NOTHING a caller can read. Measured 2026-08-09 on the
    # shipped three-model panel, all three void in one run: opus exceeded its
    # slice of the budget, deepseek-flash failed after reading the bundle, and
    # gemini-pro-high truncated at its output cap with its answer (the prompt,
    # echoed back) demoted to *.rejected.md. era exited 0. On a single-reviewer
    # dispatch that reads as "reviewed, no findings" when nothing was reviewed.
    #
    # Deliberately AFTER Write-ReviewMetadata: the round's telemetry and every
    # artifact must survive the non-zero exit so the failure can be diagnosed.
    #
    # Exit 2, NOT 1. Every exit 1 in this script is a preflight refusal that
    # spent nothing and can be re-run for free (Stop-EraWithError). A void round
    # already cost real money, so a caller must be able to tell the two apart
    # before deciding to retry. SKILL.md documents both.
    #
    # $runSucceeded is deliberately left unset so the finally block keeps the
    # repomix config as a receipt for the failed run.
    $voidReport = Get-EraVoidRoundReport -ReviewDir $reviewDir -Round $round `
        -Results $results -RequestedCount @($reviewerList).Count
    if ($voidReport.IsVoid) {
        Write-Host "[era] ERROR: round $round produced no usable review."
        foreach ($line in $voidReport.Lines) { Write-Host $line }
        Write-Host "Artifacts kept in $reviewDir for diagnosis."
        exit 2
    }

    $firstResult = @($results.Values) | Select-Object -First 1
    if ($firstResult -and $firstResult.WallClockSec) {
        Write-Host "Done. Wall clock: $($firstResult.WallClockSec)s | Tokens: $tokenCount"
    }

    # Reached only on a clean run. The finally block below keeps the repomix
    # config when this is not set, so a failed run leaves a receipt.
    $runSucceeded = $true

} finally {
    # Clean up the round-claim file regardless of dispatch outcome. Previously
    # this delete lived inside the try block at the end, so if Invoke-ReviewerDispatch
    # or any earlier step threw, the claim file persisted and permanently
    # blocked that round number. The claim is per-process state -- once this
    # process is done with it (success or failure), it shouldn't be a tombstone
    # for future runs. Pro 4-7 validation finding.
    if ($claimPath -and (Test-Path -LiteralPath $claimPath)) { Remove-Item -LiteralPath $claimPath -Force -ErrorAction SilentlyContinue }
    # configPath may not be defined if we threw before it was assigned (e.g. in
    # Reserve-ReviewRound), so guard the removal.
    #
    # Deleted ONLY on success. era used to delete it either way (PowerShell
    # unwinds `exit` through `finally`), and the manifest that would replace it
    # is written only after repomix succeeds -- so a failed run left no bundle,
    # no manifest and no config, and nothing to diagnose from. The claim-file
    # delete above stays unconditional: that one really is per-process state.
    if ($runSucceeded) {
        if ($configPath -and (Test-Path -LiteralPath $configPath)) { Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue }
    } elseif ($configPath -and (Test-Path -LiteralPath $configPath)) {
        Write-Host "[era] Retained repomix config for diagnosis: $configPath"
    }
}
