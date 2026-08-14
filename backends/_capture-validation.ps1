<#
.SYNOPSIS
    Shared capture-validation helper, dot-sourced by the agentic backends (agy,
    opencode) whose models can emit a non-review (tool-intent narration or a
    "can't read the bundle" refusal) and still exit 0. Both backends route their
    captured output through Test-AgenticNarrationCapture so such captures fail
    honestly instead of being recorded as a successful review.
#>

function Test-AgenticNarrationCapture {
    <#
    .SYNOPSIS
        Classify a captured response as an agentic tool-intent narration / refusal
        (a non-review) rather than a real review. Returns $true when the response
        should be treated as a FAILED capture.

    .DESCRIPTION
        Agentic backends (agy --print; opencode run, which reads the bundle via a
        Read tool) sometimes emit a short tool-intent narration ("I will view
        tests/x.py...", "Let me run the unit tests") or a "I cannot read the
        bundle" refusal instead of reviewing. Those exit 0 and were silently
        recorded as successful reviews. This detector flags them.

        Logic:
          Flag IFF
            (no markdown heading AND narration-match)                       [B1]
          OR
            (no heading AND no list marker AND length < $LengthFloor)       [B2]
          OR
            (no heading AND bundle-unavailable refusal)                     [B3]

        ALL anchored patterns use (?m)/(?im) so a multi-line real review whose
        FIRST line is prose but which contains "## Critical issues" later is NOT
        mis-flagged (without (?m), PowerShell ^ matches only the very start of
        the whole string).

        The list-marker gate applies ONLY to the length branch — otherwise an
        agentic "I will check these:\n- a\n- b" capture (which DOES carry a list
        marker) would slip past the narration branch.

        The list regex is (?m)^\s*([-*+]|\d+[.)]) — NOT [-*+\d], which would
        mis-count "2026 update:" / "404 errors:" as a list and open a false
        negative.

        A response that is exactly/primarily "(none)" (a legitimately empty
        review) is treated as VALID and never flagged.
    #>
    [CmdletBinding()]
    param(
        [string]$Response,
        [int]$LengthFloor = 300
    )

    # Empty / whitespace-only captures are not "narration" per se; let the caller
    # treat a null response as a hard failure separately. Here, only classify
    # actual text. An empty string is not flagged by this detector.
    if (-not $Response) { return $false }
    $text = [string]$Response

    # "(none)"-only valid empty-form guard. A legitimately empty review may be just
    # "(none)" with no heading/list and <floor chars; it must not be flagged by the
    # length branch.
    if ($text.Trim() -match '^\(none\)\.?$') { return $false }

    $hasHeading = $text -match '(?m)^\s*#{1,6}\s'
    $hasList    = $text -match '(?m)^\s*([-*+]|\d+[.)])'
    $narration  = $text -match '(?im)^\s*(I will|I''ll|Let me|I need to|First,?\s+I)\b.*\b(view|open|read|run|check|inspect|look)\b'

    # B3: a "bundle not available" refusal is not a review. An agentic backend may
    # return "I cannot review the bundle content because it was not included ...
    # please paste the content" instead of reviewing. Such a capture can EXCEED the
    # length floor and match no narration verb, so it needs its own branch.
    # Anchored on the bundle/file/content being unavailable (or a request to paste
    # it), so a real review that merely says "I cannot find any issues" (no bundle
    # reference) is NOT flagged. The no-heading gate (consistent with B1) further
    # protects a structured review that discusses this failure mode in prose.
    $bundleRefusal =
        ($text -match '(?im)\b(cannot|can.?t|could ?n.?t|unable to|not able to)\b[^.\n]{0,40}\b(review|see|access|read|open|find|locate|retrieve)\b[^.\n]{0,40}\b(bundle|attachment|attached|file|content)\b') -or
        ($text -match '(?im)\bpaste\b[^.\n]{0,40}\b(bundle|content|file)\b') -or
        ($text -match '(?im)\b(bundle|attachment|file content)\b[^.\n]{0,40}\b(not|n.t)\s+(included|attached|provided|present|available)\b')

    # Branch 1: no heading + narration -> flag (list marker irrelevant here).
    if (-not $hasHeading -and $narration) { return $true }

    # Branch 2: no heading + no list + under the length floor -> flag,
    # UNLESS the text reads like natural-language code-review prose
    # (e.g. "No correctness issues found; the concurrency fix is sound.")
    # which is a legitimate terse review, not agentic narration.
    $hasProseReview = $text -match '(?im)\b(correct|incorrect|issue|sound|valid|should\s+(be|fix|work)|seems?\s+(fine|good|ok|correct|right)|looks?\s+(good|fine|correct|right)|no\s+(problems?|issues?|bugs?|concerns?|edge.cases?)|edge\s+case|suggest(|ion|ed)\b)'
    $noNarration = -not ($text -match '(?im)(I will|I.ll|Let me|I need to|First,?\s+I)\b')
    # A bare GERUND OPENER ("Checking...", "Looking into...") is the same
    # tool-intent narration B1 catches, minus the "I will". Round-5 (opus): the
    # prose whitelist above matches any occurrence of issue|correct|valid|sound|
    # edge case|suggest, so "Checking for issues now." (24 chars) was classified
    # as a legitimate terse review and the sub-floor branch -- the one that
    # catches two-character answers on `opus` -- was defeated by one common word.
    #
    # This belongs to the LENGTH branch, not to B1. A substantial prose review
    # may legitimately open "Checking the dispatcher for races, I found..."; it
    # is only narration when the text is also short. Putting it in B1 (which has
    # no length gate) would reject those. Both directions are pinned by test.
    # (?i) only -- deliberately NOT (?m). Round-7 (opus): with (?m), ^ matches at
    # every line start, so this disqualified the whitelist for a gerund on ANY
    # line. Measured: "No correctness issues found; the concurrency fix is
    # sound.\nReviewing the retry loop confirmed it." (97 chars) was flagged as a
    # non-review purely for its second sentence. \A anchors to the start of the
    # whole text, which is what "opener" was always supposed to mean.
    $gerundOpener = $text -match '(?i)\A\s*(checking|looking|reviewing|analy[sz]ing|examining|inspecting|scanning|starting|beginning|working)\b'
    if ($hasProseReview -and $noNarration -and -not $gerundOpener) {
        # Legitimate terse review prose — let it pass even if under the floor.
    } elseif (-not $hasHeading -and -not $hasList -and $text.Length -lt $LengthFloor) { return $true }

    # Branch 3: no heading + bundle-unavailable refusal -> flag.
    if (-not $hasHeading -and $bundleRefusal) { return $true }

    return $false
}

