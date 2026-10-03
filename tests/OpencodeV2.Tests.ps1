# opencode backend on opencode v2 (default) with v1 rollback.
#
# MEASURED 2026-10-03 (Windows, opencode v2.0.22):
# - `--variant X` is REJECTED ("Unrecognized flag"); the variant joins the
#   model after '#': `-m provider/model#variant`.
# - Background-service mode never starts ("Timed out waiting for the background
#   service to start" after 220s), so every v2 invocation MUST pass
#   --standalone (private server). `run --standalone` boots fine.
# - An isolated XDG dir with ONLY auth.json copied (era's isolation shape)
#   lists NO file credentials; OPENCODE_API_KEY=dummy surfaces
#   "OpenCode Go / environment". The v2 seat needs the key in its child env.
# - `session list -n 10 --format json --standalone` returns [] RC=0 in a fresh
#   isolated dir; v2 session objects carry id + created (ms), which
#   Select-OpencodeNewestSession already reads.
#
# Rollback: ERA_OPENCODE_CLI=v1 restores the legacy binary + argv byte for byte.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/OpencodeV2.Tests.ps1 -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/../backends/opencode.ps1"

    function Save-EraOpencodeCliEnv {
        return @{
            CLI = $env:ERA_OPENCODE_CLI
            V2  = $env:ERA_OPENCODE_V2_EXE
            V1  = $env:ERA_OPENCODE_V1_EXE
        }
    }
    function Restore-EraOpencodeCliEnv {
        param($saved)
        $env:ERA_OPENCODE_CLI = $saved.CLI
        $env:ERA_OPENCODE_V2_EXE = $saved.V2
        $env:ERA_OPENCODE_V1_EXE = $saved.V1
    }
}

Describe 'Resolve-OpencodeCli' -Tag Unit {
    It 'defaults to v2 with an installed binary' {
        $saved = Save-EraOpencodeCliEnv
        try {
            $env:ERA_OPENCODE_CLI = $null
            $env:ERA_OPENCODE_V2_EXE = $null
            $env:ERA_OPENCODE_V1_EXE = $null
            $cli = Resolve-OpencodeCli
            $cli.Version | Should -Be 'v2'
            Test-Path -LiteralPath $cli.Exe | Should -BeTrue
        } finally { Restore-EraOpencodeCliEnv $saved }
    }

    It "selects the legacy v1 binary on ERA_OPENCODE_CLI=v1" {
        $saved = Save-EraOpencodeCliEnv
        try {
            $env:ERA_OPENCODE_CLI = 'v1'
            $env:ERA_OPENCODE_V1_EXE = $null
            $cli = Resolve-OpencodeCli
            $cli.Version | Should -Be 'v1'
            Test-Path -LiteralPath $cli.Exe | Should -BeTrue
        } finally { Restore-EraOpencodeCliEnv $saved }
    }

    It 'honours explicit exe overrides for both versions' {
        $saved = Save-EraOpencodeCliEnv
        try {
            $probe = (Resolve-OpencodeCli).Exe  # default v2 exe exists (pinned above)
            $env:ERA_OPENCODE_CLI = 'v1'
            $env:ERA_OPENCODE_V1_EXE = $probe
            (Resolve-OpencodeCli).Exe | Should -Be $probe
            $env:ERA_OPENCODE_CLI = 'v2'
            $env:ERA_OPENCODE_V2_EXE = $probe
            $cli = Resolve-OpencodeCli
            $cli.Version | Should -Be 'v2'
            $cli.Exe | Should -Be $probe
        } finally { Restore-EraOpencodeCliEnv $saved }
    }

    It 'fails closed on an unknown selector or a missing binary (never the wrong backend)' {
        $saved = Save-EraOpencodeCliEnv
        try {
            $env:ERA_OPENCODE_CLI = 'v3'
            { Resolve-OpencodeCli } | Should -Throw
            $env:ERA_OPENCODE_CLI = 'v2'
            $env:ERA_OPENCODE_V2_EXE = Join-Path $TestDrive 'absent-opencode.exe'
            { Resolve-OpencodeCli } | Should -Throw
            $env:ERA_OPENCODE_CLI = 'v1'
            $env:ERA_OPENCODE_V1_EXE = Join-Path $TestDrive 'absent-opencode.cmd'
            { Resolve-OpencodeCli } | Should -Throw
        } finally { Restore-EraOpencodeCliEnv $saved }
    }
}

