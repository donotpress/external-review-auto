<#
  The retired Read-tool path, and the snapshot bug that hid why it failed.

  DIAGNOSIS (2026-08-31). The Read-tool path was believed to "never start":
  every artifact in %TEMP%\opencode-stall-debug is 0 bytes, while the error line
  beside it reports a non-zero `total bytes`. That contradiction was a BUG IN THE
  SNAPSHOT, not evidence.

    $stdoutSink.Length  counts bytes still sitting in the FileStream write buffer
    Get-Content / Copy-Item  see only what has reached disk

  So every snapshot under 4 KB came back empty. Reproduced: 218 bytes copied in ->
  sink.Length = 218, on-disk length = 0, after Flush() -> 218. The same 218 as the
  2026-08-31 timeout log.

  The ONE artifact that survived (4,096 bytes — exactly one buffer flush) shows
  what actually happens on that path:

      -> Read .external-reviews/<slug>/round-1-bundle.xml
      -> Read .external-reviews/<slug>/round-1-bundle.xml [offset=822]
      $  Get-ChildItem -LiteralPath "...\<slug>" -Force | Select-Object ...
      $  Get-Content -LiteralPath "...\round-1-config.json"; ... round-1-prompt.md

  It starts fine, chunk-reads the bundle, then wanders into unrelated shell
  commands until the budget is gone. Never "never starts" — never finishes.
#>

BeforeAll {
    $script:SkillRoot = Split-Path -Parent $PSScriptRoot
    $script:Src = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/opencode.ps1')
}

Describe 'the stall snapshot tells the truth' -Tag Unit {

    It 'flushes both capture sinks before reading them' {
        # THE REGRESSION GUARD. Without this the forensics are empty and the next
        # person to debug a stall is sent after a startup failure that is not
        # happening.
        $script:Src | Should -Match '\$snapshotPartialAndDebug = \{[\s\S]{0,2000}?\$stdoutSink\.Flush\(\)'
        $script:Src | Should -Match '\$snapshotPartialAndDebug = \{[\s\S]{0,2000}?\$stderrSink\.Flush\(\)'
    }

    It 'flushes BEFORE the Get-Content that builds the tail' {
        $block   = [regex]::Match($script:Src, '\$snapshotPartialAndDebug = \{[\s\S]{0,3000}?\n        \}').Value
        $block   | Should -Not -BeNullOrEmpty
        $flushAt = $block.IndexOf('$stdoutSink.Flush()')
        $readAt  = $block.IndexOf('$partialOut = (Get-Content')
        $flushAt | Should -BeGreaterThan -1
        $readAt  | Should -BeGreaterThan $flushAt
    }

    It 'demonstrates the bug it fixes: FileStream.Length counts unflushed bytes' {
        # Not a mock — the actual .NET behaviour that produced "total bytes=218"
        # next to a 0-byte artifact.
        $tmp  = [System.IO.Path]::GetTempFileName()
        try {
            $sink = [System.IO.File]::Open($tmp, [System.IO.FileMode]::Create,
                        [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $src  = [System.IO.MemoryStream]::new([byte[]]@(1..218 | ForEach-Object { 65 }))
                $null = $src.CopyToAsync($sink).Wait(5000)

                $sink.Length                             | Should -Be 218
                (Get-Item -LiteralPath $tmp).Length      | Should -Be 0    # the bug
                $sink.Flush()
                (Get-Item -LiteralPath $tmp).Length      | Should -Be 218  # the fix
            } finally { $sink.Dispose() }
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the Read-tool path is retired' -Tag Unit {

    It 'refuses an oversized bundle without spawning opencode' {
        # Behavioural, not a source assertion: the refusal must happen before
        # Process::Start, so it costs a second and no tokens rather than 600s.
        . (Join-Path $script:SkillRoot 'backends/opencode.ps1')
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-oc-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        $null = New-Item -ItemType Directory -Path $dir -Force
        try {
            $bundle = Join-Path $dir 'bundle.xml'
            [System.IO.File]::WriteAllBytes($bundle, [byte[]]::new(60000))   # > 51,200
            $prompt = Join-Path $dir 'prompt.md'; 'review this' | Set-Content -LiteralPath $prompt
            $resp   = Join-Path $dir 'response.md'

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            { Invoke-OpencodeReview -BundlePath $bundle -PromptPath $prompt -ResponsePath $resp `
                -ModelInfo @{ model_id = 'opencode-go/deepseek-v4-flash' } -TimeoutSec 600 } |
                Should -Throw -ExpectedMessage '*opencode cannot review this bundle*'
            $sw.Stop()

            # A refusal, not a hang. The whole point.
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
            Test-Path -LiteralPath $resp | Should -BeFalse
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'says how far over the cap the bundle is, and what to do about it' {
        . (Join-Path $script:SkillRoot 'backends/opencode.ps1')
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-oc-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        $null = New-Item -ItemType Directory -Path $dir -Force
        try {
            $bundle = Join-Path $dir 'bundle.xml'
            [System.IO.File]::WriteAllBytes($bundle, [byte[]]::new(512000))  # 10x the cap
            $prompt = Join-Path $dir 'prompt.md'; 'review this' | Set-Content -LiteralPath $prompt
            $msg = $null
            try {
                Invoke-OpencodeReview -BundlePath $bundle -PromptPath $prompt `
                    -ResponsePath (Join-Path $dir 'r.md') `
                    -ModelInfo @{ model_id = 'opencode-go/deepseek-v4-flash' } -TimeoutSec 600
            } catch { $msg = $_.Exception.Message }

            $msg | Should -Match '512000 bytes'
            $msg | Should -Match '10%'              # the fraction the model would have seen
            $msg | Should -Match '-IncludeFiles'    # the way out
            $msg | Should -Match 'retired'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'still attaches a bundle under the cap' {
        # The refusal must not have swallowed the working path.
        $script:Src | Should -Match "if \(-not \`$useReadTool\) \{[\s\S]{0,200}ArgumentList\.Add\('-f'\)"
    }

    It 'records the evidence in the source, not just in a commit message' {
        # The next person to hit this must find the measurement without git
        # archaeology — the same standard the rest of this adapter is held to.
        $script:Src | Should -Match 'chunk-read|CHUNK-READ'
        # Including the COUNTER-example. The path is unreliable, not uniformly
        # fatal -- muse-spark returned a real review on the same 2.4 MB bundle
        # deepseek-flash failed on -- and a comment that hides that is arguing
        # for the fix rather than recording what was measured.
        $script:Src | Should -Match 'muse-spark'
        $script:Src | Should -Match 'SUCCEEDED'
    }
}
