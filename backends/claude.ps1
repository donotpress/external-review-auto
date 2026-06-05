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
        [string]$OpencodeProvider
    )
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
        if (-not (Test-Path $cmdPath)) { throw "claude.cmd not found at $cmdPath" }
        $cmdPath
    } else { $claudeCli.Source }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $claudeExe
    $psi.ArgumentList.Add('--print')
    $psi.ArgumentList.Add('--model')
    $psi.ArgumentList.Add($modelId)
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
    $stderr = ''
    $stdoutSink = $null
    $stderrSink = $null
    $stdinCopyTask = $null
    $stdoutCopyTask = $null
    $stderrCopyTask = $null
    $claudeProc = $null

    try {
        $claudeProc = [System.Diagnostics.Process]::Start($psi)

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
            $null = $stdinCopyTask.Wait($TimeoutSec * 1000)
        } finally {
            $bundleStream.Dispose()
            $claudeProc.StandardInput.Close()
        }

        if (-not $claudeProc.WaitForExit($TimeoutSec * 1000)) {
            # Kill($true): tear down the whole tree. claude is a shim (cmd -> node);
            # a bare Kill() would orphan the node child.
            try { $claudeProc.Kill($true) } catch {}
            throw "claude CLI exceeded timeout of ${TimeoutSec}s (model=$modelId)"
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

        $resultText = (Get-Content -Raw $stdFile -ErrorAction SilentlyContinue)
        if (-not $resultText) { $resultText = '' }
        $stderr = (Get-Content -Raw $errFile -ErrorAction SilentlyContinue)
        if (-not $stderr) { $stderr = '' }
        $clean = $resultText -replace '\x1b\[\??[0-9;]*[a-zA-Z]', '' -replace "\r", ''

        Remove-Item $stdFile -ErrorAction SilentlyContinue
        Remove-Item $errFile -ErrorAction SilentlyContinue
        $sw.Stop()
    }

    # Truncation detection: scan stderr for precisely-anchored phrases that
    # claude CLI emits on context-window-exceeded / output-truncated.
    # See Test-ClaudeTruncation for the pattern list and rationale.
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

    if ($exitCode -ne 0 -or -not $clean) {
        throw "claude CLI failed (exit=$exitCode, model=$modelId): $stderr"
    }
    $clean | Set-Content -Path $ResponsePath -Encoding utf8
    return @{
        Response = $clean
        ExitCode = $exitCode
        CaptureMethod = 'direct'
        InputTokens = $null
        OutputTokens = [Math]::Ceiling($clean.Length / 4)
        WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        TruncationWarning = $truncationWarning
        Stderr = $stderr
        Warnings = @()
    }
}