#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer-2 model-hint resolver for /external-review-auto (era.ps1).

.DESCRIPTION
    Resolves a free-form `-Model <hint>` string to a concrete model_id +
    provider by two-pass (exact-then-substring) matching across the claude / agy
    / opencode registries in `_registry.json`.

    EXTRACTED from era.ps1's inline Layer-2 loop (PR-D / D.0). This is a
    BEHAVIOR-PRESERVING refactor. The original code lived inline at era.ps1
    ~lines 261-414 and relied on `$script:_MatchMode` plus the closures
    `_Canon`/`_CanonMatch`. Lifting that into a function changes `$script:`
    semantics, so per R4-Opus-I5 the match mode is now a FUNCTION PARAMETER
    (`-MatchMode`, the outer loop iterates 'exact' then 'substring') and both
    `_Canon`/`_CanonMatch` are FUNCTION-LOCAL. Without this rewrite the two-pass
    exact/substring matching would silently regress (e.g. exact `mimo-v2.5`
    would be shadowed by `mimo-v2.5-pro` — the classic shorter-canonical-of-
    longer substring trap).

    Pure refactor: the matching logic, registry traversal order (claude → agy →
    opencode), tier selection, and explicit-tier handling are identical to the
    original inline code. It returns ONLY the resolved model_id + provider; all
    of era.ps1's downstream cross-backend application / messaging stays in
    era.ps1.

.OUTPUTS
    A hashtable @{ ModelId = <string>; Provider = <string> } on a successful
    resolution, or $null when the hint resolves to nothing.
#>