function Test-EraPromptEcho {
    <#
    .SYNOPSIS
        Is this "response" just the prompt handed back? Returns $true for an
        echo, which is a non-review no matter how well-formed it looks.

    .DESCRIPTION
        Measured 2026-08-09: gemini-pro-high hit maxOutputTokens and what landed
        on disk was THE PROMPT, ECHOED BACK. Nothing caught it as content:

          * Test-AgenticNarrationCapture cannot -- every one of its branches is
            gated on the response having NO markdown heading, and an era prompt
            is full of them.
          * A response contract cannot either -- the prompt necessarily CONTAINS
            the tokens it requires, so an echo satisfies it. Measured:
            Test-ResponseContract on an echoed prompt returns Ok=$true,
            Missing=[].

        Method: normalise whitespace and case, sample $Samples evenly-spaced
        windows of $WindowChars from the PROMPT, and count how many appear
        verbatim in the response. An echo reproduces runs from all over the
        prompt; a real review does not.

        THRESHOLD, measured against 69 real prompt->response pairs across 28
        topics in the local .external-reviews/ corpus. Full table in
        docs/assessments/2026-08-10-prompt-echo-threshold.md.

          window   legit max   pairs>0 of 69   TP full   TP half   TP quarter
             20        0.150              50     1.000     0.500        0.250
             40        0.050              21     1.000     0.500        0.250
             60        0.025              10     1.000     0.500        0.250
             80        0.000               0     1.000     0.475        0.225
            120        0.000               0     1.000     0.475        0.225
            240        0.000               0     1.000     0.450        0.200

        The decay from 50 nonzero pairs at W=20 to zero at W=80 is what shows the
        metric measures real overlap rather than always returning 0. W=120 sits
        well inside the clean plateau, and 0.15 is above every legitimate value
        observed at ANY window size while staying below the worst true positive
        (a quarter-echo at 0.225).

        The hardest false-positive case is in that corpus: round 2+ prompts embed
        the previous round's full responses via {{PREVIOUS_ROUND}} -- the
        era-grade round-2 prompt is 85 KB of mostly prior review text -- and
        reviewers discuss them at length. Still 0.000: reviewers paraphrase and
        re-cite line numbers, they do not reproduce 120-char verbatim runs.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$PromptText,
        [AllowNull()][AllowEmptyString()][string]$Response,
        [AllowNull()][AllowEmptyString()][string]$PromptPath,
        [int]$WindowChars = 120,
        [int]$Samples = 40,
        # Forward = how much of the PROMPT reappears in the response. A cheap
        # pre-filter only -- measured on tests/fixtures/echo-corpus, forward
        # CANNOT separate the two populations: legitimate max 0.450 EXCEEDS true
        # positive min 0.350. That overlap is exactly why the one-directional
        # detector rejected good reviews.
        [double]$Threshold = 0.15,
        # Reverse = how much of the RESPONSE is verbatim prompt. This is the
        # real discriminator, and it is not close: every echo measures 1.000
        # (the response IS prompt text) against a legitimate maximum of 0.100.
        # 0.60 sits in the middle of a 10x gap and costs nothing -- no measured
        # true positive is below 1.000. See tests/EchoCalibration.Tests.ps1.
        [double]$ReverseThreshold = 0.60
    )
    if ($PromptPath -and [string]::IsNullOrEmpty($PromptText)) {
        $PromptText = Get-Content -Raw -LiteralPath $PromptPath -ErrorAction SilentlyContinue
    }
    if ([string]::IsNullOrWhiteSpace($PromptText) -or [string]::IsNullOrWhiteSpace($Response)) { return $false }

    $ratio = Get-EraPromptEchoRatio -PromptText $PromptText -Response $Response `
        -WindowChars $WindowChars -Samples $Samples
    if (-not $ratio.Judged) { return $false }
    return (($ratio.Forward -ge $Threshold) -and ($ratio.Reverse -ge $ReverseThreshold))
}

function Get-EraPromptEchoRatio {
    <#
    .SYNOPSIS
        The raw bidirectional overlap between a prompt and a response. Returns
        @{ Judged; Forward; Reverse; Min }.

    .DESCRIPTION
        Split out of Test-EraPromptEcho 2026-08-11 so the calibration harness can
        measure the MARGIN between legitimate reviews and echoes, not merely
        whether the current threshold happens to separate them today. A boolean
        cannot tell you the separation is narrowing; a ratio can.

        Judged=$false means the pair is outside this detector's competence (one
        side shorter than WindowChars*2) and the caller must fail open.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$PromptText,
        [AllowNull()][AllowEmptyString()][string]$Response,
        [int]$WindowChars = 120,
        [int]$Samples = 40
    )
    $unjudged = @{ Judged = $false; Forward = 0.0; Reverse = 0.0; Min = 0.0 }
    if ([string]::IsNullOrWhiteSpace($PromptText) -or [string]::IsNullOrWhiteSpace($Response)) { return $unjudged }

    $p = (($PromptText -replace '\s+', ' ').Trim()).ToLowerInvariant()
    $r = (($Response   -replace '\s+', ' ').Trim()).ToLowerInvariant()
    if ($p.Length -lt ($WindowChars * 2)) { return $unjudged }
    if ($r.Length -lt ($WindowChars * 2)) { return $unjudged }

    # Fraction of evenly-spaced windows sampled from $From that appear verbatim
    # in $In.
    $overlap = {
        param([string]$From, [string]$In)
        $starts = [System.Collections.Generic.HashSet[int]]::new()
        $span = $From.Length - $WindowChars
        for ($i = 0; $i -lt $Samples; $i++) {
            $null = $starts.Add([int]($i * $span / [Math]::Max(1, $Samples - 1)))
        }
        $hit = 0
        foreach ($s in $starts) {
            if ($In.Contains($From.Substring($s, $WindowChars))) { $hit++ }
        }
        return ([double]$hit / $starts.Count)
    }

    $forward = & $overlap $p $r
    $reverse = & $overlap $r $p
    return @{
        Judged  = $true
        Forward = $forward
        Reverse = $reverse
        Min     = [Math]::Min($forward, $reverse)
    }
}

function Test-EraCaptureAcceptable {
    <#
    .SYNOPSIS
        Is this captured text a review? Returns @{ Ok; Error; Warning }.

    .DESCRIPTION
        One classification shared by the adapters that reach the decision at the
        same point with the same inputs -- the three REST backends and claude.
        Round 5 and 6 both flagged the same ~15-line block replicated across six
        adapters; opus's verdict was "half is defensible, half is not". This is
        the half that is not.

        agy and opencode keep their own call sites on purpose: agy decides inside
        its retry loop, where a rejection means "try again" rather than "fail",
        and opencode returns a fully-formed failure hashtable early. Forcing
        those through one signature would be worse than the duplication.

        Order matters: narration is checked BEFORE echo, so a bundle-access
        refusal -- which is also technically prompt-shaped -- is reported as the
        refusal it actually is.

        Call it on the model's OWN text, before any truncation banner is
        prepended; the banners are this skill's prose and would both dilute the
        echo ratio and inflate the narration length floor.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Response,
        [AllowNull()][AllowEmptyString()][string]$PromptPath,
        [string]$Vendor = 'The provider'
    )
    if (Test-AgenticNarrationCapture -Response $Response) {
        return @{
            Ok = $false; Error = 'agentic-narration-capture'
            Warning = "$Vendor returned a non-review (tool-intent narration / bundle-access refusal / sub-floor non-answer); detector fired — re-dispatch to retry."
        }
    }
    if ($PromptPath -and (Test-EraPromptEcho -PromptPath $PromptPath -Response $Response)) {
        return @{
            Ok = $false; Error = 'prompt-echo'
            Warning = "$Vendor returned the prompt echoed back rather than a review (prompt-echo detector fired); re-dispatch to retry."
        }
    }
    return @{ Ok = $true; Error = $null; Warning = $null }
}
