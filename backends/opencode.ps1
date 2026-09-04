<#
.SYNOPSIS
    opencode backend adapter for /external-review-auto. Invokes
    `opencode run "<prompt>" -m <model_id> [--variant <v>] -f <bundle>`.
.DESCRIPTION
    - Bundle delivery is SIZE-DEPENDENT. At or under 51,200 bytes it is ATTACHED
      via `-f` (fast, no tool calls). Above that opencode truncates an attached
      file silently, so the model is told to READ the bundle itself — verified
      2026-08-31 with mid-bundle canaries up to 668,389 bytes on both default
      seats. Past 1,048,576 bytes, beyond anything measured, the adapter refuses.
      ERA_OPENCODE_READ_TOOL forces either mode (1 = read, 0 = attach).
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
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
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

function Resolve-OpencodeStallPlan {
    <#
    .SYNOPSIS
        How long may opencode go quiet before we call it stalled, given the
        budget we were actually handed? Returns
        @{ StallThresholdMs; WantedMs; CeilingMs; Clamped; BundleTokenEst }.

    .DESCRIPTION
        Reasoning-heavy variants ('max') can think silently for minutes before
        the first token, so the appetite scales with the variant, plus a
        bundle-size overlay (20ms/token ~ 50 tok/sec) for large bundles.

        THE STALL MUST FIRE BEFORE OUR OWN TIMEOUT, or both land at once and the
        timeout label wins -- mis-attributing a silent-think stall and skipping
        the forensic snapshot the stall path writes.

        This used to be achieved by ESCALATING $TimeoutSec to (stall + 30s). An
        adapter cannot do that: the dispatcher waits TimeoutSec + 30 and then
        abandons the reviewer, so time the adapter grants itself beyond that
        does not exist. Measured, from the round that surfaced it:

          [dispatch] Scaled TimeoutSec 600s -> 1800s for 174313-token bundle.
          [opencode] Escalating timeout from 1800s to 3152s (variant=max,
                     bundle=156116tok, stall threshold 3122.32s + 30s margin).

        Dispatcher patience 1830s; stall 3122s; adapter timeout 3152s. BOTH of
        the adapter's deadlines sat beyond the dispatcher's, so for a large
        max-variant bundle neither could ever fire, the dispatcher always won,
        and every failure was labelled "Timed out (global)" with no snapshot --
        precisely the outcome the escalation existed to prevent.

        So the budget is now taken as given and the THRESHOLD is clamped to fit
        inside it. Same intent, using time that actually exists. The resulting
        order holds at every size and variant:

            stall threshold  <  adapter TimeoutSec  <  dispatcher TimeoutSec+30

        A clamp is reported, not silent: it means the budget is too small for
        this variant/bundle, which is a real thing for an operator to know.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$TimeoutSec,
        [string]$Variant,
        [long]$BundleBytes = 0
    )
    $variantBaseMs = switch ($Variant) {
        # 'xhigh' and 'max' are the SAME budget deliberately. They are two
        # providers' names for "think as long as you like", not two tiers:
        # opencode-go/muse-spark declares minimal/low/medium/high/xhigh, while
        # google/* and opencode-go/deepseek-* declare high/max. A model declares
        # one vocabulary or the other, never both (checked across the whole
        # registry 2026-09-04), so nothing has to rank them against each other.
        'xhigh'  { 600000 }
        'max'    { 600000 }
        'high'   { 300000 }
        default  { 120000 }
    }
    # THE 20ms/TOKEN RULE IS IMPLEMENTED TWICE, and this is the copy that has to
    # guess. Get-EraDispatchPlan (workflow.ps1, `$bundleScaledSec = [int]($BundleTokens
    # * 0.02)`) applies the same 20ms/token to the REAL repomix token count; this
    # adapter is handed only -BundleBytes, so it re-derives tokens from a ratio.
    # Named independently by the gemini and muse-spark seats of the 2026-09-02
    # panel, both of which framed it as "bytes/4 here vs the measured 3.369
    # elsewhere".
    #
    # SWAPPING THE CONSTANT IS NOT THE FIX, and that is a measurement, not an
    # opinion. The ratio is not a property of repomix, it is a property of the
    # bundle: 2,396,233 B / 711,253 tok = 3.369 on the bundle 3.369 was measured
    # on, and 532,112 B / 146,167 tok = 3.640 on the bundle the panel that raised
    # this ran over. Eight percent apart. Either literal is wrong for some bundle.
    #
    # WHAT IT COSTS TODAY, measured on that same round: the adapter estimated
    # 133,028 tokens where repomix counted 146,167, so `wantedMs` differed by 10%
    # -- and the stall threshold was IDENTICAL, because at 532 KB both values are
    # far above $ceilingMs and both clamp. The divergence only reaches the
    # threshold in the unclamped regime (small bundle, large budget): 60,000 B at
    # any budget gives 300s here against 356s from the real count. So the live
    # cost is a stall window up to ~16% tighter than the dispatcher's own model of
    # the same bundle, plus a token count in the "[opencode] Stall threshold:"
    # line that disagrees with the round's own "Bundle ready. Tokens:" by 10%.
    #
    # THE FIX IS TO PASS THE REAL COUNT DOWN, not to pick a better constant --
    # the dispatcher already has it. That means a new parameter on every adapter
    # (the dispatch ScriptBlock passes its arguments uniformly; see the
    # accepted-and-ignored -OpencodeProvider in agy.ps1), which is a change to
    # live dispatch for a heuristic whose measured effect on the round that found
    # it was zero. Left deliberately, with the numbers, rather than done in
    # passing.
    $bundleTokenEst = [int]($BundleBytes / 4)
    $bundleScaledMs = [long]$bundleTokenEst * 20
    $wantedMs       = [Math]::Max([long]$variantBaseMs, $bundleScaledMs)

    # Leave the same 30s margin the escalation used, so the stall throw has room
    # to fire cleanly before our own deadline. Floored so an absurdly small
    # budget still yields a positive, sub-timeout threshold rather than 0 or a
    # negative one.
    # No 75%-of-budget fallback branch here. One was written and round 8
    # (deepseek-flash) measured it as dead: 'ceilingMs >= TimeoutSec*1000' holds
    # only for TimeoutSec <= 1, and the dispatcher's floor is the 600s default,
    # so it could not fire for any real budget. Deleted rather than left as
    # decoration -- the same arithmetic the tests already do would have caught it.
    $ceilingMs = [Math]::Max(1000L, ([long]$TimeoutSec - 30) * 1000)
    $clamped = $wantedMs -gt $ceilingMs
    $useMs   = if ($clamped) { $ceilingMs } else { $wantedMs }

    return @{
        StallThresholdMs = [int]$useMs
        WantedMs         = [int]$wantedMs
        CeilingMs        = [int]$ceilingMs
        Clamped          = $clamped
        BundleTokenEst   = $bundleTokenEst
    }
}

function Get-OpencodePollIntervalMs {
    <#
    .SYNOPSIS
        How often the run loop wakes to check on the child. THE one definition.

    .DESCRIPTION
        This was a bare `$pollMs = 10000` local, ~500 lines down inside
        Invoke-OpencodeReview's run loop, and Resolve-OpencodeRunBudget's
        MinRunSec default was the literal 15 -- "one 10s poll plus margin" --
        derived from it by a comment and by nothing else.

        WHAT COUPLES THEM, precisely. The run loop is

            while (-not $exited) {
                $exited = $opencodeProc.WaitForExit($pollMs)
                ...
                if ($deadline.Elapsed.TotalSeconds -gt $effectiveTimeoutSec) { kill }
            }

        and $effectiveTimeoutSec is $runBudget.EffectiveSec, which is exactly the
        time left. So the deadline is only ever CHECKED at a multiple of $pollMs.
        A run launched with less than one poll's worth of budget cannot be
        stopped before its first wake, and at that wake the deadline has already
        passed: it is killed there, having overrun the dispatcher on the way, for
        nothing but the bundle prefill it billed on the way in. MinRunSec is what
        refuses to launch that run.

        Raise the poll interval to 30s while the floor stays 15 and every seat
        between 15s and 35s left is called viable and lands in exactly that case.
        Silently wrong in the direction that spends money, from a change made
        five hundred lines away with no reason to look here.

        Named by the v2.8.2 panel; nothing closed it until now. The fix is the
        one this repository keeps arriving at: make it ONE number that both
        sites call, and pin the RULE (the floor covers at least one poll, with
        margin) in tests/OpencodeConstantParity.Tests.ps1 so re-hardcoding either
        side fails a test instead of a round. Measured with the decoupling
        restored (poll 30000, MinRunSec default back to the literal 15): 3 of the
        32 assertions across AdapterTimeBudget and OpencodeConstantParity fail,
        and all 3 are new. Before this change, none would have.
    #>
    return 10000
}

