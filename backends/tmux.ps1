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

function ConvertTo-EraWslPathPure {
    <#
    .SYNOPSIS
        `C:\X\Y` -> `/mnt/c/X/Y`, computed locally, with no round trip.

    .DESCRIPTION
        Deliberately NOT `wslpath`: calling it would need an argument to survive
        the boundary, which is the very thing that cannot be relied on (see
        Invoke-EraTmuxScript). The drive-letter mapping is deterministic, and it is
        VERIFIED once per attempt by asking WSL whether the directory exists --
        so a wrong mapping fails loudly at startup instead of silently pointing a
        seat at nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WindowsPath)
    $p = $WindowsPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') {
        return ('/mnt/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2])
    }
    return $p
}

function Invoke-EraTmuxScript {
    <#
    .SYNOPSIS
        Run a shell script inside WSL. Returns @{ Rc; Out; Err }.

    .DESCRIPTION
        EVERYTHING GOES THROUGH A SCRIPT FILE, and the only thing crossing the
        Windows->WSL boundary is that file's path. This is the third design of
        this function and the first that is not fighting a quoting layer.

        `wsl.exe -- cmd args` DOES NOT EXEC DIRECTLY: it hands the arguments to
        `bash -c`. Measured 2026-09-06, that shell was found three times over,
        each looking like a different bug:

          * `wslpath -u C:\Users\Joshua` returned `C:UsersJoshua` -- backslashes
            eaten as escapes.
          * `list-windows -F #{window_name}` failed with "-F expects an
            argument" -- `#` began a COMMENT and swallowed the format string.
          * `sh -c 'sleep N; tmux kill-server'` was re-parsed by a second shell
            and died instantly, taking the server with it.

        Single-quoting each argument fixed the first two and broke on the third,
        because .NET does its OWN Windows-style quoting on top: an argument
        containing double quotes came out with `"$@"` expanded to nothing. Layers
        of escaping stacked on layers of escaping is not a fix, it is a queue of
        future bugs.

        A script file has no such layers. era writes the commands with
        PowerShell, WSL reads them with bash, and the boundary carries one path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptBody,
        [Parameter(Mandatory)][string]$ScratchDir
    )

    $name = 'era-cmd-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sh'
    $win  = Join-Path $ScratchDir $name
    # LF endings: bash rejects a script whose lines end with CR ("\r: command
    # not found"), and Set-Content on Windows would supply CRLF.
    [System.IO.File]::WriteAllText($win, ($ScriptBody -replace "`r`n", "`n"))
    $wsl = ConvertTo-EraWslPathPure -WindowsPath $win

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'wsl.exe'
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $distro = Get-EraTmuxDistro
    if ($distro) { $psi.ArgumentList.Add('-d'); $psi.ArgumentList.Add($distro) }
    $psi.ArgumentList.Add('--')
    $psi.ArgumentList.Add('bash')
    $psi.ArgumentList.Add($wsl)

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
    try { Remove-Item -LiteralPath $win -Force -ErrorAction SilentlyContinue } catch { }
    return @{ Rc = $p.ExitCode; Out = $out; Err = $err }
}

