<#
.SYNOPSIS
    cmdc (Command Code) backend. Process-spawn, headless, stdout-captured --
    era's ordinary adapter shape, reaching 68 models that had no backend at all.

.DESCRIPTION
    WHY THIS EXISTS RATHER THAN A tmux SEAT. `cmdc` was the last surviving
    argument for the tmux TUI transport (backends/tmux.ps1): 68 models, no era
    adapter, so reaching them looked like it needed an interactive TUI. Round 1
    of the transport's own findings review reduced that to one checkable
    property -- can cmdc be driven non-interactively? Measured 2026-09-06: YES.
    `cmdc -p --tools-all` with stdin closed and no TTY read a 59,034-byte bundle
    and summarised its contents correctly, exit 0. So this is a normal backend,
    and the transport is not required for cmdc.

    IT STILL CROSSES THE WSL BOUNDARY, and that was NOT free -- an earlier
    version of this claim said a process-spawn cmdc backend would "cross no
    boundary at all", which a reviewer correctly called false. Measured: `cmdc`
    is on the WSL PATH only (`where.exe cmdc` finds nothing), where `claude` and
    `opencode` both have Windows installs that era spawns directly. So this
    adapter inherits the boundary facts recorded in
    references/wsl-argument-boundary.md:

      * `wsl.exe -d X -- cmd args` does NOT exec directly; it hands the arguments
        to `bash -c`, so every one is shell-parsed. Backslashes are eaten, `#`
        starts a comment, and .NET's own quoting composes with bash's.
        -> Everything here goes through a SCRIPT FILE; only its path crosses.
      * `wsl.exe` gives a NON-LOGIN bash whose PATH is the system default, and
        `cmdc` is `#!/usr/bin/env node` with node absent from it. Resolving the
        script's absolute path is not enough; the interpreter must be findable.
        -> The script runs the seat under `bash -l`.

    WHAT IT DOES NOT NEED, compared with the tmux transport: no server, no
    windows, no watchdog, no launch latch, no canary. The process exits when the
    turn ends, and stdout is complete by definition at that point -- which is the
    property an interactive TUI cannot offer, and the reason it needed all five.

    THE PROMPT IS STAGED ON DISK. `cmdc -p <query>` takes its query as an argv
    value, and era's round prompt can reach 80,000 characters once
    {{PREVIOUS_ROUND}} is substituted (workflow.ps1:711). The argv carries a
    fixed ~50-byte pointer instead and the model reads the real instructions from
    its working directory.
#>

. (Join-Path $PSScriptRoot '_capture-validation.ps1')

function Get-EraCmdcDistro {
    <#
    .SYNOPSIS
        The WSL distro this adapter addresses, resolved once.
    #>
    [CmdletBinding()]
    param()
    if ($script:EraCmdcDistro) { return $script:EraCmdcDistro }
    # THE DEFAULT DISTRO, NOT THE FIRST LISTED. `wsl -l -q` order is not the
    # default; `wsl -l -v` marks the default with a leading `*`. Measured
    # 2026-09-06: this box has three (Ubuntu, Ubuntu-22.04, docker-desktop) and
    # the default happens to be first, so first-listed worked BY LUCK. On a box
    # where it is not, era would dispatch into a distro that may lack cmdc, pass
    # the staging-visibility probe anyway -- /mnt/c is visible from every distro
    # -- and then fail with the misleading "cmdc is not installed". Raised by
    # deepseek-flash in the 2026-09-06 review of this file.
    try {
        $verbose = & wsl.exe -l -v 2>$null
        foreach ($line in @($verbose)) {
            $t = ($line -replace "`0", '').TrimEnd()
            if ($t -match '^\s*\*\s+(\S+)') { $script:EraCmdcDistro = $Matches[1]; break }
        }
    } catch { $script:EraCmdcDistro = $null }
    if (-not $script:EraCmdcDistro) {
        # Fall back to first-listed rather than to nothing: omitting -d entirely
        # would let each call pick independently, which is the failure this
        # function exists to prevent.
        try {
            $raw = & wsl.exe -l -q 2>$null
            $first = @($raw | ForEach-Object { ($_ -replace "`0", '').Trim() } |
                       Where-Object { $_ }) | Select-Object -First 1
            if ($first) { $script:EraCmdcDistro = $first }
        } catch { $script:EraCmdcDistro = $null }
    }
    return $script:EraCmdcDistro
}

