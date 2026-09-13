<#
 Module: dispatch -- ThreadJob lifecycle, straggler policy, breaker streaks, void reporting.
 Part of the workflow.ps1 split (see docs/specs/2026-09-12-era-module-boundaries.md).
 Dot-sourced by workflow.ps1; never loaded directly (no independent state).
#>

function Test-EraOwnReviewArtifact {
    <#
    .SYNOPSIS
        Is this path era's OWN output, as opposed to something it was asked to
        review? Repo-relative or absolute, either way.

    .DESCRIPTION
        The rule: anything under .external-reviews is era's own artifact and must
        never be hashed into a manifest or a diff -- EXCEPT round-N-external/,
        which holds review SUBJECTS staged in from outside the repo because
        repomix can only bundle beneath repoRoot. Those are the review, not the
        output.

        Extracted round-7 (opus, finding 6): this predicate existed VERBATIM
        TWICE, in Get-ReviewDiff and Write-ReviewManifest, and the ignore-parser
        refactor that landed between them absorbed neither. Two copies of a rule
        is how the {{PREVIOUS_ROUND}} blocker happened in the same round.

        NOT the same rule as era.ps1's own .external-reviews filter, which has no
        round-N-external carve-out because it is answering a different question
        (what to put in the include list, not what to hash). Deliberately left
        separate rather than force-fitted here.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $n = $Path -replace '\\', '/'
    return ($n -match '(^|/)\.external-reviews(/|$)' -and $n -notmatch '/round-\d+-external/')
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
    # Strip a leading './' PREFIX -- and nothing else. This was .TrimStart('./'),
    # and .NET reads that argument as a SET OF CHARACTERS, so it ate the leading
    # dot of every root-level dot-path:
    #
    #   '.git/config'    -> 'git/config'
    #   '.venv/lib/x.py' -> 'venv/lib/x.py'
    #
    # Measured (round-7): '**/.git/**' is a SHIPPED vendor pattern, it parses
    # into SkipDirNames correctly, and it still returned $false for '.git/config'
    # -- so a correctly-written, correctly-parsed ignore never matched and the
    # manifest/diff walks were free to hash .git. NESTED dot-dirs were unaffected
    # ('sub/.venv/...' keeps its dot), which is why it went unnoticed.
    $n = ($RelPath -replace '\\', '/')
    if ($n.StartsWith('./')) { $n = $n.Substring(2) }
    if ($Sets.ContainsKey('SkipExact') -and $Sets.SkipExact.Contains($n)) { return $true }
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
    # 'dir/*.*' -- direct children only. NOT a prefix test: anything in a
    # SUBdirectory must fall through, or era's '<base>/<slug>/*.*' would swallow
    # the current round's round-N-external/ staging, which holds the review
    # subjects themselves.
    if ($Sets.ContainsKey('SkipDirFiles') -and $Sets.SkipDirFiles.Count -gt 0) {
        $slash = $n.LastIndexOf('/')
        if ($slash -gt 0) {
            $parent = $n.Substring(0, $slash)
            $leaf   = $n.Substring($slash + 1)
            if ($leaf.Contains('.') -and $Sets.SkipDirFiles.Contains($parent)) { return $true }
        }
    }
    if ($Sets.ContainsKey('SkipDirExt') -and $Sets.SkipDirExt.Count -gt 0) {
        $ext2 = [System.IO.Path]::GetExtension($n)
        foreach ($de in $Sets.SkipDirExt) {
            if ($ext2 -and ($ext2 -ieq $de.Ext) -and
                ($n.StartsWith(($de.Dir + '/'), [System.StringComparison]::OrdinalIgnoreCase))) { return $true }
        }
    }
    return $false
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

function Wait-EraJobDone {
    <#
    .SYNOPSIS
        Wait, bounded, for a ThreadJob to reach a terminal state.
    .DESCRIPTION
        The abandon paths must JOIN before reaping: killing the native child
        unblocks the adapter, but its finally (forensic snapshot + structured
        throw/return) still needs a moment. Stop-Job first reaps a record
        that names the failure precisely (measured 2026-09-11: the opencode
        exit-fail trailer). Same 20s unwind the grace path already allowed.
    .OUTPUTS
        [bool] — $true if the job finished in time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Job,
        [int]$TimeoutSec = 20
    )
    $doneStates = @('Completed', 'Failed', 'Stopped')
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($Job.State -notin $doneStates -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    return ($Job.State -in $doneStates)
}

function Get-EraHeartbeatSec {
    <#
    .SYNOPSIS
        How often the dispatch poll loop should report that it is still alive.
        60s default; ERA_HEARTBEAT_SEC overrides; 0 disables.

    .DESCRIPTION
        Pure so it can be tested without a dispatch, the same reason
        Test-EraStragglerExpired below is pure. A bad env value falls back to the
        default rather than throwing or silencing the heartbeat: silence is the
        failure mode this exists to remove, so an unparseable tunable must not
        produce it.
    #>
    [CmdletBinding()]
    param([string]$EnvValue, [int]$Default = 60)
    if ([string]::IsNullOrWhiteSpace($EnvValue)) { return $Default }
    $v = 0
    if ([int]::TryParse($EnvValue, [ref]$v) -and $v -ge 0) { return $v }
    return $Default
}

function Test-EraHeartbeatDue {
    <#
    .SYNOPSIS
        Is a heartbeat due at $ElapsedSec, given the last scheduled beat?
        Returns $true/$false. Disabled entirely when $HeartbeatSec is 0.
    #>
    [CmdletBinding()]
    param([int]$ElapsedSec, [int]$NextBeatSec, [int]$HeartbeatSec)
    if ($HeartbeatSec -le 0) { return $false }
    return ($ElapsedSec -ge $NextBeatSec)
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

function Get-EraNewlyDone {
    <#
    .SYNOPSIS
        Dispatched entries whose job newly reached a terminal state. Pure.
    .DESCRIPTION
        The poll loop calls this every iteration with the seen-set it keeps;
        newly finished seats get one log line each (delivered vs. finished
        without artifact, via the response file -- never by Receiving the
        job early, which would steal the collection path's result). Callers
        add the returned presets to their seen-set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Dispatched,
        [string[]]$Seen = @()
    )
    $doneStates = @('Completed', 'Failed', 'Stopped')
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($Dispatched)) {
        if (-not $d -or -not $d.Job) { continue }
        if ($Seen -contains $d.Preset) { continue }
        try { $st = $d.Job.State } catch { continue }
        if ($st -in $doneStates) { $out.Add($d) }
    }
    return @($out)
}

function Write-EraCompletionReceipt {
    <#
    .SYNOPSIS
        One machine-readable receipt per round, on EVERY exit path.
    .DESCRIPTION
        `round-N-done.json`: tool, round, topic, timestamp, exit code,
        usable/requested counts, per-seat preset/exit/error/chars, duration.
        Response TEXT never lands here (chars only) -- this file is for
        watchers, and a 16KB review does not belong in a ping payload.
        Best-effort throughout: telemetry must never fail a round, so all
        errors are swallowed. Module: bundle (telemetry writer).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewDir,
        [Parameter(Mandatory)][int]$Round,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TopicSlug,
        [Parameter(Mandatory)][AllowNull()][object]$Results,
        [Parameter(Mandatory)][int]$ExitCode,
        [double]$DurationSec = 0
    )
    try {
        $seats = [System.Collections.Generic.List[object]]::new()
        $usable = 0
        $keys = @()
        if ($Results -is [hashtable]) { $keys = @($Results.Keys) }
        foreach ($k in ($keys | Sort-Object)) {
            $res = $Results[$k]
            $ex = 0
            try { $ex = [int]$res.ExitCode } catch { $ex = -1 }
            if ($ex -eq 0) { $usable++ }
            $chars = 0
            try { if ($null -ne $res.Response) { $chars = ([string]$res.Response).Length } } catch {}
            $seats.Add([ordered]@{
                preset = [string]$k
                exit   = $ex
                error  = [string]$res.Error
                chars  = $chars
            })
        }
        $receipt = [ordered]@{
            tool      = 'era'
            round     = $Round
            topic     = [string]$TopicSlug
            timestamp = ([datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
            exit_code = $ExitCode
            usable    = $usable
            requested = @($keys).Count
            seats     = @($seats)
            duration_s = $DurationSec
        }
        $receipt | ConvertTo-Json -Compress -Depth 4 |
            Set-Content -LiteralPath (Join-Path $ReviewDir "round-$Round-done.json") -Encoding utf8 -ErrorAction Stop
    } catch { }
}

function Send-EraCompletionPing {
    <#
    .SYNOPSIS
        Best-effort human ping on round end. Never throws, never blocks.
    .DESCRIPTION
        Toast via BurntToast when the module is present, else a console
        beep attempt. Headless/redirected hosts fail either path silently --
        the receipt file above is the reliable channel, this is a courtesy.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Round, [Parameter(Mandatory)][int]$ExitCode)
    try {
        if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
            Import-Module BurntToast -ErrorAction SilentlyContinue
            New-BurntToastNotification -Text "era round $Round finished", "exit $ExitCode" -ErrorAction SilentlyContinue
        } else {
            [Console]::Beep(880, 300)
        }
    } catch { }
}

