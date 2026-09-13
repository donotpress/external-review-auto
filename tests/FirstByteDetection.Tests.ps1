# First-byte detection for claude + REST attempt caps + dead-transport gate.
#
# MEASURED gaps: a hung claude seat burns its whole budget with zero
# detection (no first-token/stall logic in backends/claude.ps1); REST seats
# wait full TimeoutSec (~600s) x MaximumRetryCount 2 with no progress
# signal. Opus once thought silently for 374s productively, so pre-byte
# and mid-think silence get different deadlines, and the first-byte bound
# (300s = ~5x the interactive p90 of 63s incl. idle) is PROVISIONAL pending
# the spawn-to-byte instrumentation this change emits (FirstByteSec lands
# in every claude result for future calibration).
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/FirstByteDetection.Tests.ps1 -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/../backends/claude.ps1"
    . "$PSScriptRoot/../workflow.ps1"
}

Describe 'Wait-ClaudeFirstByte' -Tag Unit {
    It 'reports first-byte seconds for a process that speaks quickly' {
        $p = Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Milliseconds 800; Write-Output "hi"' `
            -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $TestDrive 'fast-out.txt')
        try {
            $r = Wait-ClaudeFirstByte -Process $p `
                -StdFile (Join-Path $TestDrive 'fast-out.txt') `
                -FirstByteTimeoutSec 60 -StallObserveSec 60 -Deadline ([datetime]::UtcNow.AddSeconds(60))
            $r.Outcome | Should -Be 'exited'
            [double]$r.FirstByteSec | Should -BeGreaterThan 0
            [double]$r.FirstByteSec | Should -BeLessThan 30
        } finally { try { $p.Kill($true) } catch {} }
    }

    It 'times out a silent process and names it first-byte-timeout' {
        $p = Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' `
            -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $TestDrive 'slow-out.txt')
        try {
            $r = Wait-ClaudeFirstByte -Process $p `
                -StdFile (Join-Path $TestDrive 'slow-out.txt') `
                -FirstByteTimeoutSec 3 -StallObserveSec 60 -Deadline ([datetime]::UtcNow.AddSeconds(60))
            $r.Outcome | Should -Be 'first-byte-timeout'
            $r.FirstByteSec | Should -BeNullOrEmpty
        } finally { try { $p.Kill($true) } catch {} }
    }

    It 'honors the attempt deadline over its own timeouts (clamp invariant)' {
        $p = Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' `
            -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $TestDrive 'cap-out.txt')
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Wait-ClaudeFirstByte -Process $p `
                -StdFile (Join-Path $TestDrive 'cap-out.txt') `
                -FirstByteTimeoutSec 600 -StallObserveSec 600 -Deadline ([datetime]::UtcNow.AddSeconds(4))
            $sw.Stop()
            $r.Outcome | Should -Be 'timeout'
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
        } finally { try { $p.Kill($true) } catch {} }
    }
}

Describe 'Test-EraDeadTransportFallback (renamed gate, one count)' -Tag Unit {
    It 'fires for any single dead transport in a usable round' {
        foreach ($c in @('agy-stream-interrupted', 'opencode-no-output', 'agy-quota-exhausted', 'claude-no-output')) {
            $n = @{ 'agy-stream-interrupted' = 0; 'opencode-no-output' = 0; 'agy-quota-exhausted' = 0; 'claude-no-output' = 0 }
            $n[$c] = 1
            Test-EraDeadTransportFallback -DeadTransport $n -UsableCount 2 | Should -BeTrue
        }
    }

    It 'stays shut with none, or in a void round' {
        $z = @{ 'agy-stream-interrupted' = 0; 'opencode-no-output' = 0; 'agy-quota-exhausted' = 0; 'claude-no-output' = 0 }
        Test-EraDeadTransportFallback -DeadTransport $z -UsableCount 2 | Should -BeFalse
        $o = @{ 'agy-stream-interrupted' = 0; 'opencode-no-output' = 1; 'agy-quota-exhausted' = 0; 'claude-no-output' = 0 }
        Test-EraDeadTransportFallback -DeadTransport $o -UsableCount 0 | Should -BeFalse
    }
}

Describe 'REST attempt timeouts are capped' -Tag Unit {
    It 'all three REST adapters cap per-attempt waits at 180s' {
        foreach ($b in @('geminiapi', 'openaicompat', 'anthropic')) {
            $src = Get-Content -Raw "$PSScriptRoot/../backends/$b.ps1"
            $src | Should -Match '\[Math\]::Min\(\$TimeoutSec,\s*180\)'
        }
    }
}

Describe 'metadata persists first-byte seconds' -Tag Unit {
    BeforeAll { . "$PSScriptRoot/../workflow.ps1" }

    It 'records first_byte_sec on success when the adapter reports it' {
        $dir = Join-Path $TestDrive 'meta-fb'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $resp = Join-Path $dir 'round-1-opus-response.md'
        '# R' | Set-Content -LiteralPath $resp -NoNewline
        $reg = @{ opus = @{ backend = 'claude'; model_id = 'm'; pricing = @{ input_per_m = 1; output_per_m = 1 } } }
        Write-ReviewMetadata -ReviewDir $dir -Round 1 -TopicSlug 't' -Mode 'assessment' -BundleTokens 10 `
            -Results @{ opus = @{ ExitCode = 0; Response = '# R'; OutputTokens = 1; WallClockSec = 5;
                                   CaptureMethod = 'direct'; FirstByteSec = 12.5 } } `
            -Registry $reg -ModelOverrides @{} -DeliveryModes @{}
        $j = Get-Content -Raw -LiteralPath (Join-Path $dir 'round-1-metadata.json') | ConvertFrom-Json
        @($j.reviewers | Where-Object { $_.preset -eq 'opus' })[0].first_byte_sec | Should -Be 12.5
    }

    It 'records null when the adapter reports nothing (other backends)' {
        $dir = Join-Path $TestDrive 'meta-fb2'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $resp = Join-Path $dir 'round-1-opus-response.md'
        '# R' | Set-Content -LiteralPath $resp -NoNewline
        $reg = @{ opus = @{ backend = 'claude'; model_id = 'm'; pricing = @{ input_per_m = 1; output_per_m = 1 } } }
        Write-ReviewMetadata -ReviewDir $dir -Round 1 -TopicSlug 't' -Mode 'assessment' -BundleTokens 10 `
            -Results @{ opus = @{ ExitCode = 0; Response = '# R'; OutputTokens = 1; WallClockSec = 5;
                                   CaptureMethod = 'direct' } } `
            -Registry $reg -ModelOverrides @{} -DeliveryModes @{}
        $j = Get-Content -Raw -LiteralPath (Join-Path $dir 'round-1-metadata.json') | ConvertFrom-Json
        @($j.reviewers | Where-Object { $_.preset -eq 'opus' })[0].first_byte_sec | Should -BeNullOrEmpty
    }
}