function Get-OpencodeMinRunSec {
    <#
    .SYNOPSIS
        The least wall clock in which an opencode run can produce anything:
        one poll wake, plus margin. Derived from Get-OpencodePollIntervalMs.

    .DESCRIPTION
        The margin exists because a run with EXACTLY one poll of budget is woken
        for the first time at the instant that budget ends, and the deadline test
        at that wake is `-gt`, so it is a coin-flip on scheduler jitter whether
        the run is killed there having been given no second chance to grow. The
        margin buys the second wake.

        AND THE FLOOR HAS A SECOND CONSTRAINT the first cut did not encode: the
        lowered first-token deadline, int(effective * 0.6), must itself be at
        least one poll or the first wake kills the run under Phase 1's headline
        instead of the timeout's. That is why the return is a Max of two
        derivations rather than one sum; see the sweep in the body.

        FIVE SECONDS IS NOT MEASURED. It is what the original literal 15 encoded
        against a 10s poll, kept because changing it was not this change's
        subject; it is a policy number, and Get-EraBackendDelivery's vocabulary
        for it would be 'chosen'. What IS enforced is the relationship -- that
        the floor exceeds one poll -- which is the half that broke silently.
    #>
    $pollSec = [Math]::Ceiling((Get-OpencodePollIntervalMs) / 1000.0)
    # TWO constraints, and the first cut of this function only had the first one.
    #
    #   (a) one poll wake, plus margin -- the run must survive its first wake.
    #   (b) the FIRST-TOKEN deadline must be reachable by a poll wake. Phase 1
    #       lowers that deadline to int(effective * 0.6) when it would otherwise
    #       exceed the budget, and Phase 1 is CHECKED BEFORE the timeout branch,
    #       so a lowered value below one poll means the first wake kills the run
    #       under the wrong headline.
    #
    # (b) was missing, and the opus seat of the 2026-09-02 panel found it in the
    # very test that had just declared this rule closed. MEASURED, sweeping
    # Resolve-OpencodeRunBudget and Resolve-OpencodeStallPlan for real:
    #
    #   remaining  Viable  lowered first-token  first wake  killed at first wake
    #          15    True                    9         10s   YES
    #          16    True                   10         10s   no
    #          17+   True                  >=10        10s   no
    #
    # ONE value, and it was exactly the old floor -- the boundary
    # OpencodeConstantParity.Tests.ps1 pins as Viable. A seat handed precisely
    # MinRunSec was killed at its first wake with "no response within 9s --
    # possible limit/popup block", which is the mis-attribution this whole line
    # of fixes exists to prevent, having billed the bundle prefill on the way in.
    #
    # (opus stated the exposure as "every seat under ~50s of effective budget".
    # That is not what the sweep says: at 16 the lowering returns 10 and the
    # `-gt` at the wake is false, so 15 is the only exposed value. The mechanism
    # was right and the range was not; the number here comes from the sweep.)
    $reachable = [Math]::Ceiling($pollSec / 0.6)
    return [int][Math]::Max($pollSec + 5, $reachable)
}

function Resolve-OpencodeRunBudget {
    <#
    .SYNOPSIS
        How much of the dispatcher's budget is still ours, and how long may we
        block on the run lock and still have time to run? Returns
        @{ RemainingSec; LockWaitMs; Exhausted }.

    .DESCRIPTION
        THE SAME RULE Resolve-OpencodeStallPlan enforces, applied to the waits
        that were added AFTER it. An adapter cannot grant itself time the
        dispatcher will not wait -- it waits TimeoutSec + 30 and then tree-kills
        the reviewer -- so every wait in here has to come OUT of TimeoutSec.

        Two waits were escaping that rule, both introduced by the run-mutex
        change that landed after ae7594c:

          * the run-lock wait was a FIXED 900s, not derived from $TimeoutSec at
            all. At the dispatcher's 600s default the adapter was willing to
            block for 270s past the point where it gets killed, having started
            no opencode process and spent nothing -- and the seat is then
            reported as "Timed out after 600 seconds (global)", which is the
            mis-attribution ae7594c exists to prevent.

          * $deadline is started AFTER the lock is acquired, so the adapter's own
            timeout was (lockWait + TimeoutSec). The DEFAULT panel runs two
            opencode seats serialised behind that mutex, so the second seat
            routinely waits out the first one's whole run and then believes it
            has a further full budget.

        ONE FLOOR, MinRunSec, for both questions it answers: how much the lock
        wait must leave behind, and how little is too little to launch. It used
        to reserve RunFloorSec=60 for the wait while viability needed only 15,
        and opus (v2.8.2 panel) showed what that gap did -- for any TimeoutSec at
        or under 60 the lock wait computed to ZERO, so `WaitOne(0)`. The
        LOCK-RETRY path passes RemainingSec in as TimeoutSec, which after a
        backoff on a 600s seat is routinely under 60, so the one call that exists
        because of a lock collision was the one call that never queued for the
        lock. Two numbers for one question, the shape this repository sweeps for,
        inside the function written to fix the previous instance of it.

        EffectiveSec is the deadline the run itself gets, and it is EXACTLY what
        is left. There is no floor, because a floor cannot fix a spent budget --
        it can only spend somebody else's.

        THIS FUNCTION REINTRODUCED ITS OWN DEFECT TWICE BEFORE IT STOPPED.
        Cut 1 wrote `[Math]::Max(60, $remaining)`, copied from claude.ps1, which
        for any TimeoutSec under 60 hands the adapter more time than it was
        given. Cut 2 capped that floor at $TimeoutSec, and the BLINDED SEAT of
        the panel run on the diff that introduced it pointed out that the case
        that matters was still wrong: at elapsed >= TimeoutSec the floor returns
        60s, so the second serialised opencode seat plans (elapsed + 60) against
        a dispatcher that waits TimeoutSec + 30 and is already about to tree-kill
        it -- and the test shipped with cut 2 asserted that 60, so it was green
        while over budget.

        Viable is the honest answer instead: with too little time left, a run is
        not worth launching, and the caller says so rather than starting
        something nobody will wait for.

        VIABILITY WAS ONCE MEASURED AGAINST A SEPARATE 60s FLOOR. That was the
        first cut and it was wrong in the expensive direction: for any TimeoutSec
        at or under that floor, `remaining >= Min(floor, TimeoutSec)` reduces to
        `remaining >= TimeoutSec`, so ONE SECOND of startup made every short run
        non-viable. Found by trying to use it -- a 40s probe was refused at 39s
        remaining by the guard written to stop refusals that cost capability.

        MinRunSec is mechanical instead of copied: the poll loop wakes every
        Get-OpencodePollIntervalMs milliseconds, so a run with less than one poll
        plus margin left is killed on its first wake having produced nothing and
        billed the bundle prefill. That is the case opus's finding named, and it
        is the only case worth refusing.

        IT USED TO BE MECHANICAL ONLY IN THE COMMENT. The default was the literal
        15 and the poll interval was a separate literal 10000 five hundred lines
        away inside the run loop; "one poll plus margin" was a sentence, not a
        dependency. Both now come from Get-OpencodePollIntervalMs, and
        OpencodeConstantParity.Tests.ps1 asserts the RULE -- the floor covers at
        least one poll -- so re-hardcoding either side fails a test.

        THE EXEMPTION KEYS ON TIME SPENT, NOT ON THE BUDGET ASKED FOR. It first
        read `$TimeoutSec -le $MinRunSec`, and gemini pointed out on the next
        panel that this makes the verdict depend on the original budget rather
        than on what is left:

            TimeoutSec 15, elapsed 1  -> 14s left -> viable
            TimeoutSec 20, elapsed 6  -> 14s left -> refused

        Same seat, same fourteen seconds, opposite answers. The exemption exists
        so that STARTUP COST does not refuse a deliberately short run, so it asks
        how much has been spent. A caller that wants a tiny TimeoutSec is served;
        a seat that lost its budget in the queue is not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$TimeoutSec,
        # Wall clock already spent inside this adapter, from its own stopwatch.
        [double]$ElapsedSec = 0,
        # The least time in which a run can produce anything: one poll of the
        # output loop, plus margin. Governs BOTH what the lock wait reserves and
        # what counts as viable -- see the docstring on why that is one number.
        # Derived from Get-OpencodePollIntervalMs, NOT copied from it.
        [int]$MinRunSec = (Get-OpencodeMinRunSec),
        # How much wall clock counts as "has not really started yet". Below this,
        # a run is viable on any time at all, because what it lost was startup
        # rather than the queue.
        [double]$StartupGraceSec = 2
    )
    $remaining = $TimeoutSec - [int][Math]::Ceiling($ElapsedSec)
    if ($remaining -lt 0) { $remaining = 0 }
    $lockWaitSec = $remaining - $MinRunSec
    if ($lockWaitSec -lt 0) { $lockWaitSec = 0 }
    return @{
        RemainingSec = [int]$remaining
        LockWaitMs   = [int]($lockWaitSec * 1000)
        EffectiveSec = [int]$remaining
        # "You need one poll's worth of time left, unless you have barely started."
        # The second clause keeps startup cost from refusing a deliberately short
        # run; the first is the only case worth refusing.
        Viable       = ($remaining -ge $MinRunSec) -or ($ElapsedSec -le $StartupGraceSec -and $remaining -gt 0)
        Exhausted    = ($remaining -le 0)
    }
}

