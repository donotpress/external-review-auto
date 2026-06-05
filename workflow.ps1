<#
.SYNOPSIS
    Core workflow for /external-review-auto. Dot-sourced by SKILL.md
    invocations and by runtimes/era.ps1 standalone shell entry.
#>

function Get-ReviewDiff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$PriorRound,
        [Parameter(Mandatory)][string[]]$CurrentFiles,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $priorManifestPath = Join-Path $ReviewDir "round-$PriorRound-manifest.json"
    if (-not (Test-Path $priorManifestPath)) { return $null }

    $priorManifest = Get-Content -Raw $priorManifestPath | ConvertFrom-Json
    $priorHashes = @{}
    if ($priorManifest.sources -and $priorManifest.source_hashes) {
        foreach ($s in $priorManifest.sources) {
            $h = $priorManifest.source_hashes.$s
            if ($null -ne $h) { $priorHashes[$s] = "$h" }
        }
    } else {
        foreach ($f in $priorManifest.files) {
            if ($f.path -and $f.sha256) { $priorHashes[$f.path] = $f.sha256 }
        }
    }

    $currentHashes = @{}
    foreach ($f in $CurrentFiles) {
        $resolved = Join-Path $RepoRoot $f
        if (Test-Path -Path $resolved) {
            # Resolve globs to concrete paths for hashing
            $concretePaths = if ($f -match '[*?]') {
                @(Get-ChildItem -Path $resolved -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            } else { @($resolved) }
            foreach ($cp in $concretePaths) {
                # SECURITY: block path traversal — skip files outside repo root
                if (-not $cp.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $relPath = $cp.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
                $currentHashes[$relPath] = (Get-FileHash -LiteralPath $cp -Algorithm SHA256).Hash.ToLower()
            }
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

function Invoke-PromptTokenSubstitution {
    <#
    .SYNOPSIS
        Substitute {{PREVIOUS_ROUND}} in a prompt file with the prior round's response.

    .DESCRIPTION
        If the prompt file at $PromptFile contains the literal token {{PREVIOUS_ROUND}},
        this function replaces it with the contents of round-($RoundN-1)-response.md.

        Callers in era.ps1 invoke this AFTER the prompt file is finalized (copied or
        written from template) and BEFORE repomix runs (the bundle picks up the prompt
        via instructionFilePath at bundle time).

        Three outcomes:
            - round-(N-1)-response.md exists: substituted with a fenced header.
            - round-(N-1)-claim.json exists (in-flight): substituted with a [in flight] note.
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

    if (-not (Test-Path $PromptFile)) { return }
    $promptText = Get-Content $PromptFile -Raw
    if ($promptText -notmatch '\{\{PREVIOUS_ROUND\}\}') { return }

    $previousN    = $RoundN - 1
    $responseFile = Join-Path $ReviewDir "round-$previousN-response.md"
    $claimFile    = Join-Path $ReviewDir "round-$previousN-claim.json"

    if (Test-Path $responseFile) {
        $previousText  = Get-Content $responseFile -Raw
        $substitution  = "## Previous round's review (round $previousN)`n`n$previousText"
    } elseif (Test-Path $claimFile) {
        $substitution  = "[Round $previousN is in flight; not yet available]"
    } else {
        $substitution  = "[Round $previousN response not found]"
    }

    # Use [regex]::Replace with a MatchEvaluator delegate so the replacement text
    # is treated as a literal string (no $ or \ interpretation). This is the only
    # safe approach when replacement content may contain arbitrary text from a
    # reviewer response (file paths with backslashes, $ in PowerShell snippets, etc.)
    $newText = [regex]::Replace($promptText, [regex]::Escape('{{PREVIOUS_ROUND}}'), [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        return $substitution
    })
    Set-Content -Path $PromptFile -Value $newText -Encoding UTF8
}

function Get-NextReviewRound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir
    )
    if (-not (Test-Path $ReviewDir)) { return 1 }
    $prior = Get-ChildItem -Path $ReviewDir -Filter 'round-*-manifest.json' -ErrorAction SilentlyContinue |
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
        [string]$RepoRoot
    )
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
    if ($SourceFiles -and $RepoRoot) {
        $manifest.sources = [array]$SourceFiles
        $manifest.source_hashes = @{}
        foreach ($s in $SourceFiles) {
            $resolved = Join-Path $RepoRoot $s
            if (Test-Path -Path $resolved) {
                $concretePaths = if ($s -match '[*?]') {
                    @(Get-ChildItem -Path $resolved -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
                } else { @($resolved) }
                foreach ($cp in $concretePaths) {
                    # SECURITY: block path traversal — skip files outside repo root
                    if (-not $cp.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    $relPath = $cp.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
                    $manifest.source_hashes[$relPath] = (Get-FileHash -LiteralPath $cp -Algorithm SHA256).Hash.ToLower()
                }
            }
        }
    }
    $outPath = Join-Path $ReviewDir "round-$Round-manifest.json"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $outPath -Encoding utf8
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
    if (-not (Test-Path $ReviewDir)) {
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
    Get-ChildItem -Path $ReviewDir -Filter 'round-*-claim.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^round-(\d+)-claim\.json$' } |
        ForEach-Object {
            if (($now - $_.LastWriteTimeUtc) -gt $claimTTL) {
                Write-Host "[era] Reclaiming orphaned claim file: $($_.Name) (last modified $($_.LastWriteTimeUtc))."
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
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
        $highestManifest = Get-ChildItem -Path $ReviewDir -Filter 'round-*-manifest.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^round-(\d+)-manifest\.json$' } |
            ForEach-Object { [int]($_.Name -replace '^round-(\d+)-manifest\.json$','$1') } |
            Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
        $highestClaim = Get-ChildItem -Path $ReviewDir -Filter 'round-*-claim.json' -ErrorAction SilentlyContinue |
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
    if ($survivorAgg -gt $AggregateCap) {
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
    $bundleScaledSec  = [int]($BundleTokens * 0.02)  # 20ms per token
    $effectiveTimeoutSec = [Math]::Max($TimeoutSec, $bundleScaledSec)
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
        $suffix = Get-ResponseFilenameSuffix -ReviewerList $ReviewerList -Preset $r
        $respPath = Join-Path $ReviewDir "round-$Round$suffix-response.md"
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
            param($adapterPath, $bp, $pp, $rp, $mi, $to, $fnName, $agyHint, $modelOverride, $opencodeProvider, $resolvedAgyModel)
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
                $h = & $fnName @commonArgs
                $h.Preset = $mi.preset
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
        } -ArgumentList @($adapterPath, $BundlePath, $PromptPath, $respPath, $modelInfo, $TimeoutSec, $fnName, $AgyModelHint, $ModelOverrides[$r], $opencodeProvider, $resolvedAgyModelForReviewer)
        [pscustomobject]@{ Job = $job; Preset = $r; ResponsePath = $respPath }
    }

    $allJobs = $dispatched | ForEach-Object { $_.Job }
    # Dispatcher timeout = adapter timeout + 30s margin. Without the margin, the
    # adapter's own stall/timeout throw races with Wait-Job's Stop-Job kill --
    # the adapter loses, leaving its native subprocesses (opencode.exe, agy.cmd,
    # claude.exe) as orphaned zombies because Stop-Job only kills the thread,
    # not the thread's children. The margin lets the adapter's own throw fire
    # cleanly, which kills its native process before this Stop-Job touches it.
    $null = Wait-Job -Job $allJobs -Timeout ($TimeoutSec + 30)

    $results = @{}
    foreach ($d in $dispatched) {
        try {
            if ($d.Job.State -ne 'Completed') {
                Stop-Job -Job $d.Job -ErrorAction SilentlyContinue
                $results[$d.Preset] = @{
                    Preset = $d.Preset; ExitCode = -1; Response = $null
                    Warnings = @("Timed out after $TimeoutSec seconds (global).")
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
                $h = $rawJobOutput | Where-Object { $_ -is [hashtable] -or $_ -is [pscustomobject] } | Select-Object -Last 1
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
          1) exact preset 'gemini'
          2) any preset whose name contains 'gemini'
          3) first successful reviewer in the approved list ($ReviewerList order)

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
    if ($ReviewerList.Count -le 1) { return }

    $isOk = {
        param($p)
        $res = $Results[$p]
        $res -and ($res.ExitCode -eq 0)
    }

    # Build the candidate order: exact gemini, then gemini-containing, then the
    # approved list order. De-dup while preserving order.
    $ordered = [System.Collections.Generic.List[string]]::new()
    if ($ReviewerList -contains 'gemini') { $ordered.Add('gemini') }
    foreach ($r in $ReviewerList) {
        if ($r -like '*gemini*' -and -not $ordered.Contains($r)) { $ordered.Add($r) }
    }
    foreach ($r in $ReviewerList) {
        if (-not $ordered.Contains($r)) { $ordered.Add($r) }
    }

    $primary = $null
    foreach ($cand in $ordered) {
        if (& $isOk $cand) { $primary = $cand; break }
    }
    if (-not $primary) { return }

    $src = Join-Path $ReviewDir "round-$Round-$primary-response.md"
    $dst = Join-Path $ReviewDir "round-$Round-response.md"
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $dst -Force
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
        [hashtable]$ModelOverrides = @{}
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
        $contentOk = if ($null -ne $r.ContentOk) { [bool]$r.ContentOk } else { ($r.ExitCode -eq 0) }
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
                warnings = $r.Warnings
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
            $finalInputCost = if ($retryCount -gt 0) { $estIn } else { 0.0 }
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
                warnings = $r.Warnings
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
        reviewers = @($reviewerEntries)
    }
    $meta | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $ReviewDir "round-$Round-metadata.json") -Encoding utf8
}