function Get-EraStragglerDeferral {
    <#
    .SYNOPSIS
        Epoch seconds to wait until instead of tree-killing now, or $null to
        kill as today.
    .DESCRIPTION
        Deadline sidecar (2026-09-11): an adapter publishes its own give-up
        epoch to "<pidfile>.deadline" at spawn. A lone seat that is silent BY
        DESIGN (opencode read-tool runs with a raised first-token deadline)
        must not be tree-killed at lone+grace while its own budget is still
        running -- measured on ebook-pipeline round 3, killed 3s before its
        own 875s budget fired.

        Returns min(sidecar + 20s unwind, budget end). The 20s is the same
        unwind margin the kill path allows the job ($unwindBy): past its own
        deadline the adapter still needs a moment to throw, snapshot, and
        return before the dispatcher moves on.

        Fail-closed toward the old behaviour: absent, unparseable, expired
        (including stale files from previous rounds, whose epochs are old by
        construction), and over-budget sidecars all return $null. A second
        grace expiry reads the same (now past) epoch, so one seat cannot
        defer twice.
    .OUTPUTS
        [long] epoch seconds, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PidFile,
        [Parameter(Mandatory)][long]$NowEpoch,
        [Parameter(Mandatory)][long]$BudgetEndEpoch
    )
    $unwindSec = 20
    if (-not $PidFile) { return $null }
    $sidecar = "$PidFile.deadline"
    if (-not (Test-Path -LiteralPath $sidecar)) { return $null }
    $raw = Get-Content -LiteralPath $sidecar -Raw -ErrorAction SilentlyContinue
    $epoch = 0
    if (-not [long]::TryParse("$raw".Trim(), [ref]$epoch)) { return $null }
    $target = [Math]::Min($epoch + $unwindSec, $BudgetEndEpoch)
    if ($target -le $NowEpoch) { return $null }
    return $target
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

