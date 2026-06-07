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
    # Default = 'gemini-pro-low' (Gemini 3.1 Pro (Low) via agy) — Fix 5. The old
    # bare-/era default 'gemini' (Gemini 3.5 Flash) was the LEAST reliable preset
    # (67% ok over 57 runs); Pro (Low) sits in the 94% reliability class with no
    # REST/CLI fallback. An explicit `-Reviewer gemini` still resolves to Flash
    # via the registry, unchanged. COST NOTE (R4-Opus-I2): Pro (Low) input/output
    # pricing ($1.5/$5.0 per M) is ~5x Flash input ($0.3/M) — bare /era is more
    # expensive than before, but far more reliable. Per-reviewer cap stays $2.
    [string[]]$Reviewer = @('gemini-pro-low'),
    [string]$AgyModel,
    [string]$Model,
    [string]$Provider,
    [ValidateSet('', 'update-models', 'doctor', 'set-default', 'review-this', 'suggest')][string]$Command = '',
    # -Doctor: preflight only. Prints a consolidated prereq/backend status report
    # (pwsh, ThreadJob, repomix, each backend CLI/API key) and exits without
    # dispatching a review. Never installs anything — it reports the fix commands.
    [switch]$Doctor,
    [switch]$Force,
    [string[]]$IncludeFiles,
    [string]$PromptOverrideFile,
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

$skillRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $skillRoot 'workflow.ps1')
# Layer-2 model-hint resolver (extracted from this script in PR-D / D.0 so the
# contract test can call Resolve-ModelFromHint directly without forking pwsh).
. (Join-Path $PSScriptRoot 'resolve-model.ps1')

if ($Force) { $env:ERA_FORCE = '1' }

# --- Doctor preflight: report prereq + backend status, then exit (no dispatch) ---
if ($Doctor) {
    $rawRegistry = Get-Content -Raw (Join-Path $skillRoot 'backends/_registry.json') | ConvertFrom-Json
    Write-Host (Format-EraDoctorReport -Checks (Get-EraDoctorReport -Registry $rawRegistry))
    return
}

