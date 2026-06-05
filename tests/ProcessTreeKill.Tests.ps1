# Invariant across ALL native-process adapters (agy/claude/opencode): when the
# adapter kills a spawned CLI on stall/timeout, it must tear down the WHOLE
# process tree via Kill($true). These CLIs are npm/shim wrappers (cmd -> node),
# so a bare Kill() terminates only the wrapper and orphans the real agent.
# (agy C2/L6.1 found this live; claude/opencode share the same pattern.)

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:Adapters = @{
        agy      = Get-Content -Raw (Join-Path $root 'backends/agy.ps1')
        claude   = Get-Content -Raw (Join-Path $root 'backends/claude.ps1')
        opencode = Get-Content -Raw (Join-Path $root 'backends/opencode.ps1')
    }
}

Describe 'native-process adapters tear down the whole tree on kill' {
    It '<_> uses Kill($true)' -ForEach @('agy','claude','opencode') {
        $script:Adapters[$_] | Should -Match '\.Kill\(\s*\$true\s*\)'
    }
    It '<_> has no bare .Kill() that would orphan the child' -ForEach @('agy','claude','opencode') {
        $script:Adapters[$_] | Should -Not -Match '\.Kill\(\s*\)'
    }
}
