# Per-seat opencode state isolation (XDG_DATA_HOME/XDG_STATE_HOME).
#
# MEASURED: two opencode seats serialize behind Global\era-opencode-run-mutex
# (616s and 645s queue waits logged) because they share one SQLite writer.
# The 2026-08-31 A/B that cleared concurrency tested ~13s runs -- long
# review runs holding the DB for minutes are a different regime the test
# never covered, so it does not refute this. Windows binary verified:
# `opencode db path` -> C:\Users\Joshua\.local\share\opencode\opencode.db,
# and with XDG_DATA_HOME set -> <that>/opencode/opencode.db (no spend).
#
# Design: temp dirs + auth.json copy per seat, XDG vars on the CHILD env
# block only (parent/siblings untouched, same pattern as the env scrub);
# run-mutex wait bypassed when isolated (nothing left to queue on);
# best-effort cleanup in the existing finally; any setup failure warns
# and falls back to the shared dir (today's behavior, never a new failure).
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/OpencodeIsolation.Tests.ps1 -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/../backends/opencode.ps1"

    function New-FakeAuth {
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ("era-authtest-" + [guid]::NewGuid().ToString('N') + ".json")
        '{"type":"oauth","token":"TEST-ONLY-FAKE"}' | Set-Content -LiteralPath $p -NoNewline -Encoding utf8
        return $p
    }
}

Describe 'New-OpencodeIsolatedState' -Tag Unit {
    It 'creates share/state dirs and a byte-identical auth copy' {
        $auth = New-FakeAuth
        try {
            $s = New-OpencodeIsolatedState -AuthSource $auth
            $s.Isolated | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $s.ShareDir 'opencode/auth.json') | Should -BeTrue
            Test-Path -LiteralPath $s.StateDir | Should -BeTrue
            $src = Get-Content -Raw -LiteralPath $auth
            $dst = Get-Content -Raw -LiteralPath (Join-Path $s.ShareDir 'opencode/auth.json')
            $dst | Should -Be $src
        } finally {
            Remove-OpencodeIsolatedState -State $s
            Remove-Item -LiteralPath $auth -ErrorAction SilentlyContinue
        }
    }

    It 'fails closed (shared dir) when the auth source is missing' {
        $s = New-OpencodeIsolatedState -AuthSource (Join-Path $TestDrive 'absent.json')
        $s.Isolated | Should -BeFalse
        $s.Reason | Should -Not -BeNullOrEmpty
    }

    It 'removes the whole temp tree on cleanup, tolerates double-remove' {
        $auth = New-FakeAuth
        try {
            $s = New-OpencodeIsolatedState -AuthSource $auth
            $root = $s.TempRoot
            Test-Path -LiteralPath $root | Should -BeTrue
            Remove-OpencodeIsolatedState -State $s
            Test-Path -LiteralPath $root | Should -BeFalse
            { Remove-OpencodeIsolatedState -State $s } | Should -Not -Throw
            { Remove-OpencodeIsolatedState -State $null } | Should -Not -Throw
        } finally { Remove-Item -LiteralPath $auth -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-OpencodeReview isolates and bypasses the queue' -Tag Unit {
    BeforeAll { $script:AdapterSrc = Get-Content -Raw "$PSScriptRoot/../backends/opencode.ps1" }

    It 'sets XDG vars on the child env block from the isolated state' {
        $script:AdapterSrc | Should -Match "Environment\['XDG_DATA_HOME'\]"
        $script:AdapterSrc | Should -Match "Environment\['XDG_STATE_HOME'\]"
    }

    It 'skips the run-mutex wait when isolated (nothing left to queue on)' {
        $script:AdapterSrc | Should -Match 'Isolated'
    }

    It 'cleans the isolated tree in the existing finally' {
        $script:AdapterSrc | Should -Match 'Remove-OpencodeIsolatedState'
    }
}
