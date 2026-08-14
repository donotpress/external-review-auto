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
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'
    $script:SkillMd   = Join-Path $script:SkillRoot 'SKILL.md'
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

Describe 'Test-EraReviewerArtifact — what counts as a readable answer' -Tag Unit {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-art-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }
    AfterEach { Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'counts the suffixed per-preset file on a panel' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-2-opus-response.md') -Value 'x'
        Test-EraReviewerArtifact -ReviewDir $script:Dir -Round 2 -Preset 'opus' -ReviewerCount 3 | Should -BeTrue
    }

    It 'counts the unsuffixed file for a genuine solo dispatch' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-2-response.md') -Value 'x'
        Test-EraReviewerArtifact -ReviewDir $script:Dir -Round 2 -Preset 'opus' -ReviewerCount 1 | Should -BeTrue
    }

    It 'does NOT count the unsuffixed file once a second reviewer exists' {
        # It belongs to whoever was promoted, not to this preset.
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-2-response.md') -Value 'x'
        Test-EraReviewerArtifact -ReviewDir $script:Dir -Round 2 -Preset 'opus' -ReviewerCount 2 | Should -BeFalse
    }

    It 'does NOT count a demoted *.rejected.md — the glob deliberately cannot read it' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-2-opus-response.rejected.md') -Value 'x'
        Test-EraReviewerArtifact -ReviewDir $script:Dir -Round 2 -Preset 'opus' -ReviewerCount 3 | Should -BeFalse
    }

    It 'is false when nothing was written at all' {
        Test-EraReviewerArtifact -ReviewDir $script:Dir -Round 2 -Preset 'opus' -ReviewerCount 3 | Should -BeFalse
    }
}

Describe 'Get-EraVoidRoundReport — did this round produce ANY usable review?' -Tag Unit {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-vr-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }
    AfterEach { Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'is NOT void when one reviewer of three produced a readable answer' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-1-gemini-response.md') -Value "## Issues`n- real"
        $results = @{
            gemini = @{ ExitCode = 0;  Response = 'ok'; ContentOk = $true }
            opus   = @{ ExitCode = -1; Response = $null; Error = 'budget-exceeded' }
            'gemini-pro-high' = @{ ExitCode = -1; Response = 'echo'; ContentOk = $true }
        }
        $rep = Get-EraVoidRoundReport -ReviewDir $script:Dir -Round 1 -Results $results -RequestedCount 3
        $rep.IsVoid      | Should -BeFalse
        $rep.UsableCount | Should -Be 1
    }

    It 'is VOID for the measured 2026-08-09 panel, and names all three reviewers' {
        # (a) opus: budget exceeded, no response file.
        # (b) deepseek-flash: opencode run failed, no response file.
        # (c) gemini-pro-high: truncated, answer demoted to *.rejected.md,
        #     adapter still reported ContentOk=$true with no Error.
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-1-gemini-pro-high-response.rejected.md') -Value 'the prompt, echoed back'
        $results = @{
            opus              = @{ ExitCode = -1; Response = $null; Error = 'budget-exceeded'; Warnings = @() }
            'deepseek-flash'  = @{ ExitCode = -1; Response = $null; ContentOk = $false; Error = 'opencode-run-failed'; Warnings = @() }
            'gemini-pro-high' = @{ ExitCode = -1; Response = 'the prompt, echoed back'; ContentOk = $true
                                   TruncationWarning = 'hit maxOutputTokens=8192'; Warnings = @('hit maxOutputTokens=8192') }
        }
        $rep = Get-EraVoidRoundReport -ReviewDir $script:Dir -Round 1 -Results $results -RequestedCount 3
        $rep.IsVoid      | Should -BeTrue
        $rep.UsableCount | Should -Be 0
        $joined = ($rep.Lines -join "`n")
        $joined | Should -Match 'opus'
        $joined | Should -Match 'deepseek-flash'
        $joined | Should -Match 'gemini-pro-high'
    }

    It 'is VOID for case (c) ALONE — the single-reviewer silent success' {
        # This is the whole point: one reviewer, adapter says ContentOk=true,
        # error=null, and there is no readable review anywhere.
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-1-gemini-pro-high-response.rejected.md') -Value 'the prompt, echoed back'
        $results = @{ 'gemini-pro-high' = @{ ExitCode = -1; Response = 'the prompt, echoed back'; ContentOk = $true; Warnings = @() } }
        $rep = Get-EraVoidRoundReport -ReviewDir $script:Dir -Round 1 -Results $results -RequestedCount 1
        $rep.IsVoid | Should -BeTrue
    }

    It 'names the demoted file so the evidence is findable' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-1-gemini-pro-high-response.rejected.md') -Value 'echo'
        $results = @{ 'gemini-pro-high' = @{ ExitCode = -1; Response = 'echo'; ContentOk = $true; Warnings = @() } }
        $rep = Get-EraVoidRoundReport -ReviewDir $script:Dir -Round 1 -Results $results -RequestedCount 1
        ($rep.Lines -join "`n") | Should -Match 'round-1-gemini-pro-high-response\.rejected\.md'
    }

    It 'reports the exit code and the failure reason per reviewer' {
        $results = @{ opus = @{ ExitCode = -1; Response = $null; Error = 'budget-exceeded'; Warnings = @() } }
        $rep = Get-EraVoidRoundReport -ReviewDir $script:Dir -Round 1 -Results $results -RequestedCount 1
        $joined = ($rep.Lines -join "`n")
        $joined | Should -Match 'exit=-1'
        $joined | Should -Match 'budget-exceeded'
    }

    It 'treats "every reviewer dropped at the cost prompt" as void, and says nothing was spent' {
        $rep = Get-EraVoidRoundReport -ReviewDir $script:Dir -Round 1 -Results @{} -RequestedCount 2
        $rep.IsVoid | Should -BeTrue
        $joined = ($rep.Lines -join "`n")
        $joined | Should -Match '0 of 2'
        $joined | Should -Match 'nothing was spent'
    }

    It 'a clean solo round is not void' {
        Set-Content -LiteralPath (Join-Path $script:Dir 'round-1-response.md') -Value "## Issues`n- real"
        $results = @{ gemini = @{ ExitCode = 0; Response = 'ok'; ContentOk = $true } }
        $rep = Get-EraVoidRoundReport -ReviewDir $script:Dir -Round 1 -Results $results -RequestedCount 1
        $rep.IsVoid | Should -BeFalse
    }
}

