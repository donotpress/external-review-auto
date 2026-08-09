# Tests for the repomix invocation guard.
#
# Two defects, both visible in the 2026-08-09 incident:
#
#   1. era.ps1 interpolated the ENTIRE captured repomix output into the failure
#      exception. The run that collected 72,378 files produced a 16.9 MB log, so
#      the "error message" was 16.9 MB of bundle chatter.
#   2. The timeout branch called Stop-Job without Receive-Job, discarding every
#      diagnostic repomix had produced — an 18-minute failure that explained
#      nothing.
#
# Known limitation, deliberately NOT fixed here: Start-ThreadJob + Wait-Job +
# Stop-Job cannot bound a NATIVE child process. Stop-Job ends the thread; the
# node process repomix spawned keeps running. The adapters solve this with
# Process.Kill($true) (asserted by tests/ProcessTreeKill.Tests.ps1), but repomix
# resolves to a .ps1/.cmd shim on Windows, so spawning it under a Process handle
# needs its own shim-resolution logic and tests. See references/troubleshooting.md.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/RepomixGuard.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'
}

Describe 'Get-EraTruncatedText' -Tag Unit {
    It 'returns short text unchanged' {
        Get-EraTruncatedText -Text 'boom' -MaxChars 100 | Should -Be 'boom'
    }

    It 'returns empty string for null input' {
        Get-EraTruncatedText -Text $null -MaxChars 100 | Should -Be ''
    }

    It 'caps long text near MaxChars instead of echoing all of it' {
        $huge = 'x' * 200000
        $out = Get-EraTruncatedText -Text $huge -MaxChars 500
        $out.Length | Should -BeLessThan 800
    }

    It 'keeps the tail as well as the head — a subprocess error is usually last' {
        $text = ('a' * 100000) + 'FINAL-ERROR-LINE'
        $out = Get-EraTruncatedText -Text $text -MaxChars 600
        $out | Should -Match 'FINAL-ERROR-LINE'
        $out.Length | Should -BeLessThan 1000
    }

    It 'says how much it dropped, so the number is not silently lost' {
        $huge = 'x' * 200000
        $out = Get-EraTruncatedText -Text $huge -MaxChars 500
        $out | Should -Match '200000|truncated'
    }
}

Describe 'era.ps1 repomix guard' -Tag Unit {
    It 'does not interpolate the raw captured output into the failure exception' {
        $src = Get-Content -Raw $script:EraPath
        # The 16.9 MB error message shape.
        $src | Should -Not -Match 'exit code \$repomixExitCode`?: \$repomixResult'
        $src | Should -Match 'Get-EraTruncatedText'
    }

    It 'receives job output before stopping the job on the timeout branch' {
        $src = Get-Content -Raw $script:EraPath
        $timeoutIdx = $src.IndexOf('repomix timed out after')
        $timeoutIdx | Should -BeGreaterThan 0
        # Look back over the timeout branch for a Receive-Job preceding Stop-Job.
        $branch = $src.Substring([Math]::Max(0, $timeoutIdx - 1200), [Math]::Min(1200, $timeoutIdx))
        $branch | Should -Match 'Receive-Job'
        $branch.IndexOf('Receive-Job') | Should -BeLessThan $branch.LastIndexOf('Stop-Job')
    }

    It 'documents that Stop-Job cannot tree-kill the native repomix child' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match '(?i)cannot (bound|kill).{0,80}(native|child)'
    }
}
