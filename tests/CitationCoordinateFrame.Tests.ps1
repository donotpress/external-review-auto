# The citation checker was calling correct citations fabricated.
#
# v2.4 added `file:line` grounding after a field report: "a reviewer cited line
# 5,891 of a 2,834-line file, in two separate rounds". Every citation past the end
# of the named file has been reported since then as one the reviewer invented, and
# the project's stated view of its own panel -- "a correct mechanism wrapped in a
# fabricated example" -- rests partly on that number.
#
# MEASURED 2026-09-01 over 20 real arms (16 A/B cells + a 4-seat panel), 95
# citations past end-of-file:
#
#     75 of 95 (79%) land INSIDE the named file's span in BUNDLE-ABSOLUTE
#     coordinates -- the line numbers the model's own Read tool reported when it
#     opened the bundle from disk.
#
# They are not inventions. They are the right file and the right place, counted
# from the top of the bundle instead of the top of the file, and the translation
# is exact: for a file whose `<file path="...">` header sits at bundle line S,
# bundle line B is in-file line B - S. Verified against the artifacts:
#
#     backends/opencode.ps1:3156   span 2685..3592  ->  prints "471:"
#     runtimes/resolve-model.ps1:1780 span 1611..1845 -> prints "169:", which is
#         `$best = $pool | Sort-Object @{ Expression = 'TierRank' ... }` -- exactly
#         the tie-break line that citation's finding was about.
#
# So the seat the round summary called the least trustworthy was pointing at the
# right code the whole time, and era was throwing the pointer away. Only the
# ONE-COORDINATE-SYSTEM assumption was ever checked; the other frame was never
# considered, which is this project's premise-blindness shape in its own tooling.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/CitationCoordinateFrame.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'workflow.ps1')

    # Two files, so the second one's span starts well past its own line count --
    # the shape that makes a bundle coordinate look like a fabrication.
    $script:Bundle = Join-Path ([System.IO.Path]::GetTempPath()) ("era-cf-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('<file path="src/first.js">')
    for ($i = 1; $i -le 600; $i++) { $null = $sb.AppendLine("${i}: first line $i") }
    $null = $sb.AppendLine('</file>')
    $null = $sb.AppendLine('<file path="src/second.js">')
    for ($i = 1; $i -le 300; $i++) { $null = $sb.AppendLine("${i}: second line $i") }
    $null = $sb.AppendLine('</file>')
    [System.IO.File]::WriteAllText($script:Bundle, $sb.ToString())

    $script:Spans  = Get-EraBundleFileSpans  -BundlePath $script:Bundle
    $script:Counts = Get-EraBundleLineCounts -BundlePath $script:Bundle
}
AfterAll { Remove-Item -LiteralPath $script:Bundle -Force -ErrorAction SilentlyContinue }

Describe 'Get-EraBundleFileSpans' -Tag Unit {

    It 'reports each file''s bundle-absolute span alongside its line count' {
        $script:Spans['src/first.js'].Lines  | Should -Be 600
        $script:Spans['src/second.js'].Lines | Should -Be 300
        # first.js header on line 1, content 2..601, </file> on 602.
        $script:Spans['src/first.js'].Start  | Should -Be 1
        $script:Spans['src/first.js'].End    | Should -Be 602
        $script:Spans['src/second.js'].Start | Should -Be 603
    }

    It 'agrees with Get-EraBundleLineCounts on every file' {
        foreach ($k in $script:Counts.Keys) {
            $script:Spans[$k].Lines | Should -Be $script:Counts[$k] -Because "$k must have one line count, not two"
        }
    }

    It 'translates a bundle-absolute line back to the in-file line exactly' {
        # in-file = bundle - Start. Verified against real artifacts, see header.
        $s = $script:Spans['src/second.js']
        (700 - $s.Start) | Should -Be 97
        $line = (Get-Content -LiteralPath $script:Bundle)[699]   # 0-based
        $line.Trim() | Should -BeLike '97: second line 97*'
    }
}

