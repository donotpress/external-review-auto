<#
 Module: telemetry -- cost, doctor, exposure, reviewer-list, round rendering.
 Part of the workflow.ps1 split (see docs/specs/2026-09-12-era-module-boundaries.md).
 Dot-sourced by workflow.ps1; never loaded directly (no independent state).
#>

function Get-ForceMode {
    $force = $env:ERA_FORCE -and `
             $env:ERA_FORCE -ne '0' -and `
             $env:ERA_FORCE -ne 'false'
    return [bool]$force -or `
           ($host.Name -notmatch 'ConsoleHost|Visual Studio') -or `
           (-not [Environment]::UserInteractive)
}

function ConvertTo-EraNativePath {
    <# Rewrite a leading Git-Bash/MSYS drive prefix (/c/foo) to native Windows
       (C:/foo) so -IncludeFiles works when invoked from bash on Windows. Pure,
       idempotent; non-MSYS and relative paths pass through unchanged. #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    # Windows only — on Linux, /c/lib/x is a legitimate absolute path, not an MSYS drive.
    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) { return $Path }
    if ($Path -match '^/([A-Za-z])/(.*)$') { return "$($Matches[1].ToUpper()):/$($Matches[2])" }
    return $Path
}

function Resolve-EraAuthJsonKeys {
    <#
      For each requested api_key_env that is NOT already set in the process env,
      source the key from opencode's auth.json (subscription providers only) and
      set it in the PROCESS env so the existing env-based adapters + availability
      checks work unchanged. Additive + safe: only fills empties, only known
      providers, never overwrites an existing env var.
    #>
    param(
        [string[]]$ApiKeyEnvs,
        [string]$AuthPath = (Join-Path $HOME '.local/share/opencode/auth.json')
    )
    $map = @{ 'OPENCODE_API_KEY' = 'opencode-go'; 'MINIMAX_API_KEY' = 'minimax'; 'NVIDIA_API_KEY' = 'nvidia' }
    if (-not (Test-Path -LiteralPath $AuthPath)) { return }
    # A corrupt file behaves like a missing one (skip), never fails the round:
    # ConvertFrom-Json throws terminating on malformed input, and this runs
    # pre-dispatch where there is nothing to recover with.
    try { $auth = Get-Content -LiteralPath $AuthPath -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch { return }
    foreach ($envName in ($ApiKeyEnvs | Where-Object { $_ } | Select-Object -Unique)) {
        if ([Environment]::GetEnvironmentVariable($envName)) { continue }
        $prov = $map[$envName]
        if (-not $prov) { continue }
        $entry = $auth.$prov
        if ($entry -and $entry.type -eq 'api' -and $entry.key) {
            [Environment]::SetEnvironmentVariable($envName, $entry.key)  # process scope only
        }
    }
}

function Get-ResponseFilenameSuffix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ReviewerList,
        [Parameter(Mandatory)][string]$Preset
    )
    # Single-reviewer runs always produce clean `round-N-response.md` regardless
    # of preset. Previously this only worked for 'gemini'; any other single-
    # reviewer run got `round-N-<preset>-response.md`, breaking downstream
    # scripts expecting a unified filename.
    if ($ReviewerList.Count -eq 1) { return '' }
    return "-$Preset"
}

function Get-PerReviewerCap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Pricing,
        [double]$CheapCap = 2.0,
        [double]$ExpensiveCap = 10.0
    )
    if ($Pricing.input_per_m -ge 10.0) { return $ExpensiveCap }
    return $CheapCap
}

function Test-AggregateCostCap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$TotalEstCost,
        [double]$AggregateCap = 15.0
    )
    return ($TotalEstCost -gt $AggregateCap)
}

