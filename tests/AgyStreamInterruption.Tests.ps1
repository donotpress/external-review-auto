# Agy model-stream interruption: distinct code + targeted fallback.
#
# MEASURED 2026-09-11 (ebook-pipeline rounds 1-2, tmux-transport round-2):
# agy spawns fine and the prompt reaches the model (USER entry with Run-ID +
# bundle path present), but EVERY MODEL/PLANNER_RESPONSE is empty and each is
# followed by SYSTEM/ERROR_MESSAGE "Error: The stream was interrupted...".
# Both in-adapter attempts die this way; the seat reports generic
# 'stall-or-timeout' and — the round already having usable reviews — no
# fallback fires, so panels silently shrink 3 -> 2 with no recovery path even
# though the gemini-api REST fallback uses a different transport.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/AgyStreamInterruption.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'backends/agy.ps1')
    . (Join-Path $script:SkillRoot 'workflow.ps1')

    # Hermetic quota: these tests exercise stall/evidence behavior, so a real
    # exhausted flag on this machine must not reroute them into the quota
    # fast-fail (see QuotaPreflight.Tests.ps1 for the flag's own tests).
    # Saved and restored around the file.
    $script:SavedQuotaOverride = $env:ERA_IGNORE_QUOTA_FLAG
    $env:ERA_IGNORE_QUOTA_FLAG = '1'

    function New-StreamSession {
        param([string]$BrainRoot, [string]$RunId, [int]$Interruptions = 3, [bool]$HealthyAnswer = $false)
        $dir = Join-Path $BrainRoot ([guid]::NewGuid().ToString())
        $logDir = Join-Path $dir '.system_generated/logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $entries = @(
            @{ source = 'USER_EXPLICIT'; type = 'USER_INPUT'; status = 'DONE'
               created_at = '2026-09-11T07:32:13Z'
               content = "<USER_REQUEST> | [Run ID: $RunId] The review bundle is the file at C:\b\round-1-bundle.xml. Review it." }
        )
        for ($i = 1; $i -le $Interruptions; $i++) {
            # Measured shape: the MODEL entry carries NO content key at all.
            $entries += @{ step_index = $i * 2 - 1; source = 'MODEL'; type = 'PLANNER_RESPONSE'
                           status = 'DONE'; created_at = '2026-09-11T07:32:17Z' }
            $entries += @{ step_index = $i * 2; source = 'SYSTEM'; type = 'ERROR_MESSAGE'
                           status = 'DONE'; created_at = '2026-09-11T07:32:17Z'
                           content = 'Error: The stream was interrupted. Please continue the task you were working on.' }
        }
        if ($HealthyAnswer) {
            $entries += @{ source = 'MODEL'; type = 'PLANNER_RESPONSE'; status = 'DONE'
                           created_at = '2026-09-11T07:32:40Z'; content = '## Findings`n- a real review' }
        }
        $path = Join-Path $logDir 'transcript_full.jsonl'
        $entries | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } | Set-Content -Path $path -Encoding utf8
        return $path
    }

    function New-TestBundle {
        param([int]$Chars = 1000)
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ("era-bundle-" + [guid]::NewGuid() + ".xml")
        ('x' * $Chars) | Set-Content -Path $p -NoNewline -Encoding utf8
        return $p
    }

    $script:MiCheap = @{
        preset = 'gemini'; backend = 'agy'
        agy_model_family = 'gemini-3.8-flash'
        pricing = @{ input_per_m = 1.5; output_per_m = 7.5 }
    }
}

