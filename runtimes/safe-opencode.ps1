<#
.SYNOPSIS
    Safely invoke the opencode CLI from a hardened harness. Drop-in
    replacement for `& opencode <args>` that prevents TUI/mouse-tracking
    escape sequences from leaking into the parent terminal.
.DESCRIPTION
    opencode is a Bubble-Tea TUI that writes directly to the console host
    (CONOUT$), bypassing stdout redirection. Calling it via PowerShell's
    call operator (`& opencode ...`) inherits the parent's console and
    lets those direct-console writes pollute whatever terminal hosts the
    parent PowerShell. ProcessStartInfo + CreateNoWindow=$true gives the
    child its own private conhost, isolating it.

    USE THIS instead of `& opencode` from any subagent, debug script, or
    ad-hoc tool call. backends/opencode.ps1 already does the hardening
    inline -- this is for everything outside that adapter.
.PARAMETER OpencodeArgs
    Arguments to pass to opencode, exactly as you'd type them after `opencode`.
    Example: -OpencodeArgs 'run','-m','opencode-go/glm-5.1','Reply with OK'
.PARAMETER TimeoutSec
    Total wall-clock cap. Default 600.
.PARAMETER StallSec
    Kill if no stdout/stderr growth for this many seconds. Default 120.
.PARAMETER Quiet
    Suppress heartbeat log lines.