function Resolve-ModelFromHint {
    [CmdletBinding()]
    param(
        # The raw -Model hint string (free-form, e.g. 'gemini 3.1 pro low').
        [Parameter(Mandatory)][AllowEmptyString()][string]$Hint,
        # The parsed _registry.json object (ConvertFrom-Json result), carrying
        # _claude_model_map / _agy_model_map / _opencode_model_map.
        [Parameter(Mandatory)]$Registry
    )

    if (-not $Hint) { return $null }

    # Canonical: alphanumeric-only, lowercase. Used for substring matching so
    # dotted version strings ('glm 5.1', 'gemini 3.1 pro', 'deepseek v4 pro')
    # match regardless of whether the hint uses spaces, dashes, or dots.
    $hintCanon = ($Hint.ToLower() -replace '[^a-z0-9]', '')

    # FUNCTION-LOCAL canonicaliser (was a script-scope closure inline).
    $_Canon = {
        param([string]$s)
        if ($null -eq $s) { return '' }
        ($s.ToLower() -replace '[^a-z0-9]', '')
    }

    # Build the three lookup maps (same as the inline code).
    $claudeMap = @{}
    if ($Registry._claude_model_map) {
        $Registry._claude_model_map.PSObject.Properties | ForEach-Object {
            $claudeMap[$_.Name] = $_.Value
        }
    }
    $opencodeMap = @{}
    if ($Registry._opencode_model_map) {
        $Registry._opencode_model_map.PSObject.Properties | ForEach-Object {
            $opencodeMap[$_.Name] = $_.Value
        }
    }
    $agyMap = @{}
    if ($Registry._agy_model_map) {
        $Registry._agy_model_map.PSObject.Properties | ForEach-Object {
            $agyMap[$_.Name] = $_.Value
        }
    }

    $resolvedModelId = $null
    $resolvedProvider = $null

    # Two-pass resolution: try exact match across all three registries first;
    # only fall back to substring matching if no exact match exists. This
    # prevents shorter-canonical-of-longer false positives (mimo-v2.5 vs
    # mimo-v2.5-pro) without sacrificing the ergonomic substring-fallback
    # behavior for partial hints. $MatchMode is now a FUNCTION PARAMETER of the
    # inner matcher (was $script:_MatchMode), iterated by this outer loop.
    foreach ($matchMode in @('exact', 'substring')) {
        if ($resolvedModelId) { break }

        # FUNCTION-LOCAL matcher; $matchMode captured from the enclosing loop.
        $_CanonMatch = {
            param([string]$a, [string]$b)
            if (-not $a -or -not $b) { return $false }
            if ($matchMode -eq 'exact') { return $a -eq $b }
            return $a.Contains($b) -or $b.Contains($a)
        }

        # --- claude registry ---
        foreach ($familyKey in $claudeMap.Keys) {
            $family = $claudeMap[$familyKey]
            foreach ($tierKey in $family.PSObject.Properties.Name) {
                $entry = $family.$tierKey
                $displayCanon = & $_Canon $entry.display
                $familyCanon = & $_Canon $familyKey
                if ((& $_CanonMatch $displayCanon $hintCanon) -or (& $_CanonMatch $familyCanon $hintCanon)) {
                    $resolvedModelId = $entry.model_id
                    $resolvedProvider = 'claude'
                    break
                }
            }
            if ($resolvedModelId) { break }
        }

        # --- agy registry ---
        if (-not $resolvedModelId) {
            # Detect explicit tier word in hint so "gemini 3.1 pro low" pins to low, not high.
            $hintExplicitTier = if ($hintCanon -match 'high$') { 'high' } elseif ($hintCanon -match 'medium$') { 'medium' } elseif ($hintCanon -match 'low$') { 'low' } else { $null }
            $agyCandidates = @()
            foreach ($familyKey in $agyMap.Keys) {
                $family = $agyMap[$familyKey]
                foreach ($tierKey in $family.PSObject.Properties.Name) {
                    $entry = $family.$tierKey
                    $displayCanon = & $_Canon $entry.display
                    $familyCanon = & $_Canon $familyKey
                    if ((& $_CanonMatch $displayCanon $hintCanon) -or (& $_CanonMatch $familyCanon $hintCanon)) {
                        $tierRank = if ($tierKey -eq 'high') { 3 } elseif ($tierKey -eq 'medium') { 2 } else { 1 }
                        $agyCandidates += @{ SettingsValue = $entry.settings_value; TierRank = $tierRank; TierKey = $tierKey }
                    }
                }
            }
            if ($agyCandidates.Count -gt 0) {
                # If the hint explicitly names a tier, restrict to that tier; otherwise prefer highest.
                $filtered = if ($hintExplicitTier) { $agyCandidates | Where-Object { $_.TierKey -eq $hintExplicitTier } } else { $null }
                $pool = if ($filtered -and @($filtered).Count -gt 0) { $filtered } else { $agyCandidates }
                $best = $pool | Sort-Object TierRank -Descending | Select-Object -First 1
                $resolvedModelId = $best.SettingsValue
                $resolvedProvider = 'agy'
            }
        }

        # --- opencode registry ---
        if (-not $resolvedModelId) {
            foreach ($providerProp in $Registry._opencode_model_map.PSObject.Properties) {
                $providerKey = $providerProp.Name
                $providerEntry = $providerProp.Value
                if ($null -eq $providerEntry) { continue }
                foreach ($modelKey in $providerEntry.PSObject.Properties.Name) {
                    $entry = $providerEntry.$modelKey
                    if ($null -eq $entry) { continue }
                    $entryDisplay = $entry.display
                    $entryModelId = $entry.model_id
                    if (-not $entryDisplay -or -not $entryModelId) { continue }
                    $displayCanon = & $_Canon $entryDisplay
                    $modelKeyCanon = & $_Canon $modelKey
                    if ((& $_CanonMatch $displayCanon $hintCanon) -or (& $_CanonMatch $modelKeyCanon $hintCanon)) {
                        $resolvedModelId = $entryModelId
                        $resolvedProvider = $providerKey
                        break
                    }
                }
                if ($resolvedModelId) { break }
            }
        }
    } # end foreach $matchMode

    if ($resolvedModelId) {
        return @{ ModelId = $resolvedModelId; Provider = $resolvedProvider }
    }
    return $null
}
