<#
.SYNOPSIS
    claude backend adapter for /external-review-auto. Invokes
    `claude --print --model X --allow-dangerously-skip-permissions <prompt>`
    with the bundle content piped via stdin (no tool-reasoning loop).
.DESCRIPTION
    Key difference from other backends:
    - Bundle content is piped via stdin (Get-Content -Raw | & claude --print ...).
      The prompt text is passed as a CLI argument, bundle as stdin.
    - No tool-reasoning loop -- the model receives the bundle directly.
    - Used by presets: opus, sonnet, haiku.
#>

# The non-review detector is shared with agy and opencode. `claude --print`
# exits 0 for any non-empty stdout, so a two-character answer, a tool-intent
# narration, or a "I don't see an attached bundle" refusal was scored as a full
# review -- on `opus`, a shipped default panel member.
. (Join-Path $PSScriptRoot '_capture-validation.ps1')

function Get-ClaudeRemainingMs {
    <#
    .SYNOPSIS
        Milliseconds left until $Deadline, never negative.

    .DESCRIPTION
        An attempt gets ONE budget. Both of the blocking waits below
        (stdinCopyTask.Wait and Process.WaitForExit) draw from this, so the sum
        of the two can never exceed it.

        It used to be $attemptTimeoutSec * 1000 passed to each in turn -- one
        budget granted twice. Worst case 2 x TimeoutSec against a dispatcher
        budget of TimeoutSec + 30, which puts the dispatcher into the one
        collection path that calls Stop-Job on a job blocked inside
        WaitForExit (see Stop-EraAdapterChild: measured to block indefinitely).

        MEASURED by reproducing the shape against a child that never drains
        stdin -- a 600 KB bundle cannot fit the ~64 KB pipe buffer, so the copy
        blocks until someone reads:

            stdin copy Wait returned False after 5.0s (budget 5s)
            WaitForExit  returned False after a FURTHER 5.0s
            TOTAL 10.1s against a single 5s budget -- 2.03x

        THE CLAMP IS NOT COSMETIC. Task.Wait(int) and Process.WaitForExit(int)
        both read a negative millisecond count as Timeout.Infinite, so an
        exhausted budget expressed as a negative number would wait FOREVER --
        turning a timeout into the exact hang this is meant to avoid.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][datetime]$Deadline)
    # UTC on both sides, deliberately. .NET DateTime relational operators and
    # subtraction compare raw Ticks IGNORING Kind: on a UTC-5 box
    # [DateTime]::UtcNow is 18,000s ahead of (Get-Date), so a (Get-Date) "now"
    # against a UTC deadline (or vice versa) misreads the budget by the whole
    # zone offset. Measured 2026-09-13: every claude seat died in ~1s labelled
    # a 708s timeout, because Wait-ClaudeFirstByte compared UtcNow against a
    # (Get-Date)-built deadline. All era deadlines in this adapter are UTC.
    $ms = ($Deadline - [DateTime]::UtcNow).TotalMilliseconds
    if ($ms -lt 0) { return 0 }
    return [int][Math]::Ceiling($ms)
}