Describe 'Get-AgyStreamInterruption' -Tag Unit {
    It 'detects the measured interruption loop after the Run-ID anchor' {
        $runId = [guid]::NewGuid().ToString()
        $tp = New-StreamSession -BrainRoot (Join-Path $TestDrive 'brain') -RunId $runId -Interruptions 3
        $r = Get-AgyStreamInterruption -BrainRoot (Join-Path $TestDrive 'brain') `
            -PreExistingSessionDirs @{} -DispatchId $runId
        $r.Interrupted | Should -BeTrue
        $r.InterruptionCount | Should -Be 3
        $r.TranscriptPath | Should -Be $tp
    }

    It 'treats empty-string MODEL content the same as a missing content key' {
        $runId = [guid]::NewGuid().ToString()
        $dir = Join-Path (Join-Path $TestDrive 'brain2') ([guid]::NewGuid().ToString())
        $logDir = Join-Path $dir '.system_generated/logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        @(
            @{ source = 'USER_EXPLICIT'; type = 'USER_INPUT'; content = "[Run ID: $runId] review C:\b.xml" }
            @{ source = 'MODEL'; type = 'PLANNER_RESPONSE'; content = '' }
            @{ source = 'SYSTEM'; type = 'ERROR_MESSAGE'; content = 'Error: The stream was interrupted. retry.' }
        ) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } |
            Set-Content -Path (Join-Path $logDir 'transcript_full.jsonl') -Encoding utf8
        $r = Get-AgyStreamInterruption -BrainRoot (Join-Path $TestDrive 'brain2') `
            -PreExistingSessionDirs @{} -DispatchId $runId
        $r.Interrupted | Should -BeTrue
        $r.InterruptionCount | Should -Be 1
    }

    It 'does NOT report interruption when the seat got a real answer' {
        $runId = [guid]::NewGuid().ToString()
        New-StreamSession -BrainRoot (Join-Path $TestDrive 'brain3') -RunId $runId `
            -Interruptions 2 -HealthyAnswer $true
        $r = Get-AgyStreamInterruption -BrainRoot (Join-Path $TestDrive 'brain3') `
            -PreExistingSessionDirs @{} -DispatchId $runId
        # A blip then an answer is a capture the poller would have found, not a dead seat.
        $r.Interrupted | Should -BeFalse
    }

    It 'does NOT match a different dispatch sharing the brain root' {
        New-StreamSession -BrainRoot (Join-Path $TestDrive 'brain4') -RunId ([guid]::NewGuid().ToString()) -Interruptions 3
        $r = Get-AgyStreamInterruption -BrainRoot (Join-Path $TestDrive 'brain4') `
            -PreExistingSessionDirs @{} -DispatchId ([guid]::NewGuid().ToString())
        $r.Interrupted | Should -BeFalse
        $r.TranscriptPath | Should -BeNullOrEmpty
    }

    It 'returns not-interrupted when the brain root has no sessions' {
        $r = Get-AgyStreamInterruption -BrainRoot (Join-Path $TestDrive 'empty') `
            -PreExistingSessionDirs @{} -DispatchId ([guid]::NewGuid().ToString())
        $r.Interrupted | Should -BeFalse
        $r.InterruptionCount | Should -Be 0
    }
}

