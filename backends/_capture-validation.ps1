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

    # Branch 2: no heading + no list + under the length floor -> flag.
    if (-not $hasHeading -and -not $hasList -and $text.Length -lt $LengthFloor) { return $true }

    # Branch 3: no heading + bundle-unavailable refusal -> flag.
    if (-not $hasHeading -and $bundleRefusal) { return $true }

    return $false
}
