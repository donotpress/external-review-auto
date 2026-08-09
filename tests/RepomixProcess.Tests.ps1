# Tests for running repomix under a killable process handle.
#
# The old guard used Start-ThreadJob + Wait-Job -Timeout + Stop-Job. Stop-Job
# ends the THREAD; it cannot bound the native child process repomix spawns, so a
# timeout left node running. The adapters already solve the equivalent problem
# with Process.Kill($true) -- an invariant tests/ProcessTreeKill.Tests.ps1
# asserts across agy/claude/opencode. repomix was the one place that did not.
#
# Separately, the timeout branch's Receive-Job was INERT: the job body captured
# all output into a local and emitted nothing until completion, so a job that had
# not completed had no output to receive. Redirecting to files fixes that -- the
# partial output is on disk and readable at kill time.
#
# Measured 2026-08-09 on this box, which is what makes the shim question tractable:
#   Get-Command repomix -> ExternalScript, C:\...\npm\repomix.ps1
#   siblings present    -> repomix, repomix.cmd, repomix.ps1
#   cmd.exe /c repomix.cmd -c <cfg>  under Start-Process -PassThru
#                       -> exit 0, stdout captured, bundle produced, 2.3s
#   .Kill($true) on the cmd.exe parent -> child count 1 -> 0, parent exited
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/RepomixProcess.Tests.ps1"

$script:OnWindows = $IsWindows -or $env:OS -eq 'Windows_NT'

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'
}

Describe 'Resolve-EraRepomixCommand' -Tag Unit {
    It 'runs a .cmd shim through the command processor' -Skip:(-not $script:OnWindows) {
        $tmp = Join-Path $env:TEMP "era-shim-cmd-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $shim = Join-Path $tmp 'repomix.cmd'
            Set-Content -Path $shim -Value '@echo off'
            $r = Resolve-EraRepomixCommand -Source $shim -CommandType 'Application'
            $r.FilePath | Should -Be $env:ComSpec
            $r.Arguments[0] | Should -Be '/c'
            $r.Arguments[1] | Should -Be $shim
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'prefers a sibling .cmd over a .ps1 shim, to avoid nesting a second pwsh' -Skip:(-not $script:OnWindows) {
        $tmp = Join-Path $env:TEMP "era-shim-both-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            Set-Content -Path (Join-Path $tmp 'repomix.cmd') -Value '@echo off'
            $ps1 = Join-Path $tmp 'repomix.ps1'
            Set-Content -Path $ps1 -Value '# shim'
            $r = Resolve-EraRepomixCommand -Source $ps1 -CommandType 'ExternalScript'
            $r.FilePath | Should -Be $env:ComSpec
            ($r.Arguments -join ' ') | Should -Match 'repomix\.cmd'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'falls back to pwsh -File for a lone .ps1 shim' {
        $tmp = Join-Path $env:TEMP "era-shim-ps1-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $ps1 = Join-Path $tmp 'repomix.ps1'
            Set-Content -Path $ps1 -Value '# shim'
            $r = Resolve-EraRepomixCommand -Source $ps1 -CommandType 'ExternalScript'
            $r.FilePath | Should -Match 'pwsh'
            ($r.Arguments -join ' ') | Should -Match '-File'
            ($r.Arguments -join ' ') | Should -Match 'repomix\.ps1'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'runs a native executable directly, with no wrapper' {
        $tmp = Join-Path $env:TEMP "era-shim-exe-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $exe = Join-Path $tmp 'repomix.exe'
            Set-Content -Path $exe -Value 'stub'
            $r = Resolve-EraRepomixCommand -Source $exe -CommandType 'Application'
            $r.FilePath | Should -Be $exe
            @($r.Arguments).Count | Should -Be 0
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-EraTrackedProcess' -Tag Unit -Skip:(-not $script:OnWindows) {
    It 'captures stdout and the exit code' {
        $r = Invoke-EraTrackedProcess -FilePath $env:ComSpec `
                -Arguments @('/c', 'echo', 'HELLO-TRACKED') `
                -WorkingDirectory $env:TEMP -TimeoutSec 30
        $r.TimedOut | Should -BeFalse
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'HELLO-TRACKED'
    }

    It 'reports a non-zero exit code without throwing' {
        $r = Invoke-EraTrackedProcess -FilePath $env:ComSpec `
                -Arguments @('/c', 'exit', '3') `
                -WorkingDirectory $env:TEMP -TimeoutSec 30
        $r.ExitCode | Should -Be 3
        $r.TimedOut | Should -BeFalse
    }

    It 'kills the whole process tree on timeout — Stop-Job could not do this' {
        $r = Invoke-EraTrackedProcess -FilePath $env:ComSpec `
                -Arguments @('/c', 'ping -n 30 127.0.0.1') `
                -WorkingDirectory $env:TEMP -TimeoutSec 2
        $r.TimedOut | Should -BeTrue
        # No surviving child of the process we started.
        @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($r.ProcessId)").Count | Should -Be 0
    }

    It 'returns the partial output captured before the timeout — the drain is real now' {
        # The old Receive-Job could never return anything, because the ThreadJob
        # body buffered everything into a local until completion.
        $r = Invoke-EraTrackedProcess -FilePath $env:ComSpec `
                -Arguments @('/c', 'ping -n 30 127.0.0.1') `
                -WorkingDirectory $env:TEMP -TimeoutSec 3
        $r.TimedOut | Should -BeTrue
        $r.Output   | Should -Match 'Pinging'
    }

    It 'quotes arguments containing spaces' {
        # Start-Process -ArgumentList joins array elements with spaces and does
        # NOT quote them, so a repo path or npm prefix containing a space split
        # into two arguments and broke repomix. Reported by opus as a regression
        # introduced with the tracked-process change.
        $tmp = Join-Path $env:TEMP "era space dir $(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $f = Join-Path $tmp 'a file.txt'
            Set-Content -Path $f -Value 'QUOTED-OK'
            $r = Invoke-EraTrackedProcess -FilePath $env:ComSpec `
                    -Arguments @('/c', 'type', $f) `
                    -WorkingDirectory $tmp -TimeoutSec 30
            $r.Output | Should -Match 'QUOTED-OK'
            $r.ExitCode | Should -Be 0
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'cleans up its redirect temp files' {
        $r = Invoke-EraTrackedProcess -FilePath $env:ComSpec `
                -Arguments @('/c', 'echo', 'x') `
                -WorkingDirectory $env:TEMP -TimeoutSec 30
        if ($r.StdOutPath) { Test-Path $r.StdOutPath | Should -BeFalse }
    }
}

Describe 'era.ps1 runs repomix under a killable handle' -Tag Unit {
    It 'no longer uses Start-ThreadJob for repomix' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Not -Match "Start-ThreadJob -Name repomix"
        $src | Should -Match 'Invoke-EraRepomix'
    }

    It 'reports the timeout through the tracked-process result, not Wait-Job' {
        $src = Get-Content -Raw $script:EraPath
        $timeoutIdx = $src.IndexOf('repomix timed out after')
        $timeoutIdx | Should -BeGreaterThan 0
        # The surrounding branch must key off the tracked result.
        $window = $src.Substring([Math]::Max(0, $timeoutIdx - 900), [Math]::Min(900, $timeoutIdx))
        $window | Should -Match 'TimedOut'
    }
}