function Get-EraCostReport {
    <#
    .SYNOPSIS
        The round's cost estimate, always. Returns
        @{ Lines; Warnings; OverCap } -- never blocks, never prompts.

    .DESCRIPTION
        Invoke-CostPrompt returns the full reviewer list immediately when
        Get-ForceMode is true, with NO cap check. Get-ForceMode is true when
        -Force is passed OR when the host is non-interactive -- and SKILL.md
        instructs the driving LLM to always pass -Force. So the $2/$10
        per-reviewer caps and the $15 aggregate cap never fired in the documented
        usage: they are enforced through a prompt that is always skipped. The
        fallback's own cap check is NOT force-gated, so the recovery dispatch was
        capped while the dispatch it recovers from was not.

        Decision 2026-08-11: report loudly, never block. Measured across 43
        recorded rounds -- worst round $1.76 against the $15 aggregate cap, worst
        single reviewer $1.71 against its $10 cap, zero breaches ever -- a
        ceiling would have bought nothing while a wrong one could refuse a
        legitimate large round. Visibility was the real gap.

        THOSE FIGURES ARE IN ESTIMATE-UNITS, and the estimate was later measured
        ~3.2x low (docs/assessments/2026-09-06-era-cost-estimates-vs-vendor-truth.md:
        reasoning tokens and agentic tool turns never reach the response text this
        derives from). Corrected, the worst round is ~$5.6 against $15 and the
        worst reviewer ~$5.5 against $10 -- so the decision SURVIVES its own
        correction, with less headroom than it looked. Anyone re-deriving a safety
        margin from $1.76 will be about 3x optimistic. The 2026-08-11 reading that
        "visibility was the real gap" turned out to be more right than it knew.

        Call this UNCONDITIONALLY, before Invoke-CostPrompt, so the numbers are
        on the record whether or not the gate runs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReviewerList,
        [Parameter(Mandatory)][hashtable]$PerReviewerCosts,
        [Parameter(Mandatory)][hashtable]$PerReviewerCaps,
        [Parameter(Mandatory)][double]$AggregateCost,
        [double]$AggregateCap = 15.0
    )
    $lines    = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $overCap  = [System.Collections.Generic.List[string]]::new()

    if (@($ReviewerList).Count -eq 0) {
        return @{ Lines = @(); Warnings = @(); OverCap = @() }
    }

    $parts = foreach ($r in $ReviewerList) {
        $c = $PerReviewerCosts[$r]
        if ($null -eq $c) { "{0} ~unknown" -f $r } else { "{0} ~`${1}" -f $r, [Math]::Round([double]$c, 4) }
    }
    $lines.Add("[era] Estimated: " + ($parts -join ' | ') + (" (round ~`${0})" -f [Math]::Round($AggregateCost, 4)))
    # SAY WHAT THE NUMBER OMITS, WHERE THE NUMBER IS SHOWN. Measured 2026-09-06
    # across 12 seats against the vendors' own records: era's estimate ran ~3.2x
    # low ($0.5651 estimated vs $1.8107 recorded), because output is estimated
    # from the FINAL RESPONSE'S CHARACTERS and that misses two whole categories --
    # 126,912 reasoning/thinking tokens, and the agentic tool-call turns that
    # never reach the response file. Per-seat: deepseek-flash 5.5-11.2x,
    # muse-spark 2.5-4.5x, opus 2.9-3.3x.
    #
    # No multiplier is applied here. The sample is n=4 per model, `agy` has no
    # readable vendor record at all, and a guessed correction would be a second
    # unmeasured number stacked on the first. What is fixed is the CLAIM: the
    # line no longer reads as the bill.
    # Full method and caveats: docs/assessments/2026-09-06-era-cost-estimates-vs-vendor-truth.md
    # Re-measure any round with: tools/token-truth.py <review-dir> <round>
    $lines.Add("[era] NOTE: that estimate counts the response text only. Reasoning tokens and agentic tool-call turns are invisible to it; measured ~3.2x low over 12 seats (worst 11.2x), so treat it as a floor.")

    foreach ($r in $ReviewerList) {
        $c = $PerReviewerCosts[$r]
        $cap = $PerReviewerCaps[$r]
        # PowerShell coerces $null -le N to $true, which would silently pass an
        # unknown estimate. Treat unknown as unbounded, exactly as the gate does.
        if ($null -eq $c)   { $c = [double]::PositiveInfinity }
        if ($null -eq $cap) { $cap = 0.0 }
        if ($c -gt $cap) {
            $overCap.Add($r)
            $shown = if ([double]::IsInfinity($c)) { 'unknown' } else { "`$$([Math]::Round([double]$c,4))" }
            $warnings.Add("[era] WARNING: reviewer '$r' estimated $shown exceeds its `$$cap cap; proceeding (cost caps are advisory under -Force).")
        }
    }
    if ($AggregateCost -gt $AggregateCap) {
        $warnings.Add("[era] WARNING: round total ~`$$([Math]::Round($AggregateCost,4)) exceeds the `$$AggregateCap aggregate cap; proceeding (advisory under -Force).")
    }
    return @{ Lines = @($lines); Warnings = @($warnings); OverCap = @($overCap) }
}