Describe 'Invoke-AgyReview maps the interruption to its own code' -Tag Unit {
    It 'reports agy-stream-interrupted when the stall throw carries stream evidence' {
        Mock _SpawnAndCaptureOnce {
            throw 'agy stalled -- no transcript activity for 99s after initial response began. [agy-stream-evidence interruptions=14 transcript=C:\u\.gemini\antigravity-cli\brain\s\.system_generated\logs\transcript_full.jsonl]'
        }
        $b = New-TestBundle
        $resp = Join-Path ([System.IO.Path]::GetTempPath()) ("era-resp-" + [guid]::NewGuid() + ".md")
        try {
            $r = Invoke-AgyReview -BundlePath $b -PromptPath $b -ResponsePath $resp `
                -ModelInfo $script:MiCheap -TimeoutSec 60
            $r.Error | Should -Be 'agy-stream-interrupted'
            $r.RetryReason | Should -Be 'agy-stream-interrupted'
            $r.ExitCode | Should -Be -1
            @($r.Warnings) -join ' ' | Should -Match 'interrupted 14 time'
            @($r.Warnings) -join ' ' | Should -Match 'transcript_full\.jsonl'
        } finally { Remove-Item -LiteralPath $b -ErrorAction SilentlyContinue }
    }

    It 'reports agy-stream-interrupted on an exit-with-empty capture backed by evidence' {
        Mock _SpawnAndCaptureOnce {
            @{ Response = $null; ExitCode = -1; Strategy = $null; Stderr = ''; WallClockSec = 1.0
               StreamEvidence = @{ Interrupted = $true; InterruptionCount = 5
                                   TranscriptPath = 'C:\u\brain\t\transcript_full.jsonl' } }
        }
        $b = New-TestBundle
        $resp = Join-Path ([System.IO.Path]::GetTempPath()) ("era-resp-" + [guid]::NewGuid() + ".md")
        try {
            $r = Invoke-AgyReview -BundlePath $b -PromptPath $b -ResponsePath $resp `
                -ModelInfo $script:MiCheap -TimeoutSec 60
            $r.Error | Should -Be 'agy-stream-interrupted'
        } finally { Remove-Item -LiteralPath $b -ErrorAction SilentlyContinue }
    }

    It 'keeps stall-or-timeout when the stall carries no stream evidence (Tier-1 fast crash)' {
        Mock _SpawnAndCaptureOnce {
            throw 'agy showed no transcript activity within 90s -- likely failed to start (bad auth, wrong model, or crash). stderr: boom'
        }
        $b = New-TestBundle
        $resp = Join-Path ([System.IO.Path]::GetTempPath()) ("era-resp-" + [guid]::NewGuid() + ".md")
        try {
            $r = Invoke-AgyReview -BundlePath $b -PromptPath $b -ResponsePath $resp `
                -ModelInfo $script:MiCheap -TimeoutSec 60
            $r.Error | Should -Be 'stall-or-timeout'
        } finally { Remove-Item -LiteralPath $b -ErrorAction SilentlyContinue }
    }
}

Describe 'agy no-start evidence (Tier-1 skeleton check)' -Tag Unit {
    It 'counts candidate session dirs even when nothing answers' {
        $runId = [guid]::NewGuid().ToString()
        New-StreamSession -BrainRoot (Join-Path $TestDrive 'brain-ns') -RunId ([guid]::NewGuid().ToString()) -Interruptions 1
        $r = Get-AgyStreamInterruption -BrainRoot (Join-Path $TestDrive 'brain-ns') `
            -PreExistingSessionDirs @{} -DispatchId $runId
        $r.Interrupted | Should -BeFalse
        $r.SessionDirsSeen | Should -Be 1
    }

    It 'reports zero session dirs for an empty brain root' {
        $r = Get-AgyStreamInterruption -BrainRoot (Join-Path $TestDrive 'brain-empty') `
            -PreExistingSessionDirs @{} -DispatchId ([guid]::NewGuid().ToString())
        $r.SessionDirsSeen | Should -Be 0
    }

    It 'names skeleton sessions in the stall warning (process started, nothing logged)' {
        Mock _SpawnAndCaptureOnce {
            throw 'agy showed no transcript activity within 99s -- likely failed to start (bad auth, wrong model, or crash). stderr:  [agy-no-start sessions=2]'
        }
        $b = New-TestBundle
        $resp = Join-Path ([System.IO.Path]::GetTempPath()) ("era-resp-" + [guid]::NewGuid() + ".md")
        try {
            $r = Invoke-AgyReview -BundlePath $b -PromptPath $b -ResponsePath $resp `
                -ModelInfo $script:MiCheap -TimeoutSec 60
            $r.Error | Should -Be 'stall-or-timeout'
            @($r.Warnings) -join ' ' | Should -Match 'skeleton'
        } finally { Remove-Item -LiteralPath $b -ErrorAction SilentlyContinue }
    }

    It 'names a clean no-start when agy created nothing (auth/crash before first write)' {
        Mock _SpawnAndCaptureOnce {
            throw 'agy showed no transcript activity within 99s -- likely failed to start (bad auth, wrong model, or crash). stderr:  [agy-no-start sessions=0]'
        }
        $b = New-TestBundle
        $resp = Join-Path ([System.IO.Path]::GetTempPath()) ("era-resp-" + [guid]::NewGuid() + ".md")
        try {
            $r = Invoke-AgyReview -BundlePath $b -PromptPath $b -ResponsePath $resp `
                -ModelInfo $script:MiCheap -TimeoutSec 60
            $r.Error | Should -Be 'stall-or-timeout'
            @($r.Warnings) -join ' ' | Should -Match 'no agy session was created'
        } finally { Remove-Item -LiteralPath $b -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-EraRecoverableFailures pins the new code recoverable' -Tag Unit {
    BeforeAll {
        $script:Reg = @{ gemini = @{ backend = 'agy' }; 'gemini-api' = @{ backend = 'geminiapi' } }
    }
    It 'recovers an agy-stream-interrupted seat (agy branch, any error string)' {
        $r = Get-EraRecoverableFailures -ReviewerList @('gemini') `
            -Results @{ gemini = @{ ExitCode = -1; Error = 'agy-stream-interrupted' } } -Registry $script:Reg
        @($r) | Should -Contain 'gemini'
    }
}

Describe 'era.ps1 consults the dead-transport gate without adding a dispatch' -Tag Unit {
    It 'references Test-EraDeadTransportFallback and still dispatches at most once' {
        $era = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1')
        $era | Should -Match 'Test-EraDeadTransportFallback'
        ([regex]::Matches($era, '=\s*Invoke-ReviewerDispatch')).Count | Should -Be 2
    }
}

AfterAll {
    if ($null -eq $script:SavedQuotaOverride) { Remove-Item Env:ERA_IGNORE_QUOTA_FLAG -ErrorAction SilentlyContinue }
    else { $env:ERA_IGNORE_QUOTA_FLAG = $script:SavedQuotaOverride }
}
