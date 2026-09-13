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

Describe 'Get-OpencodeSeatState' -Tag Unit {
    It 'creates persistent dirs and a byte-identical auth copy' {
        $auth = New-FakeAuth
        $base = Join-Path $TestDrive 'opstate'
        $map = Join-Path $TestDrive 'map.json'
        try {
            $s = Get-OpencodeSeatState -Preset 'deepseek-flash' -StateBase $base -AuthSource $auth -MapPath $map
            $s.Mode | Should -Be 'persistent'
            Test-Path -LiteralPath (Join-Path $s.ShareDir 'opencode/auth.json') | Should -BeTrue
            Test-Path -LiteralPath $s.StateDir | Should -BeTrue
            $src = Get-Content -Raw -LiteralPath $auth
            $dst = Get-Content -Raw -LiteralPath (Join-Path $s.ShareDir 'opencode/auth.json')
            $dst | Should -Be $src
            $s.SessionId | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $auth -ErrorAction SilentlyContinue }
    }

    It 'fails closed to shared when the auth source is missing' {
        $s = Get-OpencodeSeatState -Preset 'x' `
            -StateBase (Join-Path $TestDrive 'opstate2') `
            -AuthSource (Join-Path $TestDrive 'absent.json') `
            -MapPath (Join-Path $TestDrive 'map2.json')
        $s.Mode | Should -Be 'shared'
        $s.Reason | Should -Not -BeNullOrEmpty
    }

    It 'resumes the mapped session id' {
        $map = Join-Path $TestDrive 'map3.json'
        Set-OpencodeSessionMap -MapPath $map -Preset 'muse-spark' -SessionId 'ses_abc'
        $auth = New-FakeAuth
        try {
            $s = Get-OpencodeSeatState -Preset 'muse-spark' `
                -StateBase (Join-Path $TestDrive 'opstate3') `
                -AuthSource $auth -MapPath $map
            $s.Mode | Should -Be 'persistent'
            $s.SessionId | Should -Be 'ses_abc'
        } finally { Remove-Item -LiteralPath $auth -ErrorAction SilentlyContinue }
    }

    It 'removes the whole temp tree on cleanup, tolerates double-remove' {
        $d = Join-Path $TestDrive 'treegone'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Remove-OpencodeIsolatedState -State @{ TempRoot = $d }
        Test-Path -LiteralPath $d | Should -BeFalse
        { Remove-OpencodeIsolatedState -State @{ TempRoot = $d } } | Should -Not -Throw
        { Remove-OpencodeIsolatedState -State $null } | Should -Not -Throw
    }
}

Describe 'Invoke-OpencodeReview isolates and bypasses the queue' -Tag Unit {
    BeforeAll { $script:AdapterSrc = Get-Content -Raw "$PSScriptRoot/../backends/opencode.ps1" }

    It 'sets XDG vars on the child env block from the isolated state' {
        $script:AdapterSrc | Should -Match "Environment\['XDG_DATA_HOME'\]"
        $script:AdapterSrc | Should -Match "Environment\['XDG_STATE_HOME'\]"
    }

    It 'skips the run-mutex wait unless fully shared (nothing left to queue on)' {
        $script:AdapterSrc | Should -Match "Mode -ne 'shared'"
    }

    It 'cleans the isolated tree in the existing finally' {
        $script:AdapterSrc | Should -Match 'Remove-OpencodeIsolatedState'
    }
}

Describe 'persistent per-preset state (session reuse)' -Tag Unit {
    It 'round-trips the session map and prunes history to 5' {
        $map = Join-Path $TestDrive 'session-map.json'
        Set-OpencodeSessionMap -MapPath $map -Preset 'deepseek-flash' -SessionId 'ses_aaa'
        foreach ($i in 1..7) {
            Set-OpencodeSessionMap -MapPath $map -Preset 'deepseek-flash' -SessionId ("ses_$i")
        }
        $m = Get-OpencodeSessionMap -MapPath $map
        $m['deepseek-flash'].current | Should -Be 'ses_7'
        @($m['deepseek-flash'].history).Count | Should -BeLessOrEqual 5
    }

    It 'reads empty for missing or malformed maps (cold start, not failure)' {
        (Get-OpencodeSessionMap -MapPath (Join-Path $TestDrive 'absent.json')).Count | Should -Be 0
        $bad = Join-Path $TestDrive 'bad.json'
        '{{{nope' | Set-Content -LiteralPath $bad -NoNewline
        (Get-OpencodeSessionMap -MapPath $bad).Count | Should -Be 0
    }

    It 'picks the newest session created after run start, else null' {
        $json = @'
[{"id":"ses_old","title":"t","updated":1000,"created":1000},
 {"id":"ses_new","title":"t","updated":3000,"created":3000}]
'@
        Select-OpencodeNewestSession -SessionsJson $json -SinceMs 2000 | Should -Be 'ses_new'
        Select-OpencodeNewestSession -SessionsJson $json -SinceMs 9999 | Should -BeNullOrEmpty
        Select-OpencodeNewestSession -SessionsJson 'not json' -SinceMs 0 | Should -BeNullOrEmpty
    }

    It 'forks the mapped session (private copy, shared parent never mutates)' {
        $src = Get-Content -Raw "$PSScriptRoot/../backends/opencode.ps1"
        $src | Should -Match "'--fork'"
    }

    It 'falls back to a plain cold run when mapping fails' {
        $src = Get-Content -Raw "$PSScriptRoot/../backends/opencode.ps1"
        $src | Should -Match 'Get-OpencodeSessionMap'
    }
}