function Invoke-CostPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ReviewerList,
        [Parameter(Mandatory)][hashtable]$PerReviewerCosts,
        [Parameter(Mandatory)][double]$AggregateCost,
        [Parameter(Mandatory)][hashtable]$PerReviewerCaps,
        [Parameter(Mandatory)][double]$AggregateCap = 15.0
    )
    if (Get-ForceMode) { return $ReviewerList }

    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $ReviewerList) {
        $cost = $PerReviewerCosts[$r]
        $cap  = $PerReviewerCaps[$r]
        # PowerShell coerces $null -le N to $true (treats null as 0), which
        # silently bypasses the cap for any reviewer missing a cost estimate.
        # Treat null as infinite so the user is explicitly prompted.
        if ($null -eq $cost) { $cost = [double]::PositiveInfinity }
        if ($null -eq $cap) { $cap = 0.0 }
        if ($cost -le $cap) { $kept.Add($r); continue }
        $resp = Read-Host "Reviewer '$r' exceeds cap (`$$cost > `$$cap). Continue? [y/N/d=drop]"
        switch ($resp.ToLower()) {
            'y' { $kept.Add($r) }
            'd' { }
            default { throw "User aborted at per-reviewer cap for '$r'." }
        }
    }
    $survivorAgg = ($kept | ForEach-Object { $PerReviewerCosts[$_] } | Measure-Object -Sum).Sum
    # Measure-Object -Sum over an empty set yields $null, which cannot bind to
    # Test-AggregateCostCap's [double]. Coerce here; the comparison was already
    # false for $null, so behaviour is unchanged.
    if ($null -eq $survivorAgg) { $survivorAgg = 0.0 }
    # Use the shared predicate rather than repeating it. It was defined and
    # called from nowhere -- two copies of one rule is how they drift apart.
    if (Test-AggregateCostCap -TotalEstCost $survivorAgg -AggregateCap $AggregateCap) {
        $resp = Read-Host "Total estimated cost across $($kept.Count) reviewer(s) is `$$survivorAgg (> `$$AggregateCap). Continue? [y/N]"
        if ($resp.ToLower() -ne 'y') {
            throw "User aborted at aggregate cap."
        }
    }
    return $kept.ToArray()
}

function Test-EraBackendAvailable {
    <# Is a preset's backend usable right now? CLI backends need the binary on PATH;
       REST backends need their API-key env var set. Resolvers injectable for tests. #>
    [CmdletBinding()]
    param(
        [string]$Backend,
        [string]$ApiKeyEnv,
        [scriptblock]$CommandExists = { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) },
        [scriptblock]$EnvValue      = { param($n) [Environment]::GetEnvironmentVariable($n) }
    )
    switch ($Backend) {
        'agy'          { return [bool](& $CommandExists 'agy') }
        'claude'       { return [bool](& $CommandExists 'claude') }
        'opencode'     { return [bool](& $CommandExists 'opencode') }
        'geminiapi'    { return [bool](& $EnvValue 'GEMINI_API_KEY') }
        'anthropic'    { return [bool](& $EnvValue 'ANTHROPIC_API_KEY') }
        'openaicompat' { if (-not $ApiKeyEnv) { return $false }; return [bool](& $EnvValue $ApiKeyEnv) }
        default        { return $false }
    }
}