Describe 'Test-EraResponseCitations separates a wrong FRAME from a wrong NUMBER' -Tag Unit {

    It 'no longer calls a bundle-absolute citation a fabrication' {
        # THE RED. Pre-fix both of these are OutOfRange and the operator is told
        # the reviewer invented them.
        $r = Test-EraResponseCitations -LineCounts $script:Counts -FileSpans $script:Spans -Response @'
1. src/second.js:700 - the retry is unbounded here.
2. src/second.js:99999 - this one really is invented.
'@
        $r.Checked                    | Should -Be 2
        $r.BundleCoordinate.Count     | Should -Be 1
        $r.OutOfRange.Count           | Should -Be 1
        ($r.BundleCoordinate -join ' ') | Should -Match '700'
        ($r.OutOfRange -join ' ')       | Should -Match '99999'
    }

    It 'tells the operator where the citation actually points' {
        # A pointer nobody can follow is the same as no pointer. 700 -> 97.
        $r = Test-EraResponseCitations -LineCounts $script:Counts -FileSpans $script:Spans `
                -Response 'see src/second.js:700 for the bug'
        ($r.BundleCoordinate -join ' ') | Should -Match 'src/second\.js:97\b'
    }

    It 'says a frame mismatch is not a fabrication, in the operator-facing lines' {
        $r = Test-EraResponseCitations -LineCounts $script:Counts -FileSpans $script:Spans `
                -Response 'see src/second.js:700'
        ($r.Lines -join ' ') | Should -Match 'bundle line numbers'
        ($r.Lines -join ' ') | Should -Not -Match 'cannot be real'
    }

    It 'still catches a genuine fabrication, and still says the finding may be real' {
        $r = Test-EraResponseCitations -LineCounts $script:Counts -FileSpans $script:Spans `
                -Response 'see src/first.js:99999'
        $r.OutOfRange.Count       | Should -Be 1
        $r.BundleCoordinate.Count | Should -Be 0
        ($r.Lines -join ' ')      | Should -Match 'may still be real'
    }

    It 'does not reclassify an in-range citation' {
        $r = Test-EraResponseCitations -LineCounts $script:Counts -FileSpans $script:Spans `
                -Response 'src/first.js:12 and src/second.js:250'
        $r.Checked                | Should -Be 2
        $r.OutOfRange.Count       | Should -Be 0
        $r.BundleCoordinate.Count | Should -Be 0
    }

    It 'behaves exactly as before when no spans are supplied' {
        # Back-compat: every existing caller and test passes -LineCounts alone.
        $r = Test-EraResponseCitations -LineCounts $script:Counts -Response 'src/second.js:700'
        $r.OutOfRange.Count       | Should -Be 1
        $r.BundleCoordinate.Count | Should -Be 0
    }
}

Describe 'the shape the measurement was taken on' -Tag Unit {

    # A COMMITTED FIXTURE, not the round artifacts. The first version of this
    # block read `.external-reviews/era-twin-sweep-v28/` directly -- and that
    # directory was destroyed hours later by an unrelated test (see
    # .external-reviews/RECONSTRUCTED-2026-09-01/README.md), which is exactly why
    # a finding worth keeping must not depend on a gitignored artifact that
    # nothing backs up. `tests/fixtures/coordinate-frame-bundle.xml` reproduces
    # the real bundle's SHAPE: four files, spans 1..901, 902..1062, 1063..1297,
    # 1298..2205, so bundle coordinates land far past each file's own length.

    BeforeAll {
        $script:Fx      = Join-Path $script:Root 'tests/fixtures/coordinate-frame-bundle.xml'
        $script:FxSpans = Get-EraBundleFileSpans  -BundlePath $script:Fx
        $script:FxCount = Get-EraBundleLineCounts -BundlePath $script:Fx
    }

    It 'has the spans the destroyed bundle had' {
        $script:FxSpans['tests/AdapterTimeBudget.Tests.ps1'].Start | Should -Be 970
        $script:FxSpans['runtimes/resolve-model.ps1'].Start        | Should -Be 1611
        $script:FxSpans['runtimes/resolve-model.ps1'].Lines        | Should -Be 233
        $script:FxSpans['backends/opencode.ps1'].Start             | Should -Be 2685
        $script:FxSpans['backends/opencode.ps1'].Lines             | Should -Be 906
        $script:FxSpans['workflow.ps1'].End                        | Should -Be 10040
    }

    It 'reclassifies the citations the panel round was scored on' {
        # These are the REAL citations muse-spark produced, reported at the time as
        # "29 of 46 checkable line numbers past the end of the named file". Against
        # a bundle of the same shape they are the bundle's own frame, and the
        # translation lands inside each file.
        $r = Test-EraResponseCitations -LineCounts $script:FxCount -FileSpans $script:FxSpans -Response @'
1. backends/opencode.ps1:3156 - the first-token fallback.
2. runtimes/resolve-model.ps1:1780 - the agy tie-break.
3. tests/AdapterTimeBudget.Tests.ps1:1083 - the pinned floor.
4. backends/opencode.ps1:99999 - nowhere at all.
'@
        $r.Checked                | Should -Be 4
        $r.BundleCoordinate.Count | Should -Be 3 -Because 'three of the four land inside their own file''s span'
        $r.OutOfRange.Count       | Should -Be 1 -Because 'only 99999 is nowhere in either frame'
        # The translations, hand-verified against the original bundle before it was
        # lost: bundle line 3156 printed "471:", bundle line 1780 printed "169:".
        ($r.BundleCoordinate -join ' ') | Should -Match 'opencode\.ps1:471'
        ($r.BundleCoordinate -join ' ') | Should -Match 'resolve-model\.ps1:169'
        ($r.BundleCoordinate -join ' ') | Should -Match 'AdapterTimeBudget\.Tests\.ps1:113'
    }
}