function Get-OpencodeDeliveryLimits {
    <#
    .SYNOPSIS
        This adapter's copy of what Get-EraBackendDelivery predicts for opencode.
        Returns @{ AttachLimitBytes; ReadToolMaxBytes }.

    .DESCRIPTION
        Extracted so the two sides can be compared to EACH OTHER rather than each
        to its own literal. The comment these constants used to carry claimed
        "OpencodeConstantParity.Tests.ps1 pins the built-in values against the
        plan's"; that file did not exist. It does now, and it calls this.

        ATTACH CAP -- opencode silently truncates an attached file at exactly
        50 KiB. Measured 2026-08-03 (DeepSeek V4 Flash reported its input ending
        at line 1169 of a 9,234-line bundle; `head -1169` is 51,191 bytes and
        line 1170 crosses 51,200) and re-confirmed 2026-08-31. It is a property
        of the TRANSPORT, so no registry key moves it -- the plan prints a NOTE
        when one tries, and this must not quietly honour what the plan refuses.

        READ-TOOL CEILING -- 668,389 bytes is verified end-to-end with mid-bundle
        canaries; muse-spark has separately carried 2,396,233. 1 MB sits between
        "measured" and "known to have worked once", which is the honest place for
        a default. This one IS a preset tunable, so max_bundle_bytes moves it --
        the same key, the same direction, as the plan's read-tool limit.
    #>
    [CmdletBinding()]
    param([hashtable]$ModelInfo = @{})
    $attach = 51200
    $read   = 1048576
    if ($ModelInfo) {
        $raw = $ModelInfo['max_bundle_bytes']
        if ($null -ne $raw -and "$raw" -ne '') {
            $parsed = [long]0
            if ([long]::TryParse("$raw", [ref]$parsed) -and $parsed -ge 0) { $read = $parsed }
            else { Write-Host "[opencode] WARNING: registry max_bundle_bytes='$raw' is not a non-negative number; keeping $read." }
        }
    }
    return @{ AttachLimitBytes = [long]$attach; ReadToolMaxBytes = [long]$read }
}

function Test-OpencodeOverAttachLimit {
    <# The mode crossover, as one expression both sides can be tested against. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$BundleBytes, [Parameter(Mandatory)][long]$AttachLimitBytes)
    return ($BundleBytes -gt $AttachLimitBytes)
}

function Get-OpencodeBundleBytes {
    <#
    .SYNOPSIS
        The bundle's size, or a refusal. Never 0 for a bundle we could not read.

    .DESCRIPTION
        FAIL CLOSED. This was `try { (Get-Item $BundlePath).Length } catch { 0 }`,
        and 0 is the one value that makes every downstream check say yes: the
        bundle looks smaller than the attach cap, the adapter attaches it, and
        opencode truncates at 51,200 bytes -- returning a well-formed review of a
        fragment, with content_ok true and nothing saying otherwise. That is the
        silent truncation the cap exists to prevent, reached through a catch that
        turns a failure into a benign-looking value.

        Third instance of that shape here (the token-count gate, then
        Get-EraBundleLineCounts, then this), and the same rule applies: a read
        failure must not be indistinguishable from a real measurement.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BundlePath)
    try { return [long](Get-Item -LiteralPath $BundlePath -ErrorAction Stop).Length }
    catch {
        throw ("opencode cannot size the bundle at '$BundlePath' ($($_.Exception.Message)). Refusing rather than attaching: " +
               "an attached bundle whose size is unknown is silently truncated at 51,200 bytes and the model returns a " +
               "well-formed review of the fragment. Nothing was dispatched and nothing was spent.")
    }
}

function Get-OpencodeReviewPrompt {
    <#
    .SYNOPSIS
        The two prompts this adapter sends -- one per delivery mode. Extracted so
        they can be asserted on without spawning opencode.

    .DESCRIPTION
        ONE RULE, TWO ADAPTERS, ONE OF THEM FIXED -- AGAIN, AND BY THE COMMIT
        THAT SAID SO. On 2026-09-02 agy's prompt moved into Get-AgyReviewPrompt
        precisely so CitationCoordinateFrame.Tests.ps1 could stop grepping source
        text, with the stated reason that a grep "would pass on a comment while
        the live prompt said anything at all". Five lines above that assertion,
        the same test file went on grepping THIS adapter's prompt out of
        backends/opencode.ps1, which was still inline. It passed only because
        those strings happen to appear nowhere else in the file -- the same
        accident that held for agy until its docstring quoted the old prompt.

        Found by the opus seat of the panel run on that commit. Extracted here
        for the same reason, and the test now calls both.

        The two prompts are NOT interchangeable and must track the delivery mode:
        'read-tool' tells the model to open the file and which line-number frame
        to cite from, because on that path its own reader reports bundle-absolute
        numbers; 'attach' tells it not to call tools at all, because on that path
        opencode has already inlined the file. Handing either prompt to the other
        mode is the delivery/prompt contradiction that F12 was about, one adapter
        over.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('read-tool','attach')][string]$Mode,
        [string]$BundlePath
    )
    $useReadTool = ($Mode -eq 'read-tool')
    return $(if ($useReadTool) {
        # THE CITATION FRAME, said once, where the mismatch is created. Your Read
        # tool reports line numbers counted from the top of the BUNDLE; the bundle
        # itself prints each file's own line numbers on every content line. A
        # model that cites the former is pointing at real code that era then
        # scores as a fabrication -- measured at 79% of every "fabricated"
        # citation across 62 archived seat-responses, and worst on this path because it is
        # the only one where a model reads the file with its own tooling.
        # era translates the UNAMBIGUOUS half (a citation past the named file's
        # end); where the two frames overlap it cannot tell, and 12.9% of archived
        # citations sit in that overlap. So this instruction is not a nicety on
        # top of a fix -- it is the only thing that addresses the half era cannot
        # see. Stop them being produced.
        ("Use the Read tool to read the bundle at '$BundlePath'. Review instructions are embedded at the bottom of that file. " +
         "CITATIONS: every content line in that bundle begins with the file's OWN line number, like ``  471: <code>``. Cite THAT number, " +
         "not the line number your Read tool reports — the tool counts from the top of the whole bundle, and those numbers do not " +
         "exist in the file you are naming. Output your structured review.")
    } else {
        "Review the attached bundle file. Every file under review and the review instructions are INSIDE the attached bundle. Output your structured review directly; do not call any tools."
    })
}

