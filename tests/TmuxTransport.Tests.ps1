# Unit tests for the tmux TUI transport backend's pure helpers.
#
# WHAT IS AND IS NOT COVERED. Everything here runs offline against files on
# disk. Nothing dispatches a seat, starts a tmux server, or crosses the WSL
# boundary -- those paths cost money and need a live TUI, and they are covered by
# the spike record in docs/assessments/2026-09-06-tmux-spike-c5-c7.md instead.
#
# The helpers tested here are exactly the ones that decide whether a review is
# accepted, so a defect in them is the difference between promoting a truncated
# review and rejecting a good one.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'backends/tmux.ps1')

    function New-TestFile {
        param([string]$Content)
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ("eratmux-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".md")
        [System.IO.File]::WriteAllText($p, $Content)
        return $p
    }
}

Describe 'Get-EraTmuxLastLine' -Tag Unit {

    It 'returns the canary when it is last, ignoring trailing blank lines and CR' {
        # The prompt says "the last line"; the file arrives with a trailing
        # newline and, from a Windows-side write, CRLF. If the validator does not
        # canonicalise both, a compliant model reads as truncated.
        $f = New-TestFile "ERA-BUNDLE-TAIL: docs/x.md`r`n`n## Critical issues`n1. thing`n`nERA-CANARY-abc123`r`n`n`n"
        try { Get-EraTmuxLastLine -Path $f | Should -Be 'ERA-CANARY-abc123' }
        finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    It 'does NOT return the canary for a truncated write (negative control)' {
        # Without this the test above passes for a helper that returns the canary
        # unconditionally.
        $f = New-TestFile "ERA-BUNDLE-TAIL: docs/x.md`n## Critical issues`n1. half a thou"
        try { Get-EraTmuxLastLine -Path $f | Should -Not -Be 'ERA-CANARY-abc123' }
        finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    It 'returns null for a missing file rather than throwing' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("nope-" + [guid]::NewGuid().ToString('N') + ".md")
        Get-EraTmuxLastLine -Path $missing | Should -BeNullOrEmpty
    }

    It 'returns null for a file that is only whitespace' {
        $f = New-TestFile "`n`n   `n"
        try { Get-EraTmuxLastLine -Path $f | Should -BeNullOrEmpty }
        finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-EraTmuxReviewBody' -Tag Unit {

    BeforeAll {
        $script:Sample = "ERA-BUNDLE-TAIL: docs/specs/thing.md`n`n## Critical issues`n1. a finding`n`nERA-CANARY-abc123`n"
    }

    It 'strips both marker lines from the body' {
        # The markers are era's scaffolding. Left in, a two-line preamble could
        # pad a sub-floor non-answer past the narration detector's length floor.
        $f = New-TestFile $script:Sample
        try {
            $b = Get-EraTmuxReviewBody -Path $f -Canary 'ERA-CANARY-abc123'
            $b.Text | Should -Not -Match 'ERA-CANARY'
            $b.Text | Should -Not -Match 'ERA-BUNDLE-TAIL'
        } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps the actual review text (guards the test above against a helper that returns nothing)' {
        $f = New-TestFile $script:Sample
        try {
            $b = Get-EraTmuxReviewBody -Path $f -Canary 'ERA-CANARY-abc123'
            $b.Text | Should -Match '## Critical issues'
            $b.Text | Should -Match '1\. a finding'
        } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    It 'reports the tail claim the read-truncation probe depends on' {
        $f = New-TestFile $script:Sample
        try {
            (Get-EraTmuxReviewBody -Path $f -Canary 'ERA-CANARY-abc123').TailClaim |
                Should -Be 'docs/specs/thing.md'
        } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    It 'reports a null tail claim when the model omitted it, rather than inventing one' {
        $f = New-TestFile "## Critical issues`n1. a finding`nERA-CANARY-abc123`n"
        try {
            (Get-EraTmuxReviewBody -Path $f -Canary 'ERA-CANARY-abc123').TailClaim |
                Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    It 'strips only THIS attempt''s canary, so a stale one stays visible as body text' {
        # Nonces are per attempt. A leftover canary from a previous attempt must
        # not be silently swallowed -- it is evidence the scratch directory was
        # reused, which the design says cannot happen.
        $f = New-TestFile "## Critical issues`n1. a finding`nERA-CANARY-OLDNONCE`nERA-CANARY-abc123`n"
        try {
            (Get-EraTmuxReviewBody -Path $f -Canary 'ERA-CANARY-abc123').Text |
                Should -Match 'ERA-CANARY-OLDNONCE'
        } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the tmux adapter''s contract with the dispatcher' -Tag Unit {

    It 'does NOT declare -PidFile' {
        # workflow.ps1 passes -PidFile only to adapters that declare it, and
        # Stop-EraAdapterChild [int]::TryParses the file. `new-window -d` returns
        # once the window exists, so the wsl.exe era launched is dead within
        # milliseconds: a pid written there would make the dispatcher's straggler
        # kill a silent no-op, or -- after pid reuse -- kill something else.
        (Get-Command Invoke-TmuxReview).Parameters.ContainsKey('PidFile') | Should -BeFalse
    }

    It 'declares the parameters the dispatcher always splats' {
        $p = (Get-Command Invoke-TmuxReview).Parameters
        foreach ($n in 'BundlePath', 'PromptPath', 'ResponsePath', 'ModelInfo', 'TimeoutSec',
                       'AgyModelHint', 'ModelOverride', 'OpencodeProvider') {
            $p.ContainsKey($n) | Should -BeTrue -Because "workflow.ps1 splats -$n at every adapter"
        }
    }

    It 'never calls capture-pane' {
        # The design's one hard invariant: if collection ever reads pane text this
        # becomes the design the earlier session correctly rejected.
        # TOKENISED, NOT REGEXED. A line filter on `^\s*#` does not strip <# #>
        # block comments, so this test fired on the file's own header -- which
        # says, in prose, that calling capture-pane would be wrong. A test that
        # cannot tell code from the comment forbidding it is not a test.
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:SkillRoot 'backends/tmux.ps1'), [ref]$tokens, [ref]$null)
        $codeTokens = @($tokens | Where-Object { $_.Kind -ne 'Comment' } |
                        ForEach-Object { $_.Text })
        ($codeTokens -join ' ') | Should -Not -Match 'capture-pane'
    }

    It 'the tokeniser actually sees this file''s code (guards the test above)' {
        # Without this, a tokeniser returning nothing would make the check above
        # pass vacuously -- the same shape as every other guard in this suite.
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:SkillRoot 'backends/tmux.ps1'), [ref]$tokens, [ref]$null)
        $codeTokens = @($tokens | Where-Object { $_.Kind -ne 'Comment' } |
                        ForEach-Object { $_.Text })
        ($codeTokens -join ' ') | Should -Match 'Invoke-TmuxReview'
    }

    It 'scrubs TMUX and TMUX_PANE along with the agent vars' {
        # A seat inheriting the driving session's pane identity would have its
        # hooks write into the operator's window.
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'backends/tmux.ps1')
        $src | Should -Match "'TMUX'"
        $src | Should -Match "'TMUX_PANE'"
    }
}
