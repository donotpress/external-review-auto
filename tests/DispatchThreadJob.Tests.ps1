# Invoke-ReviewerDispatch driven with REAL ThreadJobs.
#
# tests/README.md listed this as not covered: "ThreadJobs are hard to mock and
# the integration is exercised by every smoke test." Two of the three failures
# in the 2026-08-09 void round came out of this function -- case (a) was the
# global-timeout collection path -- so "exercised by smoke tests" means
# "exercised by the runs that go wrong".
#
# It does not need mocking. Invoke-ReviewerDispatch already takes
# -SkillRootOverride, and it resolves each adapter as
# <skillRoot>/backends/<backend>.ps1 with function Invoke-<Backend>Review. So a
# temp skill root holding a fake backend drives the REAL dispatcher, the REAL
# Start-ThreadJob, the REAL poll loop and the REAL collection path, with no
# network, no API key and no production code changed.
#
# The fake adapter records every argument it was handed to a JSON file, which is
# how the passthrough assertions below observe what the dispatcher actually sent
# rather than what it looks like it sends.
#
# NOTE ON TIMING: one test here takes ~35s. $budgetSec is hardcoded
# $TimeoutSec + 30, so the global-timeout path cannot be exercised faster than
# 30s. It is the path that produced case (a); it is worth the wall clock. Every
# other test in this file is sub-second.
#
# These are COVERAGE tests over existing behaviour, not TDD-red tests -- they
# passed on first run. Their non-vacuity is demonstrated by mutation in
# docs/assessments/2026-08-10-threadjob-coverage.md.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/DispatchThreadJob.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'workflow.ps1')

    # A fake backend adapter. It mirrors the real adapter signature, records what
    # it was handed, then behaves according to $ModelInfo.behavior.
    #
    # $DeclarePidFile / $DeclareResolvedAgy control whether those params appear in
    # the param block at all -- the dispatcher splats them only when
    # (Get-Command $fn).Parameters says the adapter declares them, so their
    # absence is itself behaviour worth testing.
    function script:New-FakeSkillRoot {
        param(
            [string[]]$Backends = @('fake'),
            [switch]$DeclarePidFile,
            [switch]$DeclareResolvedAgy
        )
        $rootDir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-tj-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $rootDir 'backends') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $rootDir 'record')   -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $rootDir 'review')   -Force | Out-Null

        $pidParam = if ($DeclarePidFile)     { ',[string]$PidFile' }          else { '' }
        $agyParam = if ($DeclareResolvedAgy) { ',[string]$ResolvedAgyModel' } else { '' }
        $agyRec   = if ($DeclareResolvedAgy) { '$rec.resolvedAgyModel = $ResolvedAgyModel' } else { '' }
        $pidRec   = if ($DeclarePidFile)     { '$rec.pidFile = $PidFile' }    else { '' }

        foreach ($b in $Backends) {
            $fn = 'Invoke-' + ((Get-Culture).TextInfo.ToTitleCase($b)) + 'Review'
            $body = @"
function $fn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]`$BundlePath,
        [Parameter(Mandatory)][string]`$PromptPath,
        [Parameter(Mandatory)][string]`$ResponsePath,
        [Parameter(Mandatory)][hashtable]`$ModelInfo,
        [int]`$TimeoutSec = 600,
        [string]`$AgyModelHint,
        [string]`$ModelOverride,
        [string]`$OpencodeProvider$pidParam$agyParam
    )
    `$rec = @{
        preset        = `$ModelInfo.preset
        timeoutSec    = `$TimeoutSec
        agyHint       = `$AgyModelHint
        modelOverride = `$ModelOverride
        provider      = `$OpencodeProvider
        modelId       = `$ModelInfo.model_id
        responsePath  = `$ResponsePath
        bundlePath    = `$BundlePath
        declaredPid   = [bool]('$pidParam' -ne '')
    }
    $agyRec
    $pidRec
    (`$rec | ConvertTo-Json -Compress) |
        Set-Content -LiteralPath (Join-Path `$ModelInfo.record_dir "`$(`$ModelInfo.preset).json") -Encoding utf8

    switch (`$ModelInfo.behavior) {
        'throw'    { throw 'fake adapter exploded: ' + `$ModelInfo.preset }
        'slowthrow' { Start-Sleep -Seconds 2; throw 'fake adapter exploded after working: ' + `$ModelInfo.preset }
        'bigthrow' {
            # An adapter whose exception carries its whole agentic transcript.
            # opencode does exactly this: round-7's deepseek-flash threw a
            # 47,301-char message and it landed verbatim in the metadata.
            throw ('fake adapter exploded: ' + `$ModelInfo.preset + ' :: ' + ('TRANSCRIPT-LINE ' * 4000) + ' :: TAIL-MARKER-AT-THE-END')
        }
        'noise'    { Write-Output 'stray debug output from a dot-sourced module'; Write-Output 42 }
        'nostruct' { Write-Output 'a bare string and nothing structured'; return }
        'trailing' {
            Write-Output @{
                ExitCode = 0; Response = 'real result'; ContentOk = `$true
                CaptureMethod = 'fake'; WallClockSec = 0; OutputTokens = 5
                Warnings = @(); TruncationWarning = `$null
            }
            Write-Output 'trailing chatter emitted AFTER the result'
            return
        }
        'hang'     { Start-Sleep -Seconds 900 }
        'child'    {
            # Spawn a real, long-lived child and record its PID the way the
            # native adapters do, so the straggler path has something to kill.
            `$p = Start-Process -FilePath (Get-Process -Id `$PID).Path ``
                    -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 900' ``
                    -PassThru -WindowStyle Hidden
            if (`$PidFile) { "`$(`$p.Id)" | Set-Content -LiteralPath `$PidFile -Encoding ascii }
            # Block until the child dies -- exactly what a real adapter does.
            `$p.WaitForExit()
            # Its child was tree-killed out from under it, so it failed. Return
            # an honest failure and write NO response file, like the real ones.
            return @{
                ExitCode = -1; Response = `$null; Error = 'stall-or-timeout'
                ContentOk = `$false; CaptureMethod = 'fake'; WallClockSec = 0
                OutputTokens = 0; Warnings = @('child was killed'); TruncationWarning = `$null
            }
        }
    }
    "## Issues``n- fake finding from `$(`$ModelInfo.preset)" | Set-Content -LiteralPath `$ResponsePath -Encoding utf8
    return @{
        ExitCode = 0; Response = "## Issues``n- fake finding from `$(`$ModelInfo.preset)"
        ContentOk = `$true; CaptureMethod = 'fake'; WallClockSec = 0
        OutputTokens = 5; Warnings = @(); TruncationWarning = `$null
    }
}
"@
            Set-Content -LiteralPath (Join-Path $rootDir "backends/$b.ps1") -Value $body -Encoding utf8
        }
        return $rootDir
    }

    function script:New-FakeRegistry {
        param([hashtable]$Presets, [string]$RecordDir)
        $reg = @{}
        foreach ($k in $Presets.Keys) {
            $p = $Presets[$k]
            $reg[$k] = @{
                backend    = $p.backend
                model_id   = if ($p.model_id) { $p.model_id } else { "model-$k" }
                behavior   = $p.behavior
                record_dir = $RecordDir
                pricing    = @{ input_per_m = 1.0; output_per_m = 1.0 }
                agy_model_family = $p.agy_model_family
                agy_model_tier   = $p.agy_model_tier
            }
        }
        return $reg
    }

    function script:Get-Record {
        param([string]$RootDir, [string]$Preset)
        $f = Join-Path $RootDir "record/$Preset.json"
        if (-not (Test-Path -LiteralPath $f)) { return $null }
        Get-Content -Raw -LiteralPath $f | ConvertFrom-Json
    }

    function script:Invoke-FakeDispatch {
        param(
            [string]$RootDir,
            [hashtable]$Registry,
            [string[]]$ReviewerList,
            [string[]]$SuffixReviewerList,
            [int]$TimeoutSec = 600,
            [int]$BundleTokens = 0,
            [hashtable]$ModelOverrides = @{},
            [hashtable]$ProviderOverrides = @{},
            [hashtable]$AgyModelMap = @{},
            [string]$ResolvedAgyModel
        )
        $bundle = Join-Path $RootDir 'bundle.xml'; 'BUNDLE' | Set-Content -LiteralPath $bundle
        $prompt = Join-Path $RootDir 'prompt.md'; 'PROMPT' | Set-Content -LiteralPath $prompt
        $splat = @{
            ReviewerList = $ReviewerList; Registry = $Registry
            BundlePath = $bundle; PromptPath = $prompt
            ReviewDir = (Join-Path $RootDir 'review'); Round = 1
            TimeoutSec = $TimeoutSec; BundleTokens = $BundleTokens
            SkillRootOverride = $RootDir
            ModelOverrides = $ModelOverrides; ProviderOverrides = $ProviderOverrides
            AgyModelMap = $AgyModelMap
        }
        if ($SuffixReviewerList) { $splat.SuffixReviewerList = $SuffixReviewerList }
        if ($ResolvedAgyModel)   { $splat.ResolvedAgyModel   = $ResolvedAgyModel }
        Invoke-ReviewerDispatch @splat
    }
}

Describe 'Invoke-ReviewerDispatch — the happy path, through real ThreadJobs' -Tag Unit {
    BeforeAll {
        $script:D1 = script:New-FakeSkillRoot
        $script:R1 = script:New-FakeRegistry -RecordDir (Join-Path $script:D1 'record') -Presets @{
            alpha = @{ backend = 'fake' }
            beta  = @{ backend = 'fake' }
        }
        $script:Res1 = script:Invoke-FakeDispatch -RootDir $script:D1 -Registry $script:R1 -ReviewerList @('alpha','beta')
    }
    AfterAll { Remove-Item $script:D1 -Recurse -Force -ErrorAction SilentlyContinue }

    It 'returns one result per reviewer, keyed by preset' {
        $script:Res1.Keys.Count | Should -Be 2
        $script:Res1['alpha'].ExitCode | Should -Be 0
        $script:Res1['beta'].ExitCode  | Should -Be 0
    }

    It 'stamps Preset onto each adapter result' {
        # Downstream keys everything off this; the adapters do not set it.
        $script:Res1['alpha'].Preset | Should -Be 'alpha'
        $script:Res1['beta'].Preset  | Should -Be 'beta'
    }

    It 'carries the adapter hashtable through Receive-Job intact' {
        $script:Res1['alpha'].ContentOk      | Should -BeTrue
        $script:Res1['alpha'].CaptureMethod  | Should -Be 'fake'
        $script:Res1['alpha'].Response       | Should -Match 'fake finding from alpha'
    }

    It 'gives each reviewer its own suffixed response path on a panel' {
        (script:Get-Record -RootDir $script:D1 -Preset 'alpha').responsePath | Should -Match 'round-1-alpha-response\.md$'
        (script:Get-Record -RootDir $script:D1 -Preset 'beta').responsePath  | Should -Match 'round-1-beta-response\.md$'
    }

    It 'actually ran them as jobs and cleaned every one up' {
        @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'review-*' }).Count |
            Should -Be 0 -Because 'Remove-Job runs in the finally for every dispatched reviewer'
    }
}

Describe 'Invoke-ReviewerDispatch — response filename suffix' -Tag Unit {
    It 'a solo reviewer writes the unsuffixed round-N-response.md' {
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{ solo = @{ backend = 'fake' } }
            $null = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('solo')
            (script:Get-Record -RootDir $d -Preset 'solo').responsePath | Should -Match 'round-1-response\.md$'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'SuffixReviewerList makes a solo fallback dispatch write a SUFFIXED file' {
        # The agy-fallback re-dispatch passes the combined list precisely so the
        # fallback's answer cannot clobber the panel's round-N-response.md.
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{ fb = @{ backend = 'fake' } }
            $null = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('fb') `
                -SuffixReviewerList @('alpha','beta','fb')
            (script:Get-Record -RootDir $d -Preset 'fb').responsePath | Should -Match 'round-1-fb-response\.md$'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-ReviewerDispatch — an adapter that misbehaves cannot kill the round' -Tag Unit {
    It 'turns an adapter exception into a structured failure, not a dead job' {
        # "Bug 2 fix" in the source: without this the dispatcher synthesised
        # empty metadata and the real cause vanished.
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{
                boom = @{ backend = 'fake'; behavior = 'throw' }
                fine = @{ backend = 'fake' }
            }
            $res = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('boom','fine')
            $res['boom'].ExitCode      | Should -Be -1
            $res['boom'].Error         | Should -Match 'fake adapter exploded'
            $res['boom'].CaptureMethod | Should -Be 'error'
            ($res['boom'].Warnings -join ' ') | Should -Match 'Adapter exception'
            # ...and it must not take the healthy reviewer down with it.
            $res['fine'].ExitCode | Should -Be 0
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Both of the following come from round 7's deepseek-flash, which failed
    # after doing real work -- it had read the bundle, run git, dot-sourced
    # workflow.ps1 and executed Test-EraPathIgnored probes -- and the record it
    # left was actively misleading:
    #
    #   wall_clock_sec   0        for a reviewer that ran for minutes
    #   error            47,301 chars, the entire agentic transcript
    #   metadata file    109,979 bytes, vs 4,219 for round 6 -- 26x
    #
    # One Error field was 43% of the round's provenance record, and the same
    # 47 KB was stored THREE times (Error, Warnings, Stderr).

    It 'records the time an adapter actually spent before throwing, not zero' {
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{
                slow = @{ backend = 'fake'; behavior = 'slowthrow' }
            }
            $res = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('slow')
            $res['slow'].ExitCode | Should -Be -1
            $res['slow'].WallClockSec | Should -BeGreaterThan 1 `
                -Because 'a reviewer that burned two seconds must not report zero; cost and latency accounting read this'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'bounds a huge adapter exception instead of inlining it into the round record' {
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{
                big = @{ backend = 'fake'; behavior = 'bigthrow' }
            }
            $res = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('big')
            $r = $res['big']
            $r.ExitCode | Should -Be -1
            # Still identifiable...
            $r.Error | Should -Match 'fake adapter exploded'
            # ...but bounded. The raw message here is >64,000 chars.
            $r.Error.Length | Should -BeLessThan 2000 `
                -Because 'the round manifest is a provenance record, not a transcript store'
            ($r.Warnings -join ' ').Length | Should -BeLessThan 2000
            "$($r.Stderr)".Length | Should -BeLessThan 2000 `
                -Because 'storing the same transcript a third time is how one failure became 43% of the file'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps the WHOLE exception on disk, including its tail, and says where' {
        # Truncating without preserving would be worse than the bloat: the TAIL
        # is where the failure is. Diagnosing round 7 needed the last 1,800
        # chars, not the first.
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{
                big = @{ backend = 'fake'; behavior = 'bigthrow' }
            }
            $res = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('big')
            $logs = @(Get-ChildItem -LiteralPath (Join-Path $d 'review') -Filter '*-error.log' -File -ErrorAction SilentlyContinue)
            $logs.Count | Should -BeGreaterThan 0 -Because 'the full text must survive somewhere'
            $body = Get-Content -Raw -LiteralPath $logs[0].FullName
            $body.Length | Should -BeGreaterThan 20000 -Because 'the log is the UNtruncated copy'
            $body | Should -Match 'TAIL-MARKER-AT-THE-END' -Because 'the tail is the diagnostic half'
            # And the record must point at it, or nobody will find it.
            ($res['big'].Warnings -join ' ') | Should -Match '-error\.log'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'ignores stray Write-Output noise and keeps the structured result' {
        # A dot-sourced module that prints lands in the job success stream
        # alongside the real return value.
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{ noisy = @{ backend = 'fake'; behavior = 'noise' } }
            $res = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('noisy')
            $res['noisy'].ExitCode      | Should -Be 0
            $res['noisy'].CaptureMethod | Should -Be 'fake'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps the real result when an adapter emits chatter AFTER it' {
        # The shape that exposes the filter predicate. `-is [pscustomobject]`
        # is True for every pipeline item, so the "filter to the last
        # hashtable" kept the chatter too and Select -Last 1 returned THAT.
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{ tail = @{ backend = 'fake'; behavior = 'trailing' } }
            $res = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('tail')
            $res['tail'].ExitCode | Should -Be 0
            $res['tail'].Response | Should -Be 'real result'
            $res['tail'].Preset   | Should -Be 'tail'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports no-structured-output when the adapter returns nothing usable' {
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{ empty = @{ backend = 'fake'; behavior = 'nostruct' } }
            $res = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('empty')
            $res['empty'].ExitCode | Should -Be -1
            $res['empty'].Error    | Should -Be 'no-structured-output'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-ReviewerDispatch — what actually reaches the adapter' -Tag Unit {
    It 'sends each reviewer its OWN model override, not the first one' {
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{
                a = @{ backend = 'fake' }; b = @{ backend = 'fake' }
            }
            $null = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('a','b') `
                -ModelOverrides @{ a = 'model-A'; b = 'model-B' }
            (script:Get-Record -RootDir $d -Preset 'a').modelOverride | Should -Be 'model-A'
            (script:Get-Record -RootDir $d -Preset 'b').modelOverride | Should -Be 'model-B'
            # The override must also land in ModelInfo.model_id, which is what
            # the metadata writer reports as the model that actually ran.
            (script:Get-Record -RootDir $d -Preset 'a').modelId | Should -Be 'model-A'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'sends each reviewer its OWN opencode provider' {
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{
                a = @{ backend = 'fake' }; b = @{ backend = 'fake' }
            }
            $null = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('a','b') `
                -ProviderOverrides @{ a = 'prov-A' }
            (script:Get-Record -RootDir $d -Preset 'a').provider | Should -Be 'prov-A'
            (script:Get-Record -RootDir $d -Preset 'b').provider | Should -BeNullOrEmpty
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'scales TimeoutSec by bundle size and the adapter sees the scaled value' {
        # 20ms/token. The adapter uses this for its own stall/timeout checks, so
        # if the scaling never reached it the whole feature would be inert.
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{ a = @{ backend = 'fake' } }
            $null = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('a') `
                -TimeoutSec 600 -BundleTokens 50000
            (script:Get-Record -RootDir $d -Preset 'a').timeoutSec | Should -Be 1000
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'caps the scaled timeout at 1800s' {
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{ a = @{ backend = 'fake' } }
            $null = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('a') `
                -TimeoutSec 600 -BundleTokens 500000
            (script:Get-Record -RootDir $d -Preset 'a').timeoutSec | Should -Be 1800
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'leaves TimeoutSec alone for a small bundle' {
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{ a = @{ backend = 'fake' } }
            $null = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('a') `
                -TimeoutSec 600 -BundleTokens 1000
            (script:Get-Record -RootDir $d -Preset 'a').timeoutSec | Should -Be 600
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-ReviewerDispatch — optional params are splatted only when declared' -Tag Unit {
    It 'passes -PidFile to an adapter that declares it' {
        $d = script:New-FakeSkillRoot -DeclarePidFile
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{ a = @{ backend = 'fake' } }
            $null = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('a')
            (script:Get-Record -RootDir $d -Preset 'a').pidFile | Should -Match 'round-1-response\.md\.pid$'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does NOT pass -PidFile to an adapter that does not declare it' {
        # A REST adapter has no child to kill and never declares the param;
        # splatting it unconditionally would be a binding error at dispatch time.
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{ a = @{ backend = 'fake' } }
            $res = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('a')
            $res['a'].ExitCode | Should -Be 0 -Because 'an unsplattable param would surface as an adapter exception'
            (script:Get-Record -RootDir $d -Preset 'a').pidFile | Should -BeNullOrEmpty
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'resolves each agy reviewer its OWN default --model token' {
        # A heterogeneous agy batch must not collapse to the first reviewer's
        # model. The fake backend is named 'agy' so the dispatcher takes its
        # agy-only branch, but resolves to the fake adapter under the temp root.
        $d = script:New-FakeSkillRoot -Backends @('agy') -DeclareResolvedAgy
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{
                flash = @{ backend = 'agy'; agy_model_family = 'gemini-3.6-flash'; agy_model_tier = 'high' }
                pro   = @{ backend = 'agy'; agy_model_family = 'gemini-3.1-pro';   agy_model_tier = 'low'  }
            }
            $map = @{
                'gemini-3.6-flash' = [pscustomobject]@{ high = [pscustomobject]@{ settings_value = 'Gemini 3.6 Flash (High)' } }
                'gemini-3.1-pro'   = [pscustomobject]@{ low  = [pscustomobject]@{ settings_value = 'Gemini 3.1 Pro (Low)'   } }
            }
            $null = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('flash','pro') -AgyModelMap $map
            (script:Get-Record -RootDir $d -Preset 'flash').resolvedAgyModel | Should -Be 'Gemini 3.6 Flash (High)'
            (script:Get-Record -RootDir $d -Preset 'pro').resolvedAgyModel   | Should -Be 'Gemini 3.1 Pro (Low)'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'an explicit batch -ResolvedAgyModel overrides every agy reviewer' {
        $d = script:New-FakeSkillRoot -Backends @('agy') -DeclareResolvedAgy
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{
                flash = @{ backend = 'agy'; agy_model_family = 'gemini-3.6-flash'; agy_model_tier = 'high' }
                pro   = @{ backend = 'agy'; agy_model_family = 'gemini-3.1-pro';   agy_model_tier = 'low'  }
            }
            $null = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('flash','pro') `
                -ResolvedAgyModel 'User Picked This'
            (script:Get-Record -RootDir $d -Preset 'flash').resolvedAgyModel | Should -Be 'User Picked This'
            (script:Get-Record -RootDir $d -Preset 'pro').resolvedAgyModel   | Should -Be 'User Picked This'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-ReviewerDispatch — the straggler grace path, end to end' -Tag Unit {
    It 'tree-kills a lone straggler''s child and completes the round' {
        # The measured hazard this encodes: DO NOT Stop-Job a ThreadJob blocked
        # in WaitForExit -- it blocks forever. The dispatcher must kill the CHILD
        # and let the job unwind.
        #
        # Grace 1, NOT 0: Test-EraStragglerExpired treats `$GraceSec -le 0` as
        # "explicitly disabled -- wait for the full budget", so 0 makes this test
        # hang for the entire 630s budget rather than firing immediately.
        $saved = $env:ERA_STRAGGLER_GRACE_SEC
        $env:ERA_STRAGGLER_GRACE_SEC = '1'
        $d = script:New-FakeSkillRoot -DeclarePidFile
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{
                quick   = @{ backend = 'fake' }
                blocked = @{ backend = 'fake'; behavior = 'child' }
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $res = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('quick','blocked') -TimeoutSec 600
            $sw.Stop()
            # The whole point: it returned instead of waiting out the 630s budget.
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 120
            $res['quick'].ExitCode   | Should -Be 0
            $res.Keys                | Should -Contain 'blocked'
            # The abandoned reviewer must be recorded as a failure with no
            # artifact -- what Test-EraReviewerArtifact and the void gate read.
            $res['blocked'].ExitCode | Should -Be -1
            Test-Path -LiteralPath (Join-Path $d 'review/round-1-blocked-response.md') | Should -BeFalse
        } finally {
            # Defensive: if anything above failed before the kill, the 900s
            # sleeper would outlive the suite. Never leak a process from a test.
            $pf = Join-Path $d 'review/round-1-blocked-response.md.pid'
            if (Test-Path -LiteralPath $pf) {
                $stray = (Get-Content -Raw -LiteralPath $pf).Trim()
                if ($stray -match '^\d+$') { Stop-Process -Id ([int]$stray) -Force -ErrorAction SilentlyContinue }
            }
            Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
            if ($null -eq $saved) { Remove-Item Env:\ERA_STRAGGLER_GRACE_SEC -ErrorAction SilentlyContinue }
            else { $env:ERA_STRAGGLER_GRACE_SEC = $saved }
        }
    }

    # NOTE: the 'grace never fires on a solo run' guard (Total -lt 2) is not
    # re-tested here. A fast fake finishes before the grace could fire, so a
    # dispatcher-level version would pass without exercising the guard, and a
    # faithful one would have to burn the full budget. It is covered directly in
    # StragglerGrace.Tests.ps1 ('never fires on a single-reviewer run').
}

Describe 'Invoke-ReviewerDispatch — the global timeout collection path' -Tag Slow {
    It 'synthesises an honest timeout result for a job that never finishes' {
        # ~35s: $budgetSec is hardcoded $TimeoutSec + 30, so this path cannot be
        # exercised faster. It is the path that produced case (a) of the
        # 2026-08-09 void round -- opus "exceeded its 600s slice of the 600s
        # budget", no response file, and the round still exited 0.
        # No ERA_STRAGGLER_GRACE_SEC games needed: this is a solo run, and the
        # grace branch is guarded by Total -ge 2. Only the budget can end it.
        $d = script:New-FakeSkillRoot
        try {
            $reg = script:New-FakeRegistry -RecordDir (Join-Path $d 'record') -Presets @{
                stuck = @{ backend = 'fake'; behavior = 'hang' }
            }
            $res = script:Invoke-FakeDispatch -RootDir $d -Registry $reg -ReviewerList @('stuck') -TimeoutSec 0
            $res['stuck'].ExitCode | Should -Be -1
            $res['stuck'].Error    | Should -Be 'timeout'
            ($res['stuck'].Warnings -join ' ') | Should -Match 'Timed out after'
            # No response file: this is precisely what Test-EraReviewerArtifact
            # and the void-round gate key on.
            Test-Path -LiteralPath (Join-Path $d 'review/round-1-response.md') | Should -BeFalse
        } finally {
            Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
