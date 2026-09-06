<#
.SYNOPSIS
    tmux TUI transport backend. Runs a seat's INTERACTIVE CLI in a detached tmux
    window and collects the review as a FILE the model writes itself.

.DESCRIPTION
    Design and evidence: docs/specs/2026-09-06-tmux-tui-transport-design.md.
    Spike results: docs/assessments/2026-09-06-tmux-spike-c5-c7.md.

    NOTHING IS SCRAPED FROM THE PANE. The model has file-write tools, so the
    prompt ends with "write your review to review.md" and collection is a file
    read: no ANSI, no spinners, no turn-boundary parsing. Everything taken from
    tmux is structured window metadata. If any line here calls `capture-pane`,
    that line is wrong.

    THE MEASUREMENTS THIS FILE IS BUILT ON (all 2026-09-06, this box):

      * A window's row VANISHES when its command exits, so absence is death --
        but the tmux server also exits with its last window, and then reads
        IDENTICALLY to "tmux is unreachable". A watchdog window that outlives
        every seat is what keeps those two apart.
      * `#{pane_current_command}` follows any FOREGROUND CHILD: a seat running a
        `bash` tool reports `sleep`/`bash`, not `opencode`. It is used only to
        confirm a launch, never to declare death.
      * `new-window` exits 0 for a NONEXISTENT BINARY, so launch success is not a
        return code. It is the window row appearing.
      * The argv ceiling is between 12,288 and 16,384 bytes while a round prompt
        may reach 80,000 ({{PREVIOUS_ROUND}}), so the prompt is STAGED ON DISK
        and the argv carries a fixed ~60-byte pointer.
      * A prompt containing newlines, quotes, $( ), backticks, `;`, `&&` and `|`
        survives byte-identically as SEPARATE ARGV ELEMENTS, with no injection.
        A shell string anywhere in this chain reintroduces that hazard.
      * A thinking TUI is NEVER quiet -- `#{window_activity}` advanced on every
        5s sample across a whole attempt -- so there is deliberately no stall
        rule here. `$TimeoutSec` is the backstop.
      * A TUI does NOT exit when its turn ends; it sits at a prompt. Without the
        turn-end hook below, a seat that finishes without writing the canary
        would idle to `$TimeoutSec`.

    ISOLATION. The seat's cwd is a fresh per-attempt scratch directory holding
    exactly bundle.xml, instructions.md and (later) review.md -- no repository.
    That is mitigation, not a sandbox: the seat runs with permission bypass and
    could still read the repo by absolute path, and `seat_containment` sees
    writes only. What it removes is any *reason or handle* to: prior rounds,
    peers' in-flight files, and the git index are simply not in its world.
#>

. (Join-Path $PSScriptRoot '_capture-validation.ps1')

$script:EraTmuxDistro = $null

function Get-EraTmuxDistro {
    <#
    .SYNOPSIS
        The WSL distro every tmux call in this attempt will address.

    .DESCRIPTION
        Resolved ONCE and reused. The four tmux calls must all reach the same
        server; letting each inherit "whatever the default distro is right now"
        is how they could silently address different ones.
    #>
    if ($script:EraTmuxDistro) { return $script:EraTmuxDistro }
    try {
        $raw = & wsl.exe -l -q 2>$null
        $first = @($raw | ForEach-Object { ($_ -replace "`0", '').Trim() } |
                   Where-Object { $_ }) | Select-Object -First 1
        if ($first) { $script:EraTmuxDistro = $first }
    } catch { $script:EraTmuxDistro = $null }
    return $script:EraTmuxDistro
}

