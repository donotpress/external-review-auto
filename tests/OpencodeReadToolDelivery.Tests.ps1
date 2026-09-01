<#
  Read-tool delivery over the attach cap, and the snapshot bug that once hid how
  it behaves.

  THE SNAPSHOT BUG. Every artifact in %TEMP%\opencode-stall-debug is 0 bytes while
  the error line beside it reports a non-zero `total bytes`. That contradiction was
  read as "the process produced nothing", and it was wrong:

    $stdoutSink.Length       counts bytes still in the FileStream write buffer
    Get-Content / Copy-Item  see only what has reached disk

  So every snapshot under 4 KB came back empty. Reproduced below: 218 bytes copied
  in -> sink.Length = 218, on-disk length = 0, after Flush() -> 218. The same 218 as
  the 2026-08-31 timeout log. A broken measuring instrument, not evidence.

  WHAT THE PATH ACTUALLY DOES. Measured 2026-08-31 with CANARIES planted at widely
  separated offsets and reported back verbatim before the review -- a review coming
  back does not prove coverage, since a model can read the head, skip to the
  instructions at the tail, and write something plausible.

    bundle      lines    canaries       wall   result
    109,066 B    2,066   1/1 both seats   57s  real reviews, file:line cited
    314,720 B    5,226   2/2 both seats   85s  real reviews
    668,389 B   10,773   3/3 both seats  256s  real reviews

  IT IS STILL INTERMITTENT and that is unexplained -- deepseek-flash lost seats at
  74,740 B and 79,294 B, sizes these probes clear comfortably. Not size, not model.
  Concurrency was the leading hypothesis; a controlled A/B (10 trials under a live
  `opencode serve` plus 22 external `opencode run` contenders, against 10 with no
  other opencode process) produced 0 stalls in BOTH arms, so it is now the
  least-supported explanation rather than the first thing to check.
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
        $script:Src | Should -Match '\$snapshotPartialAndDebug = \{[\s\S]{0,4000}?\$stdoutSink\.Flush\(\)'
        $script:Src | Should -Match '\$snapshotPartialAndDebug = \{[\s\S]{0,4000}?\$stderrSink\.Flush\(\)'
    }

    It 'flushes BEFORE the Get-Content that builds the tail' {
        $block   = [regex]::Match($script:Src, '\$snapshotPartialAndDebug = \{[\s\S]{0,6000}?\n        \}').Value
        $block   | Should -Not -BeNullOrEmpty
        $flushAt = $block.IndexOf('$stdoutSink.Flush()')
        $readAt  = $block.IndexOf('$partialOut = (Get-Content')
        $flushAt | Should -BeGreaterThan -1
        $readAt  | Should -BeGreaterThan $flushAt
    }

    It 'quiesces the async copy before flushing, and does not swallow a flush failure' {
        # Flush() pushes the FileStream's own buffer to the OS; it does not drain
        # bytes still in the CopyToAsync pipeline, so a snapshot taken mid-drain
        # can be short -- the same class as the bug this block exists to fix.
        # And a silently-swallowed flush failure reproduces the exact signature
        # (empty artifact, non-zero byte count) that was misread as "the process
        # produced nothing" and used to retire a working path.
        $block = [regex]::Match($script:Src, '\$snapshotPartialAndDebug = \{[\s\S]{0,6000}?\n        \}').Value
        $block | Should -Not -BeNullOrEmpty
        $block | Should -Match '\$stdoutCopyTask\.Wait\('
        $block | Should -Match '\$stderrCopyTask\.Wait\('
        $waitAt  = $block.IndexOf('$stdoutCopyTask.Wait(')
        $flushAt = $block.IndexOf('$stdoutSink.Flush()')
        $waitAt  | Should -BeGreaterThan -1
        $flushAt | Should -BeGreaterThan $waitAt
        # catch{} with no body is the silent form.
        $block | Should -Not -Match 'try \{ \$stdoutSink\.Flush\(\) \} catch \{\}'
        $block | Should -Match 'could not flush the stdout capture'
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

Describe 'the Read-tool path carries bundles over the attach cap' -Tag Unit {

    It 'does NOT refuse a bundle in the verified range' {
        # Regression guard for the day this was retired. 74,740 bytes is the size
        # that stalled on 2026-08-31 and triggered the retirement; a 109,066-byte
        # bundle was afterwards covered in full on this same seat, so refusing here
        # removes a capability over a failure that is not about size.
        . (Join-Path $script:SkillRoot 'backends/opencode.ps1')
        $script:Src | Should -Match '\$useReadTool\s*=\s*\$forceReadTool\s*-or\s*\(\$overAttachLimit'
        $script:Src | Should -Match '\$OPENCODE_READ_TOOL_MAX_BYTES\s*=\s*1048576'
    }

    It 'refuses past the verified ceiling, without spawning opencode' {
        . (Join-Path $script:SkillRoot 'backends/opencode.ps1')
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-oc-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        $null = New-Item -ItemType Directory -Path $dir -Force
        try {
            $bundle = Join-Path $dir 'bundle.xml'
            [System.IO.File]::WriteAllBytes($bundle, [byte[]]::new(2000000))   # > 1 MB
            $prompt = Join-Path $dir 'prompt.md'; 'review this' | Set-Content -LiteralPath $prompt
            $resp   = Join-Path $dir 'response.md'

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            { Invoke-OpencodeReview -BundlePath $bundle -PromptPath $prompt -ResponsePath $resp `
                -ModelInfo @{ model_id = 'opencode-go/deepseek-v4-flash' } -TimeoutSec 600 } |
                Should -Throw -ExpectedMessage '*opencode cannot review this bundle*'
            $sw.Stop()

            $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
            Test-Path -LiteralPath $resp | Should -BeFalse
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'still attaches a bundle under the cap' {
        # The refusal must not have swallowed the working path.
        $script:Src | Should -Match "if \(-not \`$useReadTool\) \{[\s\S]{0,200}ArgumentList\.Add\('-f'\)"
    }

    It 'records the canary measurements in the source, not just a commit message' {
        # The next person to hit this must find the measurement without git
        # archaeology -- the same standard the rest of this adapter is held to.
        $script:Src | Should -Match 'CANARY'
        $script:Src | Should -Match '668,389'
        $script:Src | Should -Match '109,066'
    }

    It 'records the intermittency AND that the leading hypothesis was ruled out' {
        # The probes all pass; the historical stalls are real and unexplained. A
        # comment reporting only the passes is arguing for its conclusion -- and a
        # comment still naming a hypothesis that has since been measured and
        # rejected is worse, because it sends the next reader down a closed path.
        $script:Src | Should -Match '74,740'
        $script:Src | Should -Match '(?i)concurrency'
        $script:Src | Should -Match '(?i)0 stalls / 10'
        $script:Src | Should -Match '(?i)(did not hold|does not hold|least-supported)'
    }
}
