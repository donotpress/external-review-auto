<#
 Module: recovery -- pure classifiers, gates, fallback selection.
 Part of the workflow.ps1 split (see docs/specs/2026-09-12-era-module-boundaries.md).
 Dot-sourced by workflow.ps1; never loaded directly (no independent state).
#>

function ConvertTo-EraContractNormalized {
    <#
    .SYNOPSIS
        Normalise text for decoration-tolerant contract matching.

    .DESCRIPTION
        Measured on the 2026-08-09 panel: deepseek-flash answered '**P1: DO**'
        while gemini and opus answered 'P1: DO'. A literal check would have
        failed the sharpest response in the panel, so strip markdown decoration
        before comparing.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text -replace '[*`_#]', ''
    $t = $t -replace '\s+', ' '
    return $t.Trim().ToLowerInvariant()
}

function Get-EraResponseContract {
    <#
    .SYNOPSIS
        Read a prompt's declared response contract.

    .DESCRIPTION
        A prompt declares what its answer must contain with a marker line:

            <!-- era-require: ORDER:, DROP-ENTIRELY:, MISSING: -->

        The contract travels WITH the prompt, so a -PromptOverrideFile carries
        its own and no extra parameter is needed. No marker means lenient --
        exactly the behaviour before this existed, so existing callers are
        untouched.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$PromptText)
    if ([string]::IsNullOrEmpty($PromptText)) { return @() }
    # (?s) so the marker may WRAP across lines. Without it, `.` stopped at the
    # newline, `\s*-->` could not match, and the marker did not match AT ALL --
    # a wrapped contract vanished silently and the round ran ungated. An editor
    # hard-wrapping a long token list must not disarm the gate.
    #
    # The quantifier stays lazy and the `-->` terminator stays required, so
    # crossing newlines cannot let one marker swallow the rest of the document.
    # First marker wins (-match returns one hit); both are pinned by tests.
    if ($PromptText -notmatch '(?ims)<!--\s*era-require:\s*(.+?)\s*-->') { return @() }
    # Trim() covers the newlines and indentation a wrapped list introduces.
    return @($matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-ResponseContract {
    <#
    .SYNOPSIS
        Does a reviewer's response contain everything the prompt required?

    .DESCRIPTION
        Nothing verified that an answer matched the request: adapters checked
        non-empty text plus a finish reason, then returned ExitCode=0. A reviewer
        returned zero of ten requested verdicts three times and each was recorded
        as a normal success -- and the promoted response feeds the NEXT round's
        prompt, so a bad round poisons its successor.

        Uses .Contains() rather than -like, so a required token containing '[' or
        '*' is matched literally instead of being read as a glob.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Response,
        [AllowNull()][string[]]$Required
    )
    $req = @($Required | Where-Object { $_ })
    if ($req.Count -eq 0) { return @{ Ok = $true; Missing = @() } }

    $haystack = ConvertTo-EraContractNormalized -Text $Response
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $req) {
        $needle = ConvertTo-EraContractNormalized -Text $r
        if (-not $needle) { continue }
        if (-not $haystack.Contains($needle)) { $missing.Add($r) }
    }
    return @{ Ok = ($missing.Count -eq 0); Missing = @($missing) }
}