Describe 'era.ps1 exits 2 on a void round' -Tag Unit {
    BeforeAll { $script:EraSrc = Get-Content -Raw $script:EraPath }

    It 'consults Get-EraVoidRoundReport and exits 2' {
        $script:EraSrc | Should -Match 'Get-EraVoidRoundReport'
        $script:EraSrc | Should -Match '(?m)^\s*exit 2\s*$'
    }

    It 'runs the post-dispatch gate AFTER Write-ReviewMetadata, so artifacts and telemetry survive' {
        # SUPERSEDED 2026-08-10: this used IndexOf (FIRST occurrence) when there
        # was only one call site. There are now two on purpose -- a guard before
        # the dispatcher (an empty approved list cannot bind to its Mandatory
        # parameter) and the gate after the metadata writer. Anchor on both
        # rather than on "the first one".
        # SUPERSEDED again 2026-08-14: this asserted the COUNT of call sites
        # (2), and broke when a third legitimate one was added -- the fallback
        # now asks the same report for UsableCount before deciding to spend.
        # Pin the POSITIONS, which is the actual invariant, so a fourth honest
        # caller does not fail the suite.
        $metaIdx  = $script:EraSrc.IndexOf('Write-ReviewMetadata -ReviewDir')
        $dispatch = $script:EraSrc.IndexOf('$results = Invoke-ReviewerDispatch')
        $calls    = [regex]::Matches($script:EraSrc, 'Get-EraVoidRoundReport -ReviewDir')
        $metaIdx  | Should -BeGreaterThan 0
        $calls.Count | Should -BeGreaterOrEqual 2
        $calls[0].Index | Should -BeLessThan $dispatch -Because 'the guard must pre-empt the empty-array binding error'
        $calls[$calls.Count - 1].Index | Should -BeGreaterThan $metaIdx -Because 'the telemetry must survive the non-zero exit'
    }

    It 'no exit-2 path sets $runSucceeded first, so every failed run leaves its repomix receipt' {
        foreach ($m in [regex]::Matches($script:EraSrc, 'Get-EraVoidRoundReport -ReviewDir')) {
            $exitIdx = $script:EraSrc.IndexOf('exit 2', $m.Index)
            $exitIdx | Should -BeGreaterThan $m.Index
            $script:EraSrc.Substring($m.Index, $exitIdx - $m.Index) |
                Should -Not -Match '\$runSucceeded\s*=\s*\$true'
        }
        # And it starts falsy, so the receipt survives a throw too.
        $script:EraSrc | Should -Match '(?m)^\$runSucceeded = \$false'
    }

    It 'every exit 2 is a void-round exit, and exit 1 stays preflight-only' {
        # The distinctness that makes code 2 worth having: 1 = nothing happened
        # and re-running is free; 2 = you got no review.
        #
        # SUPERSEDED 2026-08-10: this used to assert "exactly one exit 2", which
        # pinned the COUNT rather than the MEANING and broke the moment a second
        # legitimate void path was added. Assert the meaning instead -- every
        # exit 2 must be reached through the void-round report.
        $script:EraSrc | Should -Match '(?s)function Stop-EraWithError.*?exit 1'
        $exits = [regex]::Matches($script:EraSrc, '(?m)^\s*exit 2\s*$')
        $exits.Count | Should -BeGreaterThan 0
        foreach ($m in $exits) {
            $start = [Math]::Max(0, $m.Index - 900)
            $script:EraSrc.Substring($start, $m.Index - $start) |
                Should -Match 'produced no usable review'
        }
    }

    It 'SKILL.md documents the exit codes so the driving LLM can tell them apart' {
        $md = Get-Content -Raw $script:SkillMd
        $md | Should -Match '(?m)exit\s*(code\s*)?2'
        $md | Should -Match 'no usable review'
    }
}

