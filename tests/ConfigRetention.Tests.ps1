# Tests that a FAILED era run leaves its repomix config behind to diagnose from.
#
# era.ps1's finally block deleted round-N-config.json on success and failure
# alike (PowerShell unwinds `exit` through `finally`), and the manifest that
# would replace it is written only AFTER repomix succeeds. So a failed run left
# no bundle, no manifest and no config. The claim-file deletion two lines above
# is correct -- that is per-process state. The config is a receipt, not a
# tombstone.
#
# The failure used here is the pre-existing "Bundle is empty" guard: an empty
# directory passes Test-Path validation, then matches nothing in repomix.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/ConfigRetention.Tests.ps1"

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'

    function Invoke-FailingEraRun {
        <# Repo whose only include target is an empty dir => "Bundle is empty". #>
        param([string]$Repo)
        New-Item -ItemType Directory -Path (Join-Path $Repo '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Repo 'emptydir') -Force | Out-Null
        & pwsh -NonInteractive -Command @"
Set-Location '$Repo'
try {
    & '$($script:EraPath)' -TopicSlug 'cfg-test' -Reviewer gemini -Force -IncludeFiles 'emptydir' 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
    }
}

Describe 'Repomix config survives a failed run' -Tag Integration {
    It 'retains round-1-config.json when the run dies at the empty-bundle guard' {
        $repo = Join-Path $env:TEMP "era-cfg-keep-$(New-Guid)"
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        try {
            $out = Invoke-FailingEraRun -Repo $repo
            # Confirm we actually exercised the failure path we think we did.
            $out | Should -Match 'Bundle is empty'
            Test-Path (Join-Path $repo '.external-reviews/cfg-test/round-1-config.json') |
                Should -BeTrue
        } finally { Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue }
    }

    It 'still removes the round-claim file on that same failure' {
        # The claim is per-process state; leaving it would permanently block the
        # round number. This must NOT regress while fixing the config.
        $repo = Join-Path $env:TEMP "era-cfg-claim-$(New-Guid)"
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        try {
            $null = Invoke-FailingEraRun -Repo $repo
            Test-Path (Join-Path $repo '.external-reviews/cfg-test/round-1-claim.json') |
                Should -BeFalse
        } finally { Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue }
    }

    It 'names the retained config in the failure output' {
        $repo = Join-Path $env:TEMP "era-cfg-msg-$(New-Guid)"
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        try {
            $out = Invoke-FailingEraRun -Repo $repo
            $out | Should -Match 'round-1-config\.json'
        } finally { Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue }
    }

    It 'deletes the config only on success (source check)' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match '\$runSucceeded'
        # The delete must be guarded by the flag, not unconditional.
        $src | Should -Match 'if\s*\(\s*\$runSucceeded[^\r\n]*\$configPath'
    }
}