function Invoke-OpencodeReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)][string]$ResponsePath,
        [Parameter(Mandatory)][hashtable]$ModelInfo,
        [int]$TimeoutSec = 600,
        # Bounded retries for `database is locked` ONLY. The run mutex below
        # serialises era's own opencode seats, but it cannot see an opencode the
        # operator has open interactively, and that one holds the same database.
        # A lock failure dies at startup in about a second having consumed no
        # tokens, so retrying it is nearly free -- unlike every other failure
        # here, which is why this is scoped to that one stderr signature.
        [int]$LockRetries = 2,
        [string]$AgyModelHint,
        [string]$ModelOverride,
        # Accepted-and-ignored: the dispatcher passes -OpencodeProvider to every
        # adapter uniformly. The provider is derived from the model_id here.
        [string]$OpencodeProvider,
        # Absolute path this adapter writes its native child PID to, so the
        # dispatcher can tree-kill the process if this reviewer has to be
        # abandoned early. Optional: omitted by callers that never abandon.
        # See workflow.ps1 Stop-EraAdapterChild for why Stop-Job cannot do it.
        [string]$PidFile
    )
    # Bundle access: ATTACH via `-f` under the cap, READ TOOL over it.
    #
    # opencode TRUNCATES an attached file at exactly 50 KiB (51200 bytes), silently.
    # Measured 2026-08-03 against two real runs: DeepSeek V4 Flash reported its input
    # ending at line 1169 of a 9,234-line bundle, and `head -1169` of that file is
    # 51,191 bytes while line 1170 would cross 51,200 - the cut lands mid-line at the
    # 50 KiB boundary. On a 474 KB bundle the reviewer therefore saw 10.7% of it.
    #
    # That failure is SILENT and worse than an error: the model still returns a
    # well-formed review, so `content_ok` is true and the run looks successful - it is
    # simply a review of a tenth of the input. So over the cap we must NOT attach.
    #
    # --- 2026-08-31: this path was retired, and then UN-retired the same day -----
    #
    # It was retired on the reading that it "hangs and returns nothing". That was
    # wrong, and it is worth recording exactly how, because the mistake was in the
    # evidence rather than in the reasoning.
    #
    # Every artifact in %TEMP%\opencode-stall-debug is 0 bytes while the error line
    # beside it reports a non-zero `total bytes`. That contradiction was read as
    # "the process produced nothing". It was actually a BUG IN THE SNAPSHOT:
    # $stdoutSink.Length counts bytes still sitting in the FileStream write buffer,
    # and the snapshot copied the file WITHOUT FLUSHING (fixed below). Reproduced:
    # 218 bytes written -> sink.Length=218, on-disk length=0. So the "it never
    # starts" premise came from a measuring instrument that was broken.
    #
    # MEASURED PROPERLY 2026-08-31, with a mid-bundle CANARY. A bundle is not
    # "covered" because a review came back - the model can read the head, skip to
    # the instructions at the tail, and write something plausible. So each probe
    # planted marker lines at widely separated offsets and asked for them back
    # verbatim before the review. Both default opencode seats, every size:
    #
    #   bundle      lines    canaries        wall   result
    #   109,066 B    2,066   1/1 both seats    57s  real reviews, file:line cited
    #   314,720 B    5,226   2/2 both seats    85s  real reviews
    #   668,389 B   10,773   3/3 both seats   256s  real reviews
    #
    # 668 KB is 13x the attach cap, with markers returned from 25/50/75% depth.
    #
    # WHAT THE CANARIES DO AND DO NOT PROVE (2026-09-01 design panel, unanimous).
    # A returned marker proves RETRIEVABILITY -- the channel carried the bytes and
    # the model could locate them -- NOT that it read the content in between. On
    # the read-tool path the model holds a Read tool over a file on disk and can
    # find a marker by searching. What actually supports "it reviewed the whole
    # bundle" is the CONJUNCTION: markers at three depths, PLUS grounded file:line
    # citations spread across a 10,773-line bundle, PLUS wall clock scaling with
    # size (57s -> 85s -> 256s). Attributing the conclusion to the canaries alone
    # overstates the canaries and understates the citations.
    #
    # A sound coverage probe would ask a question answerable only by synthesising
    # text BETWEEN the markers, rather than echoing the markers. That is not what
    # was run here.
    #
    # IT IS STILL INTERMITTENT, and that is not explained. Historically:
    #
    #   deepseek-flash  74,740 B     600s timeout, nothing   (2026-08-31)
    #   deepseek-flash  79,294 B     600s timeout, nothing   (2026-08-25)
    #   deepseek-flash  2,396,233 B  failed                  (2026-08-30)
    #   muse-spark      2,396,233 B  SUCCEEDED - a 7,628-byte grounded review
    #
    # Not size (109 KB works, 74 KB failed) and not model (both models pass every
    # probe here; both appear in the failure list).
    #
    # CONCURRENCY WAS THE LEADING HYPOTHESIS. IT WAS TESTED, AND IT DID NOT HOLD.
    # 2026-08-31, controlled A/B against this adapter directly (no repomix, no
    # round machinery), one fixed 65,196-byte bundle and one fixed prompt, 10
    # trials per arm, deepseek-flash:
    #
    #   arm A  no other opencode process       0 stalls / 10   mean 14.5s, max 28.3s
    #   arm B  `opencode serve` holding the     0 stalls / 10   mean 13.0s, max 22.5s
    #          database + 22 external
    #          `opencode run` contenders
    #
    # `database is locked` never appeared in either arm, and arm B was marginally
    # FASTER. The mid-bundle canary came back in every trial that produced text.
    # So the run mutex's blind spot -- an operator's own opencode session -- is not
    # what killed those rounds, and this comment no longer gets to claim it is.
    #
    # WHAT THAT DOES AND DOES NOT SETTLE. It does not reproduce the failing
    # regime: these trials finish in ~13s while the historical failures burned the
    # full 600s, so whatever they were doing, this is not it. Ten trials with zero
    # events bounds the per-arm stall rate at roughly 26% (rule of three), so a
    # rarer mechanism would not have shown up. The cause of the 74,740 B and
    # 79,294 B stalls remains genuinely unknown -- with concurrency now the
    # least-supported explanation rather than the most.
    #
    # The next stall will leave a real artifact (the flush above), which is the
    # thing that was missing every previous time this was investigated.
    #
    # Refusing outright was the wrong trade: it removes the only way to review
    # anything over 50 KiB on an opencode seat, to avoid a failure that the stall
    # detector and timeout already bound. Over the cap we read; far over it - past
    # anything measured - we refuse, because an unbounded agentic read on a bundle
    # nobody has ever successfully reviewed is a bet, not a default.
    # These two are the adapter's copy of what Get-EraBackendDelivery predicts. They
    # MUST honour the same registry override, or raising a ceiling in
    # backends/_registry.json makes the plan say "fits" and this throw after the
    # round is already paid for on the other seats -- a free preflight refusal
    # upgraded into a billed void round (2026-08-31 panel, muse-spark finding 1).
    # OpencodeConstantParity.Tests.ps1 pins the built-in values against the plan's.
    # The values and the registry override live in Get-OpencodeDeliveryLimits, so
    # tests/OpencodeConstantParity.Tests.ps1 can compare them to the plan's own
    # Get-EraBackendDelivery instead of each side to its own literal -- which is
    # what the comment above has claimed since 2026-08-31 and what did not exist.
    $ocLimits = Get-OpencodeDeliveryLimits -ModelInfo $ModelInfo
    $OPENCODE_ATTACH_LIMIT_BYTES  = $ocLimits.AttachLimitBytes
    $OPENCODE_READ_TOOL_MAX_BYTES = $ocLimits.ReadToolMaxBytes
    $forceReadTool = $env:ERA_OPENCODE_READ_TOOL -and $env:ERA_OPENCODE_READ_TOOL -ne '0' -and $env:ERA_OPENCODE_READ_TOOL -ne 'false'
    $forceAttach = $env:ERA_OPENCODE_READ_TOOL -and ($env:ERA_OPENCODE_READ_TOOL -eq '0' -or $env:ERA_OPENCODE_READ_TOOL -eq 'false')
    # FAIL CLOSED: a size we could not read must not read as "small enough to
    # attach". See Get-OpencodeBundleBytes.
    $bundleBytes = Get-OpencodeBundleBytes -BundlePath $BundlePath
    $overAttachLimit = Test-OpencodeOverAttachLimit -BundleBytes $bundleBytes -AttachLimitBytes $OPENCODE_ATTACH_LIMIT_BYTES
    $useReadTool = $forceReadTool -or ($overAttachLimit -and -not $forceAttach)

    if ($overAttachLimit -and $forceAttach) {
        Write-Host "[opencode] WARNING: bundle is $bundleBytes bytes but ERA_OPENCODE_READ_TOOL=0 forces attach - opencode will TRUNCATE at $OPENCODE_ATTACH_LIMIT_BYTES bytes; the review covers only the first $([math]::Round($OPENCODE_ATTACH_LIMIT_BYTES * 100 / $bundleBytes, 1))%."
    }
    elseif ($useReadTool -and $bundleBytes -gt $OPENCODE_READ_TOOL_MAX_BYTES -and -not $forceReadTool) {
        throw ("opencode cannot review this bundle: it is $bundleBytes bytes. Attaching truncates at $OPENCODE_ATTACH_LIMIT_BYTES bytes " +
               "(the reviewer would see the first $([math]::Round($OPENCODE_ATTACH_LIMIT_BYTES * 100 / $bundleBytes, 1))% and report on it as if it were the whole thing), and the Read-tool path " +
               "is only verified to $OPENCODE_READ_TOOL_MAX_BYTES bytes. Curate with -IncludeFiles, or send this round to a reviewer whose channel can carry it " +
               "(agy reads from disk). To try the read anyway you need BOTH -ForceBundleSize (or ERA_BUNDLE_FORCE=1) to get past era's preflight AND ERA_OPENCODE_READ_TOOL=1 to get past this one. Nothing was dispatched and nothing was spent.")
    }
    elseif ($overAttachLimit) {
        Write-Host "[opencode] bundle is $bundleBytes bytes (> $OPENCODE_ATTACH_LIMIT_BYTES attach cap) - using the Read tool so the model sees ALL of it, not the first 50 KiB."
    }
    $prompt = Get-OpencodeReviewPrompt -Mode $(if ($useReadTool) { 'read-tool' } else { 'attach' }) -BundlePath $BundlePath
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stdFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $modelId = if ($ModelOverride) { $ModelOverride } else { $ModelInfo.model_id }

    # --- Phase 1: First-token deadline configuration ---
    # Default 120s; env var must be a positive integer >= 10 (poll interval = 10s).
    # Values 1-9 clamp to 10s; non-integer/empty/negative fall back to 120s.
    $firstTokenSec = 120
    if ($env:ERA_OPENCODE_FIRST_TOKEN_SEC) {
        $parsed = 0
        if ([int]::TryParse($env:ERA_OPENCODE_FIRST_TOKEN_SEC, [ref]$parsed) -and $parsed -ge 10) {
            $firstTokenSec = $parsed
        } else {
            $applied = if ($parsed -gt 0 -and $parsed -lt 10) { 10 } else { 120 }
            Write-Host "[opencode] ERA_OPENCODE_FIRST_TOKEN_SEC='$($env:ERA_OPENCODE_FIRST_TOKEN_SEC)' is not a positive integer >= 10; falling back to ${applied}s."
            $firstTokenSec = $applied
        }
    }

    # --- Variant resolution (registry-driven; NO state.json mutation) ---
    # Pick the strongest declared variant (max -> high -> medium -> low), else
    # 'default'. Passed via --variant and used to tune the stall threshold below.
    # A slash-less / unknown model_id resolves to 'default' gracefully (no throw —
    # the old state-swap crashed on it).
    $providerID, $modelIDPart = $modelId -split '/', 2
    $chosenVariant = 'default'
    $registryPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'backends/_registry.json'
    $modelVariants = @()
    if ($providerID -and (Test-Path -LiteralPath $registryPath)) {
        try {
            $registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
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
    # STRONGEST FIRST. 'xhigh' was added 2026-09-04 and is not cosmetic: opencode
    # DOES NOT VALIDATE VARIANT NAMES. Measured that day --
    # `opencode run --variant totally-bogus-zzz` returns exit 0 and a normal
    # answer, byte-identical in shape to `--variant max` -- so a variant the model
    # does not declare is silently ignored, not rejected. muse-spark declares
    # minimal/low/medium/high/xhigh and NOT 'max', so era asking for 'max' was in
    # the same class as asking for nonsense: the seat ran at opencode's default
    # reasoning effort while era believed it had asked for maximum. Because the
    # failure is silent in both directions, the guard is a test
    # (OpencodeVariantDeclared.Tests.ps1) and not a runtime check -- there is
    # nothing at runtime to check against.
    foreach ($preferred in @('xhigh','max','high','medium','low')) {
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
        if (-not (Test-Path -LiteralPath $cmdPath)) { throw "opencode.cmd not found at $cmdPath" }
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

    # REPORT WHAT ACTUALLY RAN. This line used to print "--variant $chosenVariant"
    # unconditionally, including when $chosenVariant is 'default' -- which is the one
    # case where the flag is NOT passed (see the omit branch above). A log that names
    # an argument the process did not receive is the same class of defect as a comment
    # asserting behaviour no code path has: it survives review because it reads true.
    $variantEcho = if ($chosenVariant -eq 'default') { "(no --variant; opencode's own default)" } else { "--variant $chosenVariant" }
    Write-Host "[opencode] run -m $modelId $variantEcho (attach=$([bool](-not $useReadTool)))"

    $exitCode = -1
    $clean = $null
    $stderr = ''
    $stdoutSink = $null
    $stderrSink = $null
    $stdoutCopyTask = $null
    $stderrCopyTask = $null
    $opencodeProc = $null

    # --- SERIALISE opencode runs across the whole machine ------------------
    # opencode keeps a single SQLite database (~/.local/share/opencode/opencode.db
    # -- 8 GB with a 97 MB WAL on this host). Two `opencode run` processes racing
    # to open it fail fast with `Error: Unexpected error\n\ndatabase is locked`,
    # exit 1, and produce no response file.
    #
    # The DEFAULT era panel does exactly that: deepseek-flash and muse-spark are
    # both opencode-backed and are dispatched as parallel ThreadJobs in one
    # process. That cost a reviewer in three consecutive rounds (3, 4, 5) --
    # always with two opencode seats in flight, never otherwise.
    #
    # A named mutex is the smallest fix that actually prevents it. Isolating the
    # data directory per child would preserve parallelism, but opencode has no
    # data-dir override and its auth lives in that same directory, so a private
    # dir means an unauthenticated reviewer.
    #
    # Cost: the opencode seats run sequentially. On the round-5 panel that is
    # additive wall clock on two of four reviewers, against losing one outright.
    # Precedent: the variant-state mutex above.
    #
    # IT DOES NOT SERIALISE THE CASE THAT MATTERS, and saying otherwise was the
    # comment's fault rather than the code's. The wait is now bounded by this
    # seat's own budget (below), so when seat 1 uses its whole 600s, seat 2's
    # wait expires at 540s and seat 2 starts ANYWAY -- in parallel with seat 1's
    # tail, which is the collision window this mutex exists to close. That is
    # deliberate ("a possible collision beats a guaranteed no-show") and it means
    # THE BOUNDED 'database is locked' RETRY BELOW IS THE REAL COLLISION HANDLER;
    # the mutex removes the common case, not the worst one. Raised by the
    # deepseek-flash seat of the twin-sweep panel, which is also the seat that
    # kept losing rounds to this collision before the mutex existed.
    #
    # THE WAIT COMES OUT OF THE BUDGET, it is not added to it. This was a fixed
    # 15 minutes, which at the dispatcher's 600s default meant the adapter would
    # block for 300s longer than the dispatcher waits -- so it could be
    # tree-killed while still queued, having started nothing and spent nothing,
    # and be recorded as a plain global timeout. See Resolve-OpencodeRunBudget.
    $runMutex = $null
    $runMutexHeld = $false
    $lockBudget = Resolve-OpencodeRunBudget -TimeoutSec $TimeoutSec -ElapsedSec $sw.Elapsed.TotalSeconds
    $lockWaitMs = $lockBudget.LockWaitMs
    try {
        $runMutex = [System.Threading.Mutex]::new($false, 'Global\era-opencode-run-mutex')
        try { $runMutexHeld = $runMutex.WaitOne($lockWaitMs) }
        catch [System.Threading.AbandonedMutexException] { $runMutexHeld = $true }
        if (-not $runMutexHeld) {
            # Degrade to the old behaviour rather than drop the reviewer: a
            # possible collision beats a guaranteed no-show.
            # A zero wait has TWO causes and they are not the same fact: the
            # budget really is spent, or the budget was small to begin with and
            # the run floor ate all of it (reachable on the retry path, which
            # passes RemainingSec straight in as TimeoutSec). Saying "already
            # spent" to a caller with a fresh 45s budget is a false statement in
            # a diagnostic -- flagged by the opus seat of this change's panel.
            $waitedSec = [int]($lockWaitMs / 1000)
            $why = if ($waitedSec -gt 0) {
                "waited ${waitedSec}s for the opencode run lock (all this seat's ${TimeoutSec}s budget could fund) and did not get it"
            } elseif ($lockBudget.Exhausted) {
                "did not wait for the opencode run lock at all -- the ${TimeoutSec}s budget for this seat is already spent"
            } else {
                "did not wait for the opencode run lock -- a ${TimeoutSec}s budget leaves nothing to spend queueing once the run floor is reserved"
            }
            Write-Host "[opencode] WARNING: $why; starting anyway (may hit 'database is locked')."
        }
    } catch {
        Write-Host "[opencode] WARNING: could not create the run mutex ($($_.Exception.Message)); starting unserialised."
    }

    # WHAT IS LEFT AFTER THE QUEUE, not a fresh copy of the original budget.
    # $deadline below is started at process launch -- i.e. after the wait above --
    # so measuring it against $TimeoutSec gave this adapter (lockWait +
    # TimeoutSec) while the dispatcher still waits only TimeoutSec + 30. The
    # DEFAULT panel serialises two opencode seats behind that mutex, so the
    # second one hits this every time both seats are slow.
    #
    # If the queue ate the budget, REFUSE rather than start a run the dispatcher
    # will not wait for: it would produce nothing and be recorded as a generic
    # global timeout, which is the mis-attribution this whole line of fixes
    # exists to prevent. Nothing has been spent at this point -- no opencode
    # process has been started.
    $runBudget = Resolve-OpencodeRunBudget -TimeoutSec $TimeoutSec -ElapsedSec $sw.Elapsed.TotalSeconds
    if (-not $runBudget.Viable) {
        throw ("opencode: this seat's ${TimeoutSec}s budget was spent waiting for the run lock " +
               "($([int]$sw.Elapsed.TotalSeconds)s in the queue, $($runBudget.RemainingSec)s left). Refusing to start a run the " +
               "dispatcher will abandon before it finishes -- it would return nothing and be recorded as a plain timeout. " +
               "Raise the reviewer timeout, or run fewer opencode seats in one panel (they serialise on one SQLite database). " +
               "Nothing was dispatched and nothing was spent.")
    }
    $effectiveTimeoutSec = $runBudget.EffectiveSec
    # Reported only when the queue actually cost something. Sub-second startup
    # jitter is not news, and a line on every healthy round trains the reader to
    # skip the line that matters.
    if ($effectiveTimeoutSec -le ($TimeoutSec - 5)) {
        Write-Host "[opencode] Budget after the run queue: ${effectiveTimeoutSec}s of the ${TimeoutSec}s handed to this seat ($([int]$sw.Elapsed.TotalSeconds)s already spent waiting for the run lock)."
    }

    try {
        $opencodeProc = [System.Diagnostics.Process]::Start($psi)
        # Publish the child PID before any blocking wait: once this thread is
        # inside WaitForExit it cannot be interrupted, so this file is the
        # dispatcher's only handle on the process.
        if ($PidFile) { try { Set-Content -LiteralPath $PidFile -Value $opencodeProc.Id -ErrorAction SilentlyContinue } catch {} }
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
        # ONE definition of the poll interval, shared with the MinRunSec floor
        # that is derived from it (Get-OpencodeMinRunSec). It was a bare literal
        # here while the floor was a bare literal 15 in Resolve-OpencodeRunBudget.
        $pollMs     = Get-OpencodePollIntervalMs
        # Already measured above and it fails closed there; reuse it rather than
        # re-probing into a second `catch { 0 }`.
        $bundleSize = $bundleBytes
        # The budget is what the dispatcher handed us. We do NOT raise it -- see
        # Resolve-OpencodeStallPlan for the measurement showing that an escalated
        # $TimeoutSec is time the dispatcher never waits, which put BOTH of this
        # adapter's deadlines out of reach on large max-variant bundles.
        $stallPlan        = Resolve-OpencodeStallPlan -TimeoutSec $effectiveTimeoutSec -Variant $chosenVariant -BundleBytes $bundleSize
        $stallThresholdMs = $stallPlan.StallThresholdMs
        if ($stallPlan.Clamped) {
            Write-Host ("[opencode] Stall threshold: $($stallThresholdMs/1000)s (variant=$chosenVariant, bundle=$($stallPlan.BundleTokenEst)tok) " +
                "-- CLAMPED from $($stallPlan.WantedMs/1000)s to fit the ${effectiveTimeoutSec}s budget. A silent think longer than " +
                "$($stallThresholdMs/1000)s will be called a stall; raise the reviewer timeout if this variant needs longer.")
        } else {
            Write-Host "[opencode] Stall threshold: $($stallThresholdMs/1000)s (variant=$chosenVariant, bundle=$($stallPlan.BundleTokenEst)tok); budget=${effectiveTimeoutSec}s of ${TimeoutSec}s."
        }

        # PHASE 1 MUST NOT CONTRADICT THE STALL PLAN. Round-8 (deepseek-flash)
        # finding 2: the ordering claim above ("stall < TimeoutSec < dispatcher")
        # omitted a FOURTH, earlier deadline. Phase 1 kills any process with zero
        # output after $firstTokenSec -- default 120s, variant-blind -- while the
        # stall plan's whole premise is that a 'max' variant may think silently
        # for minutes before the first token, and grants it 600s of base appetite
        # (1770s after this round's clamp). Measured on the real case:
        #
        #   stall threshold (max, 624 KB bundle) : 1770s of permitted silence
        #   Phase-1 default                      :  120s -> kills first
        #
        # So on exactly the case the clamp was built for, a model thinking
        # silently for 121s was killed and labelled "possible limit/popup block"
        # -- the same mis-attribution the clamp exists to prevent -- and Phase 1
        # is the one kill path that writes NO forensic snapshot.
        #
        # An explicit ERA_OPENCODE_FIRST_TOKEN_SEC still wins: the operator has
        # said what they want. Otherwise the two deadlines are reconciled, so
        # the variant-aware number is the one that decides.
        if (-not $env:ERA_OPENCODE_FIRST_TOKEN_SEC) {
            $planSilenceSec = [int]($stallThresholdMs / 1000)
            if ($planSilenceSec -gt $firstTokenSec) {
                Write-Host "[opencode] First-token deadline raised ${firstTokenSec}s -> ${planSilenceSec}s to match the silence this variant is expected to need (variant=$chosenVariant). Set ERA_OPENCODE_FIRST_TOKEN_SEC to override."
                $firstTokenSec = $planSilenceSec
            }
        }
        # ...AND RECONCILED DOWNWARD TOO. The block above only ever RAISES
        # $firstTokenSec. A seat that queued behind the run mutex can hold an
        # $effectiveTimeoutSec smaller than the 120s default, and then the
        # timeout throw always wins the race and Phase 1 -- the one kill path
        # that reports "possible limit/popup block" -- becomes unreachable for
        # exactly the seats the run-budget code exists to handle. Same shape as
        # the round-8 finding the block above documents, one direction over;
        # raised by the opus seat of this change's panel.
        # LOWERED PROPORTIONALLY, not to a fixed floor. `Max(10, $eff - 10)` was
        # the first cut, and gemini pointed out on the v2.8.2 panel that it
        # defeats itself at the small end: for any $eff at or under 15s it
        # returns 10, the poll loop's first wake is at 10s, and `-gt` is strict --
        # so Phase 1 cannot fire at t=10, the next wake at t=20 is already past
        # the deadline, and the timeout wins every time. The comment above would
        # then be claiming a reconciliation that does not happen, which is the
        # category-E defect this file has been audited for twice.
        if ($firstTokenSec -ge $effectiveTimeoutSec) {
            $lowered = [Math]::Max(1, [int]($effectiveTimeoutSec * 0.6))
            Write-Host "[opencode] First-token deadline lowered ${firstTokenSec}s -> ${lowered}s to fit this seat's remaining ${effectiveTimeoutSec}s budget; otherwise the timeout fires first and the no-output branch can never report."
            $firstTokenSec = $lowered
        }
        $lastSize   = $stdoutSink.Length + $stderrSink.Length
        $lastGrowth = [System.Diagnostics.Stopwatch]::StartNew()
        $deadline   = [System.Diagnostics.Stopwatch]::StartNew()
        $firstTokenDeadline = [System.Diagnostics.Stopwatch]::StartNew()
        $hasSeenOutput = $false
        # $firstTokenDeadline is a total wall-clock from process start (not a sliding
        # window). Once $hasSeenOutput=$true, Phase 1 is permanently disabled — Phase 2
        # takes over with its own independent stall tracking via $lastGrowth.
        $exited     = $false

        # Snapshot partial stdout/stderr to a debug dir + return a tail suffix, so a
        # killed stuck process still leaves a forensic clue.
        $snapshotPartialAndDebug = {
            param([string]$prefix)
            # FLUSH FIRST (2026-08-31). CopyToAsync writes through a buffered
            # FileStream, and FileStream.Length counts bytes still IN that buffer
            # while Get-Content/Copy-Item see only what reached disk. So every
            # snapshot under 4 KB came back EMPTY while the error line beside it
            # reported a non-zero `total bytes` -- and that contradiction was read
            # as "the process produced nothing", which sent the diagnosis after a
            # startup failure that was never happening.
            #
            # Reproduced exactly: 218 bytes copied in -> sink.Length = 218,
            # on-disk length = 0, and after Flush() -> 218. Same 218 as the
            # 2026-08-31 timeout log. Every artifact in opencode-stall-debug
            # predating this line is empty or cut at a 4,096-byte boundary for
            # this reason, not because opencode was silent.
            # Quiesce the async copies BEFORE flushing. Flush() pushes the
            # FileStream's own buffer to the OS; it does not drain bytes still
            # sitting in the CopyToAsync pipeline started above, so a snapshot
            # taken while the child is still draining can be short -- the same
            # class as the bug this whole block exists to fix, just bounded.
            # A bounded wait, never an unbounded one: the child has already been
            # killed by every caller of this block.
            try { $null = $stdoutCopyTask.Wait(500) } catch {}
            try { $null = $stderrCopyTask.Wait(500) } catch {}
            # A FAILED flush must not be silent. A swallowed exception here
            # reproduces the exact signature that was misread as "the process
            # produced nothing" -- an empty artifact beside a non-zero byte count
            # -- and leaves the next reader the same broken instrument.
            try { $stdoutSink.Flush() } catch { Write-Host "[opencode] WARNING: could not flush the stdout capture before snapshotting ($($_.Exception.Message)); the artifact below may be short." }
            try { $stderrSink.Flush() } catch { Write-Host "[opencode] WARNING: could not flush the stderr capture before snapshotting ($($_.Exception.Message)); the artifact below may be short." }
            $partialOut = (Get-Content -Raw -LiteralPath $stdFile -ErrorAction SilentlyContinue)
            $partialErr = (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue)
            $cleanOut   = if ($partialOut) { $partialOut -replace '\x1b\[\??[0-9;]*[a-zA-Z]', '' -replace "\r", '' } else { '' }
            $tailOut    = if ($cleanOut) { $cleanOut.Substring([math]::Max(0, $cleanOut.Length - 400)) } else { '<no stdout>' }
            $tailErr    = if ($partialErr) { $partialErr.Substring([math]::Max(0, $partialErr.Length - 400)) } else { '<no stderr>' }
            $debugDir   = Join-Path $env:TEMP 'opencode-stall-debug'
            $stamp      = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-pid$PID"
            try {
                if (-not (Test-Path -LiteralPath $debugDir)) { $null = New-Item -ItemType Directory -Path $debugDir -Force }
                Copy-Item -LiteralPath $stdFile -Destination (Join-Path $debugDir "$prefix-$stamp-stdout.txt") -ErrorAction SilentlyContinue
                Copy-Item -LiteralPath $errFile -Destination (Join-Path $debugDir "$prefix-$stamp-stderr.txt") -ErrorAction SilentlyContinue
                $existing = @(Get-ChildItem -LiteralPath $debugDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
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

            if ($now -gt 0) { $hasSeenOutput = $true }

            if (-not $hasSeenOutput -and $firstTokenDeadline.Elapsed.TotalSeconds -gt $firstTokenSec) {
                try { $opencodeProc.Kill($true) } catch {}
                if (-not $opencodeProc.HasExited) {
                    $null = $opencodeProc.WaitForExit(1000)
                }
                # Snapshot like the stall and timeout kills do. Round-8
                # (deepseek-flash) finding 2: this was the ONE kill path that
                # produced no forensic artifact, so the failure it reports is
                # also the failure you can least diagnose.
                $tailInfo = & $snapshotPartialAndDebug 'firsttoken'
                throw "opencode: no response within ${firstTokenSec}s — possible limit/popup block. Total captured bytes: 0. $tailInfo"
            }

            if ($now -gt $lastSize) {
                $lastSize = $now
                $lastGrowth.Restart()
            }
            if ($lastGrowth.ElapsedMilliseconds -gt $stallThresholdMs) {
                try { $opencodeProc.Kill($true) } catch {}
                $tailInfo = & $snapshotPartialAndDebug 'stall'
                throw "opencode stalled: no output growth for $($stallThresholdMs/1000)s (model=$modelId, variant=$chosenVariant, total wall=$([math]::Round($deadline.Elapsed.TotalSeconds,1))s, total bytes=$lastSize). $tailInfo"
            }
            if ($deadline.Elapsed.TotalSeconds -gt $effectiveTimeoutSec) {
                try { $opencodeProc.Kill($true) } catch {}
                $tailInfo = & $snapshotPartialAndDebug 'timeout'
                throw "opencode run exceeded its ${effectiveTimeoutSec}s slice of the ${TimeoutSec}s budget (model=$modelId, variant=$chosenVariant, total bytes=$lastSize). $tailInfo"
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

        $resultText = (Get-Content -Raw -LiteralPath $stdFile -ErrorAction SilentlyContinue)
        if (-not $resultText) { $resultText = '' }
        $stderr = (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue)
        if (-not $stderr) { $stderr = '' }
        $clean = $resultText -replace '\x1b\[\??[0-9;]*[a-zA-Z]', '' -replace "\r", ''

        Remove-Item -LiteralPath $stdFile -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
        $sw.Stop()

        # Released only after the child is reaped, so the next opencode seat
        # never overlaps this one's database handle.
        if ($runMutex) {
            if ($runMutexHeld) { try { $runMutex.ReleaseMutex() } catch {} }
            try { $runMutex.Dispose() } catch {}
        }
    }

    if ($exitCode -ne 0 -or -not $clean) {
        if ($LockRetries -gt 0 -and $stderr -match '(?i)database is locked') {
            $backoffSec = 10 * (3 - $LockRetries)   # 10s, then 20s
            # THE RETRY SPENDS OUR BUDGET, it does not get a new one. This used
            # to recurse with the unchanged $TimeoutSec, so two backoffs plus
            # three attempts could reach 3 x TimeoutSec + 30s against a
            # dispatcher that waits TimeoutSec + 30 -- the same "an adapter
            # cannot grant itself time" defect ae7594c fixed one path over. A
            # lock failure normally dies at startup in about a second, so this
            # is cheap in practice; it is the worst case that was unbounded.
            $retryBudget = Resolve-OpencodeRunBudget -TimeoutSec $TimeoutSec `
                -ElapsedSec ($sw.Elapsed.TotalSeconds + $backoffSec)
            # VIABLE, not merely non-zero. Refusing only on Exhausted let a retry
            # go out with 1-9s left: the poll loop's first wake is 10s, so the
            # deadline check fires on the very first poll, opencode is spawned,
            # the bundle prefill is BILLED, and the child is killed having
            # produced nothing. Found by the opus seat of the panel run on the
            # change that introduced this block.
            if (-not $retryBudget.Viable) {
                throw ("opencode run failed (exit=$exitCode, model=$modelId) with 'database is locked', and the ${TimeoutSec}s budget " +
                       "has $($retryBudget.RemainingSec)s left after $([int]$sw.Elapsed.TotalSeconds)s and a ${backoffSec}s backoff -- too little to finish a retry, " +
                       "which would bill the bundle prefill and then be killed on its first poll: $stderr")
            }
            Write-Host "[opencode] 'database is locked' (another opencode holds ~/.local/share/opencode/opencode.db). Retrying in ${backoffSec}s with $($retryBudget.RemainingSec)s of budget left, $LockRetries retries left."
            Start-Sleep -Seconds $backoffSec
            $retryArgs = @{} + $PSBoundParameters
            $retryArgs['LockRetries'] = $LockRetries - 1
            $retryArgs['TimeoutSec']  = $retryBudget.RemainingSec
            return Invoke-OpencodeReview @retryArgs
        }
        # SNAPSHOT THIS PATH TOO. This is the throw the read-tool intermittency
        # actually takes, and until 2026-09-04 it was the only failure exit that
        # wrote NO forensic artifact -- so the instrument that exists for exactly
        # this bug had never once fired on it.
        #
        # The three detector throws above (firsttoken / stall / timeout) each call
        # $snapshotPartialAndDebug. This one does not, because it is reached when
        # the CHILD died on its own: no detector tripped, opencode exited with a
        # non-zero code (or exited clean with nothing parseable), and era only
        # noticed afterwards. Measured on direction-paths-2026-09-04 round 2:
        # deepseek-flash on the read-tool path, 124,188-byte bundle, ran 570.5s,
        # emitted three "Read <bundle>" tool lines and no review, exit -1. The
        # stall threshold for that round was ~620.9s, so the detector was right
        # not to fire -- and the artifact directory stayed empty. Same shape as
        # the 74,740 B and 79,294 B losses in the watch list.
        #
        # It cannot reuse $snapshotPartialAndDebug: that scriptblock reads $stdFile
        # and $errFile, and the finally above has already read them into
        # $resultText/$stderr and DELETED them. So write from the strings we still
        # hold. Best-effort throughout -- a diagnostic must never replace the real
        # error with an error about diagnostics.
        $exitTail = ''
        try {
            $debugDir = Join-Path ([System.IO.Path]::GetTempPath()) 'opencode-stall-debug'
            $null = New-Item -ItemType Directory -Path $debugDir -Force -ErrorAction SilentlyContinue
            $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
            $pidPart = if ($opencodeProc) { $opencodeProc.Id } else { 'nopid' }
            $base = Join-Path $debugDir "exitfail-$stamp-pid$pidPart"
            Set-Content -LiteralPath "$base-stdout.txt" -Value $resultText -Encoding utf8 -ErrorAction SilentlyContinue
            Set-Content -LiteralPath "$base-stderr.txt" -Value $stderr     -Encoding utf8 -ErrorAction SilentlyContinue
            Set-Content -LiteralPath "$base-context.txt" -Encoding utf8 -ErrorAction SilentlyContinue -Value @"
model            : $modelId
variant          : $chosenVariant
delivery         : $(if ($useReadTool) { 'read-tool' } else { 'attach' })
bundle bytes     : $bundleBytes
exit code        : $exitCode
wall clock sec   : $([math]::Round($sw.Elapsed.TotalSeconds,1))
effective budget : ${effectiveTimeoutSec}s of ${TimeoutSec}s
stall threshold  : $([math]::Round($stallThresholdMs/1000,1))s  (did NOT fire, or this throw would not be the one reporting)
first-token sec  : $firstTokenSec
stdout bytes     : $($resultText.Length)
stderr bytes     : $($stderr.Length)
"@
            $exitTail = " Forensic snapshot: $base-*.txt"
        } catch {}
        throw "opencode run failed (exit=$exitCode, model=$modelId): $stderr$exitTail"
    }

    # Honest content validation: even on a clean exit, the capture can be a
    # NON-review (a tool-intent narration, a bundle-access refusal, or the prompt
    # handed straight back). Flag those and fail honestly instead of recording
    # the garbage as a successful review.
    #
    # ONE classification, shared with claude and the three REST adapters. This
    # used to be 37 lines running the two detectors itself and building a
    # failure hashtable per branch. The justification for keeping the copy was
    # that opencode "returns a fully-formed failure hashtable early" -- but the
    # SHAPE of the return is this adapter's business and the CLASSIFICATION is
    # not, so the verdict object supports it directly (round-7 opus, finding 7).
    # Narration-before-echo ordering lives in the helper, so a bundle-access
    # refusal is still reported as the refusal it is rather than as an echo.
    $verdict = Test-EraCaptureAcceptable -Response $clean -PromptPath $PromptPath -Vendor 'opencode'
    if (-not $verdict.Ok) {
        return @{
            Response      = $clean
            ExitCode      = -1
            Error         = $verdict.Error
            CaptureMethod = 'direct'
            ContentOk     = $false
            RetryCount    = 0
            RetryReason   = $verdict.Error
            InputTokens   = $null
            OutputTokens  = [Math]::Ceiling($clean.Length / 4)
            WallClockSec  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            Stderr        = $stderr
            Warnings      = @($verdict.Warning)
        }
    }

    $clean | Set-Content -LiteralPath $ResponsePath -Encoding utf8
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
