# Meta-review round-2 adoptions (opus 1-9, muse-spark 1-6 as ranked).
# Each Describe names the proposal; tests fail until its implementation lands.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/MetaReviewRound2.Tests.ps1 -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    . "$PSScriptRoot/../backends/agy.ps1"

    # Hermetic quota: these tests exercise stall/retry/evidence behavior, so
    # a real exhausted flag on this machine must not reroute them into the
    # quota fast-fail (see QuotaPreflight.Tests.ps1 for the flag's own tests).
    # Saved and restored around the file.
    $script:SavedQuotaOverride = $env:ERA_IGNORE_QUOTA_FLAG
    $env:ERA_IGNORE_QUOTA_FLAG = '1'

    function New-BundleFile {
        param([int]$Chars = 1000)
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ("era-bundle-" + [guid]::NewGuid() + ".xml")
        ('x' * $Chars) | Set-Content -Path $p -NoNewline -Encoding utf8
        return $p
    }
}

Describe 'O1: Tier-1 liveness baseline' -Tag Unit {
    It 'returns null when the brain root is missing or empty' {
        Get-AgyTranscriptBaseline -BrainRoot (Join-Path $TestDrive 'nobrain') | Should -BeNullOrEmpty
    }

    It 'returns the newest transcript mtime present before dispatch' {
        $root = Join-Path $TestDrive 'brain-base'
        foreach ($i in 1..2) {
            $logDir = Join-Path $root ("sess$i" + [guid]::NewGuid().ToString())
            $logDir = Join-Path $logDir '.system_generated/logs'
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            @{ source = 'MODEL'; type = 'PLANNER_RESPONSE'; content = "old $i" } |
                ConvertTo-Json -Compress | Set-Content -Path (Join-Path $logDir 'transcript_full.jsonl') -Encoding utf8
        }
        $max = (Get-ChildItem -Path (Join-Path $root '*/.system_generated/logs/transcript_full.jsonl') |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        [datetime](Get-AgyTranscriptBaseline -BrainRoot $root) | Should -Be $max
    }

    It '_SpawnAndCaptureOnce seeds its seen-mtime from the baseline' {
        $src = Get-Content -Raw "$PSScriptRoot/../backends/agy.ps1"
        $src | Should -Match 'Get-AgyTranscriptBaseline'
    }
}

Describe 'O3: attempt wall clock survives the throw' -Tag Unit {
    BeforeAll { . "$PSScriptRoot/../backends/agy.ps1" }

    It 'records burned seconds instead of zero when both attempts stall out' {
        Mock _SpawnAndCaptureOnce {
            Start-Sleep -Milliseconds 1200
            throw 'agy stalled -- no transcript activity for 99s after initial response began.'
        }
        $b = New-BundleFile
        $resp = Join-Path ([System.IO.Path]::GetTempPath()) ("era-resp-" + [guid]::NewGuid() + ".md")
        try {
            $mi = @{ preset = 'gemini'; backend = 'agy'; agy_model_family = 'gemini-3.8-flash'
                     pricing = @{ input_per_m = 1.5; output_per_m = 7.5 } }
            $r = Invoke-AgyReview -BundlePath $b -PromptPath $b -ResponsePath $resp `
                -ModelInfo $mi -TimeoutSec 60
            $r.ExitCode | Should -Be -1
            # Final attempt's wall clock (each mocked attempt sleeps 1.2s):
            # non-zero proves the throw no longer discards the stopwatch.
            [double]$r.WallClockSec | Should -BeGreaterThan 1
        } finally { Remove-Item -LiteralPath $b -ErrorAction SilentlyContinue }
    }
}

Describe 'O4: unsizable bundle names its real cause' -Tag Unit {
    BeforeAll { . "$PSScriptRoot/../backends/agy.ps1" }

    It 'reports empty-capture (not narration) when the bundle cannot be sized' {
        Mock _SpawnAndCaptureOnce {
            @{ Response = $null; ExitCode = -1; Strategy = $null; Stderr = ''; WallClockSec = 1.0
               StreamEvidence = @{ Interrupted = $false; InterruptionCount = 0; TranscriptPath = $null; SessionDirsSeen = 0 } }
        }
        $resp = Join-Path ([System.IO.Path]::GetTempPath()) ("era-resp-" + [guid]::NewGuid() + ".md")
        $mi = @{ preset = 'gemini'; backend = 'agy'; agy_model_family = 'gemini-3.8-flash'
                 pricing = @{ input_per_m = 1.5; output_per_m = 7.5 } }
        $r = Invoke-AgyReview -BundlePath (Join-Path $TestDrive 'does-not-exist.xml') `
            -PromptPath (Join-Path $TestDrive 'does-not-exist.xml') -ResponsePath $resp `
            -ModelInfo $mi -TimeoutSec 60
        $r.Error | Should -Be 'empty-capture'
        $r.RetryReason | Should -Be 'empty-capture'
    }
}

Describe 'O2: agy publishes one deadline sidecar' -Tag Unit {
    It 'has exactly one sidecar write site (single write per dispatch, not per attempt)' {
        $src = Get-Content -Raw "$PSScriptRoot/../backends/agy.ps1"
        ([regex]::Matches($src, '\.deadline')).Count | Should -Be 1
    }

    It 'round-trips a review with a pid file and leaves a future sidecar' {
        . "$PSScriptRoot/../backends/agy.ps1"
        Mock _SpawnAndCaptureOnce {
            @{ Response = '## Findings`n- real review text here'; ExitCode = 0; Strategy = 'run-id-match'
               Stderr = ''; WallClockSec = 1.0
               StreamEvidence = @{ Interrupted = $false; InterruptionCount = 0; TranscriptPath = $null; SessionDirsSeen = 0 } }
        }
        $b = New-BundleFile
        $resp = Join-Path ([System.IO.Path]::GetTempPath()) ("era-resp-" + [guid]::NewGuid() + ".md")
        $pidFile = "$resp.pid"
        try {
            $mi = @{ preset = 'gemini'; backend = 'agy'; agy_model_family = 'gemini-3.8-flash'
                     pricing = @{ input_per_m = 1.5; output_per_m = 7.5 } }
            $before = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $null = Invoke-AgyReview -BundlePath $b -PromptPath $b -ResponsePath $resp `
                -ModelInfo $mi -TimeoutSec 600 -PidFile $pidFile
            $epoch = [long](Get-Content -Raw -LiteralPath "$pidFile.deadline")
            $epoch | Should -BeGreaterThan ($before + 500)
            $epoch | Should -BeLessThan ($before + 700)
        } finally {
            Remove-Item -LiteralPath $b, $pidFile, "$pidFile.deadline" -ErrorAction SilentlyContinue
        }
    }
}

Describe 'MS3: repomix adoption requires a complete tail' -Tag Unit {
    It 'rejects a bundle whose tail lacks the closing marker' {
        $b = Join-Path $TestDrive 'trunc-bundle.xml'
        '<xml><file>half-written content with no closing' | Set-Content -LiteralPath $b -NoNewline -Encoding utf8
        Test-EraRepomixCompleted -PartialOutput 'Packing completed successfully!' `
            -BundlePath $b -SinceUtc ([datetime]::UtcNow.AddMinutes(-1)) | Should -BeFalse
    }

    It 'adopts a bundle whose tail closes properly' {
        $b = Join-Path $TestDrive 'whole-bundle.xml'
        "<xml><file>content</file></files>`n</instruction>" | Set-Content -LiteralPath $b -NoNewline -Encoding utf8
        Test-EraRepomixCompleted -PartialOutput 'Packing completed successfully!' `
            -BundlePath $b -SinceUtc ([datetime]::UtcNow.AddMinutes(-1)) | Should -BeTrue
    }
}

Describe 'O7/MS1: answered codes single-sourced' -Tag Unit {
    It 'exposes one answered-badly set' {
        $codes = Get-EraAnsweredBadlyCodes
        @($codes) | Should -Contain 'response-contract'
        @($codes) | Should -Contain 'agentic-narration-capture'
        @($codes) | Should -Contain 'prompt-echo'
    }

    It 'both classifiers reference the single source' {
        $src = Get-Content -Raw "$PSScriptRoot/../workflow.ps1"
        $src | Should -Match 'Get-EraAnsweredBadlyCodes'
        ([regex]::Matches($src, 'Get-EraAnsweredBadlyCodes')).Count | Should -BeGreaterThan 2
    }

    It 'classifies every answered code as answered-badly (drift-proof)' {
        foreach ($c in Get-EraAnsweredBadlyCodes) {
            Get-EraFailureCategory -Result @{ ExitCode = -1; Error = $c } | Should -Be 'answered-badly'
        }
    }
}

AfterAll {
    if ($null -eq $script:SavedQuotaOverride) { Remove-Item Env:ERA_IGNORE_QUOTA_FLAG -ErrorAction SilentlyContinue }
    else { $env:ERA_IGNORE_QUOTA_FLAG = $script:SavedQuotaOverride }
}