function ConvertTo-EraCmdcWslPath {
    <#
    .SYNOPSIS
        `C:\X\Y` -> `/mnt/c/X/Y`, computed locally.

    .DESCRIPTION
        Deliberately not `wslpath`: calling it would need an argument to survive
        the boundary, which is the thing that cannot be relied on. The mapping is
        deterministic for a drive-letter path, and Invoke-EraCmdcRun verifies the
        staged directory is visible before spending a model call on it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WindowsPath)
    $p = $WindowsPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') {
        return ('/mnt/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2])
    }
    return $p
}

function ConvertTo-EraCmdcQuoted {
    <#
    .SYNOPSIS
        One shell-safe single-quoted token, for building script text where there
        is exactly one shell and its rules are known.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Invoke-EraCmdcRun {
    <#
    .SYNOPSIS
        Run a bash script inside WSL, bounded by a deadline. @{ Rc; Out; Err; TimedOut }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptBody,
        [Parameter(Mandatory)][string]$WorkDir,
        [int]$TimeoutSec = 700
    )
    # THE SCRIPT GOES IN ON STDIN, AND NOTHING BUT `bash` CROSSES ON THE
    # COMMAND LINE. Three earlier shapes all failed, each in a different place:
    #
    #   1. the path as a bare argument  -> `$` and `#` in it were shell-parsed
    #      (`era$probe#x` arrived as `era#x`, exit 127). Measured.
    #   2. the path single-quoted       -> fixed that, and BROKE SPACES: .NET
    #      wraps a spaced argument in double quotes of its own, so bash saw
    #      "'...'" and the single quotes became literal. Measured.
    #   3. quoting harder               -> not attempted; two independent quoting
    #      layers compose, and adding a third is how this file got here.
    #
    # With `wsl.exe -- bash` and the body on stdin there is no path, no quoting
    # and no shell parsing to get wrong -- the argument vector is a constant.
    # This is the reviewer's suggestion from the 2026-09-06 round, taken after
    # the cheaper fix was measured and found to move the bug rather than remove
    # it. The seat still gets `< /dev/null` of its own, so it never consumes the
    # script bash is reading.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'wsl.exe'
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $distro = Get-EraCmdcDistro
    if ($distro) { $psi.ArgumentList.Add('-d'); $psi.ArgumentList.Add($distro) }
    $psi.ArgumentList.Add('--')
    $psi.ArgumentList.Add('bash')

    # NO WINDOWS-SIDE ENV SCRUB HERE, BECAUSE IT WOULD DO NOTHING. Windows
    # environment variables do NOT cross into WSL unless named in WSLENV, and
    # WSLENV is unset on this box. Measured 2026-09-06:
    #     CLAUDECODE=1 wsl.exe -- printenv CLAUDECODE   ->   (empty)
    # So removing these from the wsl.exe child's Windows environment is a no-op
    # for the Linux process, and a test asserting it was false assurance. Raised
    # by opus in the review of this file. The scrub that actually bites is the
    # `unset` at the top of the script body (see Invoke-CmdcReview).

    $p = [System.Diagnostics.Process]::Start($psi)
    # LF only: bash rejects CRLF script lines with "\r: command not found".
    $p.StandardInput.Write(($ScriptBody -replace "`r`n", "`n") + "`n")
    $p.StandardInput.Close()
    # Read both streams asynchronously BEFORE waiting. A synchronous
    # ReadToEnd on one stream while the child fills the other deadlocks on the
    # pipe buffer -- the failure mode era's other adapters record at length.
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $exited  = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) {
        try { $p.Kill($true) } catch { }
        $null = $p.WaitForExit(10000)
        return @{ Rc = -1; Out = ''; Err = 'timed out'; TimedOut = $true }
    }
    return @{ Rc = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result; TimedOut = $false }
}

