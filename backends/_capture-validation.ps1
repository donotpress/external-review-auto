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
    if ($hasProseReview -and $noNarration) {
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
        [double]$Threshold = 0.15
    )
    if ($PromptPath -and [string]::IsNullOrEmpty($PromptText)) {
        $PromptText = Get-Content -Raw -LiteralPath $PromptPath -ErrorAction SilentlyContinue
    }
    if ([string]::IsNullOrWhiteSpace($PromptText) -or [string]::IsNullOrWhiteSpace($Response)) { return $false }

    $p = (($PromptText -replace '\s+', ' ').Trim()).ToLowerInvariant()
    $r = (($Response   -replace '\s+', ' ').Trim()).ToLowerInvariant()

    # Too short to sample meaningfully. Fail open -- this detector exists to
    # catch a specific measured failure, not to guess. A response this short is
    # a non-review anyway and belongs to the narration detector's length floor.
    if ($p.Length -lt ($WindowChars * 2)) { return $false }
    if ($r.Length -lt ($WindowChars * 2)) { return $false }

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

    # BIDIRECTIONAL, and both directions must clear the bar.
    #
    # The forward ratio alone was unsafe in the regime this actually ships in.
    # A false positive needs a contiguous verbatim run of
    # WindowChars + 5*span/(Samples-1) characters. Against the 3-85 KB
    # hand-written prompts the threshold was originally tuned on, that is
    # ~11,000 chars -- hence a measured 0.000 across 69 pairs. Against era's own
    # DEFAULT template (~628 chars normalised) it is ~195, and two adjacent
    # sentences of that template are 314. 34 of 50 historical prompts are under
    # 2,000 chars, so the short regime is the common one and was the one never
    # measured. Found by the round-5 panel on the day the detector shipped.
    #
    # The asymmetry that fixes it: an echo is prompt-shaped in BOTH directions,
    # while a review that merely quotes its instructions is prompt-shaped in one.
    #   full echo      forward ~1.00  reverse ~1.00  -> flagged
    #   quarter echo   forward ~0.23  reverse ~1.00  -> flagged
    #   review quoting 314 chars of a 628-char prompt inside a 7,655-char answer
    #                  forward ~0.30  reverse ~0.05  -> PASSES
    $forward = & $overlap $p $r
    # Cheap exit: no need to scan the response if the prompt barely appears in it.
    if ($forward -lt $Threshold) { return $false }
    $reverse = & $overlap $r $p
    return ($reverse -ge $Threshold)
}