function Get-EraReviewerList {
    <# Pure: rows of selectable reviewer presets with live readiness. Resolvers
       injectable for tests (mirrors Get-EraDoctorReport). #>
    [CmdletBinding()]
    param(
        $Registry,
        [string]$Default,
        [scriptblock]$CommandExists = { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) },
        [scriptblock]$EnvValue      = { param($n) [Environment]::GetEnvironmentVariable($n) }
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $Registry.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        $b = $p.Value.backend
        if (-not $b) { continue }
        $ready = Test-EraBackendAvailable -Backend $b -ApiKeyEnv $p.Value.api_key_env `
            -CommandExists $CommandExists -EnvValue $EnvValue
        $req = switch ($b) {
            'agy'          { 'agy CLI' }
            'claude'       { 'claude CLI' }
            'opencode'     { 'opencode CLI' }
            'geminiapi'    { 'GEMINI_API_KEY' }
            'anthropic'    { 'ANTHROPIC_API_KEY' }
            'openaicompat' { "$($p.Value.api_key_env)" }
            default        { '' }
        }
        $rows.Add([pscustomobject]@{
            preset = $p.Name; backend = $b; ready = [bool]$ready
            model = "$($p.Value.model_id)"; requirement = $req
            is_default = ($p.Name -eq $Default)
        })
    }
    return $rows.ToArray()
}

function Format-EraReviewerList {
    <# Render Get-EraReviewerList rows grouped by backend. Pure. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Rows, [string]$Default)
    $order = @('agy','claude','opencode','openaicompat','geminiapi','anthropic')
    $label = @{ agy='agy (Gemini, subscription)'; claude='claude CLI (subscription)';
        opencode='opencode (TUI)'; openaicompat='REST / opencode HTTP (API key or auth.json)';
        geminiapi='Gemini REST (API key)'; anthropic='Anthropic REST (API key)' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Reviewers ([x] = ready now)'); $lines.Add('')
    $allBackends = @($order) + @($Rows | Select-Object -ExpandProperty backend) | Select-Object -Unique
    foreach ($b in $allBackends) {
        $group = @($Rows | Where-Object { $_.backend -eq $b })
        if (-not $group) { continue }
        $head = $label[$b]; if (-not $head) { $head = $b }
        $lines.Add($head)
        foreach ($r in $group) {
            $mark = if ($r.ready) { '[x]' } else { '[ ]' }
            $line = "  $mark $($r.preset)"
            if ($r.model)      { $line += "  ($($r.model))" }
            if ($r.is_default) { $line += '  [default]' }
            if (-not $r.ready -and $r.requirement) { $line += "  -> needs $($r.requirement)" }
            $lines.Add($line)
        }
        $lines.Add('')
    }
    $defLabel = if ($Default) { $Default } else { '(none ready)' }
    $lines.Add("Default: $defLabel   .   change: /era set default <name>")
    return ($lines -join "`n")
}

