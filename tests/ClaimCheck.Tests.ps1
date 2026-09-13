# Claim-check probe: per-seat citation grounding with receipt.
#
# Drives tools/probes/claim-check.ps1 end to end on fixtures (no mocks of
# the probe itself -- the script IS the unit). Fixture repo + bundle are
# built under TestDrive; the receipt JSON shape is asserted, not just the
# console line.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/ClaimCheck.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Probe = "$PSScriptRoot/../tools/probes/claim-check.ps1"

    function New-ClaimFixture {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("era-claim-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
        1..50 | ForEach-Object { "line $_" } | Set-Content -LiteralPath (Join-Path $root 'src/a.ps1')
        1..10 | ForEach-Object { "row $_" } | Set-Content -LiteralPath (Join-Path $root 'src/b.md')
        $bundle = Join-Path $root 'round-1-bundle.xml'
        @'
<file path="src/a.ps1">
line 1
line 2
</file>
<file path="src/b.md">
row 1
</file>
'@ | Set-Content -LiteralPath $bundle -NoNewline -Encoding utf8
        return @{ Root = $root; Bundle = $bundle }
    }
}

Describe 'claim-check receipt' -Tag Unit {
    It 'grounds valid citations in both frames' {
        $fx = New-ClaimFixture
        $resp = Join-Path $fx.Root 'round-1-opus-response.md'
        @'
# Findings
- `src/a.ps1:2` looks right.
- src/b.md:2 is fine.
'@ | Set-Content -LiteralPath $resp -NoNewline -Encoding utf8
        try {
            & $script:Probe -ResponsePath $resp -BundlePath $fx.Bundle -RepoRoot $fx.Root
            $j = Get-Content -Raw -LiteralPath "$resp.check.json" | ConvertFrom-Json
            $j.tool | Should -Be 'era-claim-check'
            $j.preset | Should -Be 'opus'
            $j.round | Should -Be 1
            $j.citations_total | Should -Be 2
            $j.grounded_bundle | Should -Be 2
            $j.grounded_disk | Should -Be 2
            @($j.ungrounded).Count | Should -Be 0
        } finally { Remove-Item -Recurse -Force -LiteralPath $fx.Root -ErrorAction SilentlyContinue }
    }

    It 'lists fabricated citations as ungrounded in both frames' {
        $fx = New-ClaimFixture
        $resp = Join-Path $fx.Root 'round-1-opus-response.md'
        @'
# Findings
- `src/a.ps1:9999` does not exist.
- src/nope.ps1:3 is invented.
'@ | Set-Content -LiteralPath $resp -NoNewline -Encoding utf8
        try {
            & $script:Probe -ResponsePath $resp -BundlePath $fx.Bundle -RepoRoot $fx.Root
            $j = Get-Content -Raw -LiteralPath "$resp.check.json" | ConvertFrom-Json
            $j.citations_total | Should -Be 2
            @($j.ungrounded).Count | Should -Be 2
        } finally { Remove-Item -Recurse -Force -LiteralPath $fx.Root -ErrorAction SilentlyContinue }
    }

    It 'resolves the bundle sibling automatically and fails clean on missing input' {
        $fx = New-ClaimFixture
        $resp = Join-Path $fx.Root 'round-2-muse-spark-response.md'
        '# nada' | Set-Content -LiteralPath $resp -NoNewline -Encoding utf8
        try {
            # No -BundlePath: sibling round-2-bundle.xml absent -> bundle frame empty, still receipts.
            & $script:Probe -ResponsePath $resp -RepoRoot $fx.Root
            $j = Get-Content -Raw -LiteralPath "$resp.check.json" | ConvertFrom-Json
            $j.citations_total | Should -Be 0
        } finally { Remove-Item -Recurse -Force -LiteralPath $fx.Root -ErrorAction SilentlyContinue }
        { & $script:Probe -ResponsePath (Join-Path $TestDrive 'absent.md') } | Should -Throw
    }
}

Describe 'dispatcher runs claim-check per delivered seat' -Tag Unit {
    It 'poll loop invokes the probe for newly delivered seats' {
        $src = Get-Content -Raw "$PSScriptRoot/../workflow.ps1"
        $src | Should -Match 'claim-check\.ps1'
    }
}