Describe 'the "everyone dropped at the cost prompt" void path is actually reachable' -Tag Unit {
    # Get-EraVoidRoundReport has an empty-Results branch that reports
    # "0 of N reviewer(s) were approved at the cost prompt." It was DEAD CODE:
    # Invoke-ReviewerDispatch declares [Parameter(Mandatory)][string[]]$ReviewerList,
    # and PowerShell refuses to bind an empty array to a Mandatory parameter. So
    # dropping every reviewer threw a raw binding error at era.ps1:1562 --
    # upstream of the gate at :1728 -- and the user got a PowerShell stack and
    # exit 1 instead of the honest message and exit 2.
    #
    # Flagged as still-open across several rounds of the graded panel
    # ("[LOW - still open, unchanged] empty $approvedList after cost prompts").
    # It only became load-bearing when the void-round gate started promising a
    # specific message for exactly this case.

    BeforeAll {
        $script:VrEra = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtimes/era.ps1')
    }

    It 'Invoke-ReviewerDispatch genuinely cannot take an empty list — this is WHY the guard must be upstream' {
        {
            Invoke-ReviewerDispatch -ReviewerList @() -Registry @{} -BundlePath 'b' `
                -PromptPath 'p' -ReviewDir 'd' -Round 1
        } | Should -Throw '*empty array*'
    }

    It 'era.ps1 guards the empty approved list BEFORE it reaches the dispatcher' {
        $guard    = $script:VrEra.IndexOf('@($approvedList).Count -eq 0')
        $dispatch = $script:VrEra.IndexOf('$results = Invoke-ReviewerDispatch')
        $guard    | Should -BeGreaterThan 0 -Because 'without a guard the dispatcher throws a raw binding error'
        $dispatch | Should -BeGreaterThan 0
        $guard    | Should -BeLessThan $dispatch
    }

    It 'and exits 2 from that guard, not 1' {
        # Two exit-2 sites now: the empty-approved guard and the post-metadata
        # void gate. Both must be exit 2 so a caller cannot tell a spent round
        # from an unspent one by accident.
        # SUPERSEDED 2026-08-14 (round-7 opus, finding 8): this pinned the COUNT
        # to exactly 2, which breaks the moment a legitimate third void-round
        # exit appears -- the same brittleness already corrected for the
        # Get-EraVoidRoundReport call sites above, and for the same reason.
        # What matters is that at least the two known sites exist and sit where
        # they belong (asserted below); that no exit-2 path sets $runSucceeded
        # first, and that every exit 2 is a void-round exit, are both pinned by
        # their own tests.
        ([regex]::Matches($script:VrEra, '(?m)^\s*exit 2\s*$')).Count | Should -BeGreaterOrEqual 2
        $guard = $script:VrEra.IndexOf('@($approvedList).Count -eq 0')
        $exit  = $script:VrEra.IndexOf('exit 2', $guard)
        $next  = $script:VrEra.IndexOf('$results = Invoke-ReviewerDispatch')
        $exit  | Should -BeGreaterThan $guard
        $exit  | Should -BeLessThan $next
    }

    It 'reuses Get-EraVoidRoundReport so the message and the exit code cannot drift apart' {
        $guard  = $script:VrEra.IndexOf('@($approvedList).Count -eq 0')
        $report = $script:VrEra.IndexOf('Get-EraVoidRoundReport', $guard)
        $next   = $script:VrEra.IndexOf('$results = Invoke-ReviewerDispatch')
        $report | Should -BeGreaterThan $guard
        $report | Should -BeLessThan $next
    }
}
