# -BlindSeat leaves no durable record of which seat was blinded.
#
# Found while trying to REPLICATE the A/B in docs/assessments/2026-09-01-blind-seat-ab.md.
# The four scored arms are four response files in one directory; which of them
# saw the comment-stripped bundle is not in round-N-metadata.json, not in
# round-N-manifest.json, and not in the response files. It exists in a console
# line ("'<preset>' reviews the comment-stripped bundle") and in the prose of the
# assessment, and nowhere a later reader can check.
#
# That is the same defect as v2.4's citation warnings, which were emitted after
# Write-ReviewMetadata so the only record of a reviewer inventing line numbers was
# a terminal line nobody keeps -- fixed by recording them. This is the arm label
# of an experiment, in the feature built to run that experiment.
#
# It also silently mislabels: nothing prevents scoring the sighted arm as blind.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/BlindSeatRecord.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'workflow.ps1')

    function script:Write-Meta {
        param([hashtable]$Overrides = @{})
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-bsr-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        $null = New-Item -ItemType Directory -Path $dir
        foreach ($p in @('opus','deepseek-flash')) {
            Set-Content -LiteralPath (Join-Path $dir "round-1-$p-response.md") -Value "## Review`n1. a.js:1 - thing." -Encoding utf8
        }
        $results = @{}
        foreach ($p in @('opus','deepseek-flash')) {
            $results[$p] = @{ ExitCode = 0; Response = 'x' * 400; CaptureMethod = 'direct'; ContentOk = $true
                              OutputTokens = 100; WallClockSec = 1; Warnings = @() }
        }
        $reg = @{
            'opus'           = @{ backend = 'claude';   model_id = 'claude-opus-5';                pricing = @{ input_per_m = 5;   output_per_m = 25 } }
            'deepseek-flash' = @{ backend = 'opencode'; model_id = 'opencode-go/deepseek-v4-flash'; pricing = @{ input_per_m = 0.14; output_per_m = 0.28 } }
        }
        Write-ReviewMetadata -ReviewDir $dir -Round 1 -TopicSlug 'blind-ab' -Mode 'spec' `
            -Results $results -Registry $reg -BundleTokens 39264 -BundleBytes 146712 `
            -BundleOverrides $Overrides
        return @{ Dir = $dir
                  Meta = (Get-Content -Raw -LiteralPath (Join-Path $dir 'round-1-metadata.json') | ConvertFrom-Json) }
    }
}

Describe 'the round records which seat was blinded' -Tag Unit {

    It 'names the blinded seat at round level' {
        $m = script:Write-Meta -Overrides @{ 'opus' = 'X:\r\round-1-bundle-blind.xml' }
        try { $m.Meta.blind_seat | Should -Be 'opus' }
        finally { Remove-Item -LiteralPath $m.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'labels each reviewer''s arm, so a response file can be scored without prose' {
        $m = script:Write-Meta -Overrides @{ 'opus' = 'X:\r\round-1-bundle-blind.xml' }
        try {
            ($m.Meta.reviewers | Where-Object { $_.preset -eq 'opus' }).blinded           | Should -BeTrue
            ($m.Meta.reviewers | Where-Object { $_.preset -eq 'deepseek-flash' }).blinded | Should -BeFalse
        } finally { Remove-Item -LiteralPath $m.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'records the bundle each seat was actually given' {
        # The A/B's control is that both arms read the SAME code. Recording the
        # path is what lets a later reader check that, instead of assuming it.
        $m = script:Write-Meta -Overrides @{ 'opus' = 'X:\r\round-1-bundle-blind.xml' }
        try {
            ($m.Meta.reviewers | Where-Object { $_.preset -eq 'opus' }).delivery_bundle | Should -Be 'round-1-bundle-blind.xml'
            ($m.Meta.reviewers | Where-Object { $_.preset -eq 'deepseek-flash' }).delivery_bundle | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $m.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'names only a seat this round actually has a result for' {
        # FOUND BY THE BLINDED SEAT OF THE PANEL RUN ON THIS CHANGE, in the
        # feature that records blinding, in the same diff that added it.
        #
        # When the blinded seat fails recoverably, Get-EraFallbackBundleOverrides
        # copies the whole map and adds the fallback preset, so the override map
        # ends up naming BOTH -- and a round-level blind_seat built from
        # $BundleOverrides.Keys then reads "gemini-api,muse-spark". A scorer
        # cannot tell from that which preset actually read the stripped bundle,
        # which is the one question the field exists to answer.
        #
        # The map is keyed by intent; the metadata is keyed by what happened.
        $m = script:Write-Meta -Overrides @{ 'muse-spark' = 'blind.xml'; 'gemini-api' = 'blind.xml' }
        try {
            # Only 'opus' and 'deepseek-flash' are in this round's results.
            $m.Meta.blind_seat | Should -BeNullOrEmpty -Because 'neither override names a seat that ran'
        } finally { Remove-Item -LiteralPath $m.Dir -Recurse -Force -ErrorAction SilentlyContinue }

        $m2 = script:Write-Meta -Overrides @{ 'opus' = 'blind.xml'; 'never-dispatched' = 'blind.xml' }
        try {
            $m2.Meta.blind_seat | Should -Be 'opus'
            ($m2.Meta.reviewers | Where-Object { $_.preset -eq 'opus' }).blinded | Should -BeTrue
        } finally { Remove-Item -LiteralPath $m2.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'records the blind bundle''s HASH, so the A/B''s control can be checked' {
        # `era.ps1` asserts in a comment that the stripped copy is "byte-comparable
        # to what every other seat sees" -- and nothing records enough to check it.
        # Write-ReviewManifest hashes @($bundlePath, $promptPath) and runs BEFORE
        # the blind bundle is created, so that file is never hashed anywhere, and
        # a filename is not evidence of content. Raised by the opus seat of the
        # twin-sweep panel against the metadata field added in the same diff.
        $f = Join-Path ([System.IO.Path]::GetTempPath()) ("era-bb-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
        Set-Content -LiteralPath $f -Value '<file path="a.ps1">' -Encoding utf8
        $expected = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
        $m = script:Write-Meta -Overrides @{ 'opus' = $f }
        try {
            ($m.Meta.reviewers | Where-Object { $_.preset -eq 'opus' }).delivery_bundle_sha256 | Should -Be $expected
            ($m.Meta.reviewers | Where-Object { $_.preset -eq 'deepseek-flash' }).delivery_bundle_sha256 | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $m.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'records no hash rather than a wrong one when the bundle is gone' {
        $m = script:Write-Meta -Overrides @{ 'opus' = 'X:\r\vanished-blind.xml' }
        try {
            ($m.Meta.reviewers | Where-Object { $_.preset -eq 'opus' }).delivery_bundle        | Should -Be 'vanished-blind.xml'
            ($m.Meta.reviewers | Where-Object { $_.preset -eq 'opus' }).delivery_bundle_sha256 | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $m.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'says no seat was blinded when none was, rather than omitting the field' {
        # An absent key and "nobody was blinded" are different facts, and a
        # scorer reading a directory of rounds has to tell them apart.
        $m = script:Write-Meta
        try {
            $m.Meta.PSObject.Properties.Name | Should -Contain 'blind_seat'
            $m.Meta.blind_seat | Should -BeNullOrEmpty
            foreach ($r in $m.Meta.reviewers) { $r.blinded | Should -BeFalse }
        } finally { Remove-Item -LiteralPath $m.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