function Resolve-DefaultReviewer {
    <#
    .SYNOPSIS
        Pick the first AVAILABLE reviewer preset by preference (live-detected), so a
        bare /era adapts to what the user has installed instead of blindly defaulting
        to agy and erroring. Returns the preset name, or $null if none is available.
    .DESCRIPTION
        Availability is detected live (PATH / env var) every call — no cached state
        file to go stale when a CLI is installed/removed. The preference order is
        overridable (era.ps1 prepends $env:ERA_DEFAULT_REVIEWER).
    #>
    [CmdletBinding()]
    param(
        $Registry,
        [string[]]$Preference = @('gemini-pro-low', 'sonnet', 'deepseek', 'gemini-api'),
        [scriptblock]$CommandExists = { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) },
        [scriptblock]$EnvValue      = { param($n) [Environment]::GetEnvironmentVariable($n) }
    )
    foreach ($preset in $Preference) {
        $entry = $Registry.$preset
        if (-not $entry -or -not $entry.backend) { continue }
        if (Test-EraBackendAvailable -Backend $entry.backend -ApiKeyEnv $entry.api_key_env `
                -CommandExists $CommandExists -EnvValue $EnvValue) {
            return $preset
        }
    }
    return $null
}

function Get-EraDoctorReport {
    <#
    .SYNOPSIS
        Preflight: gather a structured prereq report (core deps + per-backend
        requirements derived from the registry). No side effects, no install.
    .DESCRIPTION
        Resolvers are injectable (CommandExists / ModuleExists / EnvValue) so the
        whole check set is unit-testable without touching the real PATH/modules/env.
        Each row: @{ name; category('core'|'backend'); required; ok; detail; fix; unlocks }.
    #>
    [CmdletBinding()]
    param(
        $Registry,
        [scriptblock]$CommandExists = { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) },
        [scriptblock]$ModuleExists  = { param($n) [bool](Get-Module -ListAvailable -Name $n -ErrorAction SilentlyContinue) },
        [scriptblock]$EnvValue      = { param($n) [Environment]::GetEnvironmentVariable($n) }
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    $row = {
        param($name, $category, $required, $ok, $detail, $fix, $unlocks)
        $rows.Add([pscustomobject]@{
            name = $name; category = $category; required = [bool]$required
            ok = [bool]$ok; detail = $detail; fix = $fix; unlocks = $unlocks
        })
    }

    # --- Core prerequisites ---
    & $row 'PowerShell 7+' 'core' $true ($PSVersionTable.PSVersion.Major -ge 7) "v$($PSVersionTable.PSVersion)" 'winget install Microsoft.PowerShell  (macOS: brew install powershell)' $null
    # Probe the COMMAND, not the module name. PS 7.4+ ships it as
    # Microsoft.PowerShell.ThreadJob, so Get-Module -Name ThreadJob reported
    # MISS on a ready machine (2026-09-08); Get-Command auto-loads from either
    # name, same as the Test-ThreadJobAvailable dispatch guard below.
    & $row 'ThreadJob (Start-ThreadJob)' 'core' $true (& $CommandExists 'Start-ThreadJob') $null 'Install-Module -Name Microsoft.PowerShell.ThreadJob -Force -Scope CurrentUser' $null
    & $row 'repomix' 'core' $true (& $CommandExists 'repomix') $null 'npm install -g repomix' $null
    & $row 'git (optional: -AutoDetect / -Diff)' 'core' $false (& $CommandExists 'git') $null 'install git from https://git-scm.com (optional)' $null

    # --- Backend requirements (distinct, derived from the registry presets) ---
    $cliFor = @{ agy = 'agy'; claude = 'claude'; opencode = 'opencode' }
    $envFor = @{ geminiapi = 'GEMINI_API_KEY'; anthropic = 'ANTHROPIC_API_KEY' }
    $seen = [ordered]@{}   # requirement-key -> @{ kind; name; presets }
    foreach ($p in $Registry.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        $backend = $p.Value.backend
        if (-not $backend) { continue }
        $kind = $null; $reqName = $null
        if ($cliFor.ContainsKey($backend))      { $kind = 'cli'; $reqName = $cliFor[$backend] }
        elseif ($envFor.ContainsKey($backend))  { $kind = 'env'; $reqName = $envFor[$backend] }
        elseif ($backend -eq 'openaicompat')    { $kind = 'env'; $reqName = $p.Value.api_key_env }
        if (-not $kind -or -not $reqName) { continue }
        $key = "${kind}:${reqName}"
        if (-not $seen.Contains($key)) { $seen[$key] = @{ kind = $kind; name = $reqName; presets = [System.Collections.Generic.List[string]]::new() } }
        $seen[$key].presets.Add($p.Name)
    }
    foreach ($key in $seen.Keys) {
        $req = $seen[$key]
        $unlocks = (@($req.presets) -join ', ')
        if ($req.kind -eq 'cli') {
            & $row "$($req.name) CLI" 'backend' $false (& $CommandExists $req.name) $null "install the $($req.name) CLI and sign in (CLI presets reuse your existing login)" $unlocks
        } else {
            & $row $req.name 'backend' $false ([bool](& $EnvValue $req.name)) $null "set `$env:$($req.name) (get a key from the provider console)" $unlocks
        }
    }
    return $rows.ToArray()
}

