<#
.SYNOPSIS
    opencode backend adapter for /external-review-auto. Invokes
    `opencode run "<prompt>" -m <model_id> [--variant <v>] -f <bundle>`.
.DESCRIPTION
    - Bundle is ATTACHED via `-f` (the model receives the file content directly in
      its message context; no agentic Read-tool call to refuse / narrate / truncate
      — the false-success root cause). ERA_OPENCODE_READ_TOOL=1 reverts to the old
      Read-tool prompt.
    - Model + variant are selected purely via the `-m` / `--variant` CLI flags.
      Probe-verified (2026-06-04): `opencode run -m <id>` overrides recent[0] and
      does NOT mutate ~/.local/state/opencode/model.json. The old state.json swap +
      Global startup mutex + multi-layer restore + era.ps1 crash-recovery existed
      only to protect/restore a file the run never touches, so they were removed —
      eliminating the mutex-abandonment / restore-race failure modes and letting
      concurrent opencode startups run in parallel.
    - $chosenVariant is still resolved from the registry (passed via --variant and
      used to widen the stall threshold for reasoning-heavy variants).
    - Captured output is routed through the shared non-review detector so a clean
      exit-0 that is actually a refusal/narration fails honestly.
    - Used by presets: minimax, deepseek.
#>

# Shared non-review detector (tool-intent narration / bundle-access refusal).
. (Join-Path $PSScriptRoot '_capture-validation.ps1')