function Invoke-EraTmuxCli {
    <#
    .SYNOPSIS
        Run one tmux command inside WSL. Returns @{ Rc; Out; Err }.

    .DESCRIPTION
        ARGUMENTS ARE PASSED AS SEPARATE ELEMENTS, never joined into a shell
        string -- that is the property measured to be injection-safe, and it is
        the only reason prompt content can be handed to tmux at all.

        Agent env vars are scrubbed per-child, `TMUX`/`TMUX_PANE` among them: a
        seat that inherited the driving session's pane identity would have its
        hooks write into the OPERATOR's window.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$TmuxArgs)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'wsl.exe'
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $distro = Get-EraTmuxDistro
    if ($distro) { $psi.ArgumentList.Add('-d'); $psi.ArgumentList.Add($distro) }
    $psi.ArgumentList.Add('--')
    foreach ($t in $TmuxArgs) { $psi.ArgumentList.Add($t) }

    foreach ($v in @('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SESSION_ID',
                     'CLAUDE_CODE_GIT_BASH_PATH', 'AI_AGENT', 'ANTIGRAVITY_AGENT',
                     'ANTIGRAVITY_SOURCE_METADATA', 'OPENCODE_YOLO',
                     'TMUX', 'TMUX_PANE')) {
        $null = $psi.Environment.Remove($v)
    }

    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $null = $p.WaitForExit(30000)
    return @{ Rc = $p.ExitCode; Out = $out; Err = $err }
}

function ConvertTo-EraWslPath {
    <#
    .SYNOPSIS
        A Windows path as WSL sees it. The ONLY path translation in this backend.

    .DESCRIPTION
        Everything the model is told is a bare filename in its own cwd, so no
        Windows path and no repo path ever reaches the prompt. era translates the
        scratch directory once, here, and nothing else.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WindowsPath)
    $r = Invoke-EraTmuxCli -TmuxArgs @('wslpath', '-u', $WindowsPath)
    if ($r.Rc -ne 0 -or -not $r.Out.Trim()) {
        throw "wslpath could not translate '$WindowsPath' (rc=$($r.Rc)): $($r.Err.Trim())"
    }
    return $r.Out.Trim()
}

function Get-EraTmuxWindowNames {
    <#
    .SYNOPSIS
        Window names on era's server, plus whether the server answered at all.

    .DESCRIPTION
        The distinction is the whole point. `ServerUp=$false` means tmux could
        not be reached and is NEVER a verdict about a seat -- era has three
        recorded fail-open catches where a read failure became indistinguishable
        from a real measurement, and this is the same shape.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Socket, [Parameter(Mandatory)][string]$Session)
    $r = Invoke-EraTmuxCli -TmuxArgs @('tmux', '-L', $Socket, 'list-windows', '-t', $Session,
                                       '-F', '#{window_name}')
    if ($r.Rc -ne 0) { return @{ ServerUp = $false; Names = @() } }
    $names = @($r.Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return @{ ServerUp = $true; Names = $names }
}

function Get-EraTmuxSeatPrompt {
    <#
    .SYNOPSIS
        era's round prompt plus the envelope that makes collection a file read.

    .DESCRIPTION
        `ERA-BUNDLE-TAIL` asks for the LAST FILE PATH IN THE CONTENT, not the
        bundle's line count. An earlier draft asked for the count and was
        VACUOUS: the seat has a shell, so it would run `wc -l` and report the
        true number however little it had actually read. A tail can only be
        answered by a read that reached the tail.

        The canary is a completion CONTRACT -- "write it only when final" -- not
        a race to win. Whether models honour it is measured, not assumed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PromptPath, [Parameter(Mandatory)][string]$Nonce)

    $prompt = Get-Content -Raw -LiteralPath $PromptPath
    $envelope = @"

---
The review bundle is the file bundle.xml in your current directory.
Write your complete review to the file review.md in your current directory.
Do not read, write, or create any other file.
State, as the FIRST line of review.md, the last file path listed in bundle.xml,
copied exactly as it appears there:
ERA-BUNDLE-TAIL: <path>
Write the LAST line only when the review is final, and do not edit the file
afterwards. That last line must be exactly, alone on the line:
ERA-CANARY-$Nonce
"@
    return ($prompt.TrimEnd() + $envelope)
}