function Compare-EraSeatContainment {
    <#
    .SYNOPSIS
        Did the working tree move while the seats were running? Takes two
        Get-EraGitState snapshots and returns a verdict.

    .DESCRIPTION
        WHAT `contained` DOES AND DOES NOT MEAN. This diffs `git status`, so it
        sees WRITES INSIDE THE WORK TREE and nothing else. It cannot see:

          * a seat READING anything -- prior rounds, a peer's in-flight response,
            any file on the machine. Reads leave no trace in `git status`.
          * a write OUTSIDE the work tree.
          * anything gitignored, including all of `.external-reviews/`, which is
            filtered below on purpose so era's own artifacts do not read as a
            breach.

        THIS IS NOT THEORETICAL. On 2026-09-06 era seats stamped the OPERATOR'S
        tmux windows -- writing their busy state and conversation ids onto panes
        belonging to another session for 900s at a time -- and this function
        reported `contained` for every one of those rounds, correctly by its own
        definition and uselessly for the purpose it was being trusted with. A
        peer session had to measure it; nothing about it was visible here.

        So `contained` is evidence that the REPO was not modified. It is not
        evidence that a seat stayed in its lane. Anything relying on the second
        claim needs a different instrument, and the honest reading of a green
        verdict is narrow.
    #>
    [CmdletBinding()]
    param($Before, $After)

    # FAIL TO 'unmeasured', NEVER TO 'contained'. Get-EraGitState returns $null
    # outside a work tree and when git is missing. Two nulls diff to nothing and
    # $null -eq $null, so every check below answers "clean" -- a fact about the
    # instrument dressed as a fact about the repo. Same shape as the three
    # fail-open catches opencode.ps1 records (token gate, bundle line counts,
    # bundle sizing): a read failure must not be indistinguishable from a real
    # measurement.
    if ($null -eq $Before -or $null -eq $After) {
        $which = if ($null -eq $Before -and $null -eq $After) { 'neither snapshot could be taken' }
                 elseif ($null -eq $Before) { 'the pre-dispatch snapshot could not be taken' }
                 else { 'the post-dispatch snapshot could not be taken' }
        return [pscustomobject]@{
            Verdict    = 'unmeasured'
            NewDirty   = @()
            HeadMoved  = $false
            BeforeHead = $null
            AfterHead  = $null
            Reason     = "$which (not a git work tree, or git is not on PATH); containment was not checked."
        }
    }

    # era's OWN artifacts are written between the two snapshots, so they are
    # guaranteed to show up in the second one. Dropping them is the same fix,
    # against the same directory, as the -AutoDetect candidate filter at
    # runtimes/era.ps1:1189 -- where the identical oversight once had era
    # "propose its own review history for review". Same regex, deliberately.
    $newDirty = @(Compare-Object -ReferenceObject @($Before.Dirty) -DifferenceObject @($After.Dirty) |
        Where-Object { $_.SideIndicator -eq '=>' } |
        ForEach-Object { $_.InputObject } |
        Where-Object {
            # Porcelain is 'XY <path>': two status chars, a space, then the path,
            # quoted when it contains a space or a non-ASCII byte.
            $p = ($_ -replace '^..\s', '').Trim('"')
            ($p -replace '\\', '/') -notmatch '(^|/)\.external-reviews(/|$)'
        })

    $headMoved = ($Before.Head -ne $After.Head)

    return [pscustomobject]@{
        Verdict    = if ($newDirty.Count -gt 0 -or $headMoved) { 'breached' } else { 'contained' }
        NewDirty   = $newDirty
        HeadMoved  = $headMoved
        BeforeHead = $Before.Head
        AfterHead  = $After.Head
        Reason     = $null
    }
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
        } catch [System.IO.DirectoryNotFoundException] {
            # NOT A COLLISION, AND IT WILL NOT BECOME ONE ON THE 50TH ATTEMPT.
            # DirectoryNotFoundException derives from IOException, so the clause
            # below used to swallow it and spin the loop 50 times before throwing
            # "Directory may be in an inconsistent state" -- a message about
            # contention, for a path problem. That is how f33705a shipped: era
            # could not claim a round at all on a repo whose review dir did not
            # exist yet. THE PATH BUG WAS FIXED THERE (the dir is created above)
            # AND THIS CATCH WAS NOT, so the swallow was still live for every
            # other way the open can fail without contention. Measured on Windows
            # PowerShell 2026-09-04, all three arrive as this one type: parent
            # directory missing (the dir deleted under a running dispatch), the
            # drive not existing, and a path over the length limit.
            #
            # Ordered FIRST on purpose: PowerShell takes the first clause whose
            # type matches and the base type matches the derived one, so placed
            # after the IOException clause this would be dead code.
            throw ("Reserve-ReviewRound: cannot create the claim file '$claimPath' -- " +
                   "the path is not reachable ($($_.Exception.Message)). This is not a " +
                   "collision with another dispatch; retrying will not help.")
        } catch [System.IO.IOException] {
            # Another process claimed this round concurrently; retry immediately.
            # A BARE IOException is the only thing that means that -- verified by
            # execution in tests/RoundClaimRetryScope.Tests.ps1, which reproduces
            # both branches against the real filesystem.
            $attempt++
        }
    }

    throw "Reserve-ReviewRound: failed to claim a round number after $maxRetries attempts in '$ReviewDir'. Directory may be in an inconsistent state."
}