function Format-EraDoctorReport {
    <# Render a Get-EraDoctorReport result as a human report + readiness verdict.
       Ready == all required core checks pass AND >=1 backend is available. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Checks)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('=== /era preflight (Doctor) ===')
    $lines.Add('')
    foreach ($c in $Checks) {
        $mark = if ($c.ok) { '[ OK ]' } elseif ($c.required) { '[MISS]' } else { '[ -- ]' }
        $line = "$mark $($c.name)"
        if ($c.detail)  { $line += "  ($($c.detail))" }
        if ($c.unlocks) { $line += "  -> unlocks: $($c.unlocks)" }
        $lines.Add($line)
        if (-not $c.ok -and $c.fix) { $lines.Add("        fix: $($c.fix)") }
    }
    $coreReq = @($Checks | Where-Object { $_.category -eq 'core' -and $_.required })
    $coreOk  = ($coreReq.Count -gt 0) -and (@($coreReq | Where-Object { $_.ok }).Count -eq $coreReq.Count)
    $working = @($Checks | Where-Object { $_.category -eq 'backend' -and $_.ok })
    $lines.Add('')
    if ($coreOk -and $working.Count -ge 1) {
        $lines.Add("READY. Core prereqs present; $($working.Count) backend(s) available: $((@($working | ForEach-Object { $_.name }) -join ', '))")
    } else {
        $need = @()
        if (-not $coreOk)          { $need += 'the [MISS] core prereq(s) above' }
        if ($working.Count -lt 1)  { $need += 'at least one backend (install a CLI or set an API key above)' }
        $lines.Add("NOT READY -- need: $($need -join '; ')")
    }
    return ($lines -join "`n")
}

function Format-EraRoundSummary {
    <#
    .SYNOPSIS
        The end-of-round `Done. ...` line: slowest seat time + token count.
    .DESCRIPTION
        This used to print the FIRST hashtable value's WallClockSec under the
        name `Wall clock` -- one arbitrary seat's time (hashtable order is not
        dispatch order) wearing a round-level label, off ~6x on the round that
        named it (119.7s for a 720s+ dispatch, 2026-09-08). The dispatcher's
        own elapsed is the round's wall clock and already prints per-heartbeat
        as `[dispatch] Ns elapsed`; this line claims only what it measures:
        the slowest seat that reported a time. Seats with no WallClockSec
        (abandoned stragglers, timeout synthetics) are ignored; when none
        reported, returns $null and the caller prints nothing (as before).
    #>
    [CmdletBinding()]
    param($Results, [int]$TokenCount = 0)
    $secs = @(@($Results.Values) | ForEach-Object { $_.WallClockSec } | Where-Object { $_ })
    if ($secs.Count -eq 0) { return $null }
    $max = ($secs | Measure-Object -Maximum).Maximum
    return "Done. Slowest seat: ${max}s | Tokens: $TokenCount"
}

function Format-EraRoundHealth {
    <#
    .SYNOPSIS
        One round-health line: seats ok, per-seat cause, fallback if one ran.
    .DESCRIPTION
        ADDITIVE by design (muse-spark review): the six assembled log lines it
        summarises stay exactly where they are until proven unparsed. "ok"
        here means ExitCode 0 (the formal usable-count lives in the void
        report, which keys on artifacts, not exit codes); anything else shows
        the seat's Error, or 'unknown' when even that is absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Results,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReviewerList,
        [string]$FallbackPreset
    )
    $parts = foreach ($r in @($ReviewerList)) {
        $res = $null
        if ($Results -is [hashtable]) { $res = $Results[$r] }
        $state = 'unknown'
        if ($res) {
            if ($res.ExitCode -eq 0) { $state = 'ok' }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$res.Error)) { $state = [string]$res.Error }
        }
        "${r}: $state"
    }
    $okCount = @(@($ReviewerList) | Where-Object {
        ($Results -is [hashtable]) -and $Results[$_] -and $Results[$_].ExitCode -eq 0
    }).Count
    $fb = if ($FallbackPreset) { "; fallback: $FallbackPreset" } else { '' }
    return "[era] Round health: $okCount/$(@($ReviewerList).Count) ok ($($parts -join '; '))$fb"
}

