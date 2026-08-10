# Void-round tests: a round that produced NO usable review must not report
# success anywhere.
#
# Reported from a live 3-model panel run (2026-08-09), all three reviewers void:
#   a. opus (claude CLI) exceeded its slice of the budget -> no response file,
#      content_ok=false. Honest telemetry; era still exited 0.
#   b. deepseek-flash (opencode) failed after reading the bundle -> no response
#      file, content_ok=false. Honest telemetry; era still exited 0.
#   c. gemini-pro-high truncated at its output cap and wrote
#      round-1-gemini-pro-high-response.rejected.md containing the PROMPT ECHOED
#      BACK -- with content_ok=TRUE, error=null, and no round-1-response.md.
#
# (c) is the silent-success case and it is fully explained by the code:
#
#   backends/agy.ps1:706-721  the clean-capture return sets ContentOk=$true
#                             UNCONDITIONALLY but passes the agy PROCESS exit
#                             code straight through ($finalResult.ExitCode).
#                             _SpawnAndCaptureOnce reads the answer from the
#                             transcript, independent of process exit, and sets
#                             ExitCode=-1 whenever the process had to be killed
#                             at the hard deadline (agy.ps1:462). So a capture
#                             that reads fine but whose process was killed
#                             returns ExitCode=-1 WITH ContentOk=$true and NO
#                             Error key.
#   workflow.ps1:1517         content_ok was read straight off ContentOk when
#                             present, so it reported that $true.
#   workflow.ps1:1432-1443    Copy-PrimaryResponseAlias demotes on ExitCode, so
#                             the same reviewer's file became *.rejected.md and
#                             no round-N-response.md was ever promoted.
#
# Net: metadata said the reviewer was fine while the artifact had been rejected.
# A single-reviewer dispatch in that state reads as "reviewed, no findings".
#
# The invariant asserted here: content_ok is TRUE only when that reviewer's
# response artifact is on disk under a name the {{PREVIOUS_ROUND}} glob will
# actually read. Copy-PrimaryResponseAlias runs BEFORE the metadata writer and
# has already renamed every rejected answer to *.rejected.md, so a plain
# Test-Path is exactly the right question to ask.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/VoidRound.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'workflow.ps1')
    $script:Reg = @{
        gemini            = @{ backend = 'agy';      model_id = 'gemini-3.6-flash-high'; pricing = @{ input_per_m = 0.3; output_per_m = 1.2 } }
        'gemini-pro-high' = @{ backend = 'agy';      model_id = 'gemini-3.1-pro-high';   pricing = @{ input_per_m = 1.5; output_per_m = 5.0 } }
        opus              = @{ backend = 'claude';   model_id = 'claude-opus-5';         pricing = @{ input_per_m = 15.0; output_per_m = 75.0 } }
        'gemini-api'      = @{ backend = 'geminiapi'; model_id = 'gemini-2.5-flash';     pricing = @{ input_per_m = 0.3; output_per_m = 1.2 } }
    }

    # A reviewer result shaped exactly like backends/agy.ps1's clean-capture
    # return: ContentOk=$true, no Error key, process ExitCode passed through.
    function script:New-AgyCleanCaptureResult {
        param([int]$ExitCode = 0, [string]$Response = "## Issues`n- a real finding")
        @{
            ExitCode = $ExitCode; Response = $Response
            CaptureMethod = 'polling'; CaptureStrategy = 'run-id-match'
            ContentOk = $true; RetryCount = 0; RetryReason = $null
            OutputTokens = 10; WallClockSec = 42
            TruncationWarning = $null; Warnings = @()
        }
    }

    function script:Get-MetaEntry {
        param([string]$Dir, [int]$Round = 1, [string]$Preset)
        $meta = Get-Content -Raw (Join-Path $Dir "round-$Round-metadata.json") | ConvertFrom-Json
        @($meta.reviewers) | Where-Object { $_.preset -eq $Preset } | Select-Object -First 1
    }
}