function Assert-EraResponseContract {
    <#
    .SYNOPSIS
        Apply a response contract across a dispatch result set, in place.
        Returns the number of results newly marked as failing.

    .DESCRIPTION
        Marks a violation exactly the way opencode marks a bad agentic capture
        (ExitCode=-1 + ContentOk=$false), so every existing consumer already
        behaves correctly: Copy-PrimaryResponseAlias skips it, the metadata
        writer records content_ok=false, and the agy fallback re-dispatches. The
        response file stays on disk -- it is evidence, not garbage; only its
        promotion to canonical is withheld.

        Results that already failed are skipped, so their original error is
        preserved and the function is idempotent. That matters because era calls
        it TWICE: once before the agy fallback, so a contract failure can trigger
        a re-dispatch, and once after, because otherwise the fallback's own
        answer is never checked.

        That second call is not hypothetical. Measured 2026-08-09 on a live
        dispatch: a failing agy reviewer triggered a fallback to gemini-api,
        whose answer was written as round-1-response.md with content_ok=true
        while missing the required token -- the exact failure mode this feature
        exists to prevent, occurring inside the feature itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Results,
        [AllowNull()][string[]]$Required
    )
    $req = @($Required | Where-Object { $_ })
    if ($req.Count -eq 0) { return 0 }

    $failed = 0
    foreach ($k in @($Results.Keys)) {
        $res = $Results[$k]
        if (-not $res -or $res.ExitCode -ne 0) { continue }
        $verdict = Test-ResponseContract -Response $res.Response -Required $req
        if ($verdict.Ok) { continue }
        $miss = ($verdict.Missing -join ', ')
        Write-Host "[era] $k FAILED the response contract; missing: $miss"
        $res.ExitCode    = -1
        $res.ContentOk   = $false
        $res.Error       = 'response-contract'
        $res.RetryReason = "response-contract: missing $miss"
        $res.Warnings    = @($res.Warnings) + "Response contract failed; missing: $miss"
        $Results[$k] = $res
        $failed++
    }
    return $failed
}

function Get-EraFallbackPresetOverride {
    <#
    .SYNOPSIS
        Effective fallback-preset override: ERA_FALLBACK_PRESET wins, else
        ERA_AGY_FALLBACK (legacy), else $null. Resolvers injectable for tests.
    .DESCRIPTION
        Alias-only by design: four order-sensitive assertions in
        ResponseContract.Tests.ps1 pin the legacy string in era.ps1, so the
        old name keeps working forever. New name wins when both are set;
        blank/whitespace counts as unset. 'off'/'0' pass through untouched --
        the disable path keys on the resolved value, and an explicit off in
        either name must survive resolution.
    #>
    [CmdletBinding()]
    param(
        [scriptblock]$EnvValue = { param($n) [Environment]::GetEnvironmentVariable($n) }
    )
    foreach ($name in @('ERA_FALLBACK_PRESET', 'ERA_AGY_FALLBACK')) {
        $v = & $EnvValue $name
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return ([string]$v).Trim() }
    }
    return $null
}

function Get-EraFallbackBlocker {
    <#
    .SYNOPSIS
        What would unlock a fallback: first preference preset + requirement.
    .DESCRIPTION
        Called only when Resolve-EraAgyFallback returned $null, so this names
        the unblock action instead of repeating the failure. Mirrors the
        resolver's preference order and its non-agy rule; reports the first
        preset's requirement (API-key env name, or which CLI must be on
        PATH). When every preference preset is already in the run (or
        agy-backed), no in-panel answer exists -- say out-of-panel explicitly
        rather than naming a requirement the operator cannot satisfy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Registry,
        [string[]]$Exclude = @(),
        [string[]]$Preference = @('gemini-api', 'deepseek-http', 'sonnet', 'haiku', 'minimax-http', 'nvidia', 'gemini-api-pro')
    )
    $cliFor = @{ agy = 'agy'; claude = 'claude'; opencode = 'opencode' }
    foreach ($p in $Preference) {
        $e = $Registry[$p]
        if (-not $e -or -not $e.backend) { continue }
        if ($Exclude -contains $p) { continue }
        if ($e.backend -eq 'agy') { continue }
        if ($e.api_key_env) { return "'$p' needs `$env:$($e.api_key_env)" }
        $cli = if ($cliFor.ContainsKey($e.backend)) { $cliFor[$e.backend] } else { $e.backend }
        return "'$p' needs the $cli CLI"
    }
    return 'all built-in fallbacks are already in this panel (or agy-backed); pass an out-of-panel preset via ERA_FALLBACK_PRESET'
}