function Invoke-TmuxReview {
    <#
    .SYNOPSIS
        Dispatch one seat over the tmux TUI transport. era's standard adapter
        contract in, era's standard result hashtable out.

    .DESCRIPTION
        -PidFile is DELIBERATELY NOT DECLARED. `new-window -d` returns as soon as
        the window exists, so the `wsl.exe` era launched is gone within
        milliseconds; a pid written there would be dead for the whole attempt,
        and `Stop-EraAdapterChild` would either no-op or, after pid reuse, kill
        an unrelated process. workflow.ps1 passes -PidFile only to adapters that
        declare it, so omitting it is supported. Teardown is this function's
        job, and the watchdog is the backstop if era itself dies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)][string]$ResponsePath,
        [Parameter(Mandatory)]$ModelInfo,
        [int]$TimeoutSec = 700,
        [AllowNull()][string]$AgyModelHint,
        [AllowNull()][string]$ModelOverride,
        [AllowNull()][string]$OpencodeProvider
    )

    $sw       = [System.Diagnostics.Stopwatch]::StartNew()
    $warnings = @()
    $modelId  = if ($ModelOverride) { $ModelOverride } else { $ModelInfo.model_id }

    $launch = $ModelInfo.tmux_launch
    if (-not $launch) {
        throw "preset '$($ModelInfo.preset)' has no tmux_launch in backends/_registry.json, so it cannot be carried over the tmux transport."
    }

    $nonce   = ([guid]::NewGuid().ToString('N').Substring(0, 16))
    $socket  = "era-$PID"
    $session = 'era'
    $seat    = if ($ModelInfo.preset) { $ModelInfo.preset } else { 'seat' }
    $window  = "era-$seat-$nonce"
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) "era-tmux-$PID-$nonce"

    # A watchdog deadline generous enough that it never pre-empts $TimeoutSec,
    # and short enough that an era crash cannot leave an unattended agent for
    # long. It is the ONLY orphan cleanup: no sweep, no pid liveness test.
    $deadline = $TimeoutSec + 120

    try {
        New-Item -ItemType Directory -Path $scratch -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $BundlePath -Destination (Join-Path $scratch 'bundle.xml') -ErrorAction Stop
        $reviewPath = Join-Path $scratch 'review.md'
        $instrPath  = Join-Path $scratch 'instructions.md'
        Get-EraTmuxSeatPrompt -PromptPath $PromptPath -Nonce $nonce |
            Set-Content -LiteralPath $instrPath -Encoding utf8 -ErrorAction Stop

        $scratchWsl = ConvertTo-EraWslPath -WindowsPath $scratch

        # Session + watchdog. -A attaches to an existing session rather than
        # erroring; the watchdog is created only when absent, because -A does NOT
        # recreate an initial window and a lost watchdog silently restores the
        # "seat death looks like transport failure" collision.
        $null = Invoke-EraTmuxCli -TmuxArgs @('tmux', '-L', $socket, 'new-session', '-A', '-d',
                                              '-s', $session, '-n', 'era-watchdog',
                                              "sh -c 'sleep $deadline; tmux -L $socket kill-server'")
        $state = Get-EraTmuxWindowNames -Socket $socket -Session $session
        if (-not $state.ServerUp) {
            throw "tmux server '$socket' did not come up; the transport is unavailable."
        }

        $argv = @()
        foreach ($a in $launch) {
            $argv += ($a -replace '\{model_id\}', $modelId -replace '\{instructions\}', 'instructions.md')
        }
        $null = Invoke-EraTmuxCli -TmuxArgs (@('tmux', '-L', $socket, 'new-window', '-d',
                                               '-t', "${session}:", '-n', $window,
                                               '-c', $scratchWsl, '--') + $argv)

        # LAUNCH LATCH. `new-window` exits 0 for a bad binary, so the only honest
        # confirmation is the row appearing. Until it has been seen once, absence
        # means "never started" (a transport fault), not "the seat died".
        $seen = $false
        $latchDeadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $latchDeadline) {
            $state = Get-EraTmuxWindowNames -Socket $socket -Session $session
            if ($state.ServerUp -and $state.Names -contains $window) { $seen = $true; break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $seen) {
            return @{
                Response = $null; ExitCode = -1; Error = 'tmux-transport-unavailable'
                ContentOk = $false; CaptureMethod = 'tmux'; InputTokens = $null; OutputTokens = 0
                WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                TruncationWarning = $null; Stderr = $null
                Warnings = @($warnings + "the seat window never appeared within 10s; the launch argv did not run (a bad model id or a missing CLI exits 0 from new-window). NOT a model failure and not re-dispatched.")
            }
        }

        # WAIT LOOP. The staged file is polled on the Windows side, which is a
        # local stat; tmux is consulted on a slower cadence because each call
        # crosses the interop boundary.
        $expected  = "ERA-CANARY-$nonce"
        $hardStop  = (Get-Date).AddSeconds($TimeoutSec)
        $lastSize  = -1
        $lastWrite = [datetime]::MinValue
        $stable    = $false
        $canary    = $false
        $nextTmux  = (Get-Date).AddSeconds(15)
        $windowGone = $false

        while ((Get-Date) -lt $hardStop) {
            if (Test-Path -LiteralPath $reviewPath) {
                $fi = Get-Item -LiteralPath $reviewPath -ErrorAction SilentlyContinue
                if ($fi) {
                    $stable = ($fi.Length -eq $lastSize -and $fi.LastWriteTimeUtc -eq $lastWrite)
                    $lastSize  = $fi.Length
                    $lastWrite = $fi.LastWriteTimeUtc
                    if ($stable) {
                        $tail = Get-EraTmuxLastLine -Path $reviewPath
                        if ($tail -eq $expected) { $canary = $true; break }
                    }
                }
            }
            if ((Get-Date) -ge $nextTmux) {
                $nextTmux = (Get-Date).AddSeconds(15)
                $state = Get-EraTmuxWindowNames -Socket $socket -Session $session
                if (-not $state.ServerUp) {
                    # The watchdog holds the server up for TimeoutSec+120, so the
                    # server being gone inside the budget is an infrastructure
                    # fault, not this seat exiting.
                    throw "tmux server '$socket' disappeared mid-attempt; the transport is unavailable."
                }
                if ($state.Names -notcontains $window) { $windowGone = $true; break }
            }
            Start-Sleep -Milliseconds 750
        }

        # STAT THE FILE BEFORE LABELLING. Every terminal branch asks what is on
        # disk first, so a complete review from a seat that exited is a SUCCESS
        # and a partial one is truncation -- not whatever ended the attempt.
        # Stability is required only while the writer is alive; once the window
        # is gone nothing can change the file.
        if (-not $canary -and (Test-Path -LiteralPath $reviewPath)) {
            if ((Get-EraTmuxLastLine -Path $reviewPath) -eq $expected) { $canary = $true }
        }

        $timedOut = -not $canary -and -not $windowGone

        if (-not $canary) {
            $hasFile = Test-Path -LiteralPath $reviewPath
            $code = if ($windowGone) { if ($hasFile) { 'tmux-seat-truncated' } else { 'tmux-seat-exited' } }
                    else             { if ($hasFile) { 'tmux-seat-timeout-partial' } else { 'tmux-seat-timeout' } }
            if ($hasFile) {
                $raw = Get-Content -Raw -LiteralPath $reviewPath -ErrorAction SilentlyContinue
                $forensic = $ResponsePath -replace '-response\.md$', '-raw.md'
                try { $raw | Set-Content -LiteralPath $forensic -Encoding utf8 -ErrorAction Stop
                      $warnings += "partial output kept at $forensic" } catch { }
            }
            return @{
                Response = $null; ExitCode = -1; Error = $code; ContentOk = $false
                CaptureMethod = 'tmux'; InputTokens = $null; OutputTokens = 0
                WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                TruncationWarning = $(if ($code -like '*truncated*' -or $code -like '*partial*') {
                    'review.md exists but does not end with this attempt''s canary, so the write did not complete.' })
                Stderr = $null; Warnings = @($warnings)
            }
        }

        if ($timedOut) {
            # Reachable when the canary was only seen on the post-loop stat --
            # i.e. the model wrote it and kept editing, so stability never held.
            # Recorded rather than silently promoted: this is precisely the
            # contract violation the envelope asks models not to commit.
            $warnings += 'the canary was present but review.md never went stable, so the model may have kept writing after declaring the review final.'
        }

        $body = Get-EraTmuxReviewBody -Path $reviewPath -Canary $expected
        $verdict = Test-EraCaptureAcceptable -Response $body.Text -PromptPath $PromptPath `
                                             -Vendor "tmux/$seat"
        if (-not $verdict.Ok) {
            $warnings += $verdict.Warning
            return @{
                Response = $body.Text; ExitCode = -1; Error = $verdict.Error; ContentOk = $false
                CaptureMethod = 'tmux'; InputTokens = $null
                OutputTokens = [Math]::Ceiling($body.Text.Length / 4)
                WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                TruncationWarning = $null; Stderr = $null; Warnings = @($warnings)
            }
        }

        if ($body.TailClaim) {
            $warnings += "seat reported bundle tail '$($body.TailClaim)' (compare against the bundle's last path to detect a truncated READ; the canary certifies only that the WRITE completed)."
        }

        $body.Text | Set-Content -LiteralPath $ResponsePath -Encoding utf8
        return @{
            Response = $body.Text; ExitCode = 0; Error = $null; ContentOk = $true
            CaptureMethod = 'tmux'; InputTokens = $null
            OutputTokens = [Math]::Ceiling($body.Text.Length / 4)
            WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            TruncationWarning = $null; Stderr = $null; Warnings = @($warnings)
        }
    }
    finally {
        # Teardown on every path, and VERIFIED: an unverified kill leaves an
        # unattended permission-bypassed agent running. The watchdog would still
        # collect it at the deadline, but not before it had done whatever it
        # liked for the rest of that window.
        try {
            $null = Invoke-EraTmuxCli -TmuxArgs @('tmux', '-L', $socket, 'kill-window', '-t', "${session}:$window")
            $after = Get-EraTmuxWindowNames -Socket $socket -Session $session
            if ($after.ServerUp -and $after.Names -contains $window) {
                Write-Host "[tmux] WARNING: window '$window' survived kill-window; the watchdog will collect it within $deadline s."
            }
            # Only era's own windows are left when the watchdog alone remains.
            $rest = Get-EraTmuxWindowNames -Socket $socket -Session $session
            if ($rest.ServerUp -and @($rest.Names | Where-Object { $_ -ne 'era-watchdog' }).Count -eq 0) {
                $null = Invoke-EraTmuxCli -TmuxArgs @('tmux', '-L', $socket, 'kill-server')
            }
        } catch { }
        try { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-EraTmuxLastLine {
    <#
    .SYNOPSIS
        The last non-empty line of a file, trailing whitespace and CR stripped.

    .DESCRIPTION
        Prompt and validator must agree byte-for-byte on what "the last line"
        means, or a compliant model is reported as truncated.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop |
                   ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' })
        if ($lines.Count -eq 0) { return $null }
        return $lines[-1]
    } catch { return $null }
}

function Get-EraTmuxReviewBody {
    <#
    .SYNOPSIS
        Strip era's two marker lines. Returns @{ Text; TailClaim }.

    .DESCRIPTION
        The markers are this transport's scaffolding, not the model's review, and
        they are removed BEFORE the detectors run -- leaving them in would let a
        two-line preamble pad a sub-floor non-answer over the length threshold.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Canary)
    $tailClaim = $null
    $keep = foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ($line.TrimEnd() -eq $Canary) { continue }
        if ($line -match '^\s*ERA-BUNDLE-TAIL:\s*(.+?)\s*$') { $tailClaim = $Matches[1]; continue }
        $line
    }
    return @{ Text = (($keep -join "`n").Trim()); TailClaim = $tailClaim }
}