Describe 'content_ok is grounded in the artifact, not in the adapter''s say-so' -Tag Unit {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-void-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }
    AfterEach {
        Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'is TRUE for a solo reviewer that exited clean AND left round-N-response.md' {
        # Non-vacuity anchor: the healthy path must keep reporting true.
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-1-response.md') -Value "## Issues`n- a real finding"
        $results = @{ gemini = script:New-AgyCleanCaptureResult }
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $results -Registry $script:Reg -BundleTokens 1000
        (script:Get-MetaEntry -Dir $script:Dir -Preset 'gemini').content_ok | Should -BeTrue
    }

    It 'is FALSE when the adapter says ContentOk=true but the process exit was non-zero (the measured case c)' {
        # agy killed at the hard deadline after a readable transcript capture.
        # Copy-PrimaryResponseAlias has already demoted the answer, so nothing is
        # on disk under a readable name.
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-1-gemini-pro-high-response.rejected.md') `
            -Value '<the prompt, echoed back>'
        $results = @{ 'gemini-pro-high' = script:New-AgyCleanCaptureResult -ExitCode -1 -Response '<the prompt, echoed back>' }
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $results -Registry $script:Reg -BundleTokens 1000
        (script:Get-MetaEntry -Dir $script:Dir -Preset 'gemini-pro-high').content_ok | Should -BeFalse
    }

    It 'is FALSE when a REST backend exited 0 but never wrote a response file' {
        # REST adapters never set ContentOk, so content_ok fell back to
        # "the HTTP call worked" rather than "we got a review".
        $results = @{
            'gemini-api' = @{
                ExitCode = 0; Response = 'text that never reached disk'
                CaptureMethod = 'rest-api'; OutputTokens = 5; WallClockSec = 3
                TruncationWarning = $null; Warnings = @()
            }
        }
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $results -Registry $script:Reg -BundleTokens 1000
        (script:Get-MetaEntry -Dir $script:Dir -Preset 'gemini-api').content_ok | Should -BeFalse
    }

    It 'does not count a demoted *.rejected.md as a usable artifact on a panel' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-1-gemini-response.md') -Value "## Issues`n- real"
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-1-opus-response.rejected.md') -Value 'echoed prompt'
        $results = @{
            gemini = script:New-AgyCleanCaptureResult
            opus   = script:New-AgyCleanCaptureResult -ExitCode -1 -Response 'echoed prompt'
        }
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $results -Registry $script:Reg -BundleTokens 1000
        (script:Get-MetaEntry -Dir $script:Dir -Preset 'gemini').content_ok | Should -BeTrue
        (script:Get-MetaEntry -Dir $script:Dir -Preset 'opus').content_ok   | Should -BeFalse
    }

    It 'does not let a failed solo reviewer claim the unsuffixed file its fallback wrote' {
        # Cross-crediting guard for the solo+fallback asymmetry. A solo dispatch
        # writes round-1-response.md with NO preset suffix
        # (Get-ResponseFilenameSuffix, workflow.ps1:730). If that reviewer fails,
        # era re-dispatches to a fallback with -SuffixReviewerList of both
        # presets (era.ps1:1622-1623), so the fallback's file IS suffixed and it
        # becomes the promoted round-1-response.md.
        #
        # The unsuffixed name is therefore ambiguous once $Results has two keys
        # -- and it is never legitimately the solo reviewer's, because a fallback
        # only exists when that reviewer already failed. Fall back to the
        # unsuffixed name for a genuine solo dispatch only.
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-1-gemini-api-response.md') -Value "## Issues`n- real"
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-1-response.md') -Value "## Issues`n- real"
        $results = @{
            gemini       = script:New-AgyCleanCaptureResult -ExitCode -1 -Response 'echoed prompt'
            'gemini-api' = @{ ExitCode = 0; Response = "## Issues`n- real"; CaptureMethod = 'rest-api'
                              OutputTokens = 5; WallClockSec = 3; Warnings = @(); TruncationWarning = $null }
        }
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $results -Registry $script:Reg -BundleTokens 1000
        (script:Get-MetaEntry -Dir $script:Dir -Preset 'gemini').content_ok       | Should -BeFalse
        (script:Get-MetaEntry -Dir $script:Dir -Preset 'gemini-api').content_ok   | Should -BeTrue
    }

    It 'says WHY it downgraded, so the disagreement is not silent' {
        $results = @{ 'gemini-pro-high' = script:New-AgyCleanCaptureResult -ExitCode -1 }
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $results -Registry $script:Reg -BundleTokens 1000
        $e = script:Get-MetaEntry -Dir $script:Dir -Preset 'gemini-pro-high'
        ($e.warnings -join ' ') | Should -Match 'content_ok'
    }

    It 'never reports content_ok=true for a reviewer with no readable artifact, across every shape' {
        # The invariant itself, swept over the result shapes the adapters emit.
        $shapes = @(
            @{ Name = 'agy-clean-capture-killed'; R = @{ ExitCode = -1; ContentOk = $true;  Response = 'x'; Warnings = @() } }
            @{ Name = 'agy-honest-failure';       R = @{ ExitCode = -1; ContentOk = $false; Response = 'x'; Error = 'empty-capture'; Warnings = @() } }
            @{ Name = 'rest-clean-exit';          R = @{ ExitCode = 0;  Response = 'x'; Warnings = @() } }
            @{ Name = 'contract-failure';         R = @{ ExitCode = -1; ContentOk = $false; Response = 'x'; Error = 'response-contract'; Warnings = @() } }
        )
        foreach ($s in $shapes) {
            $d = Join-Path ([System.IO.Path]::GetTempPath()) ("era-void-shape-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            try {
                Write-ReviewMetadata -ReviewDir $d -Round 1 -TopicSlug 't' -Mode 'code' `
                    -Results @{ gemini = $s.R } -Registry $script:Reg -BundleTokens 1000
                $ok = (script:Get-MetaEntry -Dir $d -Preset 'gemini').content_ok
                if ($ok) { throw "shape '$($s.Name)' reported content_ok=true with no artifact on disk" }
            } finally {
                Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
