# Repomix adopt-or-retry: a bundle step that did the work must not fail the round.
#
# MEASURED 2026-09-11 (ebook-pipeline round 3, first attempt): era threw
# "repomix timed out after 300s (process tree killed)" while the partial
# output showed EVERY phase through "Packing completed successfully!" and
# "All Done!" -- the process hung at EXIT, after the bundle was written.
# The retry bundled fine in seconds. The round died for nothing.
#
# Policy: on repomix timeout, ADOPT the bundle when the partial output
# carries the completion banner AND the bundle file exists, is non-empty,
# and is newer than the repomix start (a stale same-round file from a
# previous crashed attempt must never be adopted). Otherwise retry repomix
# EXACTLY once, then throw as today.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/RepomixTimeoutRecovery.Tests.ps1 -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
}

Describe 'Test-EraRepomixCompleted' -Tag Unit {
    BeforeAll { $script:Banner = 'Packing completed successfully!' }

    It 'adopts a bundle whose run printed the banner and wrote a fresh file' {
        $b = Join-Path $TestDrive 'round-3-bundle.xml'
        "<xml>content</xml>`n</instruction>" | Set-Content -LiteralPath $b -NoNewline -Encoding utf8
        Test-EraRepomixCompleted -PartialOutput "line1`n$script:Banner`nAll Done!" `
            -BundlePath $b -SinceUtc ([datetime]::UtcNow.AddMinutes(-1)) | Should -BeTrue
    }

    It 'rejects when the banner is absent (genuinely stuck mid-run)' {
        $b = Join-Path $TestDrive 'round-3b-bundle.xml'
        '<xml>content</xml>' | Set-Content -LiteralPath $b -NoNewline -Encoding utf8
        Test-EraRepomixCompleted -PartialOutput 'Searching for files...' `
            -BundlePath $b -SinceUtc ([datetime]::UtcNow.AddMinutes(-1)) | Should -BeFalse
    }

    It 'rejects when the bundle file is missing' {
        Test-EraRepomixCompleted -PartialOutput $script:Banner `
            -BundlePath (Join-Path $TestDrive 'nope-bundle.xml') -SinceUtc ([datetime]::UtcNow.AddMinutes(-1)) |
            Should -BeFalse
    }

    It 'rejects a stale same-round bundle from a previous crashed attempt' {
        $b = Join-Path $TestDrive 'round-3c-bundle.xml'
        '<xml>old</xml>' | Set-Content -LiteralPath $b -NoNewline -Encoding utf8
        Test-EraRepomixCompleted -PartialOutput $script:Banner `
            -BundlePath $b -SinceUtc ([datetime]::UtcNow.AddMinutes(5)) | Should -BeFalse
    }

    It 'rejects an empty bundle file' {
        $b = Join-Path $TestDrive 'round-3d-bundle.xml'
        '' | Set-Content -LiteralPath $b -NoNewline -Encoding utf8
        Test-EraRepomixCompleted -PartialOutput $script:Banner `
            -BundlePath $b -SinceUtc ([datetime]::UtcNow.AddMinutes(-1)) | Should -BeFalse
    }
}

Describe 'era.ps1 retries the bundle step at most once' -Tag Unit {
    BeforeAll { $script:EraSrc = Get-Content -Raw "$PSScriptRoot/../runtimes/era.ps1" }

    It 'checks adoptability before failing a timed-out repomix' {
        $script:EraSrc | Should -Match 'Test-EraRepomixCompleted'
    }

    It 'invokes repomix at most twice (initial + one retry)' {
        ([regex]::Matches($script:EraSrc, '=\s*Invoke-EraRepomix')).Count | Should -Be 2
    }
}
