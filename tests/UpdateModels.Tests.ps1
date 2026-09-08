# Tests for `runtimes/update-models.ps1` provider discovery + summary counts.
#
# 2026-09-08, seventh era finding: `era.ps1 -Command update-models` printed
# "Found providers: T" on a box with six credentials and "opencode-go : 1 1 1..."
# per-provider counts, then exited 0 having merged nothing. Two independent
# causes in one function:
#
#   (a) The boundary regex `^[\└┌├]` was built against TERMINAL output, but era
#       captures through a pipe, where opencode.exe emits an ASCII-fallback
#       alphabet (corner `T`, separator `|`, footer em-dash, bullet U+2022) and
#       Windows-pwsh ibm437 decoding further mangles non-ASCII bytes (U+2022 ->
#       three chars). So no boundary ever matched, every line fell into the
#       collection branch, the six real providers were lost (bullet strip missed)
#       and the `T  Environment` section header was collected as provider "T".
#       Fixtures below are built from PIPED bytes (od-verified), never terminal
#       output -- testing the terminal alphabet proves the wrong thing.
#   (b) The summary counter `$entry.PSObject.Properties.Count` member-enumerates
#       on PSMemberInfoIntegratingCollection: one `1` per model, so 15 models
#       print as fifteen 1s. The count must be `@(...).Count`.
#
# pin: run with  pwsh -Command "Invoke-Pester -Path tests/UpdateModels.Tests.ps1"

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtimes/update-models.ps1')

    $script:Esc = [char]27

    # Faithful PIPED output of `opencode.exe providers list` (raw bytes captured
    # with od: fallback alphabet + SGR wraps, no trailing reset, LF endings).
    # Bullet here is U+2022 as emitted; see the mangled-bullet test for what
    # Windows-pwsh ibm437 decoding makes of it before the parser ever sees it.
    function script:New-PipedProvidersFixture {
        param([string]$Bullet = "•")
        $e = $script:Esc
        $lines = @(
            "${e}[90mT${e}[39m  Credentials ${e}[90m~/.local/share/opencode/auth.json"
            ""
            "${e}[90m|${e}[39m"
            "${e}[34m${Bullet}${e}[39m  Nvidia ${e}[90mapi"
            "${e}[90m|${e}[39m"
            "${e}[34m${Bullet}${e}[39m  Google ${e}[90moauth"
            "${e}[90m|${e}[39m"
            "${e}[34m${Bullet}${e}[39m  MiniMax (minimax.io) ${e}[90mapi"
            "${e}[90m|${e}[39m"
            "${e}[34m${Bullet}${e}[39m  OpenCode Go ${e}[90mapi"
            "${e}[90m|${e}[39m"
            "${e}[34m${Bullet}${e}[39m  MiniMax Token Plan (minimax.io) ${e}[90mapi"
            "${e}[90m|${e}[39m"
            "${e}[34m${Bullet}${e}[39m  MiniMax (minimaxi.com) ${e}[90mapi"
            "${e}[90m|${e}[39m"
            "${e}[90m—${e}[39m  6 credentials"
            ""
            "${e}[90mT${e}[39m  Environment"
            "${e}[90m|${e}[39m"
            "${e}[34m${Bullet}${e}[39m  Google ${e}[90mGOOGLE_API_KEY"
            "${e}[90m|${e}[39m"
            "${e}[34m${Bullet}${e}[39m  Google ${e}[90mGEMINI_API_KEY"
            "${e}[90m|${e}[39m"
            "${e}[90m—${e}[39m  2 environment variables"
            ""
        )
        return $lines
    }

    # TERMINAL alphabet (true UTF-8 box drawing, as `| cat -A` shows on a tty):
    # the old code was built against this and must keep working.
    function script:New-TerminalProvidersFixture {
        $lines = @(
            "┌  Credentials ~/.local/share/opencode/auth.json"
            "│"
            "●  Nvidia api"
            "│"
            "●  Google oauth"
            "│"
            "●  MiniMax (minimax.io) api"
            "│"
            "●  OpenCode Go api"
            "│"
            "●  MiniMax Token Plan (minimax.io) api"
            "│"
            "●  MiniMax (minimaxi.com) api"
            "│"
            "└  6 credentials"
            ""
        )
        return $lines
    }

    $script:ExpectedProviders = @(
        'Nvidia', 'Google', 'MiniMax (minimax.io)', 'OpenCode Go',
        'MiniMax Token Plan (minimax.io)', 'MiniMax (minimaxi.com)'
    )
}

Describe 'Resolve-OpencodeProviderNames' {
    It 'finds all six providers in piped fallback-alphabet output' {
        $names = @(Resolve-OpencodeProviderNames -Lines (New-PipedProvidersFixture))
        $names | Should -BeExactly $script:ExpectedProviders
    }

    It 'finds them when the bullet arrives codepage-mangled (ibm437 receipt)' {
        # MEASURED on Windows-pwsh: U+2022 (e2 80 a2) decoded as ibm437 arrives
        # as three chars U+0393 U+00C7 U+00F3, which the old [●○•] strip missed.
        $mangledBullet = [string][char[]](0x0393, 0x00C7, 0x00F3)
        $names = @(Resolve-OpencodeProviderNames -Lines (New-PipedProvidersFixture -Bullet $mangledBullet))
        $names | Should -BeExactly $script:ExpectedProviders
    }

    It 'finds the same six in terminal-alphabet output (old behavior kept)' {
        $names = @(Resolve-OpencodeProviderNames -Lines (New-TerminalProvidersFixture))
        $names | Should -BeExactly $script:ExpectedProviders
    }

    It 'never mistakes a section header for a provider (the T tell)' {
        $names = @(Resolve-OpencodeProviderNames -Lines (New-PipedProvidersFixture))
        $names | Should -Not -Contain 'T'
        @($names | Where-Object { $_.Length -le 1 }).Count | Should -Be 0
    }

    It 'finds more than one provider on a six-credential box' {
        # A count of 1 from a machine with six credentials is the tell that
        # discovery collapsed; fail here, not as a silent no-op merge later.
        @(Resolve-OpencodeProviderNames -Lines (New-PipedProvidersFixture)).Count | Should -BeGreaterThan 1
    }
}

Describe 'Get-OpencodeProviderModelCount' {
    It 'returns the number of models, not one 1 per model' {
        # Shape as ConvertFrom-Json yields for backends/_registry.json values:
        # PSCustomObject whose .PSObject.Properties is a
        # PSMemberInfoIntegratingCollection (member-enumerates .Count).
        $entry = [pscustomobject]@{}
        foreach ($m in @('a','b','c','d','e','f','g','h','i','j','k','l','m','n','o')) {
            $entry | Add-Member -MemberType NoteProperty -Name $m -Value @{ display = $m }
        }
        Get-OpencodeProviderModelCount -Entry $entry | Should -Be 15
    }

    It 'returns an int for a single-model provider (no accidental array)' {
        $entry = [pscustomobject]@{ only = @{ display = 'only' } }
        $c = Get-OpencodeProviderModelCount -Entry $entry
        $c | Should -Be 1
        $c | Should -BeOfType [int]
    }

    It 'still counts hashtable entries (fresh-fetch shape) via .Count' {
        $entry = @{ a = 1; b = 2; c = 3 }
        Get-OpencodeProviderModelCount -Entry $entry | Should -Be 3
    }
}
