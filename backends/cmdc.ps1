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
    try {
        $raw = & wsl.exe -l -q 2>$null
        $first = @($raw | ForEach-Object { ($_ -replace "`0", '').Trim() } |
                   Where-Object { $_ }) | Select-Object -First 1
        if ($first) { $script:EraCmdcDistro = $first }
    } catch { $script:EraCmdcDistro = $null }
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
    $name = 'era-cmdc-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sh'
    $win  = Join-Path $WorkDir $name
    # LF only: bash rejects CRLF scripts with "\r: command not found", and
    # Set-Content supplies CRLF on Windows.
    [System.IO.File]::WriteAllText($win, ($ScriptBody -replace "`r`n", "`n"))

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'wsl.exe'
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $distro = Get-EraCmdcDistro
    if ($distro) { $psi.ArgumentList.Add('-d'); $psi.ArgumentList.Add($distro) }
    $psi.ArgumentList.Add('--')
    $psi.ArgumentList.Add('bash')
    $psi.ArgumentList.Add((ConvertTo-EraCmdcWslPath -WindowsPath $win))

    foreach ($v in @('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SESSION_ID',
                     'CLAUDE_CODE_GIT_BASH_PATH', 'AI_AGENT', 'ANTIGRAVITY_AGENT',
                     'ANTIGRAVITY_SOURCE_METADATA', 'OPENCODE_YOLO', 'TMUX', 'TMUX_PANE')) {
        $null = $psi.Environment.Remove($v)
    }

    $p = [System.Diagnostics.Process]::Start($psi)
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
            throw "WSL cannot see the staging directory '$stage'; cmdc is unreachable from here."
        }

        # `--tools-all` is required: a headless run WITHHOLDS tools by default, and
        # this seat's whole job is reading a file off disk.
        $qModel = ConvertTo-EraCmdcQuoted -Value $modelId
        $effort = if ($ModelInfo.cmdc_effort) { " --effort " + (ConvertTo-EraCmdcQuoted -Value $ModelInfo.cmdc_effort) } else { '' }
        $body = @"
set -e
cd $qDir
CMDC=`$(bash -lc 'command -v cmdc' 2>/dev/null || true)
if [ -z "`$CMDC" ]; then echo 'era-cmdc: cmdc is not on the login PATH inside WSL' >&2; exit 3; fi
exec bash -lc "exec `$CMDC -m $qModel$effort -p --tools-all 'Read instructions.md and follow it exactly.' < /dev/null"
"@
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