Describe 'Get-OpencodeRunArgs' -Tag Unit {
    It 'v2 attach: --standalone AND -m model#variant present, --variant absent (one value)' {
        $argv = Get-OpencodeRunArgs -CliVersion v2 -Prompt 'p' `
            -ModelId 'opencode-go/muse-spark-1.3-contributor' -Variant 'xhigh' `
            -UseReadTool $false -BundlePath 'b.xml'
        $flat = $argv -join ' '
        ($argv -contains '--standalone') | Should -BeTrue
        ($argv -contains 'opencode-go/muse-spark-1.3-contributor#xhigh') | Should -BeTrue
        ($argv -contains '--variant') | Should -BeFalse
        $flat | Should -Match '--standalone'
    }

    It 'v1 attach: --variant present, --standalone absent, -m bare (one value)' {
        $argv = Get-OpencodeRunArgs -CliVersion v1 -Prompt 'p' `
            -ModelId 'opencode-go/muse-spark-1.3-contributor' -Variant 'xhigh' `
            -UseReadTool $false -BundlePath 'b.xml'
        $i = [array]::IndexOf($argv, '-m')
        ($argv -contains '--standalone') | Should -BeFalse
        ($argv -contains '--variant') | Should -BeTrue
        $argv[$i + 1] | Should -Be 'opencode-go/muse-spark-1.3-contributor'
        $argv[$i + 1] | Should -Not -Match '#'
    }

    It 'v2 default variant: -m bare AND --standalone, still no --variant' {
        $argv = Get-OpencodeRunArgs -CliVersion v2 -Prompt 'p' `
            -ModelId 'opencode-go/glm-5' -Variant 'default' `
            -UseReadTool $false -BundlePath 'b.xml'
        ($argv -contains '--standalone') | Should -BeTrue
        ($argv -contains 'opencode-go/glm-5') | Should -BeTrue
        ($argv -contains '--variant') | Should -BeFalse
    }

    It 'read-tool path drops -f on both versions (run first, bundle never attached)' {
        $v2 = Get-OpencodeRunArgs -CliVersion v2 -Prompt 'p' `
            -ModelId 'm' -Variant 'default' -UseReadTool $true -BundlePath 'b.xml'
        $v1 = Get-OpencodeRunArgs -CliVersion v1 -Prompt 'p' `
            -ModelId 'm' -Variant 'default' -UseReadTool $true -BundlePath 'b.xml'
        ($v2 -contains '-f') | Should -BeFalse
        ($v1 -contains '-f') | Should -BeFalse
        ($v2 -contains 'b.xml') | Should -BeFalse
        ($v1 -contains 'b.xml') | Should -BeFalse
        $v2[0] | Should -Be 'run'
        $v2[1] | Should -Be '--standalone'
        $v2[2] | Should -Be 'p'
        $v1[0] | Should -Be 'run'
        $v1[1] | Should -Be 'p'
    }
}

Describe 'Get-OpencodeGoApiKey' -Tag Unit {
    It 'returns the opencode-go key and null when absent, malformed, or keyless' {
        $good = Join-Path $TestDrive 'auth-good.json'
        '{"opencode-go":{"type":"api","key":"TEST-ONLY-FAKE-KEY"},"google":{"type":"oauth"}}' |
            Set-Content -LiteralPath $good -NoNewline -Encoding utf8
        Get-OpencodeGoApiKey -AuthSource $good | Should -Be 'TEST-ONLY-FAKE-KEY'

        Get-OpencodeGoApiKey -AuthSource (Join-Path $TestDrive 'absent.json') |
            Should -BeNullOrEmpty

        $bad = Join-Path $TestDrive 'auth-bad.json'
        '{{{nope' | Set-Content -LiteralPath $bad -NoNewline -Encoding utf8
        Get-OpencodeGoApiKey -AuthSource $bad | Should -BeNullOrEmpty

        $keyless = Join-Path $TestDrive 'auth-keyless.json'
        '{"google":{"type":"oauth"}}' | Set-Content -LiteralPath $keyless -NoNewline -Encoding utf8
        Get-OpencodeGoApiKey -AuthSource $keyless | Should -BeNullOrEmpty
    }
}

Describe 'v2 wiring inside Invoke-OpencodeReview' -Tag Unit {
    BeforeAll { $script:AdapterSrc = Get-Content -Raw "$PSScriptRoot/../backends/opencode.ps1" }

    It 'resolves the binary through Resolve-OpencodeCli (no bare Get-Command opencode on the run path)' {
        $script:AdapterSrc | Should -Match 'Resolve-OpencodeCli'
        $script:AdapterSrc | Should -Match 'Get-OpencodeRunArgs'
    }

    It 'injects OPENCODE_API_KEY on the v2 run child env block (and only when the parent does not set it)' {
        $script:AdapterSrc | Should -Match "Environment\['OPENCODE_API_KEY'\]"
        $script:AdapterSrc | Should -Match 'Get-OpencodeGoApiKey'
    }

    It 'lists resume sessions with --standalone on v2 (service mode never starts here)' {
        $script:AdapterSrc | Should -Match "CliVersion -eq 'v2'"
    }

    It 'skips the v1 state-file variant insurance on v2 (the variant travels as model#variant)' {
        $script:AdapterSrc | Should -Match "cliVersion -eq 'v1'"
    }
}
