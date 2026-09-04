# THE VARIANT era ASKS FOR MUST BE ONE THE MODEL ACTUALLY HAS.
#
# opencode DOES NOT VALIDATE VARIANT NAMES. Measured 2026-09-04:
#
#   opencode run -m opencode-go/muse-spark-1.3-contributor --variant totally-bogus-zzz
#     -> exit 0, "> build - muse-spark-1.3-contributor", then the answer
#   opencode run -m opencode-go/muse-spark-1.3-contributor --variant max
#     -> exit 0, identical in shape
#
# So an undeclared variant is SILENTLY IGNORED, not rejected. That makes this the
# worst kind of defect for this project: era asks for maximum reasoning effort,
# opencode drops the request on the floor, the review comes back looking normal,
# and nothing anywhere says the seat ran at default effort. There is no runtime
# signal to check, which is why the guard has to be a test.
#
# It had already happened. `muse-spark` shipped in the default panel on
# 2026-08-26 with variants ["max"]; opencode declares that model's variants as
# minimal/low/medium/high/xhigh. There is no 'max'. So from 2026-08-26 to
# 2026-09-04 the 4th panel seat asked for a variant equivalent to nonsense.
#
# WHAT THIS TEST USED TO LEAVE UNCOVERED, and no longer does. The rule started
# as "only check what era actually SENDS", on the argument that an undeclared
# name era will never choose is inert and asserting on it would pressure someone
# into editing a live default-panel seat to satisfy a test. That was true and it
# was too narrow. Swept 2026-09-04, FOUR registry entries listed variants the
# snapshot says opencode does not declare:
#
#   opencode-go/deepseek-v4-pro        low, medium   (declares high, max)
#   opencode-go/mimo-v2.5              low, medium, high   (declares none)
#   opencode-go/mimo-v2.5-pro          low, medium, high   (declares none)
#   google/gemini-2.5-flash-image      high, max     (declares none)
#
# All four inert, all four one edit away from being live: reorder the preference
# loop, or have opencode drop 'max' from deepseek-v4-pro, and era starts sending
# a name that is silently ignored -- with no runtime signal, which is the whole
# reason this file exists. They are corrected in the registry and the sweep below
# is now asserted, so the next one cannot be added quietly.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/OpencodeVariantDeclared.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'backends/opencode.ps1')
    $script:Reg  = Get-Content -Raw (Join-Path $script:Root 'backends/_registry.json') | ConvertFrom-Json
    $script:Snap = Get-Content -Raw (Join-Path $script:Root 'tests/fixtures/opencode-declared-variants.json') | ConvertFrom-Json

    # The adapter's own choice, reproduced. Kept in lockstep with the preference
    # loop in backends/opencode.ps1 by the last test in this file.
    function script:Get-ChosenVariant {
        param([string]$ModelId)
        $prov, $fam = $ModelId -split '/', 2
        $entry = $script:Reg._opencode_model_map.$prov.$fam
        $variants = @($entry.variants)
        foreach ($p in @('xhigh','max','high','medium','low')) {
            if ($variants -contains $p) { return $p }
        }
        return 'default'
    }

    $script:OpencodePresets = @(
        $script:Reg.PSObject.Properties |
            Where-Object { $_.Name -notlike '_*' -and $_.Value.backend -eq 'opencode' -and $_.Value.model_id } |
            ForEach-Object { @{ Preset = $_.Name; ModelId = $_.Value.model_id; Retired = [bool]$_.Value.retired } }
    )
}

