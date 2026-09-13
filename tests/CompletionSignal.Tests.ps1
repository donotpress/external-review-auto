# Completion signaling: every round ends in a machine-readable receipt,
# every seat finish is named in the log, and a best-effort ping fires.
#
# Callers are arbitrary (opencode TUI, claude, tmux, CI): none of this
# requires the caller's cooperation. The contract is files + stdout:
# `round-N-done.json` appears exactly once per round on every exit path
# (0 usable, 2 void, 1 preflight/abort), per-seat finishes log as they
# happen, and the ping never fails a round.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/CompletionSignal.Tests.ps1 -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
}

Describe 'Write-EraCompletionReceipt' -Tag Unit {
    It 'writes one JSON receipt with per-seat outcomes' {
        $dir = Join-Path $TestDrive 'round'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-EraCompletionReceipt -ReviewDir $dir -Round 3 -TopicSlug 't' -Results @{
            opus   = @{ ExitCode = 0; Response = ('x' * 100); WallClockSec = 10 }
            gemini = @{ ExitCode = -1; Error = 'stall-or-timeout'; Response = $null; WallClockSec = 0 }
        } -ExitCode 0 -DurationSec 12.5
        $f = Join-Path $dir 'round-3-done.json'
        Test-Path -LiteralPath $f | Should -BeTrue
        $j = Get-Content -Raw -LiteralPath $f | ConvertFrom-Json
        $j.tool | Should -Be 'era'
        $j.round | Should -Be 3
        $j.exit_code | Should -Be 0
        $j.usable | Should -Be 1
        $j.requested | Should -Be 2
        $j.duration_s | Should -Be 12.5
        $g = @($j.seats | Where-Object { $_.preset -eq 'gemini' })[0]
        $g.exit | Should -Be -1
        $g.error | Should -Be 'stall-or-timeout'
        $o = @($j.seats | Where-Object { $_.preset -eq 'opus' })[0]
        $o.chars | Should -Be 100
    }

    It 'records an aborted pre-dispatch round with zero seats, never throws' {
        $dir = Join-Path $TestDrive 'roundx'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        { Write-EraCompletionReceipt -ReviewDir $dir -Round 1 -TopicSlug 't' `
                -Results $null -ExitCode 1 -DurationSec 0 } | Should -Not -Throw
        $j = Get-Content -Raw -LiteralPath (Join-Path $dir 'round-1-done.json') | ConvertFrom-Json
        $j.exit_code | Should -Be 1
        $j.usable | Should -Be 0
    }

    It 'never throws on an unwritable directory' {
        { Write-EraCompletionReceipt -ReviewDir (Join-Path $TestDrive 'no-such-dir') `
                -Round 1 -TopicSlug 't' -Results @{} -ExitCode 2 -DurationSec 1 } | Should -Not -Throw
    }
}

Describe 'Get-EraNewlyDone' -Tag Unit {
    BeforeAll {
        function script:FakeJob { param([string]$State) [pscustomobject]@{ State = $State } }
    }

    It 'returns presets that finished since last seen' {
        $d = @(
            [pscustomobject]@{ Preset = 'opus'; ResponsePath = 'o'; Job = (script:FakeJob 'Completed') }
            [pscustomobject]@{ Preset = 'gemini'; ResponsePath = 'g'; Job = (script:FakeJob 'Running') }
        )
        $new = Get-EraNewlyDone -Dispatched $d -Seen @('opus')
        @($new).Count | Should -Be 0
        $new2 = Get-EraNewlyDone -Dispatched $d -Seen @()
        @($new2 | ForEach-Object { $_.Preset }) | Should -Contain 'opus'
        @($new2 | ForEach-Object { $_.Preset }) | Should -Not -Contain 'gemini'
    }

    It 'treats Failed/Stopped as done, ignores running and empty input' {
        $d = @(
            [pscustomobject]@{ Preset = 'a'; ResponsePath = 'a'; Job = (script:FakeJob 'Failed') }
            [pscustomobject]@{ Preset = 'b'; ResponsePath = 'b'; Job = (script:FakeJob 'Stopped') }
            [pscustomobject]@{ Preset = 'c'; ResponsePath = 'c'; Job = (script:FakeJob 'Running') }
        )
        @(Get-EraNewlyDone -Dispatched $d -Seen @()).Count | Should -Be 2
        @(Get-EraNewlyDone -Dispatched @() -Seen @()).Count | Should -Be 0
    }
}

Describe 'Send-EraCompletionPing' -Tag Unit {
    It 'never throws, with or without toast support' {
        { Send-EraCompletionPing -Round 1 -ExitCode 0 } | Should -Not -Throw
        { Send-EraCompletionPing -Round 1 -ExitCode 2 } | Should -Not -Throw
    }
}

Describe 'era.ps1 emits receipt, transitions, and ping' -Tag Unit {
    BeforeAll { $script:EraSrc = Get-Content -Raw "$PSScriptRoot/../runtimes/era.ps1" }

    It 'writes the receipt from the finally block (all exit paths)' {
        $fin = $script:EraSrc.IndexOf('} finally {')
        $fin | Should -BeGreaterThan 0
        $script:EraSrc.Substring($fin) | Should -Match 'Write-EraCompletionReceipt'
        $script:EraSrc.Substring($fin) | Should -Match 'Send-EraCompletionPing'
    }

    It 'tracks the exit code explicitly (void 2 vs success 0 vs abort 1)' {
        $script:EraSrc | Should -Match '\$eraExitCode = 2'
        $script:EraSrc | Should -Match '\$eraExitCode = 0'
    }

    It 'announces seat finishes from the dispatch poll loop' {
        $wf = Get-Content -Raw "$PSScriptRoot/../workflow.ps1"
        $wf | Should -Match 'Get-EraNewlyDone'
    }
}