function Get-EraCmdcScriptBody {
    <#
    .SYNOPSIS
        The exact bash the seat runs. Pure: same inputs, same string, no I/O.

    .DESCRIPTION
        EXTRACTED SO IT CAN BE TESTED ON ITS OUTPUT. The tests used to grep this
        file's SOURCE for `--tools-all` and `bash -lc` -- and both strings also
        appear in comments explaining them, so deleting the real flag left every
        test green while every seat silently lost its file-read tool. Raised by
        opus in the 2026-09-04 review of this backend: "these assert a conclusion
        rather than replaying the mechanism".

        ONE SHELL, NOT TWO. An earlier body ended with
            exec bash -lc "exec $CMDC -m $qModel$effort ..."
        which put single-quoted tokens inside a DOUBLE-quoted word, where single
        quotes do not quote and `$`/backticks still expand. Three of four seats
        found it. The login shell was only ever needed for PATH -- cmdc is
        `#!/usr/bin/env node` and node is absent from wsl.exe's non-login PATH --
        so PATH is imported by value and the seat is exec'd directly.
        `bash -l <script>` was rejected: a profile's output would land on the
        seat's STDOUT, which is the review.

        THE ENV SCRUB LIVES HERE, not on the Windows side. Windows variables do
        not cross into WSL unless named in WSLENV (measured: `CLAUDECODE=1
        wsl.exe -- printenv CLAUDECODE` prints nothing), so scrubbing the
        wsl.exe child's environment could never have affected cmdc. `unset` in
        the script does.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StageWsl,
        [Parameter(Mandatory)][string]$ModelId,
        [AllowNull()][string]$Effort
    )
    $qDir    = ConvertTo-EraCmdcQuoted -Value $StageWsl
    $qModel  = ConvertTo-EraCmdcQuoted -Value $ModelId
    $effortA = if ($Effort) { ' --effort ' + (ConvertTo-EraCmdcQuoted -Value $Effort) } else { '' }
    $unset   = 'unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_GIT_BASH_PATH AI_AGENT ANTIGRAVITY_AGENT ANTIGRAVITY_SOURCE_METADATA OPENCODE_YOLO TMUX TMUX_PANE'
    return @"
set -e
$unset
cd $qDir
PATH="`$(bash -lc 'printf %s "`$PATH"')"
export PATH
CMDC=`$(command -v cmdc || true)
if [ -z "`$CMDC" ]; then echo 'era-cmdc: cmdc is not on the login PATH inside WSL' >&2; exit 3; fi
exec "`$CMDC" -m $qModel$effortA -p --tools-all 'Read instructions.md and follow it exactly.' < /dev/null
"@
}

