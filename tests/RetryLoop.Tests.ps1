# Retry-loop tests for the agy adapter (Invoke-AgyReview).
#
# R7: a stall/timeout thrown by _SpawnAndCaptureOnce on attempt 1 must be treated
#     as a bad attempt and retried once (not propagated out, bypassing the loop).
# R3: the retry cost-cap guard must use the REAL per-reviewer cap ($2 cheap /
#     $10 expensive, mirroring Get-PerReviewerCap), NOT a hardcoded $15 that never
#     fires for a single agy reviewer.
#
# _SpawnAndCaptureOnce is a top-level function in agy.ps1, so Pester can Mock it
# to drive Invoke-AgyReview's loop without spawning a real agy process.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'backends/agy.ps1')

    function New-Bundle {
        param([int]$Chars = 1000)
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ("era-bundle-" + [guid]::NewGuid() + ".xml")
        # Bundle size drives estInputTokens (chars/4) which drives the cap math.
        ('x' * $Chars) | Set-Content -Path $p -NoNewline -Encoding utf8
        return $p
    }
    function New-Tmp {
        Join-Path ([System.IO.Path]::GetTempPath()) ("era-tmp-" + [guid]::NewGuid() + ".md")
    }
    $script:GoodReview = "## Critical issues`n- a real finding about the dispatcher`n## Minor`n- nit"
    $script:Narration  = 'I will view tests/x.py to understand the setup before reviewing.'

    # Cheap agy preset (input < $10/M => $2 per-reviewer cap).
    $script:MiCheap = @{
        preset = 'gemini-pro-low'; backend = 'agy'
        agy_model_family = 'gemini-3.1-pro'
        pricing = @{ input_per_m = 1.5; output_per_m = 5.0 }
    }
    # Pricing tuned so a ~600 KB bundle replayed twice exceeds the $2 cheap cap
    # ($2.997) but stays under the legacy $15 guard — distinguishes the fix.
    $script:MiCapTest = @{
        preset = 'cap-test'; backend = 'agy'
        agy_model_family = 'gemini-3.1-pro'
        pricing = @{ input_per_m = 9.99; output_per_m = 5.0 }
    }
}

Describe 'Invoke-AgyReview — R7: stall/timeout is retried, not bypassed' {
    It 'retries once when attempt 1 stalls, then succeeds on attempt 2' {
        $script:n = 0
        Mock _SpawnAndCaptureOnce {
            $script:n++
            if ($script:n -eq 1) { throw 'agy stalled -- no transcript activity for 90s after initial response began.' }
            return @{ Response = $script:GoodReview; ExitCode = 0; Strategy = 'run-id-match'; Stderr = ''; WallClockSec = 5 }
        }
        $bundle = New-Bundle 1000; $prompt = New-Tmp; $resp = New-Tmp
        $r = Invoke-AgyReview -BundlePath $bundle -PromptPath $prompt -ResponsePath $resp `
            -ModelInfo $script:MiCheap -TimeoutSec 60 -ResolvedAgyModel 'Gemini 3.1 Pro (Low)'
        $r.ContentOk   | Should -BeTrue
        $r.ExitCode    | Should -Be 0
        $r.RetryCount  | Should -Be 1
        $r.RetryReason | Should -Be 'stall-or-timeout'
        Should -Invoke _SpawnAndCaptureOnce -Times 2 -Exactly
        (Get-Content -Raw $resp) | Should -Match 'real finding'
    }

    It 'returns an honest ExitCode=-1 failure when both attempts stall' {
        Mock _SpawnAndCaptureOnce { throw 'agy showed no transcript activity within 90s -- likely failed to start.' }
        $bundle = New-Bundle 1000; $prompt = New-Tmp; $resp = New-Tmp
        $r = Invoke-AgyReview -BundlePath $bundle -PromptPath $prompt -ResponsePath $resp `
            -ModelInfo $script:MiCheap -TimeoutSec 60 -ResolvedAgyModel 'Gemini 3.1 Pro (Low)'
        $r.ContentOk   | Should -BeFalse
        $r.ExitCode    | Should -Be -1
        $r.RetryReason | Should -Be 'stall-or-timeout'
        $r.Error       | Should -Be 'stall-or-timeout'
        Should -Invoke _SpawnAndCaptureOnce -Times 2 -Exactly
    }

    It 'still retries an agentic-narration capture (regression — existing behavior)' {
        $script:n = 0
        Mock _SpawnAndCaptureOnce {
            $script:n++
            if ($script:n -eq 1) { return @{ Response = $script:Narration; ExitCode = 0; Strategy = 'run-id-match'; Stderr = ''; WallClockSec = 3 } }
            return @{ Response = $script:GoodReview; ExitCode = 0; Strategy = 'run-id-match'; Stderr = ''; WallClockSec = 5 }
        }
        $bundle = New-Bundle 1000; $prompt = New-Tmp; $resp = New-Tmp
        $r = Invoke-AgyReview -BundlePath $bundle -PromptPath $prompt -ResponsePath $resp `
            -ModelInfo $script:MiCheap -TimeoutSec 60 -ResolvedAgyModel 'Gemini 3.1 Pro (Low)'
        $r.ContentOk   | Should -BeTrue
        $r.RetryCount  | Should -Be 1
        $r.RetryReason | Should -Be 'agentic-narration-capture'
        Should -Invoke _SpawnAndCaptureOnce -Times 2 -Exactly
    }
}

Describe 'Invoke-AgyReview — R3: retry cost-cap uses the real per-reviewer cap' {
    It 'skips the retry when a replay would breach the $2 cheap per-reviewer cap' {
        # ~600 KB bundle => est input 150k tok; 2 replays at $9.99/M = ~$3.00 > $2.
        Mock _SpawnAndCaptureOnce {
            return @{ Response = $script:Narration; ExitCode = 0; Strategy = 'run-id-match'; Stderr = ''; WallClockSec = 3 }
        }
        $bundle = New-Bundle 600000; $prompt = New-Tmp; $resp = New-Tmp
        $r = Invoke-AgyReview -BundlePath $bundle -PromptPath $prompt -ResponsePath $resp `
            -ModelInfo $script:MiCapTest -TimeoutSec 60 -ResolvedAgyModel 'Gemini 3.1 Pro (Low)'
        $r.ContentOk  | Should -BeFalse
        $r.RetryCount | Should -Be 0
        $r.FirstAttempt | Should -Not -BeNullOrEmpty
        Should -Invoke _SpawnAndCaptureOnce -Times 1 -Exactly `
            -Because 'the real $2 cap must skip the replay; the legacy $15 guard never would'
    }

    It 'proceeds with the retry when the replay stays under the cap (small bundle)' {
        $script:n = 0
        Mock _SpawnAndCaptureOnce {
            $script:n++
            if ($script:n -eq 1) { return @{ Response = $script:Narration; ExitCode = 0; Strategy = 'run-id-match'; Stderr = ''; WallClockSec = 3 } }
            return @{ Response = $script:GoodReview; ExitCode = 0; Strategy = 'run-id-match'; Stderr = ''; WallClockSec = 5 }
        }
        $bundle = New-Bundle 1000; $prompt = New-Tmp; $resp = New-Tmp
        $r = Invoke-AgyReview -BundlePath $bundle -PromptPath $prompt -ResponsePath $resp `
            -ModelInfo $script:MiCapTest -TimeoutSec 60 -ResolvedAgyModel 'Gemini 3.1 Pro (Low)'
        $r.ContentOk  | Should -BeTrue
        $r.RetryCount | Should -Be 1
        Should -Invoke _SpawnAndCaptureOnce -Times 2 -Exactly
    }
}
