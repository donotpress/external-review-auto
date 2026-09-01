# The -BlindSeat fallback fix that did not fix anything.
#
# e5d465e finding 4: "-BundleOverrides was never passed to the agy fallback
# re-dispatch, so a blinded seat's fallback silently received the SIGHTED
# bundle." The fix added `-BundleOverrides $bundleOverrides` to that call.
#
# It is a no-op, and it cannot be anything else. $bundleOverrides is keyed by
# PRESET NAME (workflow.ps1: `$BundleOverrides.ContainsKey($r)` where $r is the
# seat), the fallback dispatches under its OWN preset name, and era.ps1 chooses
# that name with
#
#     Resolve-EraAgyFallback -Exclude @($reviewerList + $approvedList | Sort-Object -Unique)
#
# so the fallback preset is GUARANTEED to differ from every seat in the round --
# including the blinded one. The map is threaded through to a lookup whose key
# can never be present. The blinded seat's replacement still gets the sighted
# bundle, exactly as before the fix.
#
# It shipped with a test that asserts the parameter EXISTS in workflow.ps1's
# source. That test passes against the broken wiring, which is the failure mode
# this repo has now hit four times.
#
# The recovered muse-spark seat of the era-unreviewed-audit round reached the
# same place from the other side, on the pre-fix code: "Today fallbackExclude
# contains $approvedList so fallback preset != blind seat ... Should either
# thread $bundleOverrides or assert BlindSeat -notin fallback."
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/FallbackBundleOverride.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'workflow.ps1')
}

Describe 'Get-EraSeatBundle' -Tag Unit {

    It 'gives an overridden seat its own bundle and everyone else the normal one' {
        $ov = @{ 'muse-spark' = 'X:\r\round-1-bundle-blind.xml' }
        Get-EraSeatBundle -Preset 'muse-spark' -BundleOverrides $ov -BundlePath 'X:\r\round-1-bundle.xml' |
            Should -Be 'X:\r\round-1-bundle-blind.xml'
        Get-EraSeatBundle -Preset 'opus' -BundleOverrides $ov -BundlePath 'X:\r\round-1-bundle.xml' |
            Should -Be 'X:\r\round-1-bundle.xml'
    }

    It 'ignores an empty override rather than dispatching a seat with no bundle' {
        Get-EraSeatBundle -Preset 'a' -BundleOverrides @{ 'a' = '' } -BundlePath 'N.xml' | Should -Be 'N.xml'
    }
}

Describe 'Get-EraFallbackBundleOverrides' -Tag Unit {

    It 'carries the blind bundle onto the preset the fallback actually dispatches under' {
        # THE RED. The shipped code passes the map unchanged, so the fallback
        # preset is absent from it and the lookup falls through to the sighted
        # bundle.
        $ov = @{ 'muse-spark' = 'blind.xml' }
        $r  = Get-EraFallbackBundleOverrides -BundleOverrides $ov -FallbackPreset 'gemini-api' `
                -BlindSeat 'muse-spark' -Replacing @('muse-spark', 'opus')
        Get-EraSeatBundle -Preset 'gemini-api' -BundleOverrides $r.Overrides -BundlePath 'normal.xml' |
            Should -Be 'blind.xml' -Because 'the fallback replaces the blinded seat, so it inherits that seat''s bundle'
        $r.Note | Should -Match 'inherits the comment-stripped bundle'
    }

    It 'does not blind a fallback that is replacing sighted seats only' {
        $ov = @{ 'muse-spark' = 'blind.xml' }
        $r  = Get-EraFallbackBundleOverrides -BundleOverrides $ov -FallbackPreset 'gemini-api' `
                -BlindSeat 'muse-spark' -Replacing @('opus')
        Get-EraSeatBundle -Preset 'gemini-api' -BundleOverrides $r.Overrides -BundlePath 'normal.xml' |
            Should -Be 'normal.xml'
        $r.Note | Should -Match 'reviews the NORMAL bundle'
    }

    It 'says which bundle the fallback got, either way' {
        # Silence is what made this a defect rather than a decision: the round
        # summary reported a blinded seat that had not been blinded.
        foreach ($replacing in @(@('muse-spark'), @('opus'))) {
            $r = Get-EraFallbackBundleOverrides -BundleOverrides @{ 'muse-spark' = 'blind.xml' } `
                    -FallbackPreset 'gemini-api' -BlindSeat 'muse-spark' -Replacing $replacing
            $r.Note | Should -Not -BeNullOrEmpty
            $r.Note | Should -Match 'gemini-api'
        }
    }

    It 'is a no-op and says nothing when no seat was blinded' {
        $r = Get-EraFallbackBundleOverrides -BundleOverrides @{} -FallbackPreset 'gemini-api' -Replacing @('opus')
        $r.Overrides.Count | Should -Be 0
        $r.Note            | Should -BeNullOrEmpty
    }

    It 'does not mutate the caller''s map' {
        # $bundleOverrides is reused by the contract re-check and the metadata
        # writer after the fallback returns.
        $ov = @{ 'muse-spark' = 'blind.xml' }
        $null = Get-EraFallbackBundleOverrides -BundleOverrides $ov -FallbackPreset 'gemini-api' `
                    -BlindSeat 'muse-spark' -Replacing @('muse-spark')
        $ov.Count | Should -Be 1
        $ov.ContainsKey('gemini-api') | Should -BeFalse
    }
}

Describe 'the dispatcher and era agree on how a seat picks its bundle' -Tag Unit {

    BeforeAll { $script:WfSrc = Get-Content -Raw (Join-Path $script:Root 'workflow.ps1')
                $script:EraSrc = Get-Content -Raw (Join-Path $script:Root 'runtimes/era.ps1') }

    It 'has ONE implementation of the seat-bundle lookup' {
        # A second copy of this rule is how the previous four defects here
        # happened. The dispatcher must call the same function the fallback
        # computation is tested against.
        $script:WfSrc | Should -Match '\$seatBundle = Get-EraSeatBundle'
    }

    It 'computes the fallback''s overrides AND passes the computed map, not the round''s' {
        # Asserting only that the function is CALLED is the same sin this file
        # exists to punish: the return value could be dropped on the floor and
        # `-BundleOverrides $bundleOverrides` passed anyway, and the suite would
        # stay green. Named by the opus seat of the twin-sweep panel.
        $script:EraSrc | Should -Match 'Get-EraFallbackBundleOverrides'
        # The fallback dispatch must be handed the RE-KEYED map. Locate the two
        # Invoke-ReviewerDispatch calls and check the second one by position, so
        # the assertion is about the call that matters rather than about whether
        # a string appears anywhere in a 2,300-line file.
        $fbIdx   = $script:EraSrc.IndexOf('$fbResults = Invoke-ReviewerDispatch')
        $fbIdx   | Should -BeGreaterThan 0
        $fbCall  = $script:EraSrc.Substring($fbIdx, 700)
        $fbCall  | Should -Match '-BundleOverrides \$fbOverride\.Overrides'
        $fbCall  | Should -Not -Match '-BundleOverrides \$bundleOverrides'
    }
}
