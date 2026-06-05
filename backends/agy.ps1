<#
.SYNOPSIS
    agy backend adapter for /external-review-auto. Invokes agy --print,
    captures response from session transcript (agy --print does NOT write stdout).
    Selects the model per-process via the `--model` flag (concurrent-safe).
.DESCRIPTION
    Why this file is large (almost 3× the size of geminiapi.ps1):
    The complexity is INTRINSIC to wrapping agy, not gratuitous. Specifically:

    - agy --print does NOT produce stdout -- responses must be retrieved from
      ~/.gemini/antigravity-cli/brain/<session-uuid>/.system_generated/logs/
      transcript_full.jsonl files. This forces transcript polling, heartbeat
      detection, and the run-id-match / new-session-dir / temporal-floor
      capture logic in Get-AgyTranscriptResponse.
    - Model selection is per-session via `--model "<settings_value>"` (NOT a
      settings.json swap). This makes concurrent agy dispatches safe: each
      process passes its own model token; nothing shared is mutated. The old
      settings.json swap + a cross-process settings mutex serialized every agy
      run (a 60s mutex wait that a ~80s Pro run could never satisfy) -- removed.
    - Console isolation via [Process]::Start + CreateNoWindow=$true prevents
      agy's TUI mouse-tracking escape sequences (ESC[?1003h) from polluting
      the parent terminal -- a real bug that caused user-visible "auto-typing"
      symptoms before being patched.
    - Env-var scrub in $psi.Environment prevents agy's recursion guard from
      fast-exiting when invoked from inside another agent (Claude Code,
      opencode, etc.).
    - Adaptive Tier-1/Tier-2 timeouts because transcript writes are the only
      signal we have that agy is still alive -- there's no stdout heartbeat.

    DO NOT "simplify" this file by removing the transcript polling, the
    console isolation, or the env scrub. Each was added in response to a real
    bug. If you want simplicity, use the REST geminiapi.ps1 adapter instead.

    Used by presets: gemini, gemini-pro-high, gemini-pro-low.

    `--sandbox` is OUT: empirically it hangs indefinitely under --print. We
    rely on prompt-hardening + capture correlation instead.
#>

function Get-AgyModelMap {
    $registryPath = Join-Path $PSScriptRoot '_registry.json'
    $registry = Get-Content -Raw $registryPath | ConvertFrom-Json
    $map = $registry._agy_model_map.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } }
    $result = @{}
    foreach ($item in $map) { $result[$item.Name] = $item.Value }
    return $result
}

function Find-AgyModelFromHint {
    [CmdletBinding()]
    param([string]$Hint)
    $map = Get-AgyModelMap
    $hintNorm = $Hint.ToLower() -replace '[^\w\s]', '' -replace '\s+', ' '

    $matches = @()
    foreach ($familyKey in $map.Keys) {
        $family = $map[$familyKey]
        foreach ($tierKey in $family.PSObject.Properties.Name) {
            $entry = $family.$tierKey
            $displayNorm = $entry.display.ToLower() -replace '[^\w\s]', '' -replace '\s+', ' '
            if ($displayNorm -match $hintNorm -or $hintNorm -match $displayNorm) {
                $matches += @{ Family = $familyKey; Tier = $tierKey; Display = $entry.display; Settings = $entry.settings_value; TierRank = if ($tierKey -eq 'high') { 3 } elseif ($tierKey -eq 'medium') { 2 } else { 1 } }
            }
        }
    }
    if ($matches.Count -eq 0) { return $null }
    # Prefer highest tier; if tie, prefer first added (family order)
    $best = $matches | Sort-Object TierRank -Descending | Select-Object -First 1
    return @{ Family = $best.Family; Tier = $best.Tier; Display = $best.Display; Settings = $best.Settings }
}

# Test-AgenticNarrationCapture is shared with the opencode backend (both wrap
# agentic CLIs whose models can emit a non-review and still exit 0). It lives in
# _capture-validation.ps1 so both adapters use one battle-tested detector.
. (Join-Path $PSScriptRoot '_capture-validation.ps1')