function Test-ClaudeTruncation {
    <#
    Detect whether claude CLI's stderr indicates response truncation or
    context-window-exceeded. Uses precisely-anchored phrasings that claude.exe
    is empirically observed to emit, so this won't false-positive on prose
    (e.g., a code-review response that incidentally discusses truncation).

    Regex notes:
    - Word boundaries (\b) on both ends of every alternative prevent matching
      inside longer words (e.g., "truncates" must not match "truncated").
    - Whitespace separators are explicit (\s+ or [\s_-]) — never bare '.', which
      would match anything including punctuation or letters.
    - PowerShell -match is case-insensitive by default, so no (?i) flag needed.
    #>
    [CmdletBinding()]
    param([string]$Text)
    if (-not $Text) { return $false }
    $patterns = @(
        '\bprompt\s+(is\s+)?too\s+long\b'                            # "Prompt is too long" / "Prompt too long"
        '\binput\s+too\s+long\b'                                     # "Input too long"
        '\bcontext\s+(length|window)\s+exceeded\b'                   # "Context length/window exceeded"
        '\bmax(imum)?[\s_-]tokens?\s+(exceeded|reached|limit)\b'     # "max tokens exceeded/reached/limit"
        '\bexceeds?\s+(the\s+)?(maximum\s+)?(context|tokens?|outputs?)\b'  # "exceeds maximum tokens" (singular/plural)
        '\bresponse\s+(was\s+)?truncated\b'                          # "Response was truncated"
        '\boutput\s+(was\s+)?truncated\b'                            # "Output truncated"
        '\btruncated\s+(at|due|because)\b'                           # "truncated at 8192 tokens"
    )
    $regex = '(' + ($patterns -join '|') + ')'
    return ($Text -match $regex)
}

function Wait-ClaudeFirstByte {
    <#
    .SYNOPSIS
        Wait for process exit, first stdout byte, or deadline -- whichever first.
    .DESCRIPTION
        Replaces a blind WaitForExit with a poll that sees startup. Returns
        @{ Outcome; FirstByteSec }: 'exited' (process done -- caller handles
        exit codes as before), 'first-byte-timeout' (nothing arrived in
        FirstByteTimeoutSec -- caller kills and codes the death), 'timeout'
        (attempt deadline hit first -- caller takes the existing timeout path).
        Growth stalls AFTER the first byte are LOGGED, never enforced: the
        only productive-silence datum (opus, 374s, pre/post-byte unknown)
        cannot tell them apart yet, so enforcement waits on the
        spawn-to-byte instrumentation this helper's FirstByteSec feeds.
        The attempt deadline always wins (clamp invariant): every return path
        re-checks it first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][string]$StdFile,
        [int]$FirstByteTimeoutSec = 300,
        [int]$StallObserveSec = 300,
        [Parameter(Mandatory)][datetime]$Deadline,
        [int]$PollMs = 500
    )
    $start = [DateTime]::UtcNow
    $firstByteAt = $null
    $lastGrowthAt = $start
    $lastSize = 0
    $observeAnnounced = $false
    while ($true) {
        if ($Process.HasExited) {
            # Final read: a byte written in the same poll window as death
            # would otherwise be missed (exit wins the race). Attributed at
            # exit time -- a slight overestimate, documented, never inventing
            # bytes that are not there.
            try {
                if ($null -eq $firstByteAt -and (Get-Item -LiteralPath $StdFile -ErrorAction Stop).Length -gt 0) {
                    $firstByteAt = ([DateTime]::UtcNow - $start).TotalSeconds
                }
            } catch {}
            break
        }
        $now = [DateTime]::UtcNow
        if ($now -ge $Deadline) {
            return @{ Outcome = 'timeout'; FirstByteSec = $firstByteAt }
        }
        $size = 0
        try { $size = (Get-Item -LiteralPath $StdFile -ErrorAction Stop).Length } catch { $size = 0 }
        if ($size -gt 0 -and $null -eq $firstByteAt) {
            $firstByteAt = ($now - $start).TotalSeconds
            $lastGrowthAt = $now
        } elseif ($size -gt $lastSize) {
            $lastGrowthAt = $now
        }
        $lastSize = $size
        if ($null -eq $firstByteAt -and ($now - $start).TotalSeconds -gt $FirstByteTimeoutSec) {
            return @{ Outcome = 'first-byte-timeout'; FirstByteSec = $null }
        }
        if ($null -ne $firstByteAt -and -not $observeAnnounced -and ($now - $lastGrowthAt).TotalSeconds -gt $StallObserveSec) {
            $observeAnnounced = $true
            Write-Host "[claude] no output growth for ${StallObserveSec}s after first byte (observing only -- growth stalls are not yet enforced)."
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return @{ Outcome = 'exited'; FirstByteSec = $firstByteAt }
}

function Get-ClaudeFirstBytePlan {
    <#
    .SYNOPSIS
        First-byte seconds for this attempt. Env override wins, else the
        attempt budget minus margin, never exceeding the budget.
    .DESCRIPTION
        `claude --print` in text mode emits nothing until the answer is
        complete (MEASURED 2026-09-15: haiku 600-word probe, 38 polls, 37 at
        0B, first byte 19.0s = exit 19.0s; 11 instrumented opus successes all
        land first-byte within ~2-6s of exit, incl. agent-inbox r4 at
        299.37/300.0s, 0.6s from the old kill). So the "first-byte" deadline
        is effectively a TOTAL-response cap and a flat 300s kills healthy
        slow reviews (awc-system-audit round 2/3, wall 301.9s, first_byte
        null, claude-no-output).

        Same rule the opencode adapter enforces: an adapter cannot grant
        itself time the dispatcher will not wait (TimeoutSec + 30), so the
        threshold is clamped to fit inside the attempt budget. The 30s margin
        leaves room for the kill + drain + throw to report cleanly before the
        attempt deadline fires under the wrong headline.

        Precedence: valid ERA_CLAUDE_FIRST_BYTE_SEC (>= 10) clamped to the
        ceiling, else ceiling. Floor 300s only when the budget allows it;
        tiny budgets clamp down to the ceiling itself.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$AttemptTimeoutSec)
    $ceiling = [Math]::Max(1, $AttemptTimeoutSec - 30)
    $wanted = [Math]::Max(300, $ceiling)
    if ($env:ERA_CLAUDE_FIRST_BYTE_SEC) {
        $parsed = 0
        if ([int]::TryParse($env:ERA_CLAUDE_FIRST_BYTE_SEC, [ref]$parsed) -and $parsed -ge 10) {
            $wanted = $parsed
        } else {
            Write-Host "[claude] ERA_CLAUDE_FIRST_BYTE_SEC='$($env:ERA_CLAUDE_FIRST_BYTE_SEC)' is not a positive integer >= 10; ignoring."
        }
    }
    if ($wanted -gt $ceiling) { return [int]$ceiling }
    return [int]$wanted
}