function Set-OpencodeVariantEntry {
    <#
    Option-B INSURANCE (opt-in via ERA_OPENCODE_VARIANT_STATE). The default path
    selects variant via the `--variant` CLI flag (Option A, always also passed).
    If a provider turns out to honor the state-file variant map rather than the
    flag, this ALSO writes variant[provider/model]=$Variant into the user's
    model.json. Returns a restore descriptor for Restore-OpencodeVariantEntry, or
    $null on any failure (best-effort; never throws). A brief Global mutex
    serializes the read-modify-write so concurrent opt-in dispatches don't clobber
    the file. NOTE: this is the only path that touches model.json; with the env
    unset, opencode is fully stateless.
    #>
    [CmdletBinding()]
    param([string]$ModelId, [string]$Variant)
    $statePath = Join-Path $HOME '.local/state/opencode/model.json'
    if (-not (Test-Path $statePath)) { return $null }
    $providerID, $modelIDPart = $ModelId -split '/', 2
    if (-not $providerID -or -not $modelIDPart) { return $null }
    $key = "$providerID/$modelIDPart"
    $mutex = $null; $held = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, 'Global\era-opencode-variant-mutex')
        try { $held = $mutex.WaitOne(15000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { return $null }
        # Capture the EXACT original bytes so Restore is byte-identical -- a
        # ConvertFrom/ConvertTo round-trip reorders keys + reflows whitespace, which
        # would leave the user's model.json semantically equal but byte-different.
        $originalBytes = [System.IO.File]::ReadAllBytes($statePath)
        $state = [System.Text.Encoding]::UTF8.GetString($originalBytes) | ConvertFrom-Json
        if (-not $state.variant) { $state | Add-Member -NotePropertyName variant -NotePropertyValue ([pscustomobject]@{}) -Force }
        if ($null -ne $state.variant.PSObject.Properties[$key]) { $state.variant.$key = $Variant }
        else { $state.variant | Add-Member -NotePropertyName $key -NotePropertyValue $Variant -Force }
        [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
        return @{ statePath = $statePath; originalBytes = $originalBytes }
    } catch { return $null }
    finally { if ($mutex) { if ($held) { try { $mutex.ReleaseMutex() } catch {} }; $mutex.Dispose() } }
}

function Restore-OpencodeVariantEntry {
    <# Undo Set-OpencodeVariantEntry by writing the EXACT original bytes back, under
       the same Global mutex. Byte-identical, best-effort, never throws. (Concurrent
       opt-in dispatches share a brief restore-race window — acceptable for an
       off-by-default insurance path; the values written are deterministic.) #>
    [CmdletBinding()]
    param($Info)
    if (-not $Info -or -not $Info.originalBytes) { return }
    $mutex = $null; $held = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, 'Global\era-opencode-variant-mutex')
        try { $held = $mutex.WaitOne(15000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { return }
        [System.IO.File]::WriteAllBytes($Info.statePath, $Info.originalBytes)
    } catch {} finally { if ($mutex) { if ($held) { try { $mutex.ReleaseMutex() } catch {} }; $mutex.Dispose() } }
}

function Invoke-OpencodeReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)][string]$ResponsePath,
        [Parameter(Mandatory)][hashtable]$ModelInfo,
        [int]$TimeoutSec = 600,
        [string]$AgyModelHint,
        [string]$ModelOverride,
        # Accepted-and-ignored: the dispatcher passes -OpencodeProvider to every
        # adapter uniformly. The provider is derived from the model_id here.
        [string]$OpencodeProvider
    )
    # Bundle access: by default ATTACH the bundle via `-f`. ERA_OPENCODE_READ_TOOL=1
    # rolls back to telling the model to Read the file itself.
    $useReadTool = $env:ERA_OPENCODE_READ_TOOL -and $env:ERA_OPENCODE_READ_TOOL -ne '0' -and $env:ERA_OPENCODE_READ_TOOL -ne 'false'
    $prompt = if ($useReadTool) {
        "Use the Read tool to read the bundle at '$BundlePath'. Review instructions are embedded at the bottom of that file. Output your structured review."
    } else {
        "Review the attached bundle file. Every file under review and the review instructions are INSIDE the attached bundle. Output your structured review directly; do not call any tools."
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stdFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $modelId = if ($ModelOverride) { $ModelOverride } else { $ModelInfo.model_id }

    # --- Variant resolution (registry-driven; NO state.json mutation) ---
    # Pick the strongest declared variant (max -> high -> medium -> low), else
    # 'default'. Passed via --variant and used to tune the stall threshold below.
    # A slash-less / unknown model_id resolves to 'default' gracefully (no throw —
    # the old state-swap crashed on it).
    $providerID, $modelIDPart = $modelId -split '/', 2
    $chosenVariant = 'default'
    $registryPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'backends/_registry.json'
    $modelVariants = @()
    if ($providerID -and (Test-Path $registryPath)) {
        try {
            $registry = Get-Content -Raw $registryPath | ConvertFrom-Json
            if ($registry._opencode_model_map) {
                $providerEntry = $registry._opencode_model_map.$providerID
                if ($providerEntry) {
                    # Scan ALL entries for this model_id and take the longest variants
                    # array (the registry can hold a variant-less alias + a canonical
                    # entry for the same id; iteration order must not decide the winner).
                    foreach ($prop in $providerEntry.PSObject.Properties) {
                        $entry = $prop.Value
                        if ($entry.model_id -eq $modelId) {
                            $thisVariants = @($entry.variants)
                            if ($thisVariants.Count -gt $modelVariants.Count) { $modelVariants = $thisVariants }
                        }
                    }
                }
            }
        } catch {} # registry read failure is non-fatal -> 'default'
    }
    foreach ($preferred in @('max','high','medium','low')) {
        if ($modelVariants -contains $preferred) { $chosenVariant = $preferred; break }
    }

    # Option-B insurance (opt-in): in addition to the --variant flag, also write the
    # variant into the user's state.json. Off by default -> fully stateless. The
    # outer try/finally below guarantees the state entry is restored on every path.
    $useVariantState = $env:ERA_OPENCODE_VARIANT_STATE -and $env:ERA_OPENCODE_VARIANT_STATE -ne '0' -and $env:ERA_OPENCODE_VARIANT_STATE -ne 'false' -and $chosenVariant -ne 'default'
    $variantStateInfo = if ($useVariantState) { Set-OpencodeVariantEntry -ModelId $modelId -Variant $chosenVariant } else { $null }
    if ($variantStateInfo) { Write-Host "[opencode] (insurance) wrote variant=$chosenVariant to state.json for $($variantStateInfo.key)" }

    try {

    # Launch opencode with its own private hidden console. opencode is a TUI binary
    # (Bubble Tea); sharing the parent console lets mouse-tracking + direct console
    # writes leak into the caller's terminal. Resolve to the actual executable:
    # ProcessStartInfo (UseShellExecute=$false) does no PATHEXT search, so a .ps1
    # shim must be swapped for its .cmd sibling.
    $opencodeCli = Get-Command opencode -ErrorAction Stop
    $opencodeExe = if ($opencodeCli.Source -match '\.ps1$') {
        $cmdPath = $opencodeCli.Source -replace '\.ps1$', '.cmd'
        if (-not (Test-Path $cmdPath)) { throw "opencode.cmd not found at $cmdPath" }
        $cmdPath
    } else { $opencodeCli.Source }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $opencodeExe
    # Arg order matters: `-f`/`--file` is a greedy yargs ARRAY, so the message must
    # come FIRST (as the positional) and `-f <bundle>` LAST, or `-f` swallows the
    # prompt as a second file path ("File not found: Review ...") — probe-confirmed.
    $psi.ArgumentList.Add('run')
    $psi.ArgumentList.Add($prompt)
    $psi.ArgumentList.Add('-m')
    $psi.ArgumentList.Add($modelId)
    if ($chosenVariant -ne 'default') {
        $psi.ArgumentList.Add('--variant')
        $psi.ArgumentList.Add($chosenVariant)
    }
    if (-not $useReadTool) {
        $psi.ArgumentList.Add('-f')
        $psi.ArgumentList.Add($BundlePath)
    }
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    # Scrub agent-context env vars from the child's env block. Defensive against
    # recursion guards in opencode (and any aggregator/proxy it spawns).
    # ProcessStartInfo.Environment is per-child -- does not affect parent.
    foreach ($var in @('CLAUDECODE','CLAUDE_CODE_ENTRYPOINT','CLAUDE_CODE_SESSION_ID',
                       'CLAUDE_CODE_GIT_BASH_PATH','AI_AGENT','ANTIGRAVITY_AGENT',
                       'ANTIGRAVITY_SOURCE_METADATA','OPENCODE_YOLO')) {
        if ($psi.Environment.ContainsKey($var)) { $null = $psi.Environment.Remove($var) }
    }

    Write-Host "[opencode] run -m $modelId --variant $chosenVariant (attach=$([bool](-not $useReadTool)))"

    $exitCode = -1
    $clean = $null
    $stderr = ''
    $stdoutSink = $null
    $stderrSink = $null
    $stdoutCopyTask = $null
    $stderrCopyTask = $null
    $opencodeProc = $null

    try {
        $opencodeProc = [System.Diagnostics.Process]::Start($psi)
        # Close stdin immediately -- opencode run reads no context from stdin.
        $opencodeProc.StandardInput.Close()

        # FileShare.ReadWrite (NOT File.Create's default of None) so the stall
        # snapshot's Get-Content can read $stdFile/$errFile while these async copies
        # still hold them.
        $stdoutSink = [System.IO.File]::Open($stdFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $stderrSink = [System.IO.File]::Open($errFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $stdoutCopyTask = $opencodeProc.StandardOutput.BaseStream.CopyToAsync($stdoutSink)
        $stderrCopyTask = $opencodeProc.StandardError.BaseStream.CopyToAsync($stderrSink)

        # Stall detector: poll every 10s; kill if no output growth for the
        # variant-aware threshold OR if the global TimeoutSec is exceeded.
        # Reasoning-heavy variants ('max') can think silently for minutes before the
        # first token, so the base scales with the variant; a bundle-size overlay
        # (20ms/token ~ 50 tok/sec) adds headroom for large bundles. Max of the two.
        $pollMs        = 10000
        $variantBaseMs = switch ($chosenVariant) {
            'max'    { 600000 }
            'high'   { 300000 }
            default  { 120000 }
        }
        $bundleSize       = try { (Get-Item -LiteralPath $BundlePath -ErrorAction Stop).Length } catch { 0 }
        $bundleTokenEst   = [int]($bundleSize / 4)
        $bundleScaledMs   = $bundleTokenEst * 20
        $stallThresholdMs = [Math]::Max($variantBaseMs, $bundleScaledMs)

        # Auto-escalate the global timeout if the stall threshold would otherwise
        # equal/exceed it (else both fire at the same instant and the timeout label
        # wins, mis-attributing a silent-think stall). +30s margin lets the stall
        # throw fire cleanly with the right label.
        $minTimeoutForVariant = [int](($stallThresholdMs / 1000) + 30)
        if ($TimeoutSec -lt $minTimeoutForVariant) {
            Write-Host "[opencode] Escalating timeout from ${TimeoutSec}s to ${minTimeoutForVariant}s (variant=$chosenVariant, bundle=$($bundleTokenEst)tok, stall threshold $($stallThresholdMs/1000)s + 30s margin)."
            $TimeoutSec = $minTimeoutForVariant
        } else {
            Write-Host "[opencode] Stall threshold: $($stallThresholdMs/1000)s (variant=$chosenVariant base=$($variantBaseMs/1000)s, bundle=$($bundleTokenEst)tok scaled=$($bundleScaledMs/1000)s); TimeoutSec=${TimeoutSec}s."
        }
        $lastSize   = $stdoutSink.Length + $stderrSink.Length
        $lastGrowth = [System.Diagnostics.Stopwatch]::StartNew()
        $deadline   = [System.Diagnostics.Stopwatch]::StartNew()
        $exited     = $false

        # Snapshot partial stdout/stderr to a debug dir + return a tail suffix, so a
        # killed stuck process still leaves a forensic clue.
        $snapshotPartialAndDebug = {
            param([string]$prefix)
            $partialOut = (Get-Content -Raw $stdFile -ErrorAction SilentlyContinue)
            $partialErr = (Get-Content -Raw $errFile -ErrorAction SilentlyContinue)
            $cleanOut   = if ($partialOut) { $partialOut -replace '\x1b\[\??[0-9;]*[a-zA-Z]', '' -replace "\r", '' } else { '' }
            $tailOut    = if ($cleanOut) { $cleanOut.Substring([math]::Max(0, $cleanOut.Length - 400)) } else { '<no stdout>' }
            $tailErr    = if ($partialErr) { $partialErr.Substring([math]::Max(0, $partialErr.Length - 400)) } else { '<no stderr>' }
            $debugDir   = Join-Path $env:TEMP 'opencode-stall-debug'
            $stamp      = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-pid$PID"
            try {
                if (-not (Test-Path $debugDir)) { $null = New-Item -ItemType Directory -Path $debugDir -Force }
                Copy-Item $stdFile (Join-Path $debugDir "$prefix-$stamp-stdout.txt") -ErrorAction SilentlyContinue
                Copy-Item $errFile (Join-Path $debugDir "$prefix-$stamp-stderr.txt") -ErrorAction SilentlyContinue
                $existing = @(Get-ChildItem -Path $debugDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
                if ($existing.Count -gt 40) {
                    $existing | Select-Object -Skip 40 | Remove-Item -Force -ErrorAction SilentlyContinue
                }
            } catch {}
            return "Partial stdout (tail): $tailOut --- Partial stderr (tail): $tailErr --- Full partial saved under $debugDir\$prefix-$stamp-*.txt"
        }

        while (-not $exited) {
            $exited = $opencodeProc.WaitForExit($pollMs)
            if ($exited) { break }

            $now = $stdoutSink.Length + $stderrSink.Length
            if ($now -gt $lastSize) {
                $lastSize = $now
                $lastGrowth.Restart()
            }
            if ($lastGrowth.ElapsedMilliseconds -gt $stallThresholdMs) {
                try { $opencodeProc.Kill($true) } catch {}
                $tailInfo = & $snapshotPartialAndDebug 'stall'
                throw "opencode stalled: no output growth for $($stallThresholdMs/1000)s (model=$modelId, variant=$chosenVariant, total wall=$([math]::Round($deadline.Elapsed.TotalSeconds,1))s, total bytes=$lastSize). $tailInfo"
            }
            if ($deadline.Elapsed.TotalSeconds -gt $TimeoutSec) {
                try { $opencodeProc.Kill($true) } catch {}
                $tailInfo = & $snapshotPartialAndDebug 'timeout'
                throw "opencode run exceeded timeout of ${TimeoutSec}s (model=$modelId, variant=$chosenVariant, total bytes=$lastSize). $tailInfo"
            }
        }
        $exitCode = $opencodeProc.ExitCode
    } finally {
        # Defensive tree-kill: if opencode is still alive at cleanup, tear down the
        # whole tree (cmd -> node) so no child is orphaned past this dispatch.
        if ($opencodeProc -and -not $opencodeProc.HasExited) { try { $opencodeProc.Kill($true) } catch {} }
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

    if ($exitCode -ne 0 -or -not $clean) {
        throw "opencode run failed (exit=$exitCode, model=$modelId): $stderr"
    }

    # Honest content validation: even on a clean exit, the capture can be a
    # NON-review (a tool-intent narration or a bundle-access refusal). Flag those
    # and fail honestly instead of recording the garbage as a successful review.
    if (Test-AgenticNarrationCapture -Response $clean) {
        return @{
            Response      = $clean
            ExitCode      = -1
            Error         = 'agentic-narration-capture'
            CaptureMethod = 'direct'
            ContentOk     = $false
            RetryCount    = 0
            RetryReason   = 'agentic-narration-capture'
            InputTokens   = $null
            OutputTokens  = [Math]::Ceiling($clean.Length / 4)
            WallClockSec  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            Stderr        = $stderr
            Warnings      = @('opencode returned a non-review (tool-intent narration / bundle-access refusal); detector fired — re-dispatch to retry.')
        }
    }

    $clean | Set-Content -Path $ResponsePath -Encoding utf8
    return @{
        Response = $clean
        ExitCode = $exitCode
        CaptureMethod = 'direct'
        ContentOk = $true
        InputTokens = $null
        OutputTokens = [Math]::Ceiling($clean.Length / 4)
        WallClockSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Stderr = $stderr
        Warnings = @()
    }

    } finally {
        # Restore the opt-in (Option B) state.json variant entry on every exit path
        # (success, honest-failure return, or throw). No-op when B is disabled.
        if ($variantStateInfo) { Restore-OpencodeVariantEntry -Info $variantStateInfo }
    }
}
