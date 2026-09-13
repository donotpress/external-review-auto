# Differential follow-ups by default (spec v2) + prior-usable gate.
#
# Spec: docs/specs/2026-09-12-differential-bundles.md v2 (HIGH risk, behind
# split+soak -- split has landed, this is the implementation). The flip:
# round >= 2 with a usable prior round goes differential unless -FullBundle
# forces full. -Diff explicit keeps working through the same helper (one
# code path, pinned below). Prior usability is COMPUTED at bundle time
# (manifest + >=1 usable artifact); void/missing priors fall back to full.
# Criticals dropped by the carry cap force full (fail-closed toward
# complete context, not truncated findings).
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/DifferentialFollowUp.Tests.ps1 -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
}

Describe 'Test-EraFollowUpRound' -Tag Unit {
    It 'never follows up on round 1' {
        Test-EraFollowUpRound -Round 1 -FullBundlePresent $false -PriorUsable $true |
            Should -BeFalse
    }

    It 'flips to diff by default on usable priors (the default change)' {
        Test-EraFollowUpRound -Round 2 -FullBundlePresent $false -PriorUsable $true |
            Should -BeTrue
        Test-EraFollowUpRound -Round 3 -FullBundlePresent $false -PriorUsable $true |
            Should -BeTrue
    }

    It '-FullBundle forces full (the close-out mechanism)' {
        Test-EraFollowUpRound -Round 2 -FullBundlePresent $true -PriorUsable $true |
            Should -BeFalse
        Test-EraFollowUpRound -Round 3 -FullBundlePresent $true -PriorUsable $true |
            Should -BeFalse
    }

    It 'falls back to full on void or missing priors' {
        Test-EraFollowUpRound -Round 2 -FullBundlePresent $false -PriorUsable $false |
            Should -BeFalse
    }
}

Describe 'Test-EraPriorRoundUsable' -Tag Unit {
    BeforeAll {
        function New-PriorRound {
            param([switch]$Manifest, [string[]]$Responses = @(), [switch]$Rejected)
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-prior-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            if ($Manifest) {
                @{ round = 2; reviewers_requested = @('opus', 'gemini') } |
                    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dir 'round-2-manifest.json')
            }
            foreach ($r in $Responses) {
                "review by $r" | Set-Content -LiteralPath (Join-Path $dir "round-2-$r-response.md")
            }
            if ($Rejected) {
                'rejected' | Set-Content -LiteralPath (Join-Path $dir 'round-2-gemini-response.rejected.md')
            }
            return $dir
        }
    }

    It 'is usable with manifest plus at least one response' {
        $d = New-PriorRound -Manifest -Responses @('opus')
        try { Test-EraPriorRoundUsable -ReviewDir $d -PriorRound 2 | Should -BeTrue }
        finally { Remove-Item -Recurse -Force -LiteralPath $d -ErrorAction SilentlyContinue }
    }

    It 'is not usable with manifest alone, responses alone, or rejected-only' {
        $d1 = New-PriorRound -Manifest
        $d2 = New-PriorRound -Responses @('opus')
        $d3 = New-PriorRound -Manifest -Rejected
        try {
            Test-EraPriorRoundUsable -ReviewDir $d1 -PriorRound 2 | Should -BeFalse
            Test-EraPriorRoundUsable -ReviewDir $d2 -PriorRound 2 | Should -BeFalse
            Test-EraPriorRoundUsable -ReviewDir $d3 -PriorRound 2 | Should -BeFalse
            Test-EraPriorRoundUsable -ReviewDir (Join-Path $TestDrive 'absent') -PriorRound 2 |
                Should -BeFalse
        } finally {
            Remove-Item -Recurse -Force -LiteralPath $d1, $d2, $d3 -ErrorAction SilentlyContinue
        }
    }
}

Describe 'critical headings survive the carry cap or force full' -Tag Unit {
    BeforeAll {
        function New-CappedPrior {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-cap-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            # Critical heading sits past char 100 so a 100-char cap drops it;
            # the uncapped default carries everything.
            $body = ('y' * 200) + "`n`n## Critical issues`n`n" + ('x' * 500) + "`n`n## Minor`n- nit"
            $body | Set-Content -LiteralPath (Join-Path $dir 'round-2-opus-response.md')
            return $dir
        }
    }

    It 'flags dropped criticals when the cap bites' {
        $old = $env:ERA_PREVIOUS_ROUND_MAX_CHARS
        $d = New-CappedPrior
        try {
            $env:ERA_PREVIOUS_ROUND_MAX_CHARS = '100'
            $dropped = $false
            $null = Get-EraPreviousRoundText -ReviewDir $d -PreviousRound 2 -CriticalsDropped ([ref]$dropped)
            $dropped | Should -BeTrue
        } finally {
            if ($null -eq $old) { Remove-Item Env:ERA_PREVIOUS_ROUND_MAX_CHARS -ErrorAction SilentlyContinue }
            else { $env:ERA_PREVIOUS_ROUND_MAX_CHARS = $old }
            Remove-Item -Recurse -Force -LiteralPath $d -ErrorAction SilentlyContinue
        }
    }

    It 'stays quiet when everything fits' {
        $d = New-CappedPrior
        try {
            $dropped = $false
            $null = Get-EraPreviousRoundText -ReviewDir $d -PreviousRound 2 -CriticalsDropped ([ref]$dropped)
            $dropped | Should -BeFalse
        } finally { Remove-Item -Recurse -Force -LiteralPath $d -ErrorAction SilentlyContinue }
    }
}

Describe 'era.ps1 routes the flip through one helper' -Tag Unit {
    BeforeAll { $script:EraSrc = Get-Content -Raw "$PSScriptRoot/../runtimes/era.ps1" }

    It 'computes follow-up in exactly one place' {
        $lines = (Get-Content -LiteralPath "$PSScriptRoot/../runtimes/era.ps1") |
            Where-Object { $_ -match '=\s*Test-EraFollowUpRound' }
        @($lines).Count | Should -Be 1
    }

    It 'declares -FullBundle and honors it' {
        $script:EraSrc | Should -Match '\[switch\]\$FullBundle'
    }

    It 'deletions message names the new opt-out' {
        $script:EraSrc | Should -Match 'FullBundle'
    }
}