function Get-ClaudeOutputFormat {
    <#
    .SYNOPSIS
        text (default) or stream-json, via ERA_CLAUDE_OUTPUT_FORMAT.
    .DESCRIPTION
        Text mode buffers the whole answer, so first-byte means completion.
        stream-json streams partial messages, so first-byte really means
        alive -- at the cost of a JSONL capture parse. Invalid values fall
        back to text with a warning, never a throw (a typo must not void a
        paid round).
    #>
    [CmdletBinding()]
    param()
    $raw = if ($env:ERA_CLAUDE_OUTPUT_FORMAT) { $env:ERA_CLAUDE_OUTPUT_FORMAT.Trim().ToLower() } else { '' }
    if (-not $raw) { return 'text' }
    if ($raw -in @('text', 'stream-json')) { return $raw }
    Write-Host "[claude] ERA_CLAUDE_OUTPUT_FORMAT='$($env:ERA_CLAUDE_OUTPUT_FORMAT)' unknown; using 'text'."
    return 'text'
}

function Convert-ClaudeStreamJsonToText {
    <#
    .SYNOPSIS
        Reassemble --output-format stream-json JSONL into plain text.
    .DESCRIPTION
        The terminal result field wins alone when present (the CLI's own
        final assembly); otherwise assistant message text plus
        content_block_delta text_deltas are reassembled in line order.
        Anything unparseable is skipped line-wise; when nothing extracts,
        the raw input is returned so the non-review detector fails honestly
        on what the model actually said instead of on an empty string this
        helper invented.
    #>
    [CmdletBinding()]
    param([string]$Raw)
    if (-not $Raw) { return '' }
    # The terminal result line is the CLI's own final assembly: when present
    # it wins alone, so message + deltas + result are not triple-counted
    # (which would also inflate the OutputTokens estimate downstream).
    # Without it (crash, kill, truncation), the partials are the fallback.
    $res = [System.Text.StringBuilder]::new()
    $prt = [System.Text.StringBuilder]::new()
    $anyRes = $false; $anyPrt = $false
    foreach ($line in ($Raw -split "`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        try { $o = $t | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        try {
            if ($o.type -eq 'result' -and $null -ne $o.result -and $o.result -is [string]) {
                $null = $res.Append([string]$o.result); $anyRes = $true; continue
            }
        } catch {}
        try {
            if ($null -ne $o.message -and $null -ne $o.message.content) {
                foreach ($b in @($o.message.content)) {
                    if ($null -ne $b -and $b.type -eq 'text' -and $null -ne $b.text) {
                        $null = $prt.Append([string]$b.text); $anyPrt = $true
                    }
                }
            }
        } catch {}
        try {
            if ($null -ne $o.delta -and $o.delta.type -eq 'text_delta' -and $null -ne $o.delta.text) {
                $null = $prt.Append([string]$o.delta.text); $anyPrt = $true
            }
        } catch {}
    }
    if ($anyRes) { return $res.ToString() }
    if ($anyPrt) { return $prt.ToString() }
    return $Raw
}

