# Structural tests for the env-var scrub block in each CLI adapter.
# These don't execute the scrub — they verify that the scrub block exists
# and lists every variable a Claude/agy/opencode recursion guard could trip on.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent

    # Vars that MUST appear in every CLI adapter's scrub list. Adding a new
    # recursion-guard-sensitive var? Add it here AND to all three adapters.
    $script:RequiredScrubVars = @(
        'CLAUDECODE'
        'CLAUDE_CODE_ENTRYPOINT'
        'CLAUDE_CODE_SESSION_ID'
        'CLAUDE_CODE_GIT_BASH_PATH'
        'AI_AGENT'
        'ANTIGRAVITY_AGENT'
        'ANTIGRAVITY_SOURCE_METADATA'
        'OPENCODE_YOLO'
    )
}

Describe 'CLI adapters must scrub agent env vars before spawning' {
    It '<adapter> contains a $psi.Environment.Remove() loop covering all required vars' -ForEach @(
        @{ adapter = 'agy' }
        @{ adapter = 'claude' }
        @{ adapter = 'opencode' }
    ) {
        $content = Get-Content -Raw (Join-Path $script:SkillRoot "backends/$adapter.ps1")

        # The scrub block uses ProcessStartInfo.Environment which is per-child.
        $content | Should -Match '\$psi\.Environment' -Because "$adapter must operate on `$psi.Environment, not [Environment]::SetEnvironmentVariable (which would mutate the parent pwsh)"

        # Verify every required var is named.
        foreach ($var in $script:RequiredScrubVars) {
            $content | Should -Match "'$var'" -Because "$adapter must scrub the '$var' env var"
        }
    }
}

Describe 'CLI adapters must use ProcessStartInfo with CreateNoWindow=$true' {
    It '<adapter> uses ProcessStartInfo + CreateNoWindow=$true (not Start-Process -NoNewWindow)' -ForEach @(
        @{ adapter = 'agy' }
        @{ adapter = 'claude' }
        @{ adapter = 'opencode' }
    ) {
        $content = Get-Content -Raw (Join-Path $script:SkillRoot "backends/$adapter.ps1")

        # Must use ProcessStartInfo (no shared console with parent).
        $content | Should -Match 'ProcessStartInfo' -Because "$adapter must spawn via ProcessStartInfo for console isolation"
        $content | Should -Match '\$psi\.CreateNoWindow\s*=\s*\$true' -Because "$adapter must set CreateNoWindow=`$true to get its own hidden console"
        $content | Should -Match '\$psi\.UseShellExecute\s*=\s*\$false' -Because "$adapter must set UseShellExecute=`$false (required for Environment dict to take effect)"

        # Must NOT use Start-Process -NoNewWindow (the original buggy pattern that
        # caused TUI mouse-tracking sequences to leak into the parent terminal).
        # Comments referencing the old pattern are OK; actual invocations are not.
        $codeOnly = $content -split "`n" | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*<#' -and $_ -notmatch '^\s*\.[A-Z]' } | Out-String
        $codeOnly | Should -Not -Match 'Start-Process[^\r\n]*-NoNewWindow' -Because "$adapter must not use Start-Process -NoNewWindow (causes TTY pollution)"
    }
}