function ConvertTo-EraShellQuoted {
    <#
    .SYNOPSIS
        One shell-safe single-quoted token. Used to BUILD script text, where
        there is exactly one shell and its rules are known.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Test-EraWslPathVisible {
    <#
    .SYNOPSIS
        Positive control on the path mapping: can WSL actually see this directory?

    .DESCRIPTION
        ConvertTo-EraWslPathPure computes the mapping without asking WSL. That is
        the right call -- but an unverified mapping would point a seat at a
        directory that does not exist and the seat would fail looking like a model
        problem. One `test -d` turns that into a loud transport error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScratchDir)
    $wsl = ConvertTo-EraWslPathPure -WindowsPath $ScratchDir
    $q = ConvertTo-EraShellQuoted -Value $wsl
    $r = Invoke-EraTmuxScript -ScratchDir $ScratchDir -ScriptBody "test -d $q && echo VISIBLE"
    return ($r.Out.Trim() -eq 'VISIBLE')
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

        The `#{window_name}` format string is why this goes through a script:
        passed as a bare argument it reaches bash, which reads `#` as a comment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Socket,
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string]$ScratchDir
    )
    $body = "tmux -L $(ConvertTo-EraShellQuoted -Value $Socket) list-windows -t $(ConvertTo-EraShellQuoted -Value $Session) -F '#{window_name}'"
    $r = Invoke-EraTmuxScript -ScratchDir $ScratchDir -ScriptBody $body
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
    $argvBuilt = @()
    foreach ($a in $launch) {
        $argvBuilt += ($a -replace '\{model_id\}', $modelId -replace '\{instructions\}', 'instructions.md')
    }

    $nonce    = ([guid]::NewGuid().ToString('N').Substring(0, 16))
    $socket   = "era-$PID"
    $session  = 'era'
    $seat     = if ($ModelInfo.preset) { $ModelInfo.preset } else { 'seat' }
    $window   = "era-$seat-$nonce"
    $scratch  = Join-Path ([System.IO.Path]::GetTempPath()) "era-tmux-$PID-$nonce"
    # Generous enough never to pre-empt $TimeoutSec, short enough that an era
    # crash cannot leave an unattended agent for long. This is the ONLY orphan
    # cleanup: no sweep, no pid liveness test, and it does not need era alive.
    $deadline = $TimeoutSec + 120

    try {
        New-Item -ItemType Directory -Path $scratch -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $BundlePath -Destination (Join-Path $scratch 'bundle.xml') -ErrorAction Stop
        $reviewPath = Join-Path $scratch 'review.md'
        Get-EraTmuxSeatPrompt -PromptPath $PromptPath -Nonce $nonce |
            Set-Content -LiteralPath (Join-Path $scratch 'instructions.md') -Encoding utf8 -ErrorAction Stop

        if (-not (Test-EraWslPathVisible -ScratchDir $scratch)) {
            throw "WSL cannot see the scratch directory '$scratch'; the transport is unavailable."
        }
        $scratchWsl = ConvertTo-EraWslPathPure -WindowsPath $scratch

        $qSock  = ConvertTo-EraShellQuoted -Value $socket
        $qSess  = ConvertTo-EraShellQuoted -Value $session
        # `-t era` names WINDOW 0 of that session; `-t era:` names the session
        # and lets tmux pick the next free index. Measured: without the colon,
        # new-window fails with "create window failed: index 0 in use".
        $qSessT = ConvertTo-EraShellQuoted -Value "${session}:"
        $qWin   = ConvertTo-EraShellQuoted -Value $window
        $qDir   = ConvertTo-EraShellQuoted -Value $scratchWsl
        # NEUTRALISE THE SEAT'S INHERITED TMUX SOCKET. tmux sets TMUX in every
        # pane it creates, so a seat would inherit era's EPHEMERAL socket --
        # measured, `TMUX=/tmp/tmux-1000/era-<pid>,15632,0`. Any turn-state
        # plugin in the seat's CLI then signals into a socket era is about to
        # destroy, and the failures land in the SHARED
        # ~/.local/state/tui-workspace/agent-signal.log, which `tui-workspace
        # check` gates pushes on for every repo on this box. A peer session had a
        # push refused by exactly that on 2026-09-06.
        #
        # `-e TMUX=` was chosen over disabling plugins (`opencode --pure`), which
        # was the first fix and is on the WRONG AXIS: the invariant is "the seat
        # must not signal to a socket that will not outlive it", which is a
        # property of the seat's ENVIRONMENT, not of its plugin set. Those
        # coincide only while the sole signalling plugin is external. §6 rule 4
        # would have era ship its OWN turn-end plugin, and no setting of --pure
        # satisfies both -- on, era loses its own signal; off, the operator's
        # plugin returns. Clearing TMUX holds on the axis the invariant lives on
        # and keeps holding when era's plugin arrives, because that plugin's
        # signal is a FILE in the scratch directory, not a tmux message.
        # (Diagnosis and the axes argument: a peer session, 2026-09-06.)
        #
        # ONE tmux argument for the watchdog: tmux JOINS multiple command
        # arguments and re-runs them through sh, so `-- /bin/sh -c 'sleep 120'`
        # became `sh -c sleep` with `120` as $0 -- the window exited instantly and
        # took the server with it. Measured 2026-09-06.
        $qWatch = ConvertTo-EraShellQuoted -Value "sleep $deadline; tmux -L $socket kill-server"
        # RESOLVE THE SEAT BINARY ON THE LOGIN PATH. `wsl.exe` runs a NON-LOGIN,
        # non-interactive bash whose PATH is only the system defaults -- measured
        # 2026-09-06: `command -v opencode` and `command -v claude` both return
        # nothing there, while a login shell finds
        # ~/.nvm/versions/node/*/bin/opencode and ~/.local/bin/claude. Launching
        # the bare name produced a window that died before the latch could see
        # it, which is indistinguishable at the tmux level from a model that
        # crashed instantly. Resolving here makes a missing CLI a LOUD, distinct
        # failure (exit 3) instead.
        $qBin  = ConvertTo-EraShellQuoted -Value $argvBuilt[0]
        $qRest = (@($argvBuilt | Select-Object -Skip 1) |
                  ForEach-Object { ConvertTo-EraShellQuoted -Value $_ }) -join ' '

        $setup = "set -e`n" +
                 "SEAT_BIN=`$(bash -lc 'command -v '$qBin 2>/dev/null || true)`n" +
                 "if [ -z `"`$SEAT_BIN`" ]; then echo `"era-tmux: seat binary $qBin is not on the login PATH inside WSL`" >&2; exit 3; fi`n" +
                 "tmux -L $qSock new-session -A -d -s $qSess -n era-watchdog $qWatch`n" +
                 "tmux -L $qSock new-window -d -e 'TMUX=' -e 'TMUX_PANE=' -t $qSessT -n $qWin -c $qDir -- `"`$SEAT_BIN`" $qRest`n"
        $r = Invoke-EraTmuxScript -ScratchDir $scratch -ScriptBody $setup
        if ($r.Rc -eq 3) { throw "the seat CLI '$($argvBuilt[0])' is not installed inside WSL; the transport cannot carry this preset. $($r.Err.Trim())" }
        if ($r.Rc -ne 0) { throw "tmux setup failed (rc=$($r.Rc)): $($r.Err.Trim())" }

        # LAUNCH LATCH. `new-window` exits 0 for a bad binary, so the only honest
        # confirmation is the row appearing. Until it has been seen once, absence
        # means "never started" (a transport fault), not "the seat died".
        $seen = $false
        $latchDeadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $latchDeadline) {
            $state = Get-EraTmuxWindowNames -Socket $socket -Session $session -ScratchDir $scratch
            if ($state.ServerUp -and $state.Names -contains $window) { $seen = $true; break }
            Start-Sleep -Milliseconds 400
        }
        if (-not $seen) {
            return @{
                Response = $null; ExitCode = -1; Error = 'tmux-transport-unavailable'
                ContentOk = $false; CaptureMethod = 'tmux'; InputTokens = $null; OutputTokens = 0
                WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                TruncationWarning = $null; Stderr = $r.Err
                Warnings = @($warnings + "the seat window never appeared within 15s, so the launch argv did not run (a bad model id or a missing CLI still exits 0 from new-window). NOT a model failure, and not re-dispatched.")
            }
        }

        # WAIT LOOP. The staged file is polled on the Windows side, which is a
        # local stat; tmux is consulted on a slower cadence because each call
        # crosses the interop boundary.
        $expected   = "ERA-CANARY-$nonce"
        $hardStop   = (Get-Date).AddSeconds($TimeoutSec)
        $lastSize   = -1
        $lastWrite  = [datetime]::MinValue
        $canary     = $false
        $windowGone = $false
        $nextTmux   = (Get-Date).AddSeconds(15)

        while ((Get-Date) -lt $hardStop) {
            if (Test-Path -LiteralPath $reviewPath) {
                $fi = Get-Item -LiteralPath $reviewPath -ErrorAction SilentlyContinue
                if ($fi) {
                    $stable = ($fi.Length -eq $lastSize -and $fi.LastWriteTimeUtc -eq $lastWrite)
                    $lastSize  = $fi.Length
                    $lastWrite = $fi.LastWriteTimeUtc
                    if ($stable -and (Get-EraTmuxLastLine -Path $reviewPath) -eq $expected) {
                        $canary = $true; break
                    }
                }
            }
            if ((Get-Date) -ge $nextTmux) {
                $nextTmux = (Get-Date).AddSeconds(15)
                $state = Get-EraTmuxWindowNames -Socket $socket -Session $session -ScratchDir $scratch
                if (-not $state.ServerUp) {
                    # The watchdog holds the server up for TimeoutSec+120, so the
                    # server being gone INSIDE the budget is infrastructure, not
                    # this seat exiting. Never recorded as a model verdict.
                    throw "tmux server '$socket' disappeared mid-attempt; the transport is unavailable."
                }
                if ($state.Names -notcontains $window) { $windowGone = $true; break }
            }
            Start-Sleep -Milliseconds 750
        }

        # STAT THE FILE BEFORE LABELLING, so a complete review from a seat that
        # exited is a SUCCESS and a partial one is truncation -- not whatever
        # ended the attempt. Stability is required only while the writer is
        # alive; once the window is gone nothing can change the file.
        if (-not $canary -and (Test-Path -LiteralPath $reviewPath)) {
            if ((Get-EraTmuxLastLine -Path $reviewPath) -eq $expected) { $canary = $true }
        }

        if (-not $canary) {
            $hasFile = Test-Path -LiteralPath $reviewPath
            $code = if ($windowGone) { if ($hasFile) { 'tmux-seat-truncated' } else { 'tmux-seat-exited' } }
                    else             { if ($hasFile) { 'tmux-seat-timeout-partial' } else { 'tmux-seat-timeout' } }
            if ($hasFile) {
                $forensic = $ResponsePath -replace '-response\.md$', '-raw.md'
                try {
                    Get-Content -Raw -LiteralPath $reviewPath -ErrorAction Stop |
                        Set-Content -LiteralPath $forensic -Encoding utf8 -ErrorAction Stop
                    $warnings += "partial output kept at $forensic"
                } catch { }
            }
            return @{
                Response = $null; ExitCode = -1; Error = $code; ContentOk = $false
                CaptureMethod = 'tmux'; InputTokens = $null; OutputTokens = 0
                WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                TruncationWarning = $(if ($hasFile) { "review.md exists but does not end with this attempt's canary, so the write did not complete." })
                Stderr = $null; Warnings = @($warnings)
            }
        }

        $body = Get-EraTmuxReviewBody -Path $reviewPath -Canary $expected
        $verdict = Test-EraCaptureAcceptable -Response $body.Text -PromptPath $PromptPath -Vendor "tmux/$seat"
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
            $warnings += "seat reported bundle tail '$($body.TailClaim)'; compare it against the bundle's last path to detect a truncated READ, which the canary cannot see -- the canary certifies only that the WRITE completed."
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
            if (Test-Path -LiteralPath $scratch) {
                $qs = ConvertTo-EraShellQuoted -Value $socket
                $qt = ConvertTo-EraShellQuoted -Value "${session}:$window"
                $qe = ConvertTo-EraShellQuoted -Value $session
                $teardown = "tmux -L $qs kill-window -t $qt 2>/dev/null`n" +
                            "left=`$(tmux -L $qs list-windows -t $qe -F '#{window_name}' 2>/dev/null | grep -v -x 'era-watchdog' | grep -c . || true)`n" +
                            "if [ `"`$left`" = `"0`" ]; then tmux -L $qs kill-server 2>/dev/null; fi`n" +
                            "exit 0`n"
                $null = Invoke-EraTmuxScript -ScratchDir $scratch -ScriptBody $teardown
            }
        } catch { }
        # RETRY THE SCRATCH REMOVAL. The seat's process holds the directory as its
        # cwd, and process exit is asynchronous: measured 2026-09-06, a
        # single-shot Remove-Item after kill-window left the directory behind
        # every time. Best-effort still, but three attempts over ~1.5s clears it.
        foreach ($attempt in 1..3) {
            if (-not (Test-Path -LiteralPath $scratch)) { break }
            try { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Stop }
            catch { Start-Sleep -Milliseconds 500 }
        }
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