function Test-ThreadJobAvailable {
    <#
    ASK WHETHER THE HOST CAN START A THREAD JOB, NOT WHETHER A MODULE HAS A
    PARTICULAR NAME. This was `Get-Module -Name ThreadJob -ListAvailable`, and on
    2026-09-06 -- after a reboot that updated PowerShell -- it took era down on
    this box completely: every dispatch threw "ThreadJob module is required.
    Install with: Install-Module -Name ThreadJob", and 28 tests in
    tests/DispatchThreadJob.Tests.ps1 failed with it.

    Nothing was missing. PowerShell RENAMED the module. Measured that day:

        Get-Module -ListAvailable ThreadJob,Microsoft.PowerShell.ThreadJob
          -> Microsoft.PowerShell.ThreadJob  2.2.0
             C:\program files\powershell\7\Modules\...
        Get-Command Start-ThreadJob
          -> Microsoft.PowerShell.ThreadJob  2.2.0

    So the probe reported a fact about ITS OWN QUESTION ("no module is called
    ThreadJob") as a fact about the SUBJECT ("this host cannot run thread
    jobs"), and era refused to dispatch on a host that was fully capable. Same
    shape as the fail-open catches recorded in backends/opencode.ps1, one
    direction over: there a read failure looked like a real measurement, here a
    naming change looked like a missing dependency.

    Get-Command auto-loads from any module that exports the cmdlet, so this form
    accepts BOTH names and whatever the next rename produces. The guard exists to
    protect Start-ThreadJob; ask about Start-ThreadJob.
    #>
    if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
        throw ("Start-ThreadJob is not available in this PowerShell. It ships with PowerShell 7 as " +
               "Microsoft.PowerShell.ThreadJob (older hosts call it ThreadJob); install with: " +
               "Install-Module -Name Microsoft.PowerShell.ThreadJob -Force -Scope CurrentUser")
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
        # preset -> an ALTERNATE bundle path for that seat only. Same shape as the
        # two override maps above. Used by -BlindSeat to hand one reviewer a
        # comment-stripped copy while every other seat reviews the normal bundle,
        # so the round is an A/B rather than a different round.
        [hashtable]$BundleOverrides = @{},
        # Bundle size in tokens (from repomix). Used to scale TimeoutSec and
        # Wait-Job timeout: reasoning-heavy models on large bundles need 8+ min
        # of silent thinking before first output. Without scaling, a 100k-token
        # bundle on Pro `max` would be killed mid-think. Conservative formula:
        # 20ms per token => ~50 tok/sec, well below first-token rate for Flash
        # but realistic for max-variant reasoning models.
        [int]$BundleTokens = 0,
        # Breaker state file (test seam; production omits it and uses the
        # machine-scoped default from Get-EraBackendHealthPath). Follows the
        # injectable-resolver convention: hermetic tests must not read the
        # operator's real streak file.
        [string]$BackendHealthPath,
        # Repo root for the claim-check probe's disk frame (agentic seats
        # cite files on disk, not the bundle subset). Optional: without it
        # the probe checks the bundle frame only.
        [string]$RepoRoot
    )
    Test-ThreadJobAvailable

    # Bundle-size-aware TimeoutSec scaling. Grows linearly past ~35k tokens. The
    # adapter sees this scaled value and uses it for both stall and timeout
    # checks; Wait-Job below uses it + 30s margin so the adapter has room to throw
    # cleanly before the dispatcher kills the ThreadJob (which would leak native
    # subprocesses). Cap at 1800s (30 min) so a very large bundle doesn't tie up a
    # threadpool slot for an unbounded period.
    #
    # THE FLOOR WAS 600s AND IT WAS A GUESS, like the four stall constants that
    # went the same way on 2026-09-04. What it had to be measured against is the
    # CLAMP: the opencode adapter's stall threshold is min(appetite, budget - 30),
    # so for any bundle small enough to sit on the floor, the BUDGET decided how
    # long a seat could think, not the measurement. At a 600s floor that clamp is
    # 569s, and one productive run in the local opencode.db is on the wrong side
    # of it:
    #
    #   7,794 input tokens (squarely on the floor), 26,525 output tokens,
    #   11,520 characters of finished review -- and 570.2s of silence.
    #   The 569s clamp would have killed it 1.2 SECONDS before it delivered.
    #
    # 570.2s is the largest silence any productive deepseek-v4-flash turn has
    # taken. A 700s floor puts the clamp at 670s, clearing it by 99.8s (17.5%),
    # and kills 0 of the 404 productive floor-regime seat-runs in the 628-round
    # archive -- against 3 at the old 570s clamp.
    #
    # NOT RAISED TO 854s, which is what it would take for the stall threshold to
    # stop clamping at all (824s appetite + 30s margin). That appetite is a GLOBAL
    # bound: it includes big-output runs and free-tier queue stalls that do not
    # happen at floor bundle sizes, where the worst observed silence is 570.2s.
    # Buying headroom nobody has used costs +254s on every wedged seat instead of
    # +100s, and 11.8% of floor-regime seat-runs are non-productive. Apply the
    # measurement for the regime, not the largest one available.
    #
    # WHAT THIS COSTS, measured rather than asserted: a wedged seat on a small
    # bundle burns 700s instead of 600s before the dispatcher abandons it. No
    # productive seat-run pays anything -- 1 of 977 in the archive ever exceeded
    # its budget at all, and only 19 of them reached even 80% of it.
    #
    # AND THE SLOPE WAS THE SAME CATEGORY ERROR AS THE FLOOR, one line down.
    # `BundleTokens * 0.02` charges 20ms per token of BUNDLE -- i.e. it predicts
    # how long a seat takes from how much it READS. Measured across 978 productive
    # seat-runs in era's own round archive:
    #
    #     r(wall clock, bundle tokens)   = +0.083
    #     r(wall clock, response chars)  = +0.506   (claude +0.799, opencode +0.536)
    #
    # Bundle size explains under 1% of the variance. What a seat spends its time
    # on is what it WRITES. The median wall clock barely moves across a fifty-fold
    # range of bundle size -- 42s at <10k tokens, 157s at 10-25k, 167s at 25-50k,
    # 188s at 50-100k, 240s at 100-200k -- while the old rule swung the budget
    # from 700s to 1800s over the same range. Same mistake the stall overlay made
    # (a generation rate applied to an input count), one level up.
    #
    # It is not zero, though: the TAIL grows with size, because a bigger bundle
    # gets a longer review. So the term stays and gets a measured coefficient.
    # The budget has to dominate the largest wall clock seen at each size:
    #
    #     bundle tokens      longest productive seat-run
    #          4,628                590.1s
    #         21,133                597.1s
    #         47,266                882.1s
    #         81,333               1005.5s
    #        122,547               1426.0s   <- this one sets the slope
    #        258,461               1051.9s
    #
    # The minimum slope that envelopes those from a 700s intercept is 0.00592
    # s/token, set by the 122,547-token run. Times the same 1.175 margin the floor
    # carries gives 0.008 -- so the budget clears the worst run at every size by
    # ~18% or better, where the old rule's tightest productive margin was 36.6s
    # (a 32,798-token round that ran 663.4s against 700s).
    #
    # MEASURED AGAINST EVERY CANDIDATE, on all 978 productive seat-runs:
    #
    #     rule                        kills   tightest margin   mean budget
    #     max(700, 0.020t)  [old]         0             36.6s         1072s
    #     flat 1100s                      1           -326.0s         1100s
    #     700 + 0.006t                    0              9.0s         1017s
    #     700 + 0.008t      [new]         0            146.9s         1102s
    #
    # Four times the margin for 2.8% more patience. The shape changes as well as
    # the size: the new rule is MORE generous in the middle, where every near-miss
    # is, and LESS at the top, where the old one granted 1800s to rounds whose
    # worst observed run was 1005.5s. A wedged seat costs 40s more on average.
    $seatBudgetFloorSec = 700
    $bundleTokenSlopeSec = 0.008
    $bundleScaledSec  = [int]($seatBudgetFloorSec + $BundleTokens * $bundleTokenSlopeSec)
    $TimeoutSec       = [Math]::Max($TimeoutSec, $seatBudgetFloorSec)
    $effectiveTimeoutSec = [Math]::Min([Math]::Max($TimeoutSec, $bundleScaledSec), 1800)
    if ($effectiveTimeoutSec -gt $TimeoutSec) {
        # REPORTED ONLY WHEN THE BUNDLE BOUGHT SOMETHING WORTH KNOWING. The rule is
        # additive now, so any bundle at all makes $effectiveTimeoutSec exceed the
        # floor and the old unconditional line would print on every single round --
        # the same "a line on every healthy round trains the reader to skip the
        # line that matters" trap the stall warning had to be pulled out of. One
        # minute of extra patience is the threshold: below that the number has not
        # meaningfully moved.
        if ($effectiveTimeoutSec -ge ($TimeoutSec + 60)) {
            Write-Host "[dispatch] Bundle-scaled TimeoutSec ${TimeoutSec}s -> ${effectiveTimeoutSec}s for ${BundleTokens}-token bundle (${seatBudgetFloorSec}s floor + ${bundleTokenSlopeSec}s/token)."
        }
        $TimeoutSec = $effectiveTimeoutSec
    }
    # $PSScriptRoot here is workflow/ (this module's dir), not the skill
    # root -- step one level up, same value workflow.ps1 produced before
    # the split. Wrong root here means backends/<backend>.ps1 never resolves
    # and every seat fails to spawn.
    $skillRoot = if ($SkillRootOverride) { $SkillRootOverride } else { Split-Path -Parent $PSScriptRoot }
    # Circuit breaker: skip seats whose backend is on a fatal streak instead
    # of burning a full seat budget failing identically. The health file is
    # machine-scoped (per-topic stores never see cross-topic streaks); a
    # missing file means no history, i.e. dispatch everything. Skipped seats
    # get synthetic records merged after collection -- no job, no spend. (The
    # pre-dispatch cost estimate conservatively still covers them: consent
    # overstates spend, never understates.)
    $breakerSkipped = @{}
    $breakerHealthPath = if ($BackendHealthPath) { $BackendHealthPath } else { Get-EraBackendHealthPath }
    $breakerHealth = Read-EraBackendHealth -StatePath $breakerHealthPath
    $breakerPick = Select-EraBreakerSkips -ReviewerList @($ReviewerList) -Registry $Registry -Health $breakerHealth -Threshold 3
    foreach ($sr in @($breakerPick.Skipped)) {
        Write-Host ("[dispatch] Skipping '{0}': {1}; not dispatching (no spend)." -f $sr, $breakerPick.Detail[$sr])
        $breakerSkipped[$sr] = @{
            Preset = $sr; ExitCode = -1; Response = $null
            Warnings = @("Skipped by circuit breaker: $($breakerPick.Detail[$sr]). Backend streaks reset on the next success or after 24h.")
            Error = 'breaker-skip'
        }
    }
    $dispatched = foreach ($r in $ReviewerList) {
        if ($breakerSkipped.ContainsKey($r)) { continue }
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
        # The deadline sidecar lives and dies with its pid file: a stale
        # sidecar reads as expired (fail-closed), but leaving them accumulate
        # in the topic dir is still litter, and a copied/reused round dir is
        # the one shape that defeats the fail-closed argument.
        Remove-Item -LiteralPath "$pidPath.deadline" -Force -ErrorAction SilentlyContinue
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
        $seatBundle = Get-EraSeatBundle -Preset $r -BundleOverrides $BundleOverrides -BundlePath $BundlePath
        $job = Start-ThreadJob -Name "review-$r" -ThrottleLimit 4 -ScriptBlock {
            param($adapterPath, $bp, $pp, $rp, $mi, $to, $fnName, $agyHint, $modelOverride, $opencodeProvider, $resolvedAgyModel, $pidFile)
            # Started here, not inside the try: on the exception path the adapter
            # returns no result to take a duration from, and this used to be
            # hardcoded WallClockSec = 0. Round-7's deepseek-flash ran for
            # minutes -- it read the bundle, ran git, dot-sourced workflow.ps1
            # and executed detector probes -- and recorded 0 seconds.
            $jobSw = [System.Diagnostics.Stopwatch]::StartNew()
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
                # AN EXCEPTION IS NOT A TRANSCRIPT STORE. This used to put the
                # entire exception message into Error, again into Warnings, and
                # a third time into Stderr. An agentic adapter throws its whole
                # session: round-7's deepseek-flash produced a 47,301-char
                # message, which made ONE Error field 43% of the round's
                # metadata and grew the file from 4,219 bytes (round 6) to
                # 109,979 -- 26x -- for a single failed reviewer.
                #
                # Truncating alone would be worse than the bloat, because the
                # TAIL is the diagnostic half: diagnosing round 7 needed the
                # LAST 1,800 chars, not the first. So the whole thing goes to
                # disk next to the response, the record keeps a bounded head+tail
                # excerpt, and the warning names the file.
                $exMsg  = "$($_.Exception.Message)"
                $exFull = "$_`n`n--- script stack trace ---`n$($_.ScriptStackTrace)"
                $logPath = $null
                try {
                    $logPath = if ($rp -match '-response\.md$') { $rp -replace '-response\.md$', '-error.log' }
                               else { "$rp.error.log" }
                    Set-Content -LiteralPath $logPath -Value $exFull -Encoding utf8 -ErrorAction Stop
                } catch { $logPath = $null }

                $exShort = $exMsg
                if ($exMsg.Length -gt 800) {
                    $where = if ($logPath) { "full text: $logPath" } else { 'full text could not be written to disk' }
                    $exShort = $exMsg.Substring(0, 400) +
                        " … [truncated: $($exMsg.Length) chars; $where] … " +
                        $exMsg.Substring($exMsg.Length - 300)
                }
                $warn = "Adapter exception: $exShort"
                return @{
                    Preset            = $mi.preset
                    ExitCode          = -1
                    Response          = $null
                    CaptureMethod     = 'error'
                    InputTokens       = $null
                    OutputTokens      = 0
                    WallClockSec      = [math]::Round($jobSw.Elapsed.TotalSeconds, 1)
                    Warnings          = @($warn)
                    Error             = $exShort
                    Stderr            = $exShort
                    TruncationWarning = $null
                }
            }
        } -ArgumentList @($adapterPath, $seatBundle, $PromptPath, $respPath, $modelInfo, $TimeoutSec, $fnName, $AgyModelHint, $ModelOverrides[$r], $opencodeProvider, $resolvedAgyModelForReviewer, $pidPath)
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
    # Wall-epoch twin of $sw for the deadline sidecar (epoch arithmetic needs
    # an absolute clock; the stopwatch only gives elapsed).
    $loopStartEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $loneSince  = -1
    # Presets already announced as finished (per-seat transition log below).
    $seenDone   = @()
    $stopReason = ''
    $doneStates = @('Completed', 'Failed', 'Stopped')

    # HEARTBEAT. Without it this loop is SILENT from the "[dispatch] Scaled
    # TimeoutSec" line until either a lone straggler appears or the budget
    # expires -- up to $budgetSec, which is 732s on a 35k-token panel and 1830s
    # on a large one. In that window the log cannot distinguish "working" from
    # "died ten minutes ago", and that ambiguity has now cost two rounds:
    #
    #   bulk-refresh-vpn-headless r1/r2 (2026-09-02): the driver read the silence
    #     as death and re-dispatched while r1 was still alive. Both seats paid twice.
    #   direction-paths-2026-09-04 r1: the dispatcher was reaped by its launcher's
    #     tool timeout at ~01:21 and nothing said so. Establishing merely WHEN it
    #     died needed process forensics and an argument from the survival of
    #     round-1-claim.json, because the log's last line was the dispatch line.
    #
    # Cheap: the loop already wakes every 500ms, so this is a counter and one
    # Write-Host. Emitted only while something is outstanding, so a fast round
    # stays quiet. ERA_HEARTBEAT_SEC tunes it; 0 disables.
    #
    # Write-Host reaches a redirected log promptly -- verified 2026-09-04 by
    # tailing a redirect mid-run -- so these lines are visible live rather than
    # arriving in one flush at exit. That is the whole point; a buffered
    # heartbeat would be worse than none, because it would look like silence.
    $heartbeatSec = Get-EraHeartbeatSec -EnvValue $env:ERA_HEARTBEAT_SEC
    $nextBeat     = $heartbeatSec

    while ($true) {
        $outstanding = @($allJobs | Where-Object { $_.State -notin $doneStates }).Count
        if ($outstanding -eq 0) { break }
        $elapsed = [int]$sw.Elapsed.TotalSeconds

        if (Test-EraHeartbeatDue -ElapsedSec $elapsed -NextBeatSec $nextBeat -HeartbeatSec $heartbeatSec) {
            $nextBeat = $elapsed + $heartbeatSec
            # Name WHO is outstanding, not just how many: on a 4-seat panel
            # "2 running" does not tell you whether the expensive seat is one of
            # them, and the seat names are what a post-mortem needs.
            $waiting = @($dispatched | Where-Object { $_.Job.State -notin $doneStates } |
                         ForEach-Object { $_.Preset }) -join ', '
            $doneN = @($allJobs).Count - $outstanding
            Write-Host ("[dispatch] {0}s elapsed of {1}s budget; {2}/{3} done; still running: {4}" -f `
                        $elapsed, $budgetSec, $doneN, @($allJobs).Count, $(if ($waiting) { $waiting } else { '(resolving)' }))
        }

        if ($outstanding -eq 1 -and $loneSince -lt 0 -and @($allJobs).Count -ge 2) {
            $loneSince = $elapsed
            Write-Host "[dispatch] One reviewer still running at ${elapsed}s; allowing ${graceSec}s grace before abandoning it (ERA_STRAGGLER_GRACE_SEC)."
        }
        # Per-seat finishes, announced once each as they happen (not just in
        # aggregate at the end). Artifact-checked, never Received: pulling the
        # job's output here would steal the collection path's result.
        foreach ($nd in @(Get-EraNewlyDone -Dispatched $dispatched -Seen $seenDone)) {
            $art = if ($nd.ResponsePath -and (Test-Path -LiteralPath $nd.ResponsePath)) { 'delivered' }
                   else { 'finished, no artifact yet' }
            Write-Host "[dispatch] Seat '$($nd.Preset)' $art."
            $seenDone += @($nd.Preset)
            # Streaming claim-check: validate each delivered seat while the
            # rest still run. Only when >1 seat remains outstanding (never on
            # the lone straggler -- grace timing is sacred) and only once per
            # seat (receipt presence). Advisory only: probe failures log and
            # the post-round synthesis covers the seat regardless.
            if ($outstanding -gt 1 -and $art -eq 'delivered') {
                $checkReceipt = "$($nd.ResponsePath).check.json"
                if (-not (Test-Path -LiteralPath $checkReceipt)) {
                    try {
                        $probeArgs = @{ ResponsePath = $nd.ResponsePath }
                        if ($RepoRoot) { $probeArgs['RepoRoot'] = $RepoRoot }
                        & (Join-Path $skillRoot 'tools/probes/claim-check.ps1') @probeArgs
                    } catch { Write-Host "[dispatch] claim-check for '$($nd.Preset)' failed to run; synthesis covers it post-round." }
                }
            }
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
            # Deadline sidecar (2026-09-11): an adapter that published a
            # give-up epoch later than this grace expiry is still working BY
            # DESIGN. Move the grace clock so it fires at the adapter's own
            # deadline instead of killing work it has not given up on. Absent
            # or expired sidecars fall through to the kill below, exactly as
            # before -- and a second expiry reads the same (now past) epoch,
            # so one seat cannot defer twice.
            $deferUntil = $null
            if ($straggler -and $straggler.PidPath) {
                $deferUntil = Get-EraStragglerDeferral -PidFile $straggler.PidPath `
                    -NowEpoch ($loopStartEpoch + $elapsed) -BudgetEndEpoch ($loopStartEpoch + $budgetSec)
            }
            if ($deferUntil) {
                $loneSince = ($deferUntil - $loopStartEpoch) - $graceSec
                Write-Host "[dispatch] Straggler '$($straggler.Preset)' is still inside its published self-deadline; deferring abandonment (grace now fires at $(($deferUntil - $loopStartEpoch))s elapsed)."
                $stopReason = ''
            }
            else {
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
        }
        elseif ($stopReason) { break }
        Start-Sleep -Milliseconds 500
    }

    $results = @{}
    foreach ($d in $dispatched) {
        try {
            if ($d.Job.State -ne 'Completed') {
                # Unblock the job BEFORE stopping it. Stop-EraAdapterChild's
                # docstring records the measurement: a ThreadJob sitting inside
                # Process.WaitForExit() cannot be interrupted, so Stop-Job blocks
                # indefinitely and the native child keeps running. The straggler
                # grace path above already tree-kills first for exactly this
                # reason; this path -- budget expiry -- did not, and it is the
                # path an adapter that overruns its own budget drives us down
                # (round-7 opus, blocker 4). Killing the child makes the
                # adapter's WaitForExit return, so Stop-Job has nothing to hang
                # on. Harmless when there is no child: it returns $false.
                $null = Stop-EraAdapterChild -PidFile $d.PidPath
                # Join BEFORE reaping (MS6): the kill unblocks the adapter, but
                # its finally (forensic snapshot + structured return carrying
                # any coded trailer) still needs a moment. Reaping first
                # discards a record that names the failure precisely and
                # synthesises a generic timeout instead. Bounded by the same
                # 20s unwind the grace path allows; on expiry fall through to
                # the synthetic below, exactly as before.
                $joined = Wait-EraJobDone -Job $d.Job -TimeoutSec 20
                $abandoned = $null
                if ($joined) {
                    try {
                        $abandoned = @(Receive-Job -Job $d.Job -ErrorAction Stop) |
                            Where-Object { $_ -is [hashtable] -or $_ -is [System.Management.Automation.PSCustomObject] } |
                            Select-Object -Last 1
                    } catch { $abandoned = $null }
                }
                Stop-Job -Job $d.Job -ErrorAction SilentlyContinue
                if ($abandoned) {
                    $results[$d.Preset] = $abandoned
                    $deadCode = Convert-EraAdapterResultError -Result $abandoned
                    if ($deadCode) { $results[$d.Preset].Error = $deadCode }
                    continue
                }
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
                # Dead-transport decode, parent-side: a coded trailer in the
                # record promotes Error to the deliberate code so recovery can
                # key on it; the free-text stays in Warnings/Stderr. Must run
                # HERE, not in the job's catch -- the job cannot see this
                # function (see Convert-EraAdapterResultError).
                $deadCode = Convert-EraAdapterResultError -Result $h
                if ($deadCode) { $results[$d.Preset].Error = $deadCode }
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
    foreach ($sk in $breakerSkipped.Keys) { $results[$sk] = $breakerSkipped[$sk] }
    return $results
}

function Get-EraBackendHealthPath {
    <#
    .SYNOPSIS
        Default machine-scoped breaker state file. Single source so the
        dispatcher and the updater cannot disagree on where streaks live.
    .DESCRIPTION
        Machine-scoped deliberately: the streaks that matter (a backend dying
        once each across three topics) never survive in per-topic round
        metadata. LOCALAPPDATA persists across reboots and processes;
        per-entry 24h expiry (on read) bounds stale outages without a janitor.
    #>
    [CmdletBinding()]
    param()
    return (Join-Path $env:LOCALAPPDATA 'era-backend-health.json')
}

function Read-EraBackendHealth {
    <#
    .SYNOPSIS
        Backend fatal-streaks, with entries older than 24h forgotten.
    .DESCRIPTION
        Fail-OPEN: missing/malformed state returns an empty map (old behavior:
        dispatch everything). Module: dispatch (file I/O lives here, never in
        recovery -- see the module-boundaries spec).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StatePath)
    $empty = @{}
    try {
        $raw = Get-Content -Raw -LiteralPath $StatePath -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch { return $empty }
    $out = @{}
    $cutoff = [datetime]::UtcNow.AddHours(-24)
    foreach ($p in $raw.PSObject.Properties) {
        try {
            $ts = [datetime]$p.Value.last_ts
            if ($ts -lt $cutoff) { continue }
            $n = [int]$p.Value.consecutive_fatals
            if ($n -le 0) { continue }
            $out[$p.Name] = @{ consecutive_fatals = $n; last_ts = $p.Value.last_ts; last_error = [string]$p.Value.last_error }
        } catch { continue }
    }
    return $out
}

function Update-EraBackendHealth {
    <#
    .SYNOPSIS
        Fold one round's results into the machine-scoped streak file.
    .DESCRIPTION
        Fatal seats (Test-EraFatalFailure) increment their backend's streak;
        anything else (success OR seat-level flakiness) resets it -- both
        prove the backend served or spoke. Best-effort write: telemetry must
        never fail a round, so all errors are swallowed after the attempt.
        Module: dispatch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Results,
        [Parameter(Mandatory)][hashtable]$Registry,
        [string]$StatePath = (Get-EraBackendHealthPath)
    )
    try {
        $health = Read-EraBackendHealth -StatePath $StatePath
        if ($null -eq $Results) { return }
        $keys = if ($Results -is [hashtable]) { @($Results.Keys) } else { @() }
        foreach ($k in $keys) {
            # Registry entries arrive as hashtables or PSCustomObjects
            # depending on the caller; read defensively either way.
            $be = $null
            if ($Registry[$k] -is [hashtable]) { $be = $Registry[$k].backend }
            elseif ($null -ne $Registry[$k] -and $Registry[$k].PSObject.Properties['backend']) { $be = $Registry[$k].backend }
            if (-not $be) { continue }
            $res = $Results[$k]
            if (Test-EraFatalFailure -Result $res) {
                $prev = 0
                if ($health.ContainsKey($be)) { $prev = [int]$health[$be].consecutive_fatals }
                $health[$be] = @{ consecutive_fatals = ($prev + 1); last_ts = ([datetime]::UtcNow.ToString('o')); last_error = [string]$res.Error }
            } else {
                if ($health.ContainsKey($be)) { $health.Remove($be) }
            }
        }
        $dir = Split-Path $StatePath -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
        }
        $health | ConvertTo-Json -Compress -Depth 4 |
            Set-Content -LiteralPath $StatePath -Encoding utf8 -ErrorAction Stop
    } catch { }
}

function Select-EraBreakerSkips {
    <#
    .SYNOPSIS
        Which requested reviewers to skip: backends on a fatal streak.
    .DESCRIPTION
        Pure selector (no file I/O; health passed in). Skips reviewers whose
        backend shows >= Threshold consecutive fatal rounds. NEVER returns all
        requested reviewers: if every backend tripped, the healthiest (lowest
        streak, ties to earliest in list) is kept -- a skipped-everything
        round would void for certainty, while dispatching the least-sick seat
        can still deliver. Callers log Detail per skipped preset.
    .OUTPUTS
        Hashtable @{ Skipped=[string[]]; Detail=[hashtable] }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReviewerList,
        [Parameter(Mandatory)][hashtable]$Registry,
        [Parameter(Mandatory)][AllowNull()][hashtable]$Health,
        [int]$Threshold = 3
    )
    $skipped = [System.Collections.Generic.List[string]]::new()
    $detail = @{}
    if ($null -eq $Health) { $Health = @{} }
    foreach ($r in $ReviewerList) {
        $be = $null
        if ($Registry[$r] -is [hashtable]) { $be = $Registry[$r].backend }
        elseif ($null -ne $Registry[$r] -and $Registry[$r].PSObject.Properties['backend']) { $be = $Registry[$r].backend }
        if (-not $be) { continue }
        if ($Health.ContainsKey($be) -and [int]$Health[$be].consecutive_fatals -ge $Threshold) {
            $skipped.Add($r)
            $detail[$r] = "backend '$be' failed fatally $([int]$Health[$be].consecutive_fatals) consecutive rounds (last: $($Health[$be].last_error))"
        }
    }
    # Never-zero: keep the healthiest tripped seat.
    if (@($ReviewerList).Count -gt 0 -and @($skipped).Count -ge @($ReviewerList).Count) {
        $best = $null; $bestStreak = [long]::MaxValue
        foreach ($r in $ReviewerList) {
            $be = $null
            if ($Registry[$r] -is [hashtable]) { $be = $Registry[$r].backend }
            elseif ($null -ne $Registry[$r] -and $Registry[$r].PSObject.Properties['backend']) { $be = $Registry[$r].backend }
            $n = if ($be -and $Health.ContainsKey($be)) { [long]$Health[$be].consecutive_fatals } else { 0 }
            if ($n -lt $bestStreak) { $bestStreak = $n; $best = $r }
        }
        if ($best -and $skipped.Contains($best)) {
            # List/Dictionary .Remove() return [bool] -- uncast output would
            # ride the return stream and turn this function's hashtable into
            # an array at the call site (measured: breaker skipped nothing and
            # crashed on Detail[$null] instead). $null both.
            $null = $skipped.Remove($best)
            $null = $detail.Remove($best)
        }
    }
    return @{ Skipped = @($skipped); Detail = $detail }
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
        [int]$RequestedCount = 0,
        # preset -> 'attach' | 'stdin' | 'inline-api' | 'disk-read'. How the
        # bundle physically reached this seat. A failed seat's delivery channel
        # is the first thing you need in order to read its failure, and it used
        # to be discoverable only by reading backend source: 'attach' means the
        # bundle was capped at 50 KiB, 'stdin' means it was inlined into the
        # prompt and could overflow the context, 'disk-read' means the model
        # opened the file itself. Optional — an omitted map just prints nothing.
        [hashtable]$DeliveryModes = @{}
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
        $via = if ($DeliveryModes.ContainsKey($preset)) { "  via=$($DeliveryModes[$preset])" } else { '' }
        $cat = Get-EraFailureCategory -Result $r -HasArtifact ([bool]$hasArtifact)
        $lines.Add(("  {0}  exit={1}{2}  [{3}]  {4}; {5}" -f $preset.PadRight($pad), $exitStr, $via, $cat, $why, $detail))
    }
    return @{ IsVoid = ($usable -eq 0); UsableCount = $usable; Lines = @($lines) }
}