function Get-AgyTranscriptResponse {
    <#
    Capture strategies (in priority order):
      0) run-id-match (PREFERRED when -DispatchId/-BundlePath supplied) --
         build a COMBINED candidate set of new + pre-existing session
         transcripts, scan each candidate's RAW text for this dispatch's
         Run-ID GUID (the GUID lives in the USER_EXPLICIT/USER_INPUT entry,
         NOT a PLANNER_RESPONSE), and return the FIRST MODEL/PLANNER_RESPONSE
         whose line index is AFTER the USER line carrying the GUID (a reused
         session may interleave USER[A]/RESP[A]/USER[B]/RESP[B] -- "last" would
         be wrong). Secondary qualification: literal .Contains() of the bundle
         path in three forms (raw, forward-slashed, JSON-escaped). The read is
         bounded at the last ~5000 lines to avoid loading a pathologically
         large shared transcript whole. We do NOT short-circuit on
         "new dirs exist" -- under concurrency another process's new dir would
         otherwise hide our own reused-session transcript.

      Legacy fallback (when -BundlePath AND -DispatchId are both empty):
      1) new-session-dir -- find session subdirs that did NOT exist before this
         dispatch. Those were created by our spawn; their transcripts are ours.
      2) temporal-floor -- if agy reused an existing session subdir, scan recent
         transcripts and accept only PLANNER_RESPONSE entries whose JSONL
         `created_at` is >= the dispatch start.
    #>
    [CmdletBinding()]
    param(
        [string]$BrainRoot,
        [hashtable]$PreExistingSessionDirs = @{},
        [datetime]$DispatchStartUtc = [datetime]::MinValue,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 2,
        # Fix 2: optional Run-ID correlation. When both are empty the function
        # falls back to the legacy recency/temporal heuristic so existing tests
        # and legacy callers still pass.
        [string]$BundlePath,
        [string]$DispatchId
    )

    $useRunId = [bool]$DispatchId -or [bool]$BundlePath

    # Precompute the literal path forms used for secondary correlation.
    $pathForms = @()
    if ($BundlePath) {
        $pathForms += $BundlePath
        $pathForms += ($BundlePath -replace '\\','/')
        $pathForms += $BundlePath.Replace('\','\\')
        $pathForms = $pathForms | Select-Object -Unique
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds $DelaySeconds }

        # New session transcripts (created since dispatch start).
        $newSessionTranscripts = Get-ChildItem -Path $BrainRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { -not $PreExistingSessionDirs.ContainsKey($_.FullName) } |
            ForEach-Object {
                # Capture ONLY from transcript_full.jsonl. agy also writes a
                # token-TRUNCATED transcript.jsonl in the same dir; including it made
                # capture depend on Sort-Object collation luck (it happens to sort
                # AFTER transcript_full under the default culture, but an ordinal sort
                # would pick the truncated copy and silently lose review text on large
                # responses). transcript_full.jsonl is always present and authoritative
                # -- and the existing-session path already scans only it.
                Get-ChildItem -Path (Join-Path $_.FullName '.system_generated/logs/transcript_full.jsonl') -ErrorAction SilentlyContinue
            } |
            Where-Object { $_ } |
            Sort-Object LastWriteTime -Descending

        # Pre-existing session transcripts (top-5 by recency).
        $existingSessionTranscripts = Get-ChildItem -Path (Join-Path $BrainRoot '*/.system_generated/logs/transcript_full.jsonl') -ErrorAction SilentlyContinue |
            Where-Object { $PreExistingSessionDirs.ContainsKey((Split-Path (Split-Path (Split-Path $_.FullName -Parent) -Parent) -Parent)) } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 5

        if ($useRunId) {
            # --- Strategy 0: Run-ID match over the COMBINED candidate set. ---
            # No short-circuit: a concurrent process's new dir must not hide our
            # own reused-session transcript.
            $combined = @()
            if ($newSessionTranscripts)     { $combined += @($newSessionTranscripts) }
            if ($existingSessionTranscripts){ $combined += @($existingSessionTranscripts) }
            $combined = $combined | Where-Object { $_ } | Sort-Object FullName -Unique

            # Extract the FIRST MODEL/PLANNER_RESPONSE after a matched USER line
            # (and before the next USER entry). Returns $null if no answer found.
            $extractAfter = {
                param($lns, $startIdx, $transcriptPath)
                for ($j = $startIdx + 1; $j -lt $lns.Count; $j++) {
                    try { $entry = $lns[$j] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                    # Stop at the next USER entry -- the answer must precede it.
                    if ($entry.source -like 'USER*' -or $entry.type -eq 'USER_INPUT') { break }
                    if ($entry.source -ne 'MODEL' -or $entry.type -ne 'PLANNER_RESPONSE' -or -not $entry.content) { continue }
                    $text = if ($entry.content -is [string]) {
                        $entry.content
                    } elseif ($entry.content.PSObject.Properties.Name -contains 'text') {
                        [string]$entry.content.text
                    } else {
                        $entry.content | ConvertTo-Json -Compress
                    }
                    return @{
                        Response       = $text
                        TranscriptPath = $transcriptPath
                        FromFallback   = $false
                        Strategy       = 'run-id-match'
                    }
                }
                return $null
            }

            # Pass 1 (PRIMARY): the GUID is collision-proof. Match it across ALL
            # candidates before considering the (weaker) path-form fallback, so a
            # sibling dispatch sharing the same bundle path can't win on path alone.
            if ($DispatchId) {
                foreach ($c in $combined) {
                    $lines = @(Get-Content $c.FullName -Tail 5000 -ErrorAction SilentlyContinue)
                    if (-not $lines) { continue }
                    for ($i = 0; $i -lt $lines.Count; $i++) {
                        if ($lines[$i].Contains($DispatchId)) {
                            $r = & $extractAfter $lines $i $c.FullName
                            if ($r) { return $r }
                            break
                        }
                    }
                }
            }

            # Pass 2 (FALLBACK): literal bundle-path forms, only when the GUID was
            # never echoed in any candidate. The anchor line MUST be a USER entry:
            # in a reused session an earlier dispatch's MODEL/PLANNER_RESPONSE can
            # itself quote the same bundle path, so a raw substring scan could latch
            # onto that stale MODEL line and return a wrong/old answer. Requiring
            # source -like 'USER*' ensures we anchor on the prompt that referenced
            # the bundle, then return the first PLANNER_RESPONSE after it.
            if ($pathForms.Count -gt 0) {
                foreach ($c in $combined) {
                    $lines = @(Get-Content $c.FullName -Tail 5000 -ErrorAction SilentlyContinue)
                    if (-not $lines) { continue }
                    for ($i = 0; $i -lt $lines.Count; $i++) {
                        $hit = $false
                        foreach ($pf in $pathForms) { if ($lines[$i].Contains($pf)) { $hit = $true; break } }
                        if (-not $hit) { continue }
                        # Confirm this line is a USER entry before treating it as the
                        # anchor. Skip non-USER lines (e.g. a stale MODEL response that
                        # merely quotes the same path) and unparseable lines.
                        try { $anchor = $lines[$i] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                        if ($anchor.source -notlike 'USER*' -and $anchor.type -ne 'USER_INPUT') { continue }
                        $r = & $extractAfter $lines $i $c.FullName
                        if ($r) { return $r }
                        break
                    }
                }
            }
            # No Run-ID/path match this attempt -- retry (transcript may still be
            # flushing). Do NOT fall back to recency here; a wrong recency match
            # under concurrency is worse than another poll.
            continue
        }

        # --- Legacy fallback (no Run-ID params): original heuristic. ---
        $existingForLegacy = @()
        if (-not $newSessionTranscripts) { $existingForLegacy = $existingSessionTranscripts }
        $candidates = if ($newSessionTranscripts) { $newSessionTranscripts } else { $existingForLegacy }
        $isStrategy2 = -not $newSessionTranscripts -and $existingForLegacy

        foreach ($c in $candidates) {
            $lines = @(Get-Content $c.FullName -Tail 200 -ErrorAction SilentlyContinue)
            if (-not $lines) { continue }
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                try {
                    $entry = $lines[$i] | ConvertFrom-Json -ErrorAction Stop
                    if ($entry.source -ne 'MODEL' -or $entry.type -ne 'PLANNER_RESPONSE' -or -not $entry.content) { continue }

                    if ($isStrategy2) {
                        $entryTimeRaw = if ($entry.created_at) { $entry.created_at }
                                        elseif ($entry.timestamp) { $entry.timestamp }
                                        else { $null }
                        if ($entryTimeRaw) {
                            try {
                                $entryTime = if ($entryTimeRaw -is [datetime]) {
                                    $entryTimeRaw.ToUniversalTime()
                                } else {
                                    [DateTime]::Parse([string]$entryTimeRaw, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
                                }
                                if ($entryTime -lt $DispatchStartUtc) { continue }
                            } catch { } # unparseable -> accept (lenient)
                        }
                    }

                    $text = if ($entry.content -is [string]) {
                        $entry.content
                    } elseif ($entry.content.PSObject.Properties.Name -contains 'text') {
                        [string]$entry.content.text
                    } else {
                        $entry.content | ConvertTo-Json -Compress
                    }
                    return @{
                        Response       = $text
                        TranscriptPath = $c.FullName
                        FromFallback   = [bool]$isStrategy2
                        Strategy       = if ($isStrategy2) { 'temporal-floor' } else { 'new-session-dir' }
                    }
                } catch { continue }
            }
        }
    }
    return @{ Response = $null; TranscriptPath = $null; FromFallback = $false; Strategy = $null }
}

function _SpawnAndCaptureOnce {
    <#
    Spawn agy --print ONCE, poll the transcript for liveness, and capture the
    response. Returns @{ Response; ExitCode; Strategy; Stderr; WallClockSec }.
    NO disk write -- the caller decides what (if anything) reaches $ResponsePath.
    Each call takes its OWN fresh deadline / brain-dir snapshot / Run-ID, so a
    retry loop can call this repeatedly without double-setting deadlines or
    re-using a stale snapshot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)][hashtable]$ModelInfo,
        [int]$TimeoutSec = 600,
        [string]$ResolvedModelToken
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $errFile  = [System.IO.Path]::GetTempFileName()
    $stdFile  = [System.IO.Path]::GetTempFileName()
    $brainRoot = Join-Path $HOME '.gemini/antigravity-cli/brain'

    # Per-dispatch Run ID, prefixed (leading) so it survives mid-prompt
    # truncation. agy echoes it verbatim into the USER_EXPLICIT/USER_INPUT
    # transcript entry (probe-confirmed), enabling concurrent-safe capture.
    $dispatchId = [guid]::NewGuid().ToString()
    # Tool-forbidding prompt hardening (Fix 3 "prevent"): agy is an agentic agent;
    # telling it to "review the code at <path>" invited it to open/run files and
    # emit tool-intent narration instead of a review. Forbid all tool use and the
    # bundle (with its embedded review instructions) is the only thing to review.
    $prompt = "[Run ID: $dispatchId] All files are in the attached bundle at $BundlePath. Do NOT open, read, fetch, list, or run anything. Review ONLY the bundle content and output the review directly. (Citing file:line locations in your findings is fine.)"

    # Snapshot brain session directories that exist BEFORE we spawn.
    $preExistingSessionDirs = @{}
    if (Test-Path $brainRoot) {
        Get-ChildItem $brainRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $preExistingSessionDirs[$_.FullName] = $true }
    }
    $dispatchStartUtc = [datetime]::UtcNow

    # Launch agy with its OWN private console (NOT inherited). agy is a TUI
    # binary; even in --print mode it sends mouse-tracking enable sequences and
    # may use WriteConsoleW. ProcessStartInfo + CreateNoWindow=$true +
    # UseShellExecute=$false give it a hidden console so that pollution is
    # contained. Stdin is closed directly via $agyProc.StandardInput.Close().
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    # Resolve actual executable: ProcessStartInfo with UseShellExecute=$false
    # doesn't search PATHEXT. If agy resolves via a .ps1 wrapper, use .cmd instead.
    $agyCli = Get-Command agy -ErrorAction Stop
    $agyExe = if ($agyCli.Source -match '\.ps1$') {
        $cmdPath = $agyCli.Source -replace '\.ps1$', '.cmd'
        if (-not (Test-Path $cmdPath)) { throw "agy.cmd not found at $cmdPath" }
        $cmdPath
    } else { $agyCli.Source }
    $psi.FileName = $agyExe
    $psi.ArgumentList.Add('--dangerously-skip-permissions')
    # Per-session model selection via --model (concurrent-safe; replaces the
    # settings.json swap). NEVER read settings.json for the model.
    if ($ResolvedModelToken) {
        $psi.ArgumentList.Add('--model')
        $psi.ArgumentList.Add($ResolvedModelToken)
    }
    # Belt-and-suspenders backstop so agy self-terminates near our deadline.
    $psi.ArgumentList.Add('--print-timeout')
    $psi.ArgumentList.Add("${TimeoutSec}s")
    $psi.ArgumentList.Add('--print')
    $psi.ArgumentList.Add($prompt)
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true   # private hidden console -- does NOT share with parent
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    # Scrub agent-context env vars from the CHILD's env block. ProcessStartInfo.Environment
    # is a copy of the parent's env that only the child sees, so this doesn't affect
    # other ThreadJobs running concurrently in the same pwsh process. Agent CLIs have
    # recursion guards that fast-exit when they detect they're running inside another
    # agent. Stripping these vars prevents that.
    foreach ($var in @('CLAUDECODE','CLAUDE_CODE_ENTRYPOINT','CLAUDE_CODE_SESSION_ID',
                       'CLAUDE_CODE_GIT_BASH_PATH','AI_AGENT','ANTIGRAVITY_AGENT',
                       'ANTIGRAVITY_SOURCE_METADATA','OPENCODE_YOLO')) {
        if ($psi.Environment.ContainsKey($var)) { $null = $psi.Environment.Remove($var) }
    }

    $agyProc = [System.Diagnostics.Process]::Start($psi)
    # Close stdin immediately so agy reads EOF, can't block on input
    $agyProc.StandardInput.Close()
    # Async-drain stdout/stderr to temp files so the OS buffers never fill.
    # FileShare.ReadWrite (NOT the File.Create default of None) so the inline
    # Tier-1 stderr read can open $errFile while this async copy still holds it.
    # With the default share, that Get-Content fails (caught silently) and the
    # diagnostic is lost regardless of the flush.
    $stdoutSink = [System.IO.File]::Open($stdFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $stderrSink = [System.IO.File]::Open($errFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $stdoutTask = $agyProc.StandardOutput.BaseStream.CopyToAsync($stdoutSink)
    $stderrTask = $agyProc.StandardError.BaseStream.CopyToAsync($stderrSink)

    $response        = $null
    $exitCode        = 0
    $activitySeen    = $false
    $lastActivityTime = [DateTime]::UtcNow
    $lastSeenMtime   = $null

    # Adaptive stall tuning (Fix 7). The adapter receives $TimeoutSec
    # (already bundle-scaled by the dispatcher), NOT $BundleTokens. Scale the
    # stall window off it, with a per-tier floor: Pro median wall is ~80s, so a
    # fixed 90s floor killed Pro runs that paused mid-think.
    $proStallSec   = 180
    $flashStallSec = 90
    $family = "$($ModelInfo.agy_model_family)"
    $tierFloor = if ($family -match 'pro') { $proStallSec } else { $flashStallSec }
    $stallSec         = [Math]::Max($tierFloor, [int]($TimeoutSec * 0.25))
    $firstActivitySec = $stallSec
    # Fix 7 REAL BUG: removed the prior 6-minute hard clamp that killed every
    # agy run at 360s regardless of the bundle-scaled $TimeoutSec. The deadline
    # now tracks $TimeoutSec directly.
    $hardDeadline     = [DateTime]::UtcNow.AddSeconds($TimeoutSec - 5)

    try {
        while (-not $agyProc.HasExited -and [DateTime]::UtcNow -lt $hardDeadline) {
            Start-Sleep -Seconds 2

            # Check transcript directory for any file whose mtime advanced
            $latestFile = Get-ChildItem -Path (Join-Path $brainRoot '*/.system_generated/logs/transcript*.jsonl') `
                -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestFile) {
                $mtime = $latestFile.LastWriteTime.ToString('O')
                if ($mtime -ne $lastSeenMtime) {
                    $activitySeen     = $true
                    $lastActivityTime = [DateTime]::UtcNow
                    $lastSeenMtime    = $mtime
                }
            }

            $idleSec = ([DateTime]::UtcNow - $lastActivityTime).TotalSeconds

            # Tier 1: no transcript activity at all within firstActivitySec
            if (-not $activitySeen -and $idleSec -gt $firstActivitySec) {
                # Kill($true): tear down the WHOLE tree. $agyProc is the agy.cmd
                # wrapper; a bare Kill() leaves its node.exe child orphaned.
                $agyProc.Kill($true)
                # Drain + flush the async stderr copy BEFORE reading $errFile, else a
                # short error from a fast crash is still buffered in the un-flushed
                # stream and we throw an unhelpful "stderr: " (round-5 I5.1). After
                # Kill the pipe hits EOF so CopyToAsync completes promptly.
                try { $null = $stderrTask.Wait(1000) } catch {}
                try { $stderrSink.Flush() } catch {}
                $stderr = Get-Content -Raw $errFile -ErrorAction SilentlyContinue
                throw "agy showed no transcript activity within ${firstActivitySec}s -- likely failed to start (bad auth, wrong model, or crash). stderr: $stderr"
            }

            # Tier 2: activity previously seen but transcript went stale
            if ($activitySeen -and $idleSec -gt $stallSec) {
                # Kill($true): tear down the WHOLE tree (see Tier-1 note above).
                $agyProc.Kill($true)
                throw "agy stalled -- no transcript activity for ${stallSec}s after initial response began."
            }
        }
    } finally {
        $null = $agyProc.WaitForExit(5000)
        # Defensive tree-kill on the NON-stall exit path (round-6 leak fix). The
        # Tier-1/Tier-2 branches already Kill($true), but the loop can also exit
        # naturally at $hardDeadline; if agy's own --print-timeout fails to
        # self-terminate, WaitForExit returns with the process still alive and the
        # agy.cmd/node.exe tree would be orphaned. Tear it down here too.
        if (-not $agyProc.HasExited) {
            try { $agyProc.Kill($true) } catch {}
            $null = $agyProc.WaitForExit(2000)
        }
        $exitCode = if ($agyProc.HasExited) { $agyProc.ExitCode } else { -1 }
        try { $null = $stdoutTask.Wait(2000) } catch {}
        try { $null = $stderrTask.Wait(2000) } catch {}
        try { $stdoutSink.Dispose() } catch {}
        try { $stderrSink.Dispose() } catch {}
        $stderrSnapshot = ''
        try {
            $rawErr = Get-Content -Raw $errFile -ErrorAction SilentlyContinue
            if ($rawErr) {
                $stderrSnapshot = $rawErr.Substring([math]::Max(0, $rawErr.Length - 600))
            }
        } catch {}
        Remove-Item $stdFile   -ErrorAction SilentlyContinue
        Remove-Item $errFile   -ErrorAction SilentlyContinue
    }

    # Transcript scan correlated by this dispatch's Run ID.
    $strategy = $null
    $fb = Get-AgyTranscriptResponse -BrainRoot $brainRoot `
        -PreExistingSessionDirs $preExistingSessionDirs `
        -DispatchStartUtc $dispatchStartUtc `
        -BundlePath $BundlePath -DispatchId $dispatchId `
        -MaxAttempts 3 -DelaySeconds 2
    if ($fb.Response) { $response = $fb.Response; $strategy = $fb.Strategy }

    $sw.Stop()
    return @{
        Response     = $response
        ExitCode     = $exitCode
        Strategy     = $strategy
        Stderr       = if ($stderrSnapshot) { $stderrSnapshot } else { '' }
        WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

function Invoke-AgyReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)][string]$ResponsePath,
        [Parameter(Mandatory)][hashtable]$ModelInfo,
        [int]$TimeoutSec = 600,
        [string]$AgyModelHint,
        [string]$ModelOverride,
        # Default settings_value resolved by era.ps1 from the preset's
        # agy_model_family/agy_model_tier. Used verbatim for --model when no
        # hint resolves a token. We NEVER read settings.json for the model.
        [string]$ResolvedAgyModel,
        # Accepted-and-ignored: the dispatcher ScriptBlock passes -OpencodeProvider
        # to EVERY adapter uniformly. agy has no use for it.
        [string]$OpencodeProvider
    )

    # --- Per-session model selection (no settings.json swap, no mutex). ---
    $resolvedToken = $null
    $effectiveHint = if ($AgyModelHint) { $AgyModelHint } else { $ModelOverride }
    if ($effectiveHint) {
        $resolved = Find-AgyModelFromHint -Hint $effectiveHint
        if ($resolved) {
            $resolvedToken = $resolved.Settings
            Write-Host "[agy] Selecting $($resolved.Display) (hint: '$effectiveHint') via --model"
        } else {
            Write-Host "[agy] WARNING: Model hint '$effectiveHint' did not resolve to a known model."
        }
    }
    if (-not $resolvedToken -and $ResolvedAgyModel) {
        $resolvedToken = $ResolvedAgyModel
        Write-Host "[agy] Using default model '$ResolvedAgyModel' via --model"
    }

    # --- Cost model for the retry cap (Fix 3 / R4-Opus-I4 + R3-Opus-I5). ---
    # The adapter doesn't receive $BundleTokens, so estimate input tokens from the
    # bundle file size (~4 chars/token, the same ratio used for output) and price
    # both with the preset's registry pricing. This lets us (a) skip the retry if
    # replaying the bundle would breach the aggregate cap and (b) record the
    # discarded first attempt's spend honestly so cap-accounting isn't understated.
    $inPerM  = if ($ModelInfo.pricing -and $ModelInfo.pricing.input_per_m)  { [double]$ModelInfo.pricing.input_per_m }  else { 0.0 }
    $outPerM = if ($ModelInfo.pricing -and $ModelInfo.pricing.output_per_m) { [double]$ModelInfo.pricing.output_per_m } else { 0.0 }
    # R3: gate the retry on THIS reviewer's REAL per-reviewer cap, mirroring
    # workflow.ps1's Get-PerReviewerCap ($2 cheap / $10 expensive), NOT a
    # hardcoded $15 that for a single agy reviewer would require millions of input
    # tokens per attempt to ever fire -- i.e. dead code. (The adapter can't call
    # Get-PerReviewerCap: it dot-sources only itself, so the threshold is inlined.)
    $perReviewerCap = if ($inPerM -ge 10.0) { 10.0 } else { 2.0 }
    $bundleChars = if (Test-Path $BundlePath) { (Get-Item $BundlePath).Length } else { 0 }
    $estInputTokens = [int][Math]::Ceiling($bundleChars / 4)
    $costFor = {
        param($inTok, $outTok)
        [Math]::Round(($inTok / 1000000.0) * $inPerM + ($outTok / 1000000.0) * $outPerM, 4)
    }

    # Each attempt's hard-deadline is capped to HALF the dispatcher budget so two
    # attempts fit inside $TimeoutSec (the dispatcher's Wait-Job is TimeoutSec+30
    # and would otherwise kill a retry mid-write). Floor at a sane minimum.
    $perAttemptTimeoutSec = [Math]::Max(30, [int]($TimeoutSec / 2))

    # --- Retry loop (≤2 attempts) INSIDE the adapter, pre-write (Fix 3). ---
    $maxAttempts   = 2
    $finalResult   = $null   # the _SpawnAndCaptureOnce result we will write
    $retryCount    = 0
    $retryReason   = $null
    $contentOk     = $false
    $firstAttempt  = $null   # preserved discarded-first-attempt audit sub-object;
                             # carries the discarded spend via est_cost_total_usd,
                             # which Write-ReviewMetadata folds into the round total.

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        # R7: _SpawnAndCaptureOnce THROWS on a Tier-1/Tier-2 stall or timeout
        # (agy.ps1 Kill+throw). Catch it here so a stall/timeout is treated as a
        # retryable BAD attempt instead of propagating out of the loop -- the old
        # un-caught call meant the single retry healed empty/narration captures but
        # NOT stalls/timeouts, which are the most common historical failures.
        $threwError = $null
        try {
            $result = _SpawnAndCaptureOnce -BundlePath $BundlePath -PromptPath $PromptPath `
                -ModelInfo $ModelInfo -TimeoutSec $perAttemptTimeoutSec -ResolvedModelToken $resolvedToken
        } catch {
            $threwError = $_.Exception.Message
            $result = @{ Response = $null; ExitCode = -1; Strategy = $null; Stderr = $threwError; WallClockSec = 0 }
        }

        $resp = $result.Response
        # A bad capture = a thrown stall/timeout, no response at all, OR a captured
        # agentic narration.
        $isBad = [bool]$threwError -or (-not $resp) -or (Test-AgenticNarrationCapture -Response $resp)
        # Label the cause precisely: stall/timeout vs empty vs narration.
        $reason = if ($threwError) { 'stall-or-timeout' }
                  elseif (-not $resp) { 'empty-capture' }
                  else { 'agentic-narration-capture' }

        if (-not $isBad) {
            # Clean capture -- use it.
            $finalResult = $result
            $contentOk   = $true
            break
        }

        # Bad capture. If attempts remain, decide whether to retry.
        if ($attempt -lt $maxAttempts) {
            # Honest cost-cap guard: a retry replays the full bundle input the
            # user already approved 1x for. Skip it (fail honestly) if the first
            # attempt's spend plus a projected retry would breach the cap.
            $firstOutTok  = if ($resp) { [int][Math]::Ceiling($resp.Length / 4) } else { 0 }
            $firstCost    = & $costFor $estInputTokens $firstOutTok
            # Project the retry as another full-bundle input + a same-size output.
            # NOTE: this intentionally reuses the bad attempt's tiny output-token
            # count as the retry's output estimate (an input-dominated projection).
            # It under-projects retry output, which is acceptable because input
            # dominates the cost for large bundles at the per-reviewer cap.
            $projRetryCost = & $costFor $estInputTokens $firstOutTok
            # Preserve the discarded first attempt for the audit trail (built once
            # for both the cap-skip and proceed branches). Its est_cost_total_usd is
            # folded into the round total by Write-ReviewMetadata so retry/cap-skip
            # spend isn't hidden.
            $firstAttempt = @{
                strategy           = $result.Strategy
                chars              = if ($resp) { $resp.Length } else { 0 }
                input_tokens       = $estInputTokens
                output_tokens      = $firstOutTok
                est_cost_total_usd = $firstCost
            }
            if (($firstCost + $projRetryCost) -gt $perReviewerCap) {
                Write-Host "[agy] Skipping retry: replay would breach this reviewer's cap (`$$([Math]::Round($firstCost + $projRetryCost,2)) > `$$perReviewerCap)."
                # Cap-skip still spent attempt-1's ~full-bundle input; $firstAttempt
                # (above) carries that spend so cap-accounting stays honest.
                $finalResult = $result
                $retryReason = $reason
                $contentOk   = $false
                break
            }

            $retryCount  = 1
            $retryReason = $reason
            Write-Host "[agy] Captured bad output ($reason) on attempt $attempt; retrying once with the same model + hardened prompt."
            continue
        }

        # Final attempt also bad -> honest failure.
        $finalResult = $result
        $contentOk   = $false
        $retryReason = $reason
    }

    $response = $finalResult.Response
    $exitCode = $finalResult.ExitCode
    $stderr   = $finalResult.Stderr

    # If the final state is a bad/agentic capture, return an honest failure
    # (ExitCode=-1) so the dispatcher records content_ok=false and does not
    # consume the garbage. We still write nothing meaningful to disk in that case.
    if (-not $contentOk) {
        # Error reflects the actual cause (empty-capture vs narration), defaulting
        # to narration if no reason was set.
        $failReason = if ($retryReason) { $retryReason } else { 'agentic-narration-capture' }
        $failWarning = switch ($failReason) {
            'empty-capture'    { 'Captured an empty response (no review found in transcript); retry exhausted or skipped.' }
            'stall-or-timeout' { 'agy stalled or timed out on every attempt (no usable transcript captured); retry exhausted or skipped.' }
            default            { 'Captured agentic-loop narration instead of a review (detector fired); retry exhausted or skipped.' }
        }
        return @{
            Response          = $response
            ExitCode          = -1
            Error             = $failReason
            CaptureMethod     = 'polling'
            CaptureStrategy   = $finalResult.Strategy
            ContentOk         = $false
            RetryCount        = $retryCount
            RetryReason       = $retryReason
            FirstAttempt      = $firstAttempt
            InputTokens       = $estInputTokens
            OutputTokens      = if ($response) { [Math]::Ceiling($response.Length / 4) } else { 0 }
            WallClockSec      = $finalResult.WallClockSec
            TruncationWarning = $null
            Stderr            = $stderr
            Warnings          = @($failWarning)
        }
    }

    # Truncation detection
    $truncationWarning = $null
    $tailWindow = if ($response.Length -gt 500) {
        $response.Substring($response.Length - 500)
    } else { $response }
    if ($tailWindow -match '<truncated (\d+) bytes>') {
        $truncBytes = [int]$matches[1]
        $truncationWarning = "<truncated $truncBytes bytes>"
        $banner = @"
> [!WARNING]
> **agy/model truncated the response -- $truncBytes bytes lost mid-content.**
> The text below is incomplete. Re-run with a tighter prompt or a model with a higher output budget.

"@
        $response = $banner + $response
    }

    # Only the FINAL (clean) attempt's text reaches disk.
    $response | Set-Content -Path $ResponsePath -Encoding utf8

    return @{
        Response          = $response
        ExitCode          = $exitCode
        CaptureMethod     = 'polling'
        CaptureStrategy   = $finalResult.Strategy
        ContentOk         = $true
        RetryCount        = $retryCount
        RetryReason       = $retryReason
        FirstAttempt      = $firstAttempt
        InputTokens       = $estInputTokens
        OutputTokens      = [Math]::Ceiling($response.Length / 4)
        WallClockSec      = $finalResult.WallClockSec
        TruncationWarning = $truncationWarning
        Stderr            = $stderr
        Warnings          = @()
    }
}
