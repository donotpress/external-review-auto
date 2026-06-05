# Cross-adapter hardening invariants from the opencode /era review (2026-06-04):
#  - capture sinks must be opened shareable so mid-flight reads (stall snapshots,
#    the agy Tier-1 stderr read) actually work (File.Create's default FileShare is
#    None, which made those reads fail silently);
#  - the non-review detector is shared and applied by both agentic backends.

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:Src = @{
        agy      = Get-Content -Raw (Join-Path $root 'backends/agy.ps1')
        claude   = Get-Content -Raw (Join-Path $root 'backends/claude.ps1')
        opencode = Get-Content -Raw (Join-Path $root 'backends/opencode.ps1')
    }
    . (Join-Path $root 'backends/_capture-validation.ps1')
}

Describe 'capture sinks are opened shareable (FileShare.ReadWrite)' {
    It '<_> opens stdout/stderr sinks with FileShare.ReadWrite' -ForEach @('agy','claude','opencode') {
        $script:Src[$_] | Should -Match 'FileShare\]::ReadWrite'
    }
    It '<_> no longer uses the exclusive [IO.File]::Create for sinks' -ForEach @('agy','claude','opencode') {
        $script:Src[$_] | Should -Not -Match '\[System\.IO\.File\]::Create\('
    }
}

Describe 'shared narration/refusal detector' {
    It 'is loaded from the shared _capture-validation.ps1' {
        Get-Command Test-AgenticNarrationCapture -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'both agentic backends dot-source the shared detector' {
        $script:Src['agy']      | Should -Match '_capture-validation\.ps1'
        $script:Src['opencode'] | Should -Match '_capture-validation\.ps1'
    }
    It 'opencode applies the detector to its captured output and fails honestly' {
        $script:Src['opencode'] | Should -Match 'Test-AgenticNarrationCapture -Response \$clean'
        $script:Src['opencode'] | Should -Match 'ContentOk\s*=\s*\$false'
    }
    It 'still flags a bundle-refusal and a tool-narration (behavioral, via shared file)' {
        Test-AgenticNarrationCapture -Response 'I cannot read the bundle file; please paste the content of the bundle here.' | Should -BeTrue
        Test-AgenticNarrationCapture -Response 'Let me read the bundle file to begin the review.' | Should -BeTrue
        Test-AgenticNarrationCapture -Response "## Critical issues`n- a real finding about the dispatcher" | Should -BeFalse
    }
}

Describe 'opencode attaches the bundle via -f by default (no Read-tool dependency)' {
    BeforeAll { $script:OC = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'backends/opencode.ps1') }

    It 'adds -f <BundlePath> to the opencode ArgumentList' {
        $script:OC | Should -Match "ArgumentList\.Add\('-f'\)"
        $script:OC | Should -Match "ArgumentList\.Add\(\`$BundlePath\)"
    }
    It 'passes the message BEFORE -m (so the greedy -f array cannot swallow the prompt)' {
        # message positional must be added before the -m option in the arg list.
        $script:OC | Should -Match "ArgumentList\.Add\(\`$prompt\)[\s\S]*?ArgumentList\.Add\('-m'\)"
    }
    It 'defaults to the attach prompt and gates the Read-tool path behind ERA_OPENCODE_READ_TOOL' {
        $script:OC | Should -Match 'Review the attached bundle file'
        $script:OC | Should -Match 'ERA_OPENCODE_READ_TOOL'
    }
}

Describe 'opencode is stateless by default (opt-in variant-state insurance)' {
    BeforeAll { $script:OC = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'backends/opencode.ps1') }

    It 'removed the old always-on startup mutex + recent[] swap' {
        $script:OC | Should -Not -Match 'era-opencode-state-mutex'   # old always-on mutex name
        $script:OC | Should -Not -Match '\$modelStatePath'
        $script:OC | Should -Not -Match '\$stateMutated'
        $script:OC | Should -Not -Match '\$state\.recent'            # recent[] manipulation gone
        $script:OC | Should -Not -Match '\$newRecent'
    }
    It 'selects model + variant via CLI flags by default (Option A)' {
        $script:OC | Should -Match "ArgumentList\.Add\('-m'\)"
        $script:OC | Should -Match "ArgumentList\.Add\('--variant'\)"
    }
    It 'state.json variant write is OPT-IN (Option B) behind ERA_OPENCODE_VARIANT_STATE' {
        $script:OC | Should -Match 'ERA_OPENCODE_VARIANT_STATE'
        # The only mutex left is the variant-insurance one, used solely by the helper.
        $script:OC | Should -Match 'era-opencode-variant-mutex'
        $script:OC | Should -Match 'Set-OpencodeVariantEntry'
        $script:OC | Should -Match 'Restore-OpencodeVariantEntry'
    }
    It 'still tree-kills and opens sinks shareable (carried over from the hardening)' {
        $script:OC | Should -Match '\.Kill\(\s*\$true\s*\)'
        $script:OC | Should -Match 'FileShare\]::ReadWrite'
    }
}