function Invoke-ClaudeReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)][string]$ResponsePath,
        [Parameter(Mandatory)][hashtable]$ModelInfo,
        [int]$TimeoutSec = 600,
        [string]$AgyModelHint,
        [string]$ModelOverride,
        [string]$OpencodeProvider,
        # Absolute path this adapter writes its native child PID to, so the
        # dispatcher can tree-kill the process if this reviewer has to be
        # abandoned early. Optional: omitted by callers that never abandon.
        # See workflow.ps1 Stop-EraAdapterChild for why Stop-Job cannot do it.
        [string]$PidFile
    )
    # NO CITATION-FRAME INSTRUCTION HERE, deliberately. The other two adapters
    # carry one because they hand the model a PATH and its own reader reports
    # bundle-absolute line numbers. Here the bundle IS the prompt: the model only
    # ever sees the per-file numbers printed in the text, and it cannot observe a
    # bundle offset to cite. Measured over 62 archived rounds -- 755 opus
    # citations, zero frame drift, against 11 of 11 for the agy seat. An
    # instruction would be noise about a problem this channel cannot have.
    $prompt = "Review the codebase XML provided. Instructions are at the bottom of the content."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stdFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $modelId = if ($ModelOverride) { $ModelOverride } else { $ModelInfo.model_id }

    # Launch claude with its own private hidden console. claude.exe is a TUI
    # binary (Ink/React) -- even in --print mode it can enable mouse tracking
    # and use direct console writes. Sharing the parent's console (the legacy
    # `& claude` invocation pattern) would pollute it. See agy.ps1 for the
    # full bug class.
    # Resolve actual executable (ProcessStartInfo doesn't search PATHEXT
    # when UseShellExecute=$false). claude is typically a direct .exe, but
    # be defensive: if Get-Command resolves to a .ps1 wrapper, switch to .cmd.
    $claudeCli = Get-Command claude -ErrorAction Stop
    $claudeExe = if ($claudeCli.Source -match '\.ps1$') {
        $cmdPath = $claudeCli.Source -replace '\.ps1$', '.cmd'
        if (-not (Test-Path -LiteralPath $cmdPath)) { throw "claude.cmd not found at $cmdPath" }
        $cmdPath
    } else { $claudeCli.Source }

    # WINDOWS-vs-WSL CREDENTIAL SPLIT (measured 2026-08-04). claude.exe reads
    # C:\Users\<u>\.claude\.credentials.json; a claude running INSIDE WSL reads the Linux home's.
    # They expire INDEPENDENTLY -- /era's opus arm went 115/119 lifetime -> 0/4 in a day when the
    # Windows token lapsed, while the interactive agent (authenticated against the WSL store) kept
    # working. So a working agent is no evidence that THIS backend works, and the WSL binary is a
    # usable fallback. Probed lazily below, only after a failure a different store would fix.
    $launcherFile = $claudeExe
    $launcherPre  = @()
    $usedKind     = 'windows'
    $fallbackNote = $null

    for ($try = 0; $try -lt 2; $try++) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $launcherFile
    foreach ($pre in $launcherPre) { $psi.ArgumentList.Add($pre) }
    $outputFormat = Get-ClaudeOutputFormat
    $psi.ArgumentList.Add('--print')
    $psi.ArgumentList.Add('--model')
    $psi.ArgumentList.Add($modelId)
    if ($outputFormat -eq 'stream-json') {
        # --verbose is REQUIRED with --print + --output-format stream-json
        # (measured: without it the CLI errors "requires --verbose").
        $psi.ArgumentList.Add('--verbose')
        $psi.ArgumentList.Add('--output-format')
        $psi.ArgumentList.Add('stream-json')
        $psi.ArgumentList.Add('--include-partial-messages')
    }
    $psi.ArgumentList.Add('--allow-dangerously-skip-permissions')
    $psi.ArgumentList.Add($prompt)
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    # Scrub agent-context env vars from the child's env block. The Claude Code CLI
    # has a recursion guard keyed on CLAUDECODE / CLAUDE_CODE_* / AI_AGENT -- if set,
    # it fast-exits with code 0 in ~2s producing no output. ProcessStartInfo.Environment
    # is per-child and doesn't affect the parent pwsh or other ThreadJobs.
    foreach ($var in @('CLAUDECODE','CLAUDE_CODE_ENTRYPOINT','CLAUDE_CODE_SESSION_ID',
                       'CLAUDE_CODE_GIT_BASH_PATH','AI_AGENT','ANTIGRAVITY_AGENT',
                       'ANTIGRAVITY_SOURCE_METADATA','OPENCODE_YOLO')) {
        if ($psi.Environment.ContainsKey($var)) { $null = $psi.Environment.Remove($var) }
    }

    $exitCode = -1
    $clean = $null
    $detectorNote = $null
    $captureError = $null
    $firstByteSec = $null
    $firstBytePlanSec = $null
    $firstByteTimeout = $false
    $stderr = ''
    $stdoutSink = $null
    $stderrSink = $null
    $stdinCopyTask = $null
    $stdoutCopyTask = $null
    $stderrCopyTask = $null
    $claudeProc = $null

    # ⚠️ THE RETRY MUST FIT INSIDE THE *GLOBAL* BUDGET, NOT GET A FRESH ONE. The dispatcher waits
    # only `TimeoutSec + 30` for this whole adapter (workflow.ps1), so two attempts each budgeted
    # `TimeoutSec` can overrun it and the ThreadJob is killed mid-retry -- recorded as a bare
    # "Timed out after N seconds (global)" with no cause. Observed 2026-08-04 on a loaded box, and a
    # single unloaded verification run cannot surface it. The second attempt therefore gets whatever
    # is LEFT, floored at 60s so a nearly-exhausted budget fails fast instead of pretending to try.
    $attemptTimeoutSec = [Math]::Max(60, $TimeoutSec - [int]$sw.Elapsed.TotalSeconds)
    # ONE deadline for this attempt. Both blocking waits below draw from it via
    # Get-ClaudeRemainingMs, so stdin drain + process wait share the budget
    # instead of each getting a full copy of it. See Get-ClaudeRemainingMs for
    # the 2.03x measurement that motivated this.
    # UTC, to match Wait-ClaudeFirstByte / Get-ClaudeRemainingMs (see the Kind
    # note there): a (Get-Date) deadline compared against UtcNow reads expired
    # by the whole zone offset on any non-UTC box and fake-times-out the seat.
    $attemptDeadline = [DateTime]::UtcNow.AddSeconds($attemptTimeoutSec)
    # Per-attempt bound (recomputed: the retry gets whatever budget is LEFT).
    $firstBytePlanSec = Get-ClaudeFirstBytePlan -AttemptTimeoutSec $attemptTimeoutSec
    $sw.Start()   # resume: the finally below stops it, so WallClockSec spans BOTH attempts
    try {
        $claudeProc = [System.Diagnostics.Process]::Start($psi)
        # Publish the child PID before any blocking wait: once this thread is
        # inside WaitForExit it cannot be interrupted, so this file is the
        # dispatcher's only handle on the process.
        if ($PidFile) { try { Set-Content -LiteralPath $PidFile -Value $claudeProc.Id -ErrorAction SilentlyContinue } catch {} }

        # Async-drain stdout/stderr so OS buffers never fill.
        # FileShare.ReadWrite (not File.Create's default None) so the files can be
        # read while these async copies hold them; harmless here since claude reads
        # after dispose, but keeps the sink-open contract uniform across adapters.
        $stdoutSink = [System.IO.File]::Open($stdFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $stderrSink = [System.IO.File]::Open($errFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $stdoutCopyTask = $claudeProc.StandardOutput.BaseStream.CopyToAsync($stdoutSink)
        $stderrCopyTask = $claudeProc.StandardError.BaseStream.CopyToAsync($stderrSink)

        # Pipe the bundle into claude's stdin, then close stdin to signal EOF.
        $bundleStream = [System.IO.File]::OpenRead($BundlePath)
        try {
            $stdinCopyTask = $bundleStream.CopyToAsync($claudeProc.StandardInput.BaseStream)
            $stdinStartSec = [int]$sw.Elapsed.TotalSeconds
            $null = $stdinCopyTask.Wait((Get-ClaudeRemainingMs -Deadline $attemptDeadline))
            # Instrumentation opus asked for before fixing. It could not measure
            # how long real `claude` takes to drain a large bundle from stdin,
            # and neither could I without a billed round -- so report it when it
            # is slow enough to matter. Quiet on every healthy round.
            $stdinSpentSec = [int]$sw.Elapsed.TotalSeconds - $stdinStartSec
            if ($stdinSpentSec -ge 5) {
                Write-Host "[claude] stdin drain took ${stdinSpentSec}s of the ${attemptTimeoutSec}s attempt budget."
            }
        } finally {
            $bundleStream.Dispose()
            $claudeProc.StandardInput.Close()
        }

        if (-not $claudeProc.WaitForExit(0)) {
            # Poll for exit, first byte, or deadline -- never blind-wait. The
            # attempt deadline still wins every branch (clamp invariant above).
            # Text mode buffers the whole answer, so this bound is a total cap:
            # $firstBytePlanSec (computed per attempt above) replaces the old
            # flat 300s. Stream-json streams partials, so the same number
            # there really means alive.
            $firstWait = Wait-ClaudeFirstByte -Process $claudeProc -StdFile $stdFile `
                -FirstByteTimeoutSec $firstBytePlanSec -StallObserveSec 300 -Deadline $attemptDeadline
            $firstByteSec = $firstWait.FirstByteSec
            if ($firstWait.Outcome -eq 'timeout') {
                # Kill($true): tear down the whole tree. claude is a shim (cmd -> node);
                # a bare Kill() would orphan the node child.
                try { $claudeProc.Kill($true) } catch {}
                throw "claude CLI exceeded its ${attemptTimeoutSec}s slice of the ${TimeoutSec}s budget (model=$modelId, launcher=$usedKind)"
            }
            if ($firstWait.Outcome -eq 'first-byte-timeout') {
                try { $claudeProc.Kill($true) } catch {}
                $firstByteTimeout = $true
            }
            if (-not $claudeProc.HasExited) {
                $null = $claudeProc.WaitForExit((Get-ClaudeRemainingMs -Deadline $attemptDeadline))
            }
        }
        if (-not $claudeProc.HasExited) {
            # Kill($true): tear down the whole tree. claude is a shim (cmd -> node);
            # a bare Kill() would orphan the node child.
            try { $claudeProc.Kill($true) } catch {}
            throw "claude CLI exceeded its ${attemptTimeoutSec}s slice of the ${TimeoutSec}s budget (model=$modelId, launcher=$usedKind)"
        }
        $exitCode = $claudeProc.ExitCode
    } finally {
        # Defensive tree-kill: if claude is somehow still alive at cleanup (e.g. the
        # timeout Kill didn't fully take), tear down the tree so no child is orphaned.
        if ($claudeProc -and -not $claudeProc.HasExited) { try { $claudeProc.Kill($true) } catch {} }
        # Wait for output drains to flush, then dispose the sinks so files unlock.
        try { $null = $stdoutCopyTask.Wait(2000) } catch {}
        try { $null = $stderrCopyTask.Wait(2000) } catch {}
        try { $stdoutSink.Dispose() } catch {}
        try { $stderrSink.Dispose() } catch {}

        $resultText = (Get-Content -Raw -LiteralPath $stdFile -ErrorAction SilentlyContinue)
        if (-not $resultText) { $resultText = '' }
        $stderr = (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue)
        if (-not $stderr) { $stderr = '' }
        if ($outputFormat -eq 'stream-json' -and $resultText.Trim()) {
            $resultText = Convert-ClaudeStreamJsonToText -Raw $resultText
        }
        $clean = $resultText -replace '\x1b\[\??[0-9;]*[a-zA-Z]', '' -replace "\r", ''

        Remove-Item -LiteralPath $stdFile -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
        $sw.Stop()
    }

    # Truncation detection: scan stderr for precisely-anchored phrases that
    # claude CLI emits on context-window-exceeded / output-truncated.
    # See Test-ClaudeTruncation for the pattern list and rationale.
    # Snapshot before the banner is prepended: the detector must judge what the
    # MODEL said, not what this adapter added to it.
    $preBannerClean = $clean

    $truncationWarning = $null
    if (Test-ClaudeTruncation $stderr) {
        $truncationWarning = "Claude CLI reported output truncation in stderr."
        $banner = @"
> [!WARNING]
> **Claude response may have been truncated.**
> The text below may be incomplete. Re-run with a tighter prompt or a model with a higher output budget.

"@
        $clean = $banner + $clean
    }

    if ($exitCode -eq 0 -and $clean) { break }

    # The CLI prints its fatal reasons to STDOUT, not stderr: throwing with $stderr alone recorded a
    # BLANK cause on 3 of 4 failures (2026-08-04) while "Failed to authenticate: OAuth session
    # expired and could not be refreshed" sat in $clean and was discarded, so four sessions read an
    # empty string and concluded the MODEL was unreliable. Carry whichever stream actually spoke.
    # ⚠️ REPORT BOTH STREAMS, never "stderr if non-empty else stdout". Measured 2026-08-04: a failing
    # run emits a benign `Ignoring 1 permissions.allow entry … not been trusted` WARNING on stderr
    # *and* the fatal `Failed to authenticate: …` on stdout, so a stderr-first rule records the
    # warning and hides the cause -- the original bug inverted. Preferring stdout would hide a
    # genuinely stderr-only fatal. Both, labelled, is the only rule that cannot mask either.
    $parts = @()
    if ($stderr.Trim()) { $parts += 'stderr: ' + $(if ($stderr.Trim().Length -gt 300) { $stderr.Trim().Substring(0,300) + '...' } else { $stderr.Trim() }) }
    if ($clean.Trim())  { $parts += 'stdout: ' + $(if ($clean.Trim().Length  -gt 300) { $clean.Trim().Substring(0,300)  + '...' } else { $clean.Trim() }) }
    $why = if ($parts) { $parts -join ' || ' } else { '<both stdout and stderr were empty>' }
    # Zero-output death with a tripped first-byte deadline: the model never
    # emitted, same dead-transport class as the opencode trailer. A fast
    # crash with output keeps its free-text cause -- only the empty case
    # codes. The trailer rides the message to the parent-side decoder
    # (Convert-EraAdapterResultError); the WSL credential retry above is
    # untouched (auth failures always print text, never trip this).
    $noOutputDeath = $firstByteTimeout -and -not $stderr.Trim() -and -not $clean.Trim()

    # Retry on a DIFFERENT CREDENTIAL STORE, and only for failures a different store could fix.
    # A bad model id, a network fault or a real API error must NOT be retried: that would double
    # every genuine failure's latency and blur which launcher produced the error.
    if ($try -eq 0 -and
        $why -match 'authenticat|OAuth|session expired|Invalid API key|not been trusted|trust dialog') {
        $wslClaude = $null
        try {
            $probe = (& wsl.exe -e sh -lc 'command -v claude || true' 2>$null | Select-Object -First 1)
            if ($probe) { $wslClaude = $probe.Trim() }
        } catch { $wslClaude = $null }
        if ($wslClaude) {
            $launcherFile = 'wsl.exe'; $launcherPre = @('-e', $wslClaude); $usedKind = 'wsl'
            $fallbackNote = "windows claude.exe failed credential-shaped (exit=$exitCode): $why " +
                            "-> retrying via WSL, which reads a SEPARATE credential store."
            Write-Host "[claude] $fallbackNote"
            continue
        }
    }
    throw $(if ($noOutputDeath) {
        "claude CLI failed (exit=$exitCode, model=$modelId, launcher=$usedKind): $why [claude-no-output stdout=0]"
    } else {
        "claude CLI failed (exit=$exitCode, model=$modelId, launcher=$usedKind): $why"
    })
    }
    # Honest content validation. Judged on the PRE-BANNER text: the truncation
    # banner adds ~190 characters, which would push a short non-answer over the
    # detector's 300-char length floor and defeat branch B2.
    # Narration and echo are both classified by the shared helper, in that
    # order, so a bundle-access refusal is reported as the refusal it is.
    $verdict = Test-EraCaptureAcceptable -Response $preBannerClean -PromptPath $PromptPath -Vendor 'claude'
    $detectorFired = -not $verdict.Ok
    if ($detectorFired) {
        $captureError = $verdict.Error
        $exitCode     = -1
        $detectorNote = $verdict.Warning
    }

    # A non-review is not written to disk, matching agy and opencode, so it
    # cannot be picked up by the round-N-*-response.md glob that builds the next
    # round's {{PREVIOUS_ROUND}} context.
    if (-not $detectorFired) {
        $clean | Set-Content -LiteralPath $ResponsePath -Encoding utf8
    }
    return @{
        Response = $clean
        ExitCode = $exitCode
        Error = $captureError
        ContentOk = ($exitCode -eq 0)
        CaptureMethod = 'direct'
        InputTokens = $null
        OutputTokens = [Math]::Ceiling($clean.Length / 4)
        WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        # Spawn-to-first-byte seconds (null when nothing arrived). CALIBRATED
        # 2026-09-15: text-mode first byte trails exit by ~2-6s (11 successes;
        # agent-inbox r4 299.37/300.0s missed the old flat 300s by 0.6s), so the
        # bound is now the attempt budget minus margin (Get-ClaudeFirstBytePlan),
        # overridable via ERA_CLAUDE_FIRST_BYTE_SEC. FirstBytePlanSec records
        # the bound this attempt used; OutputFormat records text/stream-json.
        FirstByteSec = $firstByteSec
        FirstBytePlanSec = $firstBytePlanSec
        OutputFormat = $outputFormat
        TruncationWarning = $truncationWarning
        Stderr = $stderr
        # A silent launcher switch would be the same defect class as the blank error string above:
        # the run reads normal while having been rescued, and the Windows credential fault stays
        # invisible forever. Record it.
        Warnings = @(@(if ($fallbackNote) { $fallbackNote }) + @(if ($detectorNote) { $detectorNote }))
    }
}