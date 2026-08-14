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

Describe 'one attempt gets ONE budget, not one budget twice' -Tag Unit {
    # Round-7 (opus) BLOCKER 4. claude.ps1 computed a single $attemptTimeoutSec
    # and then spent it TWICE, sequentially:
    #
    #   $attemptTimeoutSec = [Math]::Max(60, $TimeoutSec - $sw.Elapsed...)
    #   $stdinCopyTask.Wait($attemptTimeoutSec * 1000)       <- full budget
    #   $claudeProc.WaitForExit($attemptTimeoutSec * 1000)   <- full budget AGAIN
    #
    # Worst case 2 x TimeoutSec against a dispatcher budget of TimeoutSec + 30
    # (Invoke-ReviewerDispatch). Opus was explicit that it could not measure
    # reachability, and asked for instrumentation before a fix. MEASURED here
    # instead, by reproducing the exact shape against a child that never drains
    # stdin (a 600 KB bundle cannot fit the ~64 KB pipe buffer, so the copy
    # blocks until someone reads):
    #
    #   stdin copy Wait returned False after 5.0s (budget 5s)
    #   WaitForExit  returned False after a FURTHER 5.0s
    #   TOTAL 10.1s against a single 5s budget -- OVERRUN FACTOR 2.03x
    #
    # So the arithmetic is real whenever the child is slow to drain stdin. Both
    # waits now derive from ONE deadline.

    BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'backends/claude.ps1') }

    It 'never returns a negative wait, because Wait(-1) means WAIT FOREVER' {
        # This is the trap the clamp exists for: Task.Wait(int) and
        # Process.WaitForExit(int) both read a negative millisecond count as
        # Timeout.Infinite. An exhausted budget must fail fast, not hang.
        Get-ClaudeRemainingMs -Deadline (Get-Date).AddSeconds(-30) | Should -Be 0
        Get-ClaudeRemainingMs -Deadline (Get-Date).AddMilliseconds(-1) | Should -Be 0
    }

    It 'returns what is actually left, not the original budget' {
        $deadline = (Get-Date).AddMilliseconds(2000)
        Start-Sleep -Milliseconds 300
        $left = Get-ClaudeRemainingMs -Deadline $deadline
        $left | Should -BeGreaterThan 0
        $left | Should -BeLessThan 2000 -Because 'time already spent must come off the budget'
    }

    It 'two sequential waits from one deadline cannot exceed the budget' {
        # The invariant the fix encodes: spend it in two places, spend it once.
        $budgetMs = 1500
        $deadline = (Get-Date).AddMilliseconds($budgetMs)
        $first = Get-ClaudeRemainingMs -Deadline $deadline
        Start-Sleep -Milliseconds 400
        $second = Get-ClaudeRemainingMs -Deadline $deadline
        ($first + $second) | Should -BeLessOrEqual ($budgetMs * 2)
        $second | Should -BeLessThan $first -Because 'the second wait inherits what the first left'
        ($second + 400) | Should -BeLessOrEqual ($budgetMs + 150) -Because 'elapsed + remaining is the budget, within timer slop'
    }

    It 'claude.ps1 spends no wait on the raw per-attempt budget' {
        # Anchored on the WAIT ARGUMENTS, not on a file-wide scan for the old
        # literal: the docstring above Get-ClaudeRemainingMs quotes
        # '$attemptTimeoutSec * 1000' to explain what was wrong, and a bare
        # -Not -Match matches that COMMENT rather than any call. Assert the
        # thing that actually matters -- what each wait is handed.
        $claude = $script:Adapters['claude']
        $stdinArg = [regex]::Match($claude, '\$stdinCopyTask\.Wait\(([^)]*(?:\([^)]*\))?[^)]*)\)').Groups[1].Value
        $procArg  = [regex]::Match($claude, '\$claudeProc\.WaitForExit\(([^)]*(?:\([^)]*\))?[^)]*)\)').Groups[1].Value
        $stdinArg | Should -Not -Match 'attemptTimeoutSec' -Because 'the stdin wait must draw from the shared deadline'
        $procArg  | Should -Not -Match 'attemptTimeoutSec' -Because 'so must the process wait'
    }

    It 'claude.ps1 derives BOTH the stdin wait and WaitForExit from one deadline' {
        $claude = $script:Adapters['claude']
        $claude | Should -Match '\$attemptDeadline\s*=' -Because 'one deadline per attempt'
        $stdinWait = [regex]::Match($claude, '\$stdinCopyTask\.Wait\(([^)]*)\)')
        $procWait  = [regex]::Match($claude, '\$claudeProc\.WaitForExit\(([^)]*)\)')
        $stdinWait.Success | Should -BeTrue
        $procWait.Success  | Should -BeTrue
        $stdinWait.Groups[1].Value | Should -Match 'attemptDeadline'
        $procWait.Groups[1].Value  | Should -Match 'attemptDeadline'
    }
}

Describe 'the dispatcher never calls Stop-Job on a job that may be inside WaitForExit' -Tag Unit {
    # Round-7 (opus) BLOCKER 4, second half. Stop-EraAdapterChild's own docstring
    # records it as MEASURED: a ThreadJob sitting inside Process.WaitForExit()
    # cannot be interrupted, so Stop-Job blocks indefinitely and the native child
    # keeps running.
    #
    # The straggler GRACE path already respects that -- it tree-kills the child
    # first and lets the job unwind on its own. The BUDGET-EXPIRY path did not:
    # the result-collection loop called Stop-Job directly. That is the one path
    # that reaches the known-blocking call, and it is exactly the path a
    # 2x-overrunning adapter (above) drives the dispatcher down.

    BeforeAll { $script:Wf = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'workflow.ps1') }

    It 'tree-kills the child before Stop-Job in the result-collection loop' {
        $loop = $script:Wf.IndexOf('foreach ($d in $dispatched)')
        $loop | Should -BeGreaterThan 0
        $stopJob = $script:Wf.IndexOf('Stop-Job -Job $d.Job', $loop)
        $stopJob | Should -BeGreaterThan 0 -Because 'the collection loop still stops unfinished jobs'
        $kill = $script:Wf.IndexOf('Stop-EraAdapterChild -PidFile $d.PidPath', $loop)
        $kill | Should -BeGreaterThan 0 -Because 'it must unblock WaitForExit first'
        $kill | Should -BeLessThan $stopJob -Because 'killing after Stop-Job is killing after the hang'
    }

    It 'and the grace path still kills the child rather than stopping the job' {
        # Pinning the behaviour that was already right, so this fix cannot be
        # "tidied" into a single shared Stop-Job later.
        $script:Wf | Should -Match 'Stop-EraAdapterChild -PidFile \$straggler\.PidPath'
    }
}
