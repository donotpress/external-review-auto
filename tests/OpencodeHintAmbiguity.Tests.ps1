# The third implementation of the rule that was fixed twice.
#
# v2.4.1 made agy hint resolution deterministic in runtimes/resolve-model.ps1.
# 2f93384 then found the SAME defect surviving in era.ps1's -AgyModel resolver
# and fixed it there, adding a test that no bare `.Keys` loop survives anywhere.
#
# Both fixes stopped at the hashtable-enumeration symptom. The rule underneath
# them is larger: AN AMBIGUOUS HINT MUST NOT BE RESOLVED SILENTLY. The claude
# branch collects every candidate, sorts, and warns when more than one model
# matched. The agy branch ranks on TierRank then Display. The OPENCODE branch,
# in the same function, still takes the first match in whatever order
# _registry.json happens to list its providers, and says nothing.
#
# It is not a hashtable, so it does not vary run-to-run -- which is exactly why
# neither previous sweep caught it. It varies when somebody REORDERS the
# registry, and it is silent in both cases.
#
# Measured against the shipped registry (41 opencode entries), substring pass:
#
#   'deepseek' -> 2 models, file-order first is opencode-go/deepseek-v4-PRO
#                 (2x the input price of the -flash the default panel uses)
#   'minimax'  -> 8 models    'flash' -> 14 models    'qwen' -> 3 models
#   'glm'      -> 2 models    'mimo'  -> 2 models     'kimi' -> 2 models
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/OpencodeHintAmbiguity.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'runtimes/resolve-model.ps1')
    $script:Reg = Get-Content -Raw (Join-Path $script:Root 'backends/_registry.json') | ConvertFrom-Json

    # Two registries holding the SAME opencode entries in opposite insertion
    # order. Anything that reads them must agree; a first-match-wins loop cannot.
    function script:New-OcRegistry {
        param([switch]$Reversed)
        $entries = [ordered]@{
            'deepseek-v4-flash' = @{ display = 'DeepSeek V4 Flash (New)'; model_id = 'opencode-go/deepseek-v4-flash' }
            'deepseek-v4-pro'   = @{ display = 'DeepSeek V4 Pro';         model_id = 'opencode-go/deepseek-v4-pro' }
        }
        $names = @($entries.Keys)
        if ($Reversed) { [array]::Reverse($names) }
        $inner = [ordered]@{}
        foreach ($n in $names) { $inner[$n] = [pscustomobject]$entries[$n] }
        return [pscustomobject]@{ _opencode_model_map = [pscustomobject]@{ 'opencode-go' = [pscustomobject]$inner } }
    }
}

Describe 'an ambiguous opencode hint resolves independently of registry order' -Tag Unit {

    It 'gives the same model whichever way the registry lists it' {
        # THE RED. First-match-wins returns -pro from one ordering and -flash
        # from the other, so this fails against the shipped resolver.
        $a = Resolve-ModelFromHint -Hint 'deepseek' -Registry (script:New-OcRegistry)
        $b = Resolve-ModelFromHint -Hint 'deepseek' -Registry (script:New-OcRegistry -Reversed)
        $a.ModelId | Should -Not -BeNullOrEmpty
        $b.ModelId | Should -Be $a.ModelId -Because 'reordering _registry.json must not re-point a hint at a different, more expensive model'
    }

    It 'is order-independent on the SHIPPED registry, for every hint measured ambiguous' {
        # WAS three repeated calls in one process against one registry object,
        # which cannot fail for ANY implementation: `_opencode_model_map` is a
        # PSCustomObject with fixed property order, so even first-match-wins is
        # stable in-process. The opus seat of the twin-sweep panel named it as a
        # test that would pass against the very resolver it was written to
        # forbid, and it was right.
        #
        # Rebuild the real registry with its opencode providers AND models in
        # reverse order instead, and require the same answer. That is the
        # property the fix actually provides.
        function script:Reverse-OcRegistry {
            param($Reg)
            $provNames = @($Reg._opencode_model_map.PSObject.Properties.Name)
            [array]::Reverse($provNames)
            $provs = [ordered]@{}
            foreach ($pn in $provNames) {
                $modelNames = @($Reg._opencode_model_map.$pn.PSObject.Properties.Name)
                [array]::Reverse($modelNames)
                $models = [ordered]@{}
                foreach ($mn in $modelNames) { $models[$mn] = $Reg._opencode_model_map.$pn.$mn }
                $provs[$pn] = [pscustomobject]$models
            }
            return [pscustomobject]@{
                _claude_model_map   = $Reg._claude_model_map
                _agy_model_map      = $Reg._agy_model_map
                _opencode_model_map = [pscustomobject]$provs
            }
        }
        $reversed = script:Reverse-OcRegistry -Reg $script:Reg
        foreach ($hint in @('deepseek', 'minimax', 'qwen', 'glm', 'kimi', 'mimo', 'flash')) {
            $a = (Resolve-ModelFromHint -Hint $hint -Registry $script:Reg).ModelId
            $b = (Resolve-ModelFromHint -Hint $hint -Registry $reversed).ModelId
            $b | Should -Be $a -Because "hint '$hint' must not follow _registry.json's ordering"
        }
    }

    It 'says so on stderr when the hint matched more than one opencode model' {
        # The claude branch has done this since v2.4.1. Picking in silence is the
        # half of that fix the opencode branch never got. stderr, never stdout:
        # resolve.ps1's contract is that stdout carries ONLY the JSON flag object.
        $old = [Console]::Error
        $sw  = [System.IO.StringWriter]::new()
        try {
            [Console]::SetError($sw)
            $null = Resolve-ModelFromHint -Hint 'deepseek' -Registry (script:New-OcRegistry)
        } finally { [Console]::SetError($old) }
        $sw.ToString() | Should -Match "model hint 'deepseek' matches 2"
    }

    It 'stays quiet and exact when the hint names one model' {
        $old = [Console]::Error
        $sw  = [System.IO.StringWriter]::new()
        try {
            [Console]::SetError($sw)
            $r = Resolve-ModelFromHint -Hint 'deepseek-v4-pro' -Registry (script:New-OcRegistry)
        } finally { [Console]::SetError($old) }
        $r.ModelId     | Should -Be 'opencode-go/deepseek-v4-pro'
        $r.Provider    | Should -Be 'opencode-go'
        $sw.ToString() | Should -Not -Match 'WARNING'
    }

    It 'still resolves the exact hints the rest of the suite depends on' {
        # The exact pass runs before the substring pass, so this fix must be
        # invisible to every hint that names its model.
        (Resolve-ModelFromHint -Hint 'mimo-v2.5'     -Registry $script:Reg).ModelId | Should -BeExactly 'opencode-go/mimo-v2.5'
        (Resolve-ModelFromHint -Hint 'mimo-v2.5-pro' -Registry $script:Reg).ModelId | Should -BeExactly 'opencode-go/mimo-v2.5-pro'
        (Resolve-ModelFromHint -Hint 'opus'          -Registry $script:Reg).ModelId | Should -Be 'claude-opus-5'
    }
}