.EXAMPLE
    & ~/.claude/skills/external-review-auto/runtimes/safe-opencode.ps1 `
        -OpencodeArgs 'run','-m','opencode-go/deepseek-v4-flash','Reply with OK only.'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$OpencodeArgs,
    [int]$TimeoutSec = 600,
    [int]$StallSec   = 120,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$sw      = [System.Diagnostics.Stopwatch]::StartNew()
$stdFile = [System.IO.Path]::GetTempFileName()
$errFile = [System.IO.Path]::GetTempFileName()

# --- Locate opencode CLI ---
# ProcessStartInfo with UseShellExecute=$false does not do PATHEXT search.
# opencode is typically an npm-installed CLI with a .cmd shim alongside the .ps1;
# prefer the .cmd (or .exe if present in some distributions).
$opencodeCli = Get-Command opencode -ErrorAction Stop
$opencodeExe = if ($opencodeCli.Source -match '\.ps1$') {
    $cmdPath = $opencodeCli.Source -replace '\.ps1$', '.cmd'
    if (-not (Test-Path $cmdPath)) { throw "opencode.cmd not found at $cmdPath" }
    $cmdPath
} else { $opencodeCli.Source }

# --- Build ProcessStartInfo ---
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $opencodeExe
foreach ($arg in $OpencodeArgs) { $psi.ArgumentList.Add($arg) }
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true
$psi.RedirectStandardInput  = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true

# Scrub agent-context env vars from the child's env block. Defensive against
# potential recursion guards in opencode (and any aggregator/proxy it spawns).
# ProcessStartInfo.Environment is per-child -- does not affect parent.
foreach ($var in @('CLAUDECODE','CLAUDE_CODE_ENTRYPOINT','CLAUDE_CODE_SESSION_ID',
                   'CLAUDE_CODE_GIT_BASH_PATH','AI_AGENT','ANTIGRAVITY_AGENT',
                   'ANTIGRAVITY_SOURCE_METADATA','OPENCODE_YOLO')) {
    if ($psi.Environment.ContainsKey($var)) { $null = $psi.Environment.Remove($var) }
}

$exitCode       = -1
$stdoutBytes    = 0
$stderrBytes    = 0
$stdoutSink     = $null
$stderrSink     = $null
$stdoutCopyTask = $null
$stderrCopyTask = $null
$opencodeProc   = $null

try {
    $opencodeProc = [System.Diagnostics.Process]::Start($psi)

    # Close stdin immediately -- opencode run reads no input from stdin.
    $opencodeProc.StandardInput.Close()

    $stdoutSink     = [System.IO.File]::Create($stdFile)
    $stderrSink     = [System.IO.File]::Create($errFile)
    $stdoutCopyTask = $opencodeProc.StandardOutput.BaseStream.CopyToAsync($stdoutSink)
    $stderrCopyTask = $opencodeProc.StandardError.BaseStream.CopyToAsync($stderrSink)

    # Startup heartbeat: poll up to 5s for first stdout/stderr byte.
    $startSw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($startSw.ElapsedMilliseconds -lt 5000 -and
           $stdoutSink.Length -eq 0 -and $stderrSink.Length -eq 0 -and
           -not $opencodeProc.HasExited) {
        Start-Sleep -Milliseconds 100
    }
    $heartbeatMs = $startSw.ElapsedMilliseconds
    $sawOutput   = ($stdoutSink.Length -gt 0 -or $stderrSink.Length -gt 0)
    if (-not $Quiet) {
        Write-Host "[safe-opencode] startup heartbeat: ${heartbeatMs}ms (output=$sawOutput exited=$($opencodeProc.HasExited))"
    }

    # Stall detector: poll every 10s, kill if no output growth for $StallSec
    # seconds OR if $TimeoutSec total wall exceeded.
    $pollMs           = 10000
    $stallThresholdMs = $StallSec * 1000
    $lastSize         = $stdoutSink.Length + $stderrSink.Length
    $lastGrowth       = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline         = [System.Diagnostics.Stopwatch]::StartNew()
    $exited           = $false

    while (-not $exited) {
        $exited = $opencodeProc.WaitForExit($pollMs)
        if ($exited) { break }

        $now = $stdoutSink.Length + $stderrSink.Length
        if ($now -gt $lastSize) {
            $lastSize = $now
            $lastGrowth.Restart()
        }
        if ($lastGrowth.ElapsedMilliseconds -gt $stallThresholdMs) {
            try { $opencodeProc.Kill() } catch {}
            throw "opencode stalled: no output growth for ${StallSec}s (total wall=$([math]::Round($deadline.Elapsed.TotalSeconds,1))s, total bytes=$lastSize)"
        }
        if ($deadline.Elapsed.TotalSeconds -gt $TimeoutSec) {
            try { $opencodeProc.Kill() } catch {}
            throw "opencode run exceeded timeout of ${TimeoutSec}s (total bytes=$lastSize)"
        }
    }
    $exitCode = $opencodeProc.ExitCode

} finally {
    try { $null = $stdoutCopyTask.Wait(2000) } catch {}
    try { $null = $stderrCopyTask.Wait(2000) } catch {}
    try { $stdoutSink.Dispose() } catch {}
    try { $stderrSink.Dispose() } catch {}

    $stdoutRaw = (Get-Content -Raw $stdFile -ErrorAction SilentlyContinue)
    if (-not $stdoutRaw) { $stdoutRaw = '' }
    $stderrRaw = (Get-Content -Raw $errFile -ErrorAction SilentlyContinue)
    if (-not $stderrRaw) { $stderrRaw = '' }

    $stdoutBytes = [System.Text.Encoding]::UTF8.GetByteCount($stdoutRaw)
    $stderrBytes = [System.Text.Encoding]::UTF8.GetByteCount($stderrRaw)

    # Strip ANSI escape sequences from stdout for clean output
    $stdoutClean = $stdoutRaw -replace '\x1b\[\??[0-9;]*[a-zA-Z]', '' -replace "\r", ''

    Remove-Item $stdFile -ErrorAction SilentlyContinue
    Remove-Item $errFile -ErrorAction SilentlyContinue
    $sw.Stop()
}

# Write stdout to pipeline unless suppressed
if (-not $Quiet -and $stdoutClean) {
    Write-Output $stdoutClean
}

# Return structured result
[PSCustomObject]@{
    Stdout       = $stdoutClean
    Stderr       = $stderrRaw
    ExitCode     = $exitCode
    WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    OutputBytes  = $stdoutBytes + $stderrBytes
}
