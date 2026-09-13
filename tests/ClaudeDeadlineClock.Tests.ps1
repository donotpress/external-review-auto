# The claude adapter's deadline clock must be ONE clock, not two.
#
# FOUND BY THE 2026-09-13 PROOF ROUND. Both opus seats died in ~1-3s labelled
# "exceeded its 708s slice of the 708s budget". Root cause: the attempt
# deadline was built with (Get-Date) (LOCAL kind) while Wait-ClaudeFirstByte
# polls against [DateTime]::UtcNow — and .NET DateTime relational operators
# compare raw Ticks IGNORING Kind. On this UTC-5 box UtcNow runs 18,000s ahead
# of local time, so `$now -ge $Deadline` was true on the first poll and every
# claude seat fake-timed-out. agy and opencode adapters use one clock
# throughout and were unaffected; the ebook opus success predates the
# first-byte detection commit that introduced the mix.
#
# Contract pinned here: ALL deadlines in backends/claude.ps1 are UTC.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'backends/claude.ps1')
}

Describe 'Get-ClaudeRemainingMs speaks the same clock as the deadline' -Tag Unit {

    It 'reads ~60s for a UTC deadline 60s out' {
        # Pre-fix this returned ~18,060,000 (the whole zone offset leaks in):
        # the helper subtracted local "now" from a UTC deadline.
        $ms = Get-ClaudeRemainingMs -Deadline ([DateTime]::UtcNow.AddSeconds(60))
        $ms | Should -BeGreaterThan 50000 -Because 'a minute of budget must remain'
        $ms | Should -BeLessThan 70000 -Because 'the zone offset must not leak in'
    }

    It 'clamps an expired UTC deadline to 0, never negative' {
        # Task.Wait(int) / WaitForExit(int) read negative as Infinite --
        # the clamp is what keeps an exhausted budget from hanging forever.
        Get-ClaudeRemainingMs -Deadline ([DateTime]::UtcNow.AddSeconds(-5)) | Should -Be 0
    }
}

Describe 'Wait-ClaudeFirstByte honors a live UTC deadline' -Tag Unit {

    It 'reports exited (not timeout) for a process that dies in ~2s' {
        # The proof-round shape: fast death, empty output. The buggy mix
        # reported this as timeout; the helper must report what happened.
        $std = [System.IO.Path]::GetTempFileName()
        try {
            $p = Start-Process -FilePath 'pwsh' `
                -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 2' `
                -RedirectStandardOutput $std -NoNewWindow -PassThru
            $r = Wait-ClaudeFirstByte -Process $p -StdFile $std `
                -Deadline ([DateTime]::UtcNow.AddSeconds(60))
            $r.Outcome | Should -Be 'exited'
            $r.FirstByteSec | Should -BeNullOrEmpty -Because 'nothing was ever written'
        } finally {
            Remove-Item -LiteralPath $std -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'the adapter builds its attempt deadline on the UTC clock' -Tag Unit {

    BeforeAll {
        $script:ClaudeSrc = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/claude.ps1')
    }

    It 'constructs $attemptDeadline from UtcNow, not Get-Date' {
        # The construction site is the other half of the mix: the wait loop
        # polls UtcNow, so a local-kind deadline is expired-by-offset on
        # arrival. Assert the pairing, not just the helper.
        $script:ClaudeSrc | Should -Match '\$attemptDeadline = \[DateTime\]::UtcNow\.AddSeconds'
    }

    It 'leaves no Get-Date deadline arithmetic in the adapter' {
        # (Get-Date -Format ...) display stamps are fine; clock MATH is not.
        # Get-ClaudeRemainingMs and the deadline construction are the only
        # deadline-arithmetic sites; both must be UTC now.
        $mathUses = [regex]::Matches($script:ClaudeSrc, '\(Get-Date\)\.AddSeconds|Deadline\) - \(Get-Date\)')
        $mathUses.Count | Should -Be 0 -Because 'every Get-Date-vs-UTC mix is a fake timeout on non-UTC boxes'
    }
}