Describe 'every dispatchable opencode preset asks for a variant its model declares' -Tag Unit {

    It 'has presets to check at all' {
        @($script:OpencodePresets).Count | Should -BeGreaterThan 0
    }

    It 'asks only for declared variants' {
        $problems = @()
        $checked  = 0
        foreach ($p in $script:OpencodePresets) {
            $declared = $script:Snap.declared.($p.ModelId)
            if ($null -eq $declared) {
                # Model absent from `opencode models` when the snapshot was taken.
                # `ox-alpha` is the known case and is flagged retired on purpose so
                # an explicit -Reviewer fails loudly rather than silently.
                if (-not $p.Retired) {
                    $problems += "$($p.Preset) -> $($p.ModelId): NOT OFFERED by opencode in the snapshot, and not flagged retired"
                }
                continue
            }
            $chosen = script:Get-ChosenVariant -ModelId $p.ModelId
            if ($chosen -eq 'default') { $checked++; continue }   # no flag is sent at all
            if (@($declared) -notcontains $chosen) {
                $problems += "$($p.Preset) -> $($p.ModelId): era sends --variant $chosen; opencode declares [$(@($declared) -join ', ')]"
            }
            $checked++
        }
        $checked | Should -BeGreaterThan 0
        $problems -join "`n" | Should -BeNullOrEmpty
    }

    It 'sends nothing rather than something invented when a model declares no variants' {
        # A model with an empty declared list must resolve to 'default', which is
        # the one value the adapter does NOT pass as a flag.
        foreach ($p in $script:OpencodePresets) {
            $declared = $script:Snap.declared.($p.ModelId)
            if ($null -eq $declared -or @($declared).Count -gt 0) { continue }
            script:Get-ChosenVariant -ModelId $p.ModelId | Should -Be 'default' `
                -Because "$($p.ModelId) declares no variants, so any flag era sent would be ignored silently"
        }
    }

    It 'gives muse-spark the variant it actually has' {
        # The case this file exists for, pinned by name so a regression is legible.
        $mid = $script:Reg.'muse-spark'.model_id
        $mid | Should -Match 'muse-spark'
        $chosen = script:Get-ChosenVariant -ModelId $mid
        $chosen | Should -Be 'xhigh'
        @($script:Snap.declared.$mid) | Should -Contain 'xhigh'
        @($script:Snap.declared.$mid) | Should -Not -Contain 'max' `
            -Because 'if opencode ever adds max here, the 2026-09-04 finding is stale and this file should be re-derived'
    }
}

Describe 'the test and the adapter rank variants the same way' -Tag Unit {

    It 'uses the adapter preference order, not its own' {
        # Get-ChosenVariant above reimplements the adapter's loop, which is the
        # standing hazard in this repo: two copies of one rule. Pin them.
        $src = Get-Content -Raw (Join-Path $script:Root 'backends/opencode.ps1')
        $code = [regex]::Replace($src, '(?s)<#.*?#>', '')
        $m = [regex]::Match($code, "foreach \(\`$preferred in @\(([^)]*)\)\)")
        $m.Success | Should -BeTrue -Because 'the adapter preference loop must still be findable'
        $adapterOrder = ($m.Groups[1].Value -replace "'", '' -replace '\s', '') -split ','
        ($adapterOrder -join ',') | Should -Be 'xhigh,max,high,medium,low'
    }

    It 'no longer lets the variant name change the stall budget at all' {
        # THIS TEST USED TO ASSERT AN ORDERING -- xhigh == max, and both above
        # 'high' -- which pinned four guessed constants that measurement has
        # since removed. Silence tracks the model and how much it generates, not
        # the reasoning-effort knob: muse-spark peaks at 194.7s over its 421
        # productive turns while deepseek-v4-flash at 'max' reaches 570.2s over
        # 655. See Resolve-OpencodeStallPlan and
        # docs/assessments/2026-09-04-stall-threshold-measured.md.
        #
        # What survives is the half that was about THIS file: whichever name era
        # resolves to, a wrong one can no longer starve the seat of stall budget.
        # That is what turned the 2026-08-26 muse-spark mismatch from a silent
        # no-op into a potential kill, and it is now structurally impossible.
        $ref = (Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant 'max' -BundleBytes 1000).WantedMs
        foreach ($v in @('xhigh','high','medium','low','minimal','default','totally-bogus-zzz')) {
            (Resolve-OpencodeStallPlan -TimeoutSec 1800 -Variant $v -BundleBytes 1000).WantedMs |
                Should -Be $ref -Because "variant '$v' must not change the stall budget"
        }
    }
}

Describe 'no registry entry asks for a variant opencode does not declare' -Tag Unit {

    It 'sweeps every model in the opencode map, not just the dispatchable presets' {
        # An inert undeclared name is one preference-loop edit away from being a
        # live one, and the failure it becomes is silent in both directions.
        # Models absent from the snapshot are skipped -- absent is not the same
        # fact as "declares nothing", and the snapshot records the difference
        # (null vs []).
        $problems = @()
        $checked  = 0
        foreach ($prov in $script:Reg._opencode_model_map.PSObject.Properties) {
            foreach ($entry in $prov.Value.PSObject.Properties) {
                $mid = $entry.Value.model_id
                if (-not $mid) { continue }
                if (-not $script:Snap.declared.PSObject.Properties[$mid]) { continue }
                $declared = $script:Snap.declared.$mid
                if ($null -eq $declared) { continue }
                $checked++
                foreach ($v in @($entry.Value.variants)) {
                    if (@($declared) -notcontains $v) {
                        $problems += "$mid lists '$v'; opencode declares [$(@($declared) -join ', ')]"
                    }
                }
            }
        }
        $checked | Should -BeGreaterThan 20 -Because 'the sweep must actually reach the map'
        $problems -join "`n" | Should -BeNullOrEmpty
    }
}