function Get-EraExposureReport {
    <#
    .SYNOPSIS
        What source left this machine, to whom, when: one row per built round.
    .DESCRIPTION
        Reads round-*-manifest.json receipts under .external-reviews/ (plus a
        round-*-metadata.json sibling when present, to resolve requested
        presets to backend/model). READ-ONLY: no dispatch, no round allocation,
        no manifest writes, so it is safe beside a round in flight. A corrupt
        receipt is skipped, never fatal: one bad file must not hide the rest.
        Rows carry the full head sha; the renderer shortens it for display.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$TopicSlug
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    $root = Join-Path $RepoRoot '.external-reviews'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    foreach ($topicDir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        if ($TopicSlug -and $topicDir.Name -ne $TopicSlug) { continue }
        foreach ($mf in @(Get-ChildItem -LiteralPath $topicDir.FullName -Filter 'round-*-manifest.json' -File -ErrorAction SilentlyContinue)) {
            if ($mf.Name -notmatch '^round-(\d+)-manifest\.json$') { continue }
            $round = [int]$matches[1]
            try { $m = Get-Content -Raw -LiteralPath $mf.FullName -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
            catch { continue }
            # ConvertFrom-Json parses ISO timestamps into [datetime], which
            # stringifies locale-dependently; keep the sortable ISO shape.
            $stamp = $m.timestamp
            if ($stamp -is [datetime]) { $stamp = $stamp.ToString('s') }
            $destinations = @($m.reviewers_requested)
            $metaPath = Join-Path $topicDir.FullName ("round-$round-metadata.json")
            if (Test-Path -LiteralPath $metaPath) {
                try {
                    $meta = Get-Content -Raw -LiteralPath $metaPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $byPreset = @{}
                    foreach ($s in @($meta.reviewers)) { $byPreset[$s.preset] = $s }
                    $destinations = @(@($m.reviewers_requested) | ForEach-Object {
                        if ($byPreset.ContainsKey($_)) {
                            $s = $byPreset[$_]
                            "$_ ($($s.backend)/$($s.model))"
                        } else { "$_" }
                    })
                } catch {}
            }
            $rows.Add([pscustomobject]@{
                TopicSlug          = if ($m.topic_slug) { [string]$m.topic_slug } else { $topicDir.Name }
                Round              = $round
                Timestamp          = if ($stamp) { [string]$stamp } else { '' }
                GitHead            = if ($m.git_head) { [string]$m.git_head } else { '' }
                GitBranch          = if ($m.git_branch) { [string]$m.git_branch } else { '' }
                GitClean           = [bool]$m.git_clean
                ReviewersRequested = @($m.reviewers_requested)
                Destinations       = @($destinations)
                SourcesCount       = @($m.sources).Count
                FilesCount         = @($m.files).Count
                ManifestPath       = $mf.FullName
                # A staged round's GitHead is a staging SHA that resolves
                # nowhere; the citable anchor is the verified origin beside it.
                StagedFrom         = if ($m.staged_from_head) { [string]$m.staged_from_head } else { '' }
                StagedResolvable   = if ($null -ne $m.staged_from_resolvable) { [bool]$m.staged_from_resolvable } else { $null }
            })
        }
    }
    return @($rows | Sort-Object { $_.Timestamp }, TopicSlug, Round)
}

function Format-EraExposureReport {
    <#
    .SYNOPSIS
        Render Get-EraExposureReport rows as a greppable receipt listing.
    #>
    [CmdletBinding()]
    param($Rows)
    $rows = @($Rows)
    if ($rows.Count -eq 0) {
        return "No exposure receipts: no round-*-manifest.json under .external-reviews/ (no round has been built here)."
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('=== era exposure: source sent out for review, by round ===')
    $lines.Add('')
    foreach ($r in $rows) {
        $short = if ($r.GitHead -and $r.GitHead.Length -ge 12) { $r.GitHead.Substring(0, 12) } else { $r.GitHead }
        $clean = if ($r.GitClean) { 'clean' } else { 'dirty' }
        $lines.Add("[$($r.TopicSlug)] round $($r.Round)  $($r.Timestamp)  head $short ($($r.GitBranch), $clean)")
        $lines.Add("  sent to : $((@($r.Destinations) -join '; '))")
        if ($r.StagedFrom) {
            $sShort = if ($r.StagedFrom.Length -ge 12) { $r.StagedFrom.Substring(0, 12) } else { $r.StagedFrom }
            $verdict = if ($r.StagedResolvable -eq $false) { 'NOT RESOLVABLE' } else { 'resolvable' }
            $lines.Add("  staged from : $sShort ($verdict)")
        }
        $lines.Add("  sources : $($r.SourcesCount) file(s), manifest files: $($r.FilesCount)  ($($r.ManifestPath))")
        $lines.Add('')
    }
    $topics = @($rows | ForEach-Object { $_.TopicSlug } | Sort-Object -Unique)
    $lines.Add("$($rows.Count) round(s) across $($topics.Count) topic(s). Manifests are the provenance record; cite their rounds, not memory.")
    return ($lines -join "`n")
}

function Test-ReviewerListAgainstRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ReviewerList,
        [Parameter(Mandatory)][hashtable]$Registry
    )
    foreach ($r in $ReviewerList) {
        if (-not $Registry.ContainsKey($r)) {
            throw "Unknown reviewer preset: $r"
        }
    }
}