function Invoke-CmdcReview {
    <#
    .SYNOPSIS
        Dispatch one cmdc seat. era's standard adapter contract in and out.

    .DESCRIPTION
        -PidFile is not declared: the child is a short-lived `wsl.exe`, this
        function owns its own deadline and kills its own tree, and a pid written
        for the dispatcher would be dead before it could be used.
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
    $stage    = Join-Path ([System.IO.Path]::GetTempPath()) ("era-cmdc-" + [guid]::NewGuid().ToString('N').Substring(0, 12))

    try {
        New-Item -ItemType Directory -Path $stage -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $BundlePath -Destination (Join-Path $stage 'bundle.xml') -ErrorAction Stop
        $prompt = Get-Content -Raw -LiteralPath $PromptPath
        ($prompt.TrimEnd() + @"


---
The review bundle is the file bundle.xml in your current directory. Read it, then
write your complete review to standard output. Do not create or modify any file.
"@) | Set-Content -LiteralPath (Join-Path $stage 'instructions.md') -Encoding utf8 -ErrorAction Stop

        $stageWsl = ConvertTo-EraCmdcWslPath -WindowsPath $stage
        $qDir     = ConvertTo-EraCmdcQuoted -Value $stageWsl
        $probe = Invoke-EraCmdcRun -WorkDir $stage -TimeoutSec 60 `
                    -ScriptBody "test -d $qDir && echo VISIBLE"
        if ($probe.Out.Trim() -ne 'VISIBLE') {
            # REPORT WHAT ACTUALLY WENT WRONG. This used to discard Rc, Err and
            # TimedOut and blame the directory for every distinct cause -- a
            # missing wsl.exe, a wrong distro, a cold-start over the deadline, a
            # path the shell mangled. One message for four faults sends the
            # reader to the wrong place three times out of four.
            $why = if ($probe.TimedOut) { 'the probe timed out' }
                   else { "rc=$($probe.Rc)" + $(if ($probe.Err.Trim()) { "; stderr: $($probe.Err.Trim())" }) }
            throw "WSL could not confirm the staging directory '$stage' ($why); cmdc is unreachable from here."
        }

        # `--tools-all` is required: a headless run WITHHOLDS tools by default, and
        # this seat's whole job is reading a file off disk.
        $qModel = ConvertTo-EraCmdcQuoted -Value $modelId
        $effort = if ($ModelInfo.cmdc_effort) { " --effort " + (ConvertTo-EraCmdcQuoted -Value $ModelInfo.cmdc_effort) } else { '' }
        $body = Get-EraCmdcScriptBody -StageWsl $stageWsl -ModelId $modelId -Effort $ModelInfo.cmdc_effort
        $r = Invoke-EraCmdcRun -WorkDir $stage -ScriptBody $body -TimeoutSec $TimeoutSec

        if ($r.TimedOut) {
            return @{
                Response = $null; ExitCode = -1; Error = 'cmdc-timeout'; ContentOk = $false
                CaptureMethod = 'cmdc'; InputTokens = $null; OutputTokens = 0
                WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                TruncationWarning = $null; Stderr = $r.Err
                Warnings = @($warnings + "cmdc did not finish within ${TimeoutSec}s and was tree-killed.")
            }
        }
        if ($r.Rc -eq 3) {
            throw "cmdc is not installed inside WSL (it is not on the login PATH); this preset cannot be dispatched."
        }
        # AN UNSUPPORTED --effort IS A PRESET BUG, NOT A MODEL FAILURE, and cmdc
        # is loud about it: exit 1 with "<Model> has no adjustable reasoning
        # effort" on stderr. Measured 2026-09-06 against `longcat` with
        # cmdc_effort=high. Named distinctly so it reads as the registry mistake
        # it is rather than a flaky seat -- and NOT recoverable, because a
        # re-dispatch sends exactly the same unsupported flag.
        #
        # This is the behaviour M9 wanted and opencode does not have: opencode
        # silently ignores an undeclared --variant and runs at default effort
        # while era believes it asked for maximum. cmdc refuses.
        if ($r.Rc -ne 0 -and $r.Err -match 'no adjustable reasoning effort') {
            return @{
                Response = $null; ExitCode = -1; Error = 'cmdc-effort-unsupported'; ContentOk = $false
                CaptureMethod = 'cmdc'; InputTokens = $null; OutputTokens = 0
                WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                TruncationWarning = $null; Stderr = $r.Err
                Warnings = @($warnings + ("preset '$($ModelInfo.preset)' sets cmdc_effort='$($ModelInfo.cmdc_effort)' but $modelId does not support it (" + $r.Err.Trim() + "). Remove cmdc_effort from the preset; a re-dispatch would send the same flag."))
            }
        }
        if ($r.Rc -ne 0) {
            throw "cmdc failed (exit=$($r.Rc), model=$modelId): $($r.Err.Trim())"
        }

        $clean = ($r.Out -replace "`r", '').Trim()

        # cmdc PRINTS ITS EFFORT DECISION on stdout before the answer, and it is
        # not part of the review: "Reasoning effort set to high for X" when the
        # flag applies, "X has no adjustable reasoning effort" when it does not.
        # Both are worth SURFACING rather than discarding -- the second means era
        # asked for something this model cannot do, which on opencode is the
        # silent failure the registry's variant notes exist for.
        $effortNote = $null
        $lines = @($clean -split "`n")
        if ($lines.Count -gt 0 -and $lines[0] -match '^(Reasoning effort set to |.* has no adjustable reasoning effort)') {
            $effortNote = $lines[0].Trim()
            $warnings  += "cmdc: $effortNote"
            $clean = (($lines | Select-Object -Skip 1) -join "`n").Trim()
        }

        $verdict = Test-EraCaptureAcceptable -Response $clean -PromptPath $PromptPath -Vendor 'cmdc'
        if (-not $verdict.Ok) {
            $warnings += $verdict.Warning
            return @{
                Response = $clean; ExitCode = -1; Error = $verdict.Error; ContentOk = $false
                CaptureMethod = 'cmdc'; InputTokens = $null
                OutputTokens = [Math]::Ceiling($clean.Length / 4)
                WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                TruncationWarning = $null; Stderr = $r.Err; Warnings = @($warnings)
            }
        }

        $clean | Set-Content -LiteralPath $ResponsePath -Encoding utf8
        return @{
            Response = $clean; ExitCode = 0; Error = $null; ContentOk = $true
            CaptureMethod = 'cmdc'; InputTokens = $null
            OutputTokens = [Math]::Ceiling($clean.Length / 4)
            WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            TruncationWarning = $null; Stderr = $r.Err; Warnings = @($warnings)
        }
    }
    finally {
        foreach ($attempt in 1..3) {
            if (-not (Test-Path -LiteralPath $stage)) { break }
            try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop }
            catch { Start-Sleep -Milliseconds 400 }
        }
    }
}
