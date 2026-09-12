# Quota preflight: never burn a 600s stall on an empty pool.
#
# MEASURED 2026-09-12: agy /usage showed the Gemini pool at 0.00% (refresh
# ~72h out) while rounds kept dispatching gemini seats that died
# stream-interrupted/no-start after full budgets. A flag file
# ($env:TEMP/era-agy-quota.json, manual or probe-written) records the
# exhaustion; the adapter fails instantly with an honest code instead of
# spawning into a wall. Fail-OPEN throughout: a missing, malformed, or
# expired flag -- or ERA_IGNORE_QUOTA_FLAG=1 -- behaves exactly as today.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/QuotaPreflight.Tests.ps1 -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/../backends/agy.ps1"
    . "$PSScriptRoot/../workflow.ps1"

    function New-QuotaFlag {
        param([bool]$Exhausted = $true, [string]$RefreshUtc = '2026-09-15T04:56:05Z', [string]$Raw = $null)
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ("era-quota-" + [guid]::NewGuid() + ".json")
        if (-not [string]::IsNullOrEmpty($Raw)) { $Raw | Set-Content -LiteralPath $p -NoNewline -Encoding utf8 }
        else {
            @{ exhausted = $Exhausted; refresh_utc = $RefreshUtc; source = 'test' } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $p -NoNewline -Encoding utf8
        }
        return $p
    }

    $script:MiGemini = @{
        preset = 'gemini'; backend = 'agy'; agy_model_family = 'gemini-3.8-flash'
        pricing = @{ input_per_m = 1.5; output_per_m = 7.5 }
    }
}

Describe 'Get-AgyQuotaState' -Tag Unit {
    It 'reports exhaustion with the parsed refresh instant' {
        $f = New-QuotaFlag
        try {
            $r = Get-AgyQuotaState -FlagPath $f
            $r.Exhausted | Should -BeTrue
            # Same instant, any Kind (Should -Be is Kind-strict on DateTimes).
            $r.RefreshUtc.ToUniversalTime() | Should -Be ([datetime]'2026-09-15T04:56:05Z').ToUniversalTime()
        } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    }

    It 'fails open when the pool has refreshed (expired flag)' {
        $f = New-QuotaFlag -RefreshUtc '2026-09-01T00:00:00Z'
        try {
            (Get-AgyQuotaState -FlagPath $f).Exhausted | Should -BeFalse
        } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    }

    It 'fails open on malformed JSON, missing file, or non-exhausted pool' {
        $bad = New-QuotaFlag -Raw 'not json{{{'
        $off = New-QuotaFlag -Exhausted $false
        try {
            (Get-AgyQuotaState -FlagPath $bad).Exhausted | Should -BeFalse
            (Get-AgyQuotaState -FlagPath $off).Exhausted | Should -BeFalse
            (Get-AgyQuotaState -FlagPath (Join-Path $TestDrive 'absent.json')).Exhausted | Should -BeFalse
        } finally { Remove-Item -LiteralPath $bad, $off -ErrorAction SilentlyContinue }
    }

    It 'fails open under ERA_IGNORE_QUOTA_FLAG=1 even when exhausted' {
        $f = New-QuotaFlag
        $old = $env:ERA_IGNORE_QUOTA_FLAG
        try {
            $env:ERA_IGNORE_QUOTA_FLAG = '1'
            (Get-AgyQuotaState -FlagPath $f).Exhausted | Should -BeFalse
        } finally {
            if ($null -eq $old) { Remove-Item Env:ERA_IGNORE_QUOTA_FLAG -ErrorAction SilentlyContinue }
            else { $env:ERA_IGNORE_QUOTA_FLAG = $old }
            Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-AgyReview fails fast on an exhausted pool' -Tag Unit {
    It 'never spawns when the flag is exhausted (zero stall burned)' {
        Mock _SpawnAndCaptureOnce { throw 'must not be called' }
        $b = Join-Path ([System.IO.Path]::GetTempPath()) ("era-bundle-" + [guid]::NewGuid() + ".xml")
        'x' | Set-Content -LiteralPath $b -NoNewline -Encoding utf8
        $resp = Join-Path ([System.IO.Path]::GetTempPath()) ("era-resp-" + [guid]::NewGuid() + ".md")
        $f = New-QuotaFlag
        try {
            $r = Invoke-AgyReview -BundlePath $b -PromptPath $b -ResponsePath $resp `
                -ModelInfo $script:MiGemini -TimeoutSec 600 -QuotaFlagPath $f
            $r.Error | Should -Be 'agy-quota-exhausted'
            $r.ExitCode | Should -Be -1
            $r.ContentOk | Should -BeFalse
            Should -Invoke _SpawnAndCaptureOnce -Times 0 -Exactly
        } finally { Remove-Item -LiteralPath $b, $f -ErrorAction SilentlyContinue }
    }

    It 'dispatches normally when no flag exists (old behavior preserved)' {
        Mock _SpawnAndCaptureOnce {
            @{ Response = '## Findings`n- real review'; ExitCode = 0; Strategy = 'run-id-match'
               Stderr = ''; WallClockSec = 1.0
               StreamEvidence = @{ Interrupted = $false; InterruptionCount = 0; TranscriptPath = $null; SessionDirsSeen = 0 } }
        }
        $b = Join-Path ([System.IO.Path]::GetTempPath()) ("era-bundle-" + [guid]::NewGuid() + ".xml")
        'x' | Set-Content -LiteralPath $b -NoNewline -Encoding utf8
        $resp = Join-Path ([System.IO.Path]::GetTempPath()) ("era-resp-" + [guid]::NewGuid() + ".md")
        try {
            $r = Invoke-AgyReview -BundlePath $b -PromptPath $b -ResponsePath $resp `
                -ModelInfo $script:MiGemini -TimeoutSec 600 -QuotaFlagPath (Join-Path $TestDrive 'absent.json')
            $r.ContentOk | Should -BeTrue
        } finally { Remove-Item -LiteralPath $b -ErrorAction SilentlyContinue }
    }
}

Describe 'quota-exhausted joins the dead-transport gate' -Tag Unit {
    It 'is recoverable (agy branch) and categorizes as not-delivered' {
        $reg = @{ gemini = @{ backend = 'agy' } }
        $r = Get-EraRecoverableFailures -ReviewerList @('gemini') `
            -Results @{ gemini = @{ ExitCode = -1; Error = 'agy-quota-exhausted' } } -Registry $reg
        @($r) | Should -Contain 'gemini'
        Get-EraFailureCategory -Result @{ ExitCode = -1; Error = 'agy-quota-exhausted' } |
            Should -Be 'not-delivered'
    }

    It 'fires the targeted fallback inside an otherwise usable round' {
        Test-EraStreamFallbackNeeded -StreamInterruptedCount 0 -OpencodeNoOutputCount 0 `
            -QuotaExhaustedCount 1 -UsableCount 2 | Should -BeTrue
        Test-EraStreamFallbackNeeded -StreamInterruptedCount 0 -OpencodeNoOutputCount 0 `
            -QuotaExhaustedCount 0 -UsableCount 2 | Should -BeFalse
    }

    It 'era.ps1 passes the quota count' {
        $era = Get-Content -Raw "$PSScriptRoot/../runtimes/era.ps1"
        $era | Should -Match 'QuotaExhaustedCount'
    }
}
