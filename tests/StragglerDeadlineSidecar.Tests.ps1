# Deadline sidecar: the dispatcher must not tree-kill a lone straggler whose
# adapter was DESIGNED to wait longer.
#
# MEASURED 2026-09-11 (ebook-pipeline round 3): muse-spark on the read-tool
# path sat silent for 860s by design (first-token deadline raised to 845s to
# match the stall plan xhigh permits), but the dispatcher abandoned it at
# lone(572s)+300s grace = 872s elapsed -- 3s before the adapter's own 875s
# budget would have fired. Two timeouts set by different findings, colliding
# on the read-tool path.
#
# Fix: the adapter publishes its give-up epoch to "<pidfile>.deadline" at
# spawn; on grace expiry the dispatcher defers the kill until
# min(sidecar + 20s unwind, budget end) instead of killing now. Absent,
# unparseable, expired, or over-budget sidecars behave exactly as today.
# A stale sidecar from a previous round carries an OLD epoch, so it reads as
# expired and fails closed toward the old behaviour.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/StragglerDeadlineSidecar.Tests.ps1 -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
}

Describe 'Get-EraStragglerDeferral' -Tag Unit {
    It 'defers the kill until sidecar + unwind when the adapter out-waits the grace' {
        $pidFile = Join-Path $TestDrive 'seat-response.md.pid'
        'x' | Set-Content -LiteralPath $pidFile -NoNewline
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        ($now + 800) | Set-Content -LiteralPath "$pidFile.deadline" -NoNewline
        Get-EraStragglerDeferral -PidFile $pidFile -NowEpoch $now -BudgetEndEpoch ($now + 900) |
            Should -Be ($now + 820)
    }

    It 'caps the deferral at the budget end, never past it' {
        $pidFile = Join-Path $TestDrive 'seat2-response.md.pid'
        'x' | Set-Content -LiteralPath $pidFile -NoNewline
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        ($now + 5000) | Set-Content -LiteralPath "$pidFile.deadline" -NoNewline
        Get-EraStragglerDeferral -PidFile $pidFile -NowEpoch $now -BudgetEndEpoch ($now + 900) |
            Should -Be ($now + 900)
    }

    It 'returns null when there is no sidecar (adapters that do not publish one)' {
        $pidFile = Join-Path $TestDrive 'nosidecar-response.md.pid'
        'x' | Set-Content -LiteralPath $pidFile -NoNewline
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Get-EraStragglerDeferral -PidFile $pidFile -NowEpoch $now -BudgetEndEpoch ($now + 900) |
            Should -BeNullOrEmpty
    }

    It 'returns null for an expired sidecar (stale file from a previous round)' {
        $pidFile = Join-Path $TestDrive 'stale-response.md.pid'
        'x' | Set-Content -LiteralPath $pidFile -NoNewline
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        ($now - 100) | Set-Content -LiteralPath "$pidFile.deadline" -NoNewline
        Get-EraStragglerDeferral -PidFile $pidFile -NowEpoch $now -BudgetEndEpoch ($now + 900) |
            Should -BeNullOrEmpty
    }

    It 'returns null for an unparseable sidecar' {
        $pidFile = Join-Path $TestDrive 'garbage-response.md.pid'
        'x' | Set-Content -LiteralPath $pidFile -NoNewline
        'not-an-epoch' | Set-Content -LiteralPath "$pidFile.deadline" -NoNewline
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Get-EraStragglerDeferral -PidFile $pidFile -NowEpoch $now -BudgetEndEpoch ($now + 900) |
            Should -BeNullOrEmpty
    }

    It 'honors a short deferral when the adapter gives up seconds from now' {
        $pidFile = Join-Path $TestDrive 'past-response.md.pid'
        'x' | Set-Content -LiteralPath $pidFile -NoNewline
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        ($now + 5) | Set-Content -LiteralPath "$pidFile.deadline" -NoNewline
        Get-EraStragglerDeferral -PidFile $pidFile -NowEpoch $now -BudgetEndEpoch ($now + 900) |
            Should -Be ($now + 25)
    }
    It 'returns null when the budget is already spent (budget outranks deferral)' {
        $pidFile = Join-Path $TestDrive 'spent-response.md.pid'
        'x' | Set-Content -LiteralPath $pidFile -NoNewline
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        ($now + 500) | Set-Content -LiteralPath "$pidFile.deadline" -NoNewline
        Get-EraStragglerDeferral -PidFile $pidFile -NowEpoch $now -BudgetEndEpoch ($now - 10) |
            Should -BeNullOrEmpty
    }
}

Describe 'dispatcher honors the sidecar on grace expiry' -Tag Unit {
    BeforeAll { $script:DispatchSrc = Get-Content -Raw "$PSScriptRoot/../workflow.ps1" }

    It 'consults Get-EraStragglerDeferral before tree-killing a lone straggler' {
        $script:DispatchSrc | Should -Match 'Get-EraStragglerDeferral'
    }

    It 'opencode publishes its give-up epoch next to the pid file at spawn' {
        $adapter = Get-Content -Raw "$PSScriptRoot/../backends/opencode.ps1"
        $adapter | Should -Match '\.deadline'
    }
}
