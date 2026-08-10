# Tests for the lone-straggler grace policy (panel item #4).
# Tag: Unit
#
# The dispatcher used to block on `Wait-Job -Job $allJobs -Timeout (T+30)`,
# which waits for ALL jobs. One hung member therefore held the round for the
# full scaled budget -- up to 1830s -- with every other reviewer long finished.
#
# The policy lives in Test-EraStragglerExpired as a pure function precisely so
# it can be tested exhaustively without spawning threads and racing them.
#
# The grace size is measured, not guessed. Per-reviewer wall-clock from four
# real rounds of the era-grade panel (round-N-metadata.json), slowest minus
# second-slowest:
#     round 1:   8.0s      round 2: 135.8s
#     round 3: 115.7s      round 4:  78.9s
# Healthy stragglers trail by at most ~136s, so 300s is ~2.2x headroom.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/StragglerGrace.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
}

Describe 'Test-EraStragglerExpired' -Tag Unit {
    It 'keeps waiting while several reviewers are still running' {
        Test-EraStragglerExpired -ElapsedSec 400 -Outstanding 2 -Total 3 `
            -BudgetSec 1830 -GraceSec 300 -LoneSinceSec -1 | Should -BeNullOrEmpty
    }

    It 'stops on the absolute budget regardless of anything else' {
        Test-EraStragglerExpired -ElapsedSec 1830 -Outstanding 2 -Total 3 `
            -BudgetSec 1830 -GraceSec 300 -LoneSinceSec -1 | Should -Be 'budget'
    }

    It 'the budget outranks an unexpired grace' {
        Test-EraStragglerExpired -ElapsedSec 2000 -Outstanding 1 -Total 3 `
            -BudgetSec 1830 -GraceSec 300 -LoneSinceSec 1990 | Should -Be 'budget'
    }

    It 'abandons a lone straggler once its grace is spent' {
        Test-EraStragglerExpired -ElapsedSec 700 -Outstanding 1 -Total 3 `
            -BudgetSec 1830 -GraceSec 300 -LoneSinceSec 400 | Should -Be 'grace'
    }

    It 'waits out a lone straggler that is still inside its grace' {
        Test-EraStragglerExpired -ElapsedSec 500 -Outstanding 1 -Total 3 `
            -BudgetSec 1830 -GraceSec 300 -LoneSinceSec 400 | Should -BeNullOrEmpty
    }

    It 'GraceSec 0 restores wait-for-the-full-budget' {
        Test-EraStragglerExpired -ElapsedSec 1700 -Outstanding 1 -Total 3 `
            -BudgetSec 1830 -GraceSec 0 -LoneSinceSec 100 | Should -BeNullOrEmpty
    }

    It 'never fires on a single-reviewer run' {
        # Outstanding 1 of 1 is the whole run, not a straggler.
        Test-EraStragglerExpired -ElapsedSec 1700 -Outstanding 1 -Total 1 `
            -BudgetSec 1830 -GraceSec 300 -LoneSinceSec 0 | Should -BeNullOrEmpty
    }

    It 'does not fire before the grace clock has started' {
        Test-EraStragglerExpired -ElapsedSec 1700 -Outstanding 1 -Total 3 `
            -BudgetSec 1830 -GraceSec 300 -LoneSinceSec -1 | Should -BeNullOrEmpty
    }

    It 'would not have fired on any measured healthy round' {
        # The guard against a future "tighten the default" change. Replays the
        # real slowest-minus-second-slowest gaps; the straggler is abandoned
        # only if it trails by more than the grace, so every one of these must
        # keep waiting at the default 300s.
        foreach ($gap in @(8, 136, 116, 79)) {
            $loneSince = 300
            Test-EraStragglerExpired -ElapsedSec ($loneSince + $gap) -Outstanding 1 -Total 3 `
                -BudgetSec 1830 -GraceSec 300 -LoneSinceSec $loneSince |
                Should -BeNullOrEmpty -Because "a healthy reviewer trailing ${gap}s must not be cut off"
        }
    }
}

Describe 'Stop-EraAdapterChild' -Tag Unit {
    # MEASURED, and the reason this function exists at all: a ThreadJob sitting
    # inside Process.WaitForExit() cannot be interrupted. Stop-Job on such a job
    # BLOCKS INDEFINITELY (observed still blocked after minutes) while the native
    # child keeps running. The first version of the grace path called Stop-Job
    # and would therefore have HUNG the dispatcher -- the exact opposite of the
    # feature's purpose -- and orphaned the child.
    #
    # Killing the CHILD instead lets the adapter's WaitForExit return, its
    # finally tree-kill run, and the job finish by itself. Measured on the real
    # shape: child killed in 76ms, job reached Completed in 0s, no orphan, and a
    # subsequent Stop-Job took 2ms.
    It 'is a safe no-op when the PID file does not exist' {
        Stop-EraAdapterChild -PidFile (Join-Path $env:TEMP "definitely-missing-$(New-Guid).pid") |
            Should -BeFalse
    }

    It 'is a safe no-op for an empty path' {
        Stop-EraAdapterChild -PidFile '' | Should -BeFalse
    }

    It 'is a safe no-op when the PID file holds garbage' {
        $f = Join-Path $env:TEMP "era-pid-$(New-Guid).pid"
        Set-Content -LiteralPath $f -Value 'not-a-pid' -Encoding UTF8
        try { Stop-EraAdapterChild -PidFile $f | Should -BeFalse }
        finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    It 'is a safe no-op when the recorded process is already gone' {
        $f = Join-Path $env:TEMP "era-pid-$(New-Guid).pid"
        # A PID that will not be running: start something and let it exit.
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c','exit' -NoNewWindow -PassThru
        $null = $p.WaitForExit(10000)
        Set-Content -LiteralPath $f -Value $p.Id -Encoding UTF8
        try { Stop-EraAdapterChild -PidFile $f | Should -BeFalse }
        finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    It 'tree-kills a live recorded process and reports it' {
        $f = Join-Path $env:TEMP "era-pid-$(New-Guid).pid"
        $p = Start-Process -FilePath 'ping.exe' -ArgumentList '-n','60','127.0.0.1' `
                -NoNewWindow -PassThru -RedirectStandardOutput ([System.IO.Path]::GetTempFileName())
        Set-Content -LiteralPath $f -Value $p.Id -Encoding UTF8
        try {
            Stop-EraAdapterChild -PidFile $f | Should -BeTrue
            (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        } finally {
            if (-not $p.HasExited) { try { $p.Kill($true) } catch {} }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'The grace path never calls Stop-Job on a possibly-blocked job' -Tag Unit {
    # The regression lock. Calling Stop-Job to abandon a straggler hangs the
    # dispatcher; abandonment must go through the child kill, and must NOT
    # happen at all when there is no killable child.
    It 'abandons via Stop-EraAdapterChild, conditionally on the kill succeeding' {
        $src = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'workflow.ps1')
        $src | Should -Match "if \(\`$straggler\) \{ \`$killed = Stop-EraAdapterChild -PidFile"
        $src | Should -Match 'if \(\$killed\) \{'
        # And when it cannot kill, it disables the grace rather than abandoning.
        $src | Should -Match '\$graceSec\s*=\s*0'
    }

    It 'every adapter that spawns a native child accepts -PidFile and records it' {
        $root = Split-Path $PSScriptRoot -Parent
        foreach ($a in @('agy', 'claude', 'opencode')) {
            $src = Get-Content -Raw (Join-Path $root "backends/$a.ps1")
            $src | Should -Match '\[string\]\$PidFile' -Because "$a must accept the pid file"
            $src | Should -Match 'Set-Content -LiteralPath \$PidFile -Value' -Because "$a must record its child PID"
        }
    }

    It 'the REST adapters are left alone — they have no child to kill' {
        $root = Split-Path $PSScriptRoot -Parent
        foreach ($a in @('anthropic', 'geminiapi', 'openaicompat')) {
            (Get-Content -Raw (Join-Path $root "backends/$a.ps1")) |
                Should -Not -Match '\[string\]\$PidFile' -Because "$a spawns nothing"
        }
    }
}

Describe 'The dispatcher no longer hard-blocks on all jobs' -Tag Unit {
    It 'uses the poll loop rather than a blocking Wait-Job over the job array' {
        $src = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'workflow.ps1')
        # The old shape held the round for the entire budget.
        $src | Should -Not -Match 'Wait-Job -Job \$allJobs -Timeout'
        $src | Should -Match 'Test-EraStragglerExpired -ElapsedSec'
    }
}
