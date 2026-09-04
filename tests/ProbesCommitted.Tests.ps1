# An assessment that says "re-measure before revisiting" must ship the means.
#
# Round-8 (opus) finding 5. docs/assessments/2026-08-14-quote-grounding-declined.md
# declined two proposals on measurement and told the next reader to re-measure --
# while the probes that produced the numbers existed only in a temp directory.
#
# docs/assessments/2026-08-10-prompt-echo-threshold.md already records what that
# costs: "nobody could re-run the calibration because the script was thrown away
# and the corpus was not in the repo." That is how the first echo threshold went
# wrong. The repo re-learned the lesson and broke it again the same day.
#
# This is the guard. It is deliberately shallow -- existence, runnability and
# self-containment -- because a heavier test would rot faster than the thing it
# protects.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/ProbesCommitted.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root      = Split-Path $PSScriptRoot -Parent
    $script:ProbeDir  = Join-Path $script:Root 'tools/probes'
    $script:Assessment = Join-Path $script:Root 'docs/assessments/2026-08-14-quote-grounding-declined.md'
    # THE GLOB WAS THE HOLE. Every assertion below filtered '*.ps1', so the first
    # probe written in anything else would have been waved through by the guard
    # whose whole subject is "the means must ship". opencode-silence.py is that
    # probe -- it reads a 5.5 GB SQLite file and Windows PowerShell has no SQLite
    # provider, so it could not have been PowerShell.
    $script:AllProbes = @(Get-ChildItem -LiteralPath $script:ProbeDir -File |
        Where-Object { $_.Extension -in @('.ps1', '.py') })
}

Describe 'the probes behind a measured decline are committed' -Tag Unit {

    It 'every probe the assessment names exists on disk' {
        Test-Path -LiteralPath $script:Assessment | Should -BeTrue
        $doc = Get-Content -Raw -LiteralPath $script:Assessment
        $named = [regex]::Matches($doc, 'tools/probes/([A-Za-z0-9._-]+\.ps1)') |
            ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
        @($named).Count | Should -BeGreaterThan 0 -Because 'the doc must name its probes by path'
        foreach ($n in $named) {
            Test-Path -LiteralPath (Join-Path $script:ProbeDir $n) |
                Should -BeTrue -Because "the assessment tells the reader to run $n"
        }
    }

    It 'and each one parses, so "re-measure" is not an instruction to debug' {
        foreach ($f in @(Get-ChildItem -LiteralPath $script:ProbeDir -Filter '*.ps1' -File)) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $f.FullName, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because "$($f.Name) must parse cleanly"
        }
    }

    It 'resolves its own root instead of hardcoding a user path' {
        # The probes started life under C:\Users\<me>\AppData\Local\Temp. A
        # committed probe that only runs on one machine is not committed.
        foreach ($f in @(Get-ChildItem -LiteralPath $script:ProbeDir -Filter '*.ps1' -File)) {
            $src = Get-Content -Raw -LiteralPath $f.FullName
            $src | Should -Match '\$PSScriptRoot' -Because "$($f.Name) must locate the repo itself"
            $src | Should -Not -Match 'C:\\Users\\[A-Za-z]' -Because "$($f.Name) must not hardcode a home directory"
        }
    }

    It 'degrades politely when the local corpus is absent' {
        # .external-reviews is gitignored, so on any other checkout it is simply
        # not there. The probe must say so rather than throw.
        foreach ($f in @(Get-ChildItem -LiteralPath $script:ProbeDir -Filter '*.ps1' -File)) {
            (Get-Content -Raw -LiteralPath $f.FullName) | Should -Match 'nothing to measure'
        }
    }
}

Describe 'the same guarantees for a probe that is not PowerShell' -Tag Unit {

    BeforeAll {
        $script:PyProbes = @($script:AllProbes | Where-Object { $_.Extension -eq '.py' })
        # `python3` is not on a Windows PATH; `python` and `py` are.
        $script:Py = @('python', 'py', 'python3') |
            ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
            Select-Object -First 1
    }

    It 'the assessment that names one ships it' {
        $doc = Join-Path $script:Root 'docs/assessments/2026-09-04-stall-threshold-measured.md'
        Test-Path -LiteralPath $doc | Should -BeTrue
        $named = [regex]::Matches((Get-Content -Raw -LiteralPath $doc),
            'tools/probes/([A-Za-z0-9._-]+\.(?:ps1|py))') |
            ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
        @($named).Count | Should -BeGreaterThan 0 -Because 'the doc must name its probe by path'
        foreach ($n in $named) {
            Test-Path -LiteralPath (Join-Path $script:ProbeDir $n) |
                Should -BeTrue -Because "the assessment tells the reader to run $n"
        }
    }

    It 'each one compiles, so "re-measure" is not an instruction to debug' {
        if (-not $script:Py) {
            Set-ItResult -Skipped -Because 'no python interpreter on PATH; the syntax check needs one'
            return
        }
        # ast.parse rather than py_compile: same syntax check, and it does not
        # drop a __pycache__ directory into the repo every time the suite runs.
        $parse = 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())'
        foreach ($f in $script:PyProbes) {
            $out = & $script:Py.Source -c $parse $f.FullName 2>&1
            $LASTEXITCODE | Should -Be 0 -Because "$($f.Name) must parse cleanly: $out"
        }
    }

    It 'resolves its own inputs instead of hardcoding a user path' {
        foreach ($f in $script:PyProbes) {
            (Get-Content -Raw -LiteralPath $f.FullName) |
                Should -Not -Match 'C:\\Users\\[A-Za-z]' -Because "$($f.Name) must not hardcode a home directory"
        }
    }

    It 'degrades politely when the local corpus is absent' {
        # Same rule as the PowerShell probes: the corpus is not in the repo, so on
        # another checkout it is simply not there.
        foreach ($f in $script:PyProbes) {
            (Get-Content -Raw -LiteralPath $f.FullName) | Should -Match 'nothing to measure'
        }
    }

    It 'and the guard above can actually see them' {
        # Non-vacuity: the original glob was '*.ps1' only, so this Describe would
        # have been empty and green.
        @($script:PyProbes).Count | Should -BeGreaterThan 0
    }
}