function Resolve-EraAgyFallback {
    <# Pick a non-agy fallback reviewer when an agy capture fails. Honors an explicit
       $env:ERA_AGY_FALLBACK preset if it is valid, non-agy, and available; otherwise
       the first available non-agy preset by preference. Excludes presets already in
       the run and ALL agy-backed presets. Returns $null if none available. Resolvers
       injectable for tests. #>
    [CmdletBinding()]
    param(
        $Registry,
        [string]$Override,
        [string[]]$Exclude = @(),
        [string[]]$Preference = @('gemini-api','deepseek-http','sonnet','haiku','minimax-http','nvidia','gemini-api-pro'),
        [scriptblock]$CommandExists = { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) },
        [scriptblock]$EnvValue      = { param($n) [Environment]::GetEnvironmentVariable($n) }
    )
    $isUsable = {
        param($p)
        $e = $Registry[$p]
        if (-not $e -or -not $e.backend) { return $false }
        if ($e.backend -eq 'agy') { return $false }
        if ($Exclude -contains $p) { return $false }
        return [bool](Test-EraBackendAvailable -Backend $e.backend -ApiKeyEnv $e.api_key_env `
            -CommandExists $CommandExists -EnvValue $EnvValue)
    }
    if ($Override -and $Override -ne 'off' -and $Override -ne '0' -and (& $isUsable $Override)) {
        return $Override
    }
    foreach ($p in $Preference) {
        if (& $isUsable $p) { return $p }
    }
    return $null
}

function Get-EraRecoverableFailures {
    <#
    .SYNOPSIS
        Which reviewers failed in a way the ONE bounded fallback re-dispatch can
        plausibly recover? Returns their preset names, de-duplicated.

    .DESCRIPTION
        The trigger used to be inline in era.ps1 and read:

            $failedAgy      = backend -eq 'agy'  AND ExitCode -ne 0
            $failedContract = Error   -eq 'response-contract'

        Its comment said the widening existed so that "a REST or opencode
        reviewer that returned off-contract output" no longer "spent the whole
        round with zero usable result and no recovery". Measured 2026-08-10, the
        intent was not met in the DEFAULT configuration: no shipped prompt
        carries an `era-require` marker (the contract is deliberately opt-in), so
        `response-contract` never fires on a default run and the only live
        trigger was `backend -eq 'agy'`. Everything else spent the round
        unrecovered -- including case (b) of the 2026-08-09 void round, where
        deepseek-flash failed after reading the bundle and nothing re-dispatched.

        Recoverable now means an HONEST CAPTURE FAILURE on any backend: the call
        completed and what came back was not a review. A second attempt can
        plausibly fix that.

        NOT recoverable: a free-text adapter exception (network fault, bad model
        id, auth, rate limit). Re-dispatching those doubles the latency and the
        bill for something a retry cannot fix -- the same reasoning the claude
        adapter already applies to its WSL credential retry.

        Widening WHAT is recoverable does not widen HOW MANY re-dispatches run:
        the caller is still bounded to one, still prices it against the
        per-reviewer cap, and still contract-checks the fallback's own answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReviewerList,
        [Parameter(Mandatory)][hashtable]$Results,
        [Parameter(Mandatory)][hashtable]$Registry
    )
    # Every error code an adapter sets deliberately to mean "this ran, and what
    # came back was not a review". Free-text exception messages are excluded by
    # construction: they never equal one of these.
    # 'empty-capture' joined 2026-09-06: a seat that returned nothing is the
    # clearest case a re-dispatch can plausibly fix, and it was previously
    # unreachable because the shared detector accepted an empty response.
    #
    # The two tmux codes are the transport's own recoverable failures (a seat
    # that crashed, or wrote a partial file before dying). Its TIMEOUT codes are
    # deliberately ABSENT: a seat that burned its whole budget must not be given
    # another whole budget, which is a defect this repo already fixed once in the
    # tmux design's own terminal conditions.
    #
    # The first three are Get-EraAnsweredBadlyCodes (referenced, not repeated):
    # a second literal here is how the two lists drifted apart in 2026-09-11.
    # 'breaker-skip' is recoverable so a round voided by skips still gets its
    # one REST fallback (usually a different pool than the skipped backend);
    # in usable rounds the standard gate already owns the decision.
    $recoverable = @((Get-EraAnsweredBadlyCodes) +
                     @('empty-capture', 'tmux-seat-exited', 'tmux-seat-truncated',
                       'breaker-skip',
                        # Zero-output deaths (each decoded from its adapter's
                        # trailer by Convert-EraAdapterResultError at result
                        # collection; free-text exceptions stay excluded):
                        # opencode exit -1, claude first-byte death (slow-kill;
                        # recoverable here for void rounds but NOT a
                        # dead-transport code, so usable rounds skip the extra
                        # REST re-dispatch), legacy claude-no-output (pre-split
                        # trailer; nothing emits it anymore, kept decoding).
                        # (Agy's stream/interruption/quota codes ride the
                        # $isAgy branch below, not this list.)
                        'opencode-no-output', 'claude-no-output', 'claude-first-byte-timeout'))

    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $ReviewerList) {
        $res = $Results[$r]
        if (-not $res -or $res.ExitCode -eq 0) { continue }
        # agy stays recoverable on ANY failure: its capture is transcript-scraped
        # and historically flaky in ways that are not error-coded.
        $isAgy = $Registry[$r] -and $Registry[$r].backend -eq 'agy'
        if ($isAgy -or ($res.Error -and $recoverable -contains $res.Error)) {
            if (-not $out.Contains($r)) { $out.Add($r) }
        }
    }
    return @($out)
}

function Get-EraFailureCategory {
    <#
    .SYNOPSIS
        One word for WHY a seat failed: 'not-delivered', 'answered-badly',
        'no-artifact', or 'unknown'.

    .DESCRIPTION
        The two are already distinguished STRUCTURALLY — an honest capture
        failure sets a coded $r.Error ('response-contract',
        'agentic-narration-capture', 'prompt-echo') while a stall, timeout or
        crash surfaces as a free-text exception message — and that distinction is
        what Get-EraRecoverableFailures keys on. But the round summary printed
        only the raw reason string, so the reader had to know the codes to tell
        "this reviewer never saw the bundle" from "this reviewer read it and
        answered off-contract". Those are opposite facts:

          not-delivered   nothing was reviewed. The panel is smaller than it looks
                          and the seat's silence carries NO information.
          answered-badly  the bundle WAS reviewed; the answer was rejected. The
                          seat's failure is about the answer, not the delivery.

        Conflating them is how a degraded panel reads as a real one, so the
        summary now says which.
    #>
    [CmdletBinding()]
    param([hashtable]$Result, [bool]$HasArtifact = $false)
    if (-not $Result) { return 'not-delivered' }
    # Deliberate capture-failure codes: the call completed and what came back was
    # not a review. Answered-badly is single-sourced (Get-EraAnsweredBadlyCodes);
    # the transport codes below intentionally stay 'not-delivered' -- nothing
    # was reviewed on those paths, which is the opposite fact.
    $answered = Get-EraAnsweredBadlyCodes
    # A BUNDLE-ACCESS REFUSAL IS NOT AN ANSWER. The detector already worked out
    # which of its three branches fired and put it in NonReviewBranch; this
    # function ignored it and called every agentic-narration-capture
    # 'answered-badly' -- including the one that means the model never SAW the
    # bundle, where nothing was reviewed at all. Those are opposite facts, and
    # collapsing them is the exact thing this classifier exists to prevent.
    # Two implementations of one rule, one of them discarding what the other
    # computed. Found by the first panel pointed at this code.
    if ($Result.NonReviewBranch -eq 'bundle-access-refusal') { return 'not-delivered' }
    if ($Result.Error -and $answered -contains $Result.Error) { return 'answered-badly' }
    if ($Result.ExitCode -eq 0 -and -not $HasArtifact) { return 'no-artifact' }
    if ($Result.Error -or $Result.RetryReason) { return 'not-delivered' }
    return 'unknown'
}

function Get-EraAnsweredBadlyCodes {
    <#
    .SYNOPSIS
        The deliberate failure codes meaning "the bundle WAS reviewed; the
        answer was rejected". Single source for both classifiers below.
    .DESCRIPTION
        Get-EraRecoverableFailures and Get-EraFailureCategory each kept their
        own literal of this set with a comment promising parity -- and
        drifted (2026-09-11: 8 codes vs 3). One function, referenced twice.
        Each code names an ANSWER failure, as opposed to the transport codes
        ('empty-capture', 'opencode-no-output', 'agy-stream-interrupted', the
        tmux pair) that mean nothing was reviewed at all.
    .OUTPUTS
        [string[]].
    #>
    [CmdletBinding()]
    param()
    return @('response-contract', 'agentic-narration-capture', 'prompt-echo')
}

function Test-EraFatalFailure {
    <#
    .SYNOPSIS
        Did this seat fail in a way that indicts its BACKEND? Pure predicate.
    .DESCRIPTION
        The circuit breaker counts consecutive backend-fatal rounds per
        backend. Fatal = the seat burned budget and returned nothing usable
        for reasons OUTSIDE the answer: stalls, timeouts, crashes, empty
        captures, dead-transport codes, quota. NOT fatal = the seat-level
        flakiness in Get-EraAnsweredBadlyCodes (narration/contract/echo):
        the backend answered, the seat misbehaved -- no streak.
        Successes and non-fatal failures both BREAK a streak (the backend
        demonstrably served or spoke).
    .OUTPUTS
        [bool].
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Result)
    if (-not $Result -or $Result.ExitCode -eq 0) { return $false }
    if ($Result.Error -and (Get-EraAnsweredBadlyCodes) -contains $Result.Error) { return $false }
    # A breaker skip records ABSENCE of evidence (the seat never ran), not a
    # failure. Counting it would grow the streak every round with no new
    # information and wedge the backend off permanently -- measured 2026-09-13:
    # claude reached 7 consecutive "fatals" with last_error breaker-skip.
    if ($Result.Error -eq 'breaker-skip') { return $false }
    return $true
}

function Test-EraFallbackNeeded {
    <#
    .SYNOPSIS
        Should the one bounded fallback re-dispatch actually run? Only when
        something is recoverable AND the round has nothing usable yet.

    .DESCRIPTION
        Round-6 finding. era dispatched the fallback whenever anything was
        recoverable, with no reference to whether a usable review already
        existed. Under the original agy-only trigger that was rare; 1f80b69
        widened recovery to agentic-narration-capture and prompt-echo on ANY
        backend, which made "one flaky member of a healthy panel" the common
        case -- and each occurrence buys a full extra bundle upload.

        Measured over the existing rounds, no new dispatch needed:
            era-grade round 4: 3/4 usable, fallback billed $0.0232
            era-grade round 6: 2/4 usable, fallback billed $0.0457
        Round 6 paid for it live: deepseek returned a 154-char non-review, the
        fallback fired, and opus and gemini had already returned real reviews.

        The fallback exists to stop an EMPTY round. If the round already has an
        answer, another full-bundle dispatch buys marginal diversity the caller
        did not ask for and did not price.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$RecoverableCount,
        [Parameter(Mandatory)][int]$UsableCount
    )
    return (($RecoverableCount -gt 0) -and ($UsableCount -eq 0))
}

function Test-EraDeadTransportFallback {
    <#
    .SYNOPSIS
        Should the one bounded fallback re-dispatch run for dead-transport
        seats even though the round already has usable reviews?
    .DESCRIPTION
        MEASURED 2026-09-11/12: a seat can die with its model never emitting
        -- agy stream interruptions, opencode zero-stdout exits, agy quota
        wall, claude first-byte death -- while the rest of the panel
        succeeds. The standard gate above then (correctly, by its own
        rationale) refuses the fallback and the panel silently shrinks.

        This gate covers exactly those cases, and ONLY those: at least one
        seat failed with a dead-transport code in $DeadTransport (counts per
        code; absent counts as zero) AND the round is otherwise usable. A
        void round stays owned by the standard gate (which fires on any
        recoverable failure); any other failure mix behaves exactly as
        before. The map form (not one param per code) is deliberate: the
        fourth code already strained per-code params, and the next dead
        transport must not require a signature change.

        The bounds are inherited, not widened: still ONE fallback dispatch per
        round, still priced against the fallback preset's per-reviewer cap,
        still delivery-checked, still disabled by the fallback override
        (outer gate in era.ps1), and the fallback still runs on the REST
        transport -- which is the entire point, since the dead transport is
        the thing that is down.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][hashtable]$DeadTransport,
        [Parameter(Mandatory)][int]$UsableCount
    )
    $any = $false
    if ($DeadTransport) {
        foreach ($v in @($DeadTransport.Values)) {
            if ([int]$v -gt 0) { $any = $true; break }
        }
    }
    return ($any -and ($UsableCount -gt 0))
}

function Convert-EraAdapterResultError {
    <#
    .SYNOPSIS
        Map a collected seat result to a deliberate failure code when its
        adapter stamped one. Returns the code, or $null.
    .DESCRIPTION
        Most adapter exceptions stay free-text (network, auth, bad model id
        -- things a re-dispatch cannot fix, deliberately excluded from
        recovery).         But an adapter can append a parseable trailer naming a
        failure whose recovery IS known. Three trailers exist:

          [opencode-no-output stdout=N delivery=D]  (opencode.ps1 exit-fail)
          [claude-no-output stdout=N]               (legacy claude.ps1 trailer)
          [claude-first-byte-timeout stdout=N after=Ns]  (claude.ps1 slow-kill)

        stdout=0 means the model never emitted anything. opencode-no-output
        and legacy claude-no-output are the dead-transport class, recoverable
        via a REST re-dispatch ("dead transport -> REST fallback", see
        Test-EraDeadTransportFallback). claude-first-byte-timeout is the
        slow-kill class: recoverable in a void round via the standard gate,
        but deliberately outside the dead-transport set -- in text mode the
        bound is a total cap, so this usually killed a healthy slow review
        and a usable round must not buy an extra upload over it. stdout>0
        (died mid-answer) keeps its free-text error: different fact,
        different recovery.

        Two channels carry one concept ("dead transport -> REST fallback",
        see Test-EraDeadTransportFallback), and they differ on purpose -- do
        not unify them: opencode throws, so the Stderr trailer is its only
        channel out; agy returns structured results, so it upgrades its
        reason in-adapter. A future trailer author registers here, in
        Convert-EraAdapterResultError, parent-side (the dispatch ThreadJobs
        cannot see workflow.ps1 functions).

        Runs PARENT-side at result collection: the dispatch ThreadJobs
        dot-source only their adapter file, so workflow.ps1 functions are
        not visible inside the job's catch (measured 2026-09-11: calling one
        from there records "not recognized" INSTEAD of the real error).
        Matching anchors at the Stderr END, where the adapter put the
        trailer -- and the in-job truncation preserves head+tail, so a long
        message keeps it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Result)
    if (-not $Result) { return $null }
    $text = [string]$Result.Stderr
    if ([string]::IsNullOrEmpty($text)) { return $null }
    if ($text -match '\[opencode-no-output stdout=(\d+) delivery=([^\]]+)\]\s*$') {
        if ([int]$Matches[1] -eq 0) { return 'opencode-no-output' }
    }
    if ($text -match '\[claude-no-output stdout=(\d+)\]\s*$') {
        if ([int]$Matches[1] -eq 0) { return 'claude-no-output' }
    }
    if ($text -match '\[claude-first-byte-timeout stdout=(\d+) after=[^\]]+\]\s*$') {
        if ([int]$Matches[1] -eq 0) { return 'claude-first-byte-timeout' }
    }
    return $null
}

