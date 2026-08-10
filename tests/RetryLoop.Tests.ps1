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

Describe 'Invoke-AgyReview — a readable capture from a process that died is not a success' {
    # THE ROOT CAUSE of the 2026-08-09 void round (case c).
    #
    # The clean-capture decision (agy.ps1:598-602) is made purely from the
    # response TEXT -- threw / empty / narration-detector -- and never consults
    # $result.ExitCode. The clean-capture return (agy.ps1:706-721) then set
    # ContentOk=$true UNCONDITIONALLY while passing the agy PROCESS exit code
    # straight through, and set no Error key.
    #
    # _SpawnAndCaptureOnce reads the answer from the transcript independently of
    # process exit and reports ExitCode=-1 whenever the process had to be killed
    # at the hard deadline (agy.ps1:462). So a readable-but-doomed capture
    # returned ExitCode=-1 WITH ContentOk=$true and error=null -- which is
    # exactly what the live run recorded for gemini-pro-high after it truncated
    # at maxOutputTokens and its answer was demoted to *.rejected.md.

    It 'does not claim ContentOk when its own exit code says the process failed' {
        Mock _SpawnAndCaptureOnce {
            return @{ Response = $script:GoodReview; ExitCode = -1; Strategy = 'run-id-match'; Stderr = 'killed at hard deadline'; WallClockSec = 300 }
        }
        $bundle = New-Bundle 1000; $prompt = New-Tmp; $resp = New-Tmp
        $r = Invoke-AgyReview -BundlePath $bundle -PromptPath $prompt -ResponsePath $resp `
            -ModelInfo $script:MiCheap -TimeoutSec 60 -ResolvedAgyModel 'Gemini 3.1 Pro (Low)'
        $r.ExitCode  | Should -Be -1
        $r.ContentOk | Should -BeFalse
    }

    It 'names a cause instead of returning error=null' {
        Mock _SpawnAndCaptureOnce {
            return @{ Response = $script:GoodReview; ExitCode = -1; Strategy = 'run-id-match'; Stderr = 'killed at hard deadline'; WallClockSec = 300 }
        }
        $bundle = New-Bundle 1000; $prompt = New-Tmp; $resp = New-Tmp
        $r = Invoke-AgyReview -BundlePath $bundle -PromptPath $prompt -ResponsePath $resp `
            -ModelInfo $script:MiCheap -TimeoutSec 60 -ResolvedAgyModel 'Gemini 3.1 Pro (Low)'
        $r.Error              | Should -Not -BeNullOrEmpty
        ($r.Warnings -join ' ') | Should -Match 'exit'
    }

    It 'still writes the text to disk — it is evidence, and the alias demotes it' {
        Mock _SpawnAndCaptureOnce {
            return @{ Response = $script:GoodReview; ExitCode = -1; Strategy = 'run-id-match'; Stderr = ''; WallClockSec = 300 }
        }
        $bundle = New-Bundle 1000; $prompt = New-Tmp; $resp = New-Tmp
        $null = Invoke-AgyReview -BundlePath $bundle -PromptPath $prompt -ResponsePath $resp `
            -ModelInfo $script:MiCheap -TimeoutSec 60 -ResolvedAgyModel 'Gemini 3.1 Pro (Low)'
        (Get-Content -Raw $resp) | Should -Match 'real finding'
    }

    It 'does NOT spend a second dispatch on it — the retry decision is unchanged' {
        # Deliberately narrow: this fix makes the RETURN self-consistent. It must
        # not quietly turn a one-attempt failure into a two-bundle bill.
        Mock _SpawnAndCaptureOnce {
            return @{ Response = $script:GoodReview; ExitCode = -1; Strategy = 'run-id-match'; Stderr = ''; WallClockSec = 300 }
        }
        $bundle = New-Bundle 1000; $prompt = New-Tmp; $resp = New-Tmp
        $r = Invoke-AgyReview -BundlePath $bundle -PromptPath $prompt -ResponsePath $resp `
            -ModelInfo $script:MiCheap -TimeoutSec 60 -ResolvedAgyModel 'Gemini 3.1 Pro (Low)'
        Should -Invoke _SpawnAndCaptureOnce -Times 1 -Exactly
        $r.RetryCount | Should -Be 0
    }

    It 'still reports ContentOk=true when the process exited clean (non-vacuity)' {
        Mock _SpawnAndCaptureOnce {
            return @{ Response = $script:GoodReview; ExitCode = 0; Strategy = 'run-id-match'; Stderr = ''; WallClockSec = 5 }
        }
        $bundle = New-Bundle 1000; $prompt = New-Tmp; $resp = New-Tmp
        $r = Invoke-AgyReview -BundlePath $bundle -PromptPath $prompt -ResponsePath $resp `
            -ModelInfo $script:MiCheap -TimeoutSec 60 -ResolvedAgyModel 'Gemini 3.1 Pro (Low)'
        $r.ContentOk | Should -BeTrue
        $r.ExitCode  | Should -Be 0
        $r.Error     | Should -BeNullOrEmpty
    }
}