function Test-BackendCliAvailable {
    <#
    .SYNOPSIS
        Refuse to dispatch a backend whose CLI is not actually reachable.

    .DESCRIPTION
        THE `tmux` BACKEND IS NOT A WINDOWS CLI AND MUST NOT BE PROBED AS ONE.
        Its transport is `wsl.exe` -> `tmux` inside WSL, and on this box
        /etc/wsl.conf sets interop.appendWindowsPath=false, so no Windows PATH
        lookup could ever find it. A plain `Get-Command tmux` therefore fails on
        a perfectly working install.

        Checking only for `wsl.exe` would be worse than the wrong check: wsl.exe
        ships with Windows, so the probe would pass on a machine with no tmux at
        all and the failure would surface later as a dead seat rather than as a
        refusal to dispatch. Both halves are checked, and `tmux -V` is the half
        that can actually be absent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CliName)

    # `cmdc` IS WSL-ONLY ON THIS BOX. `where.exe cmdc` finds nothing, where
    # `claude` and `opencode` both have Windows installs era spawns directly. A
    # Windows PATH lookup would therefore refuse a working install, exactly as it
    # did for tmux. Both halves are checked, and it is `cmdc --version` that can
    # actually be absent -- wsl.exe ships with Windows, so probing only for that
    # would pass on a machine with no cmdc and defer the failure to a dead seat.
    if ($CliName -eq 'cmdc') {
        if (-not (Get-Command 'wsl.exe' -ErrorAction SilentlyContinue)) {
            throw "Backend CLI 'cmdc' needs wsl.exe, which is not on PATH."
        }
        $probe = $null
        try { $probe = (& wsl.exe -- bash -lc 'command -v cmdc' 2>$null | Select-Object -First 1) } catch { $probe = $null }
        if (-not $probe -or -not $probe.Trim()) {
            throw "Backend CLI 'cmdc' is not installed inside WSL (not on the login PATH)."
        }
        return
    }

    if ($CliName -eq 'tmux') {
        if (-not (Get-Command 'wsl.exe' -ErrorAction SilentlyContinue)) {
            throw "Backend CLI 'tmux' needs wsl.exe, which is not on PATH."
        }
        $probe = $null
        try { $probe = (& wsl.exe -- tmux -V 2>$null | Select-Object -First 1) } catch { $probe = $null }
        if (-not $probe -or $probe -notmatch '^tmux\s') {
            throw "Backend CLI 'tmux' is not installed inside WSL (`wsl.exe -- tmux -V` returned nothing usable)."
        }
        return
    }

    if (-not (Get-Command $CliName -ErrorAction SilentlyContinue)) {
        throw "Backend CLI '$CliName' is not on PATH."
    }
}

