# Two agy resolvers, both made deterministic, tie-breaking on DIFFERENT keys.
#
# v2.4.1 made runtimes/resolve-model.ps1 deterministic; v2.7.1 found era.ps1's
# independent copy of the same rule and made it deterministic too, and added a
# sweep asserting no bare `.Keys` loop survives anywhere.
#
# Both fixes stopped at "each copy is deterministic". Neither asked whether the
# two copies are deterministic THE SAME WAY:
#
#   resolve-model.ps1   Sort-Object TierRank desc, SettingsValue asc
#   era.ps1             Sort-Object TierRank desc, Display       asc
#
# Sort-Object is stable, so on a TierRank tie the answer is whichever of those
# two fields sorts first -- and display names and settings values are not ordered
# alike in general. One rule, two implementations, both "fixed", still able to
# disagree.
#
# MEASURED against the shipped registry: they do NOT currently diverge. Every
# ambiguous hint probed (`gemini`, `pro`, `flash`, `low`, `high`, `medium`, `3`,
# and single letters) resolves to the same model both ways. So this is a latent
# divergence, not a live one -- reported as such, fixed because the next registry
# entry is what decides whether it stays latent, and pinned here so that entry
# fails the suite instead of shipping.
#
# Raised by the blinded seat of the 2026-09-01 twin-sweep panel, which is the
# fourth time a surviving twin here was found by a reviewer and not by reading.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/AgyTieBreakParity.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:EraSrc = Get-Content -Raw (Join-Path $script:Root 'runtimes/era.ps1')
    $script:RmSrc  = Get-Content -Raw (Join-Path $script:Root 'runtimes/resolve-model.ps1')
    $script:Reg    = Get-Content -Raw (Join-Path $script:Root 'backends/_registry.json') | ConvertFrom-Json
}

Describe 'the two agy resolvers break a tie the same way' -Tag Unit {

    It 'both rank on TierRank and then on settings_value' {
        # A wiring assertion, and it is the only kind available: era.ps1's copy
        # is 30 lines inside a 2,300-line script with no seam. The BEHAVIOURAL
        # consequence -- that both resolvers name the same model -- is asserted
        # below against the real registry.
        $script:RmSrc  | Should -Match "Expression = 'TierRank'; Descending = \`$true \}, @\{ Expression = 'SettingsValue'"
        $script:EraSrc | Should -Match "Expression = 'TierRank'; Descending = \`$true \}, @\{ Expression = 'SettingsValue'"
        $script:EraSrc | Should -Not -Match "Expression = 'TierRank'; Descending = \`$true \}, @\{ Expression = 'Display'"
    }

    It 'names the same model from either resolver, for every ambiguous hint in the shipped registry' {
        # The sweep is the guard. It passes today (measured: no divergence), and
        # it is what a future registry entry has to keep true.
        $canon = { param($s) if ($null -eq $s) { return '' }; ($s.ToLower() -replace '[^a-z0-9]', '') }
        $agyMap = @{}
        $script:Reg._agy_model_map.PSObject.Properties | ForEach-Object { $agyMap[$_.Name] = $_.Value }

        foreach ($hint in @('gemini','pro','flash','low','high','medium','3','g','o','e','i','n','lite','preview','gemini 3.1 pro')) {
            $hc = & $canon $hint
            $cands = @()
            foreach ($fk in ($agyMap.Keys | Sort-Object)) {
                foreach ($tk in $agyMap[$fk].PSObject.Properties.Name) {
                    $e = $agyMap[$fk].$tk
                    $dc = & $canon $e.display; $fc = & $canon $fk
                    if ($dc.Contains($hc) -or $hc.Contains($dc) -or $fc.Contains($hc) -or $hc.Contains($fc)) {
                        $tr = if ($tk -eq 'high') { 3 } elseif ($tk -eq 'medium') { 2 } else { 1 }
                        $cands += [pscustomobject]@{ SettingsValue = $e.settings_value; Display = $e.display; TierRank = $tr }
                    }
                }
            }
            if ($cands.Count -eq 0) { continue }
            $bySv = $cands | Sort-Object @{Expression='TierRank';Descending=$true}, @{Expression='SettingsValue';Descending=$false} | Select-Object -First 1
            $byDp = $cands | Sort-Object @{Expression='TierRank';Descending=$true}, @{Expression='Display';Descending=$false}       | Select-Object -First 1
            $bySv.SettingsValue | Should -Be $byDp.SettingsValue `
                -Because "hint '$hint' must not resolve to a different agy model depending on which resolver asked"
        }
    }
}