$repoRoot = if (Test-Path ".git") { (Get-Location).Path } else { $(& git rev-parse --show-toplevel 2>$null) }
if (-not $repoRoot) { $repoRoot = (Get-Location).Path }

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
if (Test-Path $agyBackupPath) {
    $agySettingsPath = Join-Path $HOME '.gemini/antigravity-cli/settings.json'
    try {
        Copy-Item -Path $agyBackupPath -Destination $agySettingsPath -Force
        Remove-Item -Path $agyBackupPath -Force -ErrorAction SilentlyContinue
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
if (Test-Path $opencodeBackupPath) {
    $opencodeStatePath = Join-Path $HOME '.local/state/opencode/model.json'
    try {
        Copy-Item -Path $opencodeBackupPath -Destination $opencodeStatePath -Force
        Remove-Item -Path $opencodeBackupPath -Force -ErrorAction SilentlyContinue
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
    $rawRegistry = Get-Content -Raw (Join-Path $skillRoot 'backends/_registry.json') | ConvertFrom-Json
    Write-Host (Format-EraDoctorReport -Checks (Get-EraDoctorReport -Registry $rawRegistry))
    return
}

# --- set-default command: persist ERA_DEFAULT_REVIEWER -----------------------
if ($Command -eq 'set-default') {
    if (-not $Reviewer -or $Reviewer.Count -ne 1) {
        throw "set-default requires exactly one reviewer preset. Got: $Reviewer"
    }
    $preset = $Reviewer[0]
    # Validate the preset exists in the registry
    $rawRegistry = Get-Content -Raw (Join-Path $skillRoot 'backends/_registry.json') | ConvertFrom-Json
    $validPresets = @($rawRegistry.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object { $_.Name })
    if ($preset -notin $validPresets) {
        throw "Unknown reviewer preset: '$preset'. Valid presets: $($validPresets -join ', ')"
    }
    # Persist per-user (survives new shells). Cross-platform.
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        [Environment]::SetEnvironmentVariable('ERA_DEFAULT_REVIEWER', $preset, 'User')
    } else {
        # macOS / Linux: write to shell profile
        $shellProfile = if ($env:ZSH_VERSION -or (Test-Path "$HOME/.zshrc")) { "$HOME/.zshrc" } else { "$HOME/.bashrc" }
        $exportLine = "export ERA_DEFAULT_REVIEWER='$preset'"
        $existing = if (Test-Path $shellProfile) { Get-Content $shellProfile -Raw } else { '' }
        if ($existing -match 'export\s+ERA_DEFAULT_REVIEWER=') {
            $updated = $existing -replace 'export\s+ERA_DEFAULT_REVIEWER=[''"][^''"]*[''"]', $exportLine
            Set-Content -Path $shellProfile -Value $updated -Encoding UTF8
        } else {
            Add-Content -Path $shellProfile -Value "`n$exportLine" -Encoding UTF8
        }
    }
    # Also set for the current session
    $env:ERA_DEFAULT_REVIEWER = $preset
    Write-Host "[era] Default reviewer set to '$preset' (persistent + current session)."
    Write-Host "[era] This takes effect immediately. New shells will also use this default."
    Write-Host "[era] To revert: unset ERA_DEFAULT_REVIEWER or run '/era set default to <other>'."
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
            $uncommitted = @(& git status --porcelain 2>$null |
                Where-Object { $_ -match '^\S\S\s+(.+)$' -or $_ -match '^\s+(.+)$' } |
                ForEach-Object { ($_ -replace '^.{3}', '').Trim() } |
                Where-Object { $_ })
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
            $TopicSlug = 'review-this'
        }
        $Force = $true  # auto-dispatch, no cost prompt
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
    if (Test-Path $reviewDir) {
        $topics = Get-ChildItem $reviewDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'test' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 10
        if ($topics) {
            $suggestions.Add("")
            $suggestions.Add("=== Existing review topics ===")
            foreach ($t in $topics) {
                $rounds = @(Get-ChildItem $t.FullName -Filter 'round-*-response.md' -ErrorAction SilentlyContinue).Count
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
    if (-not (Test-Path $SpecReview)) {
        throw "-SpecReview: spec file not found: $SpecReview"
    }
    $specReviewPath = (Resolve-Path $SpecReview).Path

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
    $specContent = Get-Content $specReviewPath -Raw
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
    if ($specReviewPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
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
    Set-Content -Path $tmpPromptPath -Value $specPromptContent -Encoding UTF8
    $PromptOverrideFile = $tmpPromptPath
    Write-Host "[era] -SpecReview: generated spec-review prompt at $tmpPromptPath"
    if ($relatedFiles.Count -gt 0) {
        Write-Host "[era] -SpecReview: auto-included related files from frontmatter: $($relatedFiles -join ', ')"
    }
}

# --- Normal review workflow starts here ---
$reviewerList = @($Reviewer -split ',' | ForEach-Object { $_.Trim().ToLower() })

$registry = Get-Content -Raw (Join-Path $skillRoot 'backends/_registry.json') | ConvertFrom-Json

# --- Adaptive default reviewer (only when -Reviewer was NOT explicitly passed) ---
# Don't blindly default to agy and error out if it isn't installed. Detect what's
# available live (CLI on PATH / API key set) and pick the first usable backend by
# preference. Override the order with $env:ERA_DEFAULT_REVIEWER. An explicit
# -Reviewer is always respected as-is (and still errors if its backend is missing).
if (-not $PSBoundParameters.ContainsKey('Reviewer')) {
    $defaultPref = @()
    if ($env:ERA_DEFAULT_REVIEWER) {
        $defaultPref += @($env:ERA_DEFAULT_REVIEWER -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    }
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
    if ($autoReviewer -ne $reviewerList[0]) {
        Write-Host "[era] No -Reviewer specified; auto-selected '$autoReviewer' based on what's installed (default 'gemini-pro-low' needs agy). Pass -Reviewer or set `$env:ERA_DEFAULT_REVIEWER to choose; run -Doctor for status."
        $reviewerList = @($autoReviewer)
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
        pricing = @{ input_per_m = $_.Value.pricing.input_per_m; output_per_m = $_.Value.pricing.output_per_m }
        supports_file_read = $_.Value.supports_file_read
        supports_streaming = $_.Value.supports_streaming
        notes = $_.Value.notes
    }
}

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
$reviewDir = Join-Path $repoRoot ".external-reviews/$TopicSlug"
New-Item -ItemType Directory -Path $reviewDir -Force -ErrorAction SilentlyContinue | Out-Null

# Auto-detect pending-prompt.md in the topic dir if the user didn't pass
# -PromptOverrideFile explicitly. The file naming convention strongly suggests
# auto-pickup; previously it was silently ignored unless the path was passed
# via -PromptOverrideFile. If both are provided, the explicit arg wins.
if (-not $PromptOverrideFile) {
    $pendingPromptPath = Join-Path $reviewDir 'pending-prompt.md'
    if (Test-Path $pendingPromptPath) {
        $PromptOverrideFile = $pendingPromptPath
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
        if (-not (Test-Path $PromptOverrideFile)) { throw "Prompt override file not found: $PromptOverrideFile" }
        $srcResolved = (Resolve-Path $PromptOverrideFile).Path
        $dstResolved = if (Test-Path $promptPath) { (Resolve-Path $promptPath).Path } else { $null }
        if ($null -ne $dstResolved -and $srcResolved -eq $dstResolved) {
            Write-Host "[era] Prompt already at target path, skipping copy"
        } else {
            Copy-Item -Path $PromptOverrideFile -Destination $promptPath -Force
            Write-Host "[era] Using pre-written prompt from $PromptOverrideFile"
        }
    } elseif (-not (Test-Path $promptPath)) {
        $promptTemplate -replace '{{TOPIC_TITLE}}', $promptTitle | Set-Content -Path $promptPath -Encoding utf8
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
        $uncommitted = @(& git status --porcelain 2>$null |
            Where-Object { $_ -match '^\S\S\s+(.+)$' -or $_ -match '^\s+(.+)$' } |
            ForEach-Object { ($_ -replace '^.{3}', '').Trim() } |
            Where-Object { $_ })

        # Files changed in the most-recent commit (HEAD~1..HEAD).
        # Use HEAD~1 only (not HEAD~5) — narrower window avoids pulling in unrelated work.
        $recentCommit = @(& git diff --name-only HEAD~1..HEAD 2>$null |
            Where-Object { $_ })

        $autoCandidates = @($uncommitted + $recentCommit) |
            Sort-Object -Unique |
            Where-Object { $_ -and $_.Trim() -ne '' }

        if ($autoCandidates.Count -eq 0) {
            Write-Host "[era] -AutoDetect: no uncommitted or recent-commit files found. Pass -IncludeFiles explicitly."
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
            $priorResponse = if (Test-Path $priorResponsePath) { Get-Content -Raw $priorResponsePath } else { $null }
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
            $diffPrompt | Set-Content -Path $promptPath -Encoding utf8
            Write-Host "[era] Diff bundle: $($diffResult.BundleFiles.Count) changed, $($diffResult.Deleted.Count) deleted"
        }
    }

    # --- AgyModel hint resolution (supplements -Model flag; does not reset it) ---
    if ($AgyModel) {
        $hint = $AgyModel.Trim()
        $hintNorm = $hint.ToLower() -replace '[^\w\s]', '' -replace '\s+', ' '
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

    $configData = @{
        output = @{ filePath = $bundlePath; style = 'xml'; instructionFilePath = $promptPath; headerText = if ($isFollowUp) { "Diff bundle for $TopicSlug round $round (delta from round $priorRound)" } else { "Full bundle for $TopicSlug round $round" } }
        include = $effectiveInclude
        ignore = @{
            useGitignore = $false
            useDefaultPatterns = $false
            customPatterns = @('node_modules/**', '.git/**', '__pycache__/**', '*.pyc', '*.duckdb', 'validation_results/**/*.db')
        }
    }
    $configJson = $configData | ConvertTo-Json -Depth 10
    $configJson | Set-Content -Path $configPath -Encoding utf8

    # Fix (PR 2 C): Validate -IncludeFiles paths against Test-Path BEFORE invoking
    # repomix. repomix runs 3+ seconds before returning an empty bundle for typo'd
    # or out-of-repo paths. Validate relative to repoRoot (same root repomix uses).
    # SECURITY: Also block path traversal (e.g. ../../../../.ssh/id_rsa) that would
    # cause repomix to bundle out-of-repo sensitive files and send them to APIs.
    if ($IncludeFiles -and $IncludeFiles.Count -gt 0) {
        Push-Location $repoRoot
        try {
            $missing = @($IncludeFiles | Where-Object { -not (Test-Path $_) })
            if ($missing) {
                throw "ERROR: -IncludeFiles paths not found relative to repo root ($repoRoot): $($missing -join ', ')"
            }
            # Path traversal guard: every resolved path must stay inside repoRoot.
            # Skip paths containing wildcards (*, ?, [, ]) — glob patterns match
            # inside the repo tree by definition and can't traverse outside it.
            # Resolve-Path on a wildcard path returns a collection, not a single
            # PathInfo, so .StartsWith would throw.
            $traversal = @($IncludeFiles | Where-Object {
                if ($_ -match '[*?\[\]]') { return $false }
                $resolved = (Resolve-Path $_ -ErrorAction SilentlyContinue).Path
                if (-not $resolved) { return $false }
                -not $resolved.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
            })
            if ($traversal) {
                throw "ERROR: -IncludeFiles paths escape the repo root (path traversal blocked): $($traversal -join ', ')"
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
    $repomixTimeoutSec = 120
    Test-ThreadJobAvailable
    $repomixJob = Start-ThreadJob -Name repomix -ScriptBlock { param($c, $r) Push-Location $r; $o = repomix -c $c 2>&1; $ec = $LASTEXITCODE; Pop-Location; @{ output = $o; exitCode = $ec } } -ArgumentList $configPath, $repoRoot
    $completed = $repomixJob | Wait-Job -Timeout $repomixTimeoutSec
    if (-not $completed) {
        Stop-Job $repomixJob -ErrorAction SilentlyContinue
        Remove-Job $repomixJob -Force -ErrorAction SilentlyContinue
        throw "repomix timed out after ${repomixTimeoutSec}s"
    }
    $repomixJobError = $repomixJob.Error | ForEach-Object { $_.ToString() }
    $repomixResultObj = Receive-Job $repomixJob -ErrorAction SilentlyContinue
    Remove-Job $repomixJob -Force -ErrorAction SilentlyContinue
    if (-not $repomixResultObj) {
        $jobError = $repomixJobError
        $msg = if ($jobError) { "repomix job failed: $jobError" } else { "repomix produced no output (is it installed? try: npm install -g repomix)" }
        throw $msg
    }
    $repomixResult = $repomixResultObj.output -join "`n"
    $repomixExitCode = $repomixResultObj.exitCode
    if ($repomixExitCode -ne 0) {
        throw "repomix failed with exit code $repomixExitCode`: $repomixResult"
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
    $bundleContent = if (Test-Path $bundlePath) { Get-Content -Raw $bundlePath -ErrorAction SilentlyContinue } else { '' }
    $fileTagCount = ([regex]::Matches($bundleContent, '<file\s+[^>]*>')).Count
    if ($fileTagCount -eq 0) {
        $includeHint = if ($IncludeFiles -and $IncludeFiles.Count -gt 0) {
            "`n`nYou passed -IncludeFiles: $($IncludeFiles -join ', ')`nrepomix only includes files INSIDE the repo root ($repoRoot). Absolute paths outside the repo, tilde-prefixed paths that didn't expand, and typo'd globs all silently produce an empty bundle.`n`nFix: use paths relative to '$repoRoot', or run `/era` from a directory whose repo root contains the files you want to bundle."
        } else {
            "`n`nNo -IncludeFiles was passed, so this is unusual. Check that the repo root ($repoRoot) actually contains files matching repomix's default globs, or pass -IncludeFiles explicitly."
        }
        throw "Bundle is empty -- repomix matched 0 files.$includeHint"
    }

    $bundleBytes = if (Test-Path $bundlePath) { (Get-Item $bundlePath).Length } else { 0 }

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

    Write-ReviewManifest -ReviewDir $reviewDir -Round $round -TopicSlug $TopicSlug -PreviousRound $(if ($isFollowUp) { $priorRound } else { $null }) -Files @($bundlePath, $promptPath) -SourceFiles $effectiveInclude -RepoRoot $repoRoot

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

    # Unified response alias (Fix 4 / R3-Gemini-C4): copy the FIRST SUCCESSFUL
    # reviewer's response to round-N-response.md UNCONDITIONALLY. The old
    # `if ($results['gemini'])` gate broke under the non-gemini default
    # (gemini-pro-low) since that key is null. Copy-PrimaryResponseAlias picks
    # the primary by preference order (gemini > *gemini* > first successful).
    Copy-PrimaryResponseAlias -ReviewDir $reviewDir -Round $round `
        -ReviewerList $approvedList -Results $results

    # Convergence: compute warnings + metadata enrichment
    $primaryResult = @($results.Values) | Where-Object { $_.ContentOk } | Select-Object -First 1
    $currentResponseChars = if ($primaryResult) { $primaryResult.ResponseChars } else { 0 }
    $convergenceWarnings = @(Test-ConvergenceDivergence -ReviewDir $reviewDir -Round $round -CurrentResponseChars $currentResponseChars)
    if ($slugWarning) { $convergenceWarnings = @($slugWarning) + $convergenceWarnings }
    foreach ($w in ($convergenceWarnings | Where-Object { $_ -and $_ -ne $slugWarning })) { Write-Host $w }

    $topicRoundCount = @(Get-ChildItem -Path $reviewDir -Filter 'round-*-metadata.json' -ErrorAction SilentlyContinue).Count + 1
    $bundleFileCount = 0
    $manifestPath = Join-Path $reviewDir "round-$round-manifest.json"
    if (Test-Path $manifestPath) {
        try { $bundleFileCount = @((Get-Content -Raw $manifestPath | ConvertFrom-Json).sources).Count } catch {}
    }

    Write-ReviewMetadata -ReviewDir $reviewDir -Round $round -TopicSlug $TopicSlug `
        -Mode $Mode -Results $results -Registry $registryHash -BundleTokens $tokenCount `
        -ModelOverrides $modelOverrides -ConvergenceWarnings $convergenceWarnings `
        -IncludeFilesList @($IncludeFiles) -BundleFileCount $bundleFileCount `
        -TopicRoundCount $topicRoundCount

    $firstResult = @($results.Values) | Select-Object -First 1
    if ($firstResult -and $firstResult.WallClockSec) {
        Write-Host "Done. Wall clock: $($firstResult.WallClockSec)s | Tokens: $tokenCount"
    }

} finally {
    # Clean up the round-claim file regardless of dispatch outcome. Previously
    # this delete lived inside the try block at the end, so if Invoke-ReviewerDispatch
    # or any earlier step threw, the claim file persisted and permanently
    # blocked that round number. The claim is per-process state -- once this
    # process is done with it (success or failure), it shouldn't be a tombstone
    # for future runs. Pro 4-7 validation finding.
    if ($claimPath -and (Test-Path $claimPath)) { Remove-Item $claimPath -Force -ErrorAction SilentlyContinue }
    # configPath may not be defined if we threw before it was assigned (e.g. in
    # Reserve-ReviewRound), so guard the removal.
    if ($configPath -and (Test-Path $configPath)) { Remove-Item $configPath -Force -ErrorAction SilentlyContinue }
}