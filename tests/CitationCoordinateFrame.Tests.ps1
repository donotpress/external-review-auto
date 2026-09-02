# The citation checker was calling correct citations fabricated.
#
# v2.4 added `file:line` grounding after a field report: "a reviewer cited line
# 5,891 of a 2,834-line file, in two separate rounds". Every citation past the end
# of the named file has been reported since then as one the reviewer invented, and
# the project's stated view of its own panel -- "a correct mechanism wrapped in a
# fabricated example" -- rests partly on that number.
#
# MEASURED over the ARCHIVE of every round this skill has run against itself --
# 62 reviewer-rounds, 1,570 citations, months, five models:
#
#     128 of 155 citations past end-of-file (83%) land INSIDE the named file's
#     span in BUNDLE-ABSOLUTE coordinates -- the line numbers the model's own
#     Read tool reported when it opened the bundle from disk. Only 27 resolve in
#     neither frame.
#
# (The fix was built on a 20-arm slice of one afternoon giving 79%. The archive
# figure supersedes it; a stale number in code is the thing this release is about.)
#
# AND THE TWO FRAMES OVERLAP, which this cannot see: 203 of those 1,570 (12.9%)
# are numbers valid in BOTH frames for the same file. 83% is a rate over the
# FLAGGED set, not over frame errors.
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
        # WAS `Should -Not -Match 'cannot be real'`, which guarded nothing: that
        # string appears nowhere in Test-EraResponseCitations and never has, so it
        # could not fail for any implementation (opus, v2.8.2 panel). Assert the
        # words the function DOES emit for a real fabrication are absent here.
        ($r.Lines -join ' ') | Should -Not -Match 'point past the end of the cited file'
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

    It 'CANNOT see a frame error where the two frames overlap — the known blind spot' {
        # THE LIMIT OF THIS WHOLE FEATURE, pinned so nobody reads the 83% as
        # "83% of frame errors are handled". Raised by the opus seat of the
        # v2.8.2 panel, which called that figure "a coincidence rate over an
        # already-flagged set". It is right.
        #
        # For a file whose span starts at S with N printed lines, every bundle
        # coordinate in S+1..min(End,N) is ALSO a valid in-file line for the same
        # file. Nothing distinguishes them without reading the cited line's
        # content. Measured over the 62-round archive: 203 of 1,570 citations
        # (12.9%) sit in that overlap.
        #
        # first.js spans 1..602 with 600 lines, so bundle line 250 is also
        # in-file line 250. A read-tool seat meaning bundle 250 (= in-file 249)
        # is accepted silently and points one line off.
        $r = Test-EraResponseCitations -LineCounts $script:Counts -FileSpans $script:Spans `
                -Response 'src/first.js:250'
        $r.Checked                | Should -Be 1
        $r.BundleCoordinate.Count | Should -Be 0 -Because 'the overlap is invisible; this documents it rather than claiming otherwise'
        $r.OutOfRange.Count       | Should -Be 0

        # The overlap is a property of the geometry, so it is computed, not guessed.
        $sp = $script:Spans['src/first.js']
        $overlap = [Math]::Max(0, [Math]::Min($sp.End, $sp.Lines) - $sp.Start)
        $overlap | Should -BeGreaterThan 0 -Because 'a file whose span starts before its own length has an ambiguous window'
    }

    It 'behaves exactly as before when no spans are supplied' {
        # Back-compat: every existing caller and test passes -LineCounts alone.
        $r = Test-EraResponseCitations -LineCounts $script:Counts -Response 'src/second.js:700'
        $r.OutOfRange.Count       | Should -Be 1
        $r.BundleCoordinate.Count | Should -Be 0
    }
}

Describe 'a citation the checker cannot see is not a clean review' -Tag Unit {

    # THE CHECKER'S OWN BLIND SPOT, and it sat on the seat the frame problem is
    # about. `Test-EraResponseCitations` matched `path:207` and not `path:L207`.
    # Across the 108-response archive, 138 citations were in the L form, EVERY
    # one of them from an agy seat (`gemini`, `gemini-pro-high`) -- the disk-read
    # path, i.e. the seats whose own reader produces bundle-frame numbers. Seven
    # distinct responses scored `Checked=0`, which era reports identically to a
    # review with nothing wrong in it.
    #
    # MEASURED, re-scoring the whole archive with `L?` accepted:
    #
    #     seat              checked        flagged past-EOF   of those, frame
    #     gemini            190 -> 248     11 -> 28           11 -> 28
    #     gemini-pro-high    16 ->  22     16 -> 22           11 -> 17
    #     (every other seat unchanged)
    #
    # Every newly visible flag on `gemini` is a frame error, 28 of 28, and no seat
    # gained a single new NON-frame flag: gemini-pro-high's residue is 5 before
    # and 5 after. So this widens coverage without inventing fabrications -- and
    # it means the v2.8.2 archive measurement undercounted the `gemini` seat's
    # FLAGGED citations by ~61% (11 of the 28 that exist; checked was low by ~23%,
    # 190 of 248) and both agy seats together by ~46% (27 of 50) -- the wider
    # number for the wider claim, which the first cut of this comment mixed up
    # because of the checker's regex rather than because of the models.

    BeforeAll {
        $script:LBundle = Join-Path ([System.IO.Path]::GetTempPath()) ("era-lf-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
        $sb = [System.Text.StringBuilder]::new()
        $null = $sb.AppendLine('<file path="src/only.js">')
        for ($i = 1; $i -le 40; $i++) { $null = $sb.AppendLine("${i}: line $i") }
        $null = $sb.AppendLine('</file>')
        [System.IO.File]::WriteAllText($script:LBundle, $sb.ToString())
        $script:LCounts = Get-EraBundleLineCounts -BundlePath $script:LBundle
    }

    AfterAll { Remove-Item -LiteralPath $script:LBundle -Force -ErrorAction SilentlyContinue }

    It 'counts a GitHub-anchor citation' {
        $r = Test-EraResponseCitations -Response 'see [only.js:L12](x#L12)' -LineCounts $script:LCounts
        $r.Checked | Should -Be 1
    }

    It 'counts the plain form exactly as before' {
        $r = Test-EraResponseCitations -Response 'see only.js:12' -LineCounts $script:LCounts
        $r.Checked | Should -Be 1
    }

    It 'does not count the same line twice when both forms appear' {
        # The dedupe key is path + line NUMBER, so `only.js:L12` and `only.js:12`
        # are one citation. They have to be: a model that writes the anchor form
        # writes the same number in the link text.
        $r = Test-EraResponseCitations -Response '[only.js:12](x#only.js:L12)' -LineCounts $script:LCounts
        $r.Checked | Should -Be 1
    }

    It 'still flags an anchor-form citation past end of file' {
        $r = Test-EraResponseCitations -Response 'only.js:L999' -LineCounts $script:LCounts
        $r.Checked                | Should -Be 1
        @($r.OutOfRange).Count    | Should -Be 1
    }

    It 'does not invent a citation out of an L that is not a line number' {
        # `L?` must not turn arbitrary text into a citation. The digits are still
        # required, and so is the file extension in front of the colon.
        $r = Test-EraResponseCitations -Response 'only.js:Lorem ipsum, and Ltd:L4' -LineCounts $script:LCounts
        $r.Checked             | Should -Be 0
        @($r.Unresolved).Count | Should -Be 0
    }

    It 'reports Checked=0 for a response era would otherwise call clean' {
        # The failure this closes: a review whose every citation is invisible
        # scores zero checked and zero flagged, which is the same output as a
        # review with nothing wrong in it. Pinned against a file NOT in the
        # bundle so the count is the only signal.
        $r = Test-EraResponseCitations -Response 'nowhere.js:L12' -LineCounts $script:LCounts
        $r.Checked             | Should -Be 0
        @($r.Unresolved).Count | Should -Be 1 -Because 'an unknown path is reported quietly, not silently'
    }
}

Describe 'every adapter that hands the bundle to a TOOL says which frame to cite' -Tag Unit {

    # ONE RULE, THREE ADAPTERS -- the shape this project keeps getting wrong.
    #
    # The frame mismatch is created wherever a model opens the bundle with its
    # own tooling, because that tooling counts from the top of the merged file.
    # v2.8.1 fixed the instruction on the opencode read-tool path only, on
    # evidence from one afternoon. The archive says that was half the job:
    #
    #     gemini (agy, disk-read)   11 of 11 flagged citations were the frame
    #     gemini-pro-high (agy)     11 of 16         <- ADDED 2026-09-02
    #     deepseek (opencode)       50 of 50
    #     deepseek-flash            9 of 9
    #     muse-spark                47 of 57
    #     opus (claude, stdin)      0 of 12          <- never uses it
    #
    # The gemini-pro-high row was missing, and it is the same backend on the same
    # delivery mode. Re-derived over all 62 archived seat-responses on 2026-09-02;
    # every other row reproduced exactly. "The agy seat is 11 of 11" is a fact
    # about ONE PRESET, not about the backend: the other agy preset in the corpus
    # leaves five flagged citations the frame does not explain.
    #
    # agy hands the model a PATH and lets it read the file, exactly like the
    # read-tool path, and nobody had told it which numbers to cite.
    #
    # claude is deliberately excluded and that is the measurement above, not an
    # oversight: the bundle IS its prompt, so it only ever sees the per-file
    # numbers printed in the text, and 755 opus citations produced zero frame
    # drift. An instruction there would be noise about a problem it cannot have.

    BeforeAll {
        . (Join-Path $script:Root 'backends/agy.ps1')
        . (Join-Path $script:Root 'backends/opencode.ps1')
        $script:ClaudeSrc = Get-Content -Raw (Join-Path $script:Root 'backends/claude.ps1')
    }

    It 'tells the opencode read-tool seat' {
        # CALLED, NOT GREPPED -- and it took a second panel to finish the job.
        # The 2026-09-02 commit moved agy's prompt behind Get-AgyReviewPrompt so
        # the assertion below could stop grepping source, wrote down exactly why
        # ("a grep would pass on a comment while the live prompt said anything at
        # all"), and then left THIS assertion grepping backends/opencode.ps1 five
        # lines above it. One rule, two adapters, one of them fixed, inside the
        # commit whose subject was that shape. Named by the opus seat of the panel
        # on it; opencode's prompts now live in Get-OpencodeReviewPrompt.
        $p = Get-OpencodeReviewPrompt -Mode 'read-tool' -BundlePath 'C:\tmp\b.xml'
        $p | Should -Match 'CITATIONS:'
        $p | Should -Match 'not the line number your Read tool reports'
        $p | Should -Match ([regex]::Escape('C:\tmp\b.xml'))
    }

    It 'does NOT give the read-tool instruction to the attach seat' {
        # The prompt has to track the delivery mode. On the attach path opencode
        # has already inlined the file, so "use the Read tool" would be an
        # instruction to go and re-open something the model was handed -- the
        # prompt/delivery contradiction F12 was about, one adapter over.
        $a = Get-OpencodeReviewPrompt -Mode 'attach'
        $a | Should -Not -Match 'Use the Read tool'
        $a | Should -Match '(?i)do not call any tools'
        # ...and the read-tool prompt must not tell the model to avoid tools.
        $r = Get-OpencodeReviewPrompt -Mode 'read-tool' -BundlePath 'C:\tmp\b.xml'
        $r | Should -Not -Match '(?i)do not call any tools'
        $r | Should -Match '(?i)Use the Read tool'
    }

    It 'tells the agy disk-read seat, which reads the bundle the same way' {
        # ASSERTED ON THE PROMPT, NOT ON THE SOURCE TEXT. This used to grep
        # agy.ps1 for the words, which was already weak and became actively
        # misleading the moment the adapter's docstring started QUOTING the old
        # prompt to explain why it was replaced: the grep would then pass on a
        # comment while the live prompt said anything at all. Call the function.
        $p = Get-AgyReviewPrompt -BundlePath 'C:\tmp\b.xml' -DispatchId 'd1'
        $p | Should -Match 'CITATIONS:'
        $p | Should -Match "file's OWN line number"
        $p | Should -Match 'not the line number your file reader reports'
    }

    It 'does NOT tell the claude stdin seat, and records why' {
        $script:ClaudeSrc | Should -Not -Match 'CITATIONS:'
        $script:ClaudeSrc | Should -Match 'the bundle IS the prompt'
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
        # The translations, hand-verified against the original bundle -- which is
        # still on this machine under the moved archive and can be re-checked:
        # bundle line 3156 printed "471:", bundle line 1780 printed "169:".
        ($r.BundleCoordinate -join ' ') | Should -Match 'opencode\.ps1:471'
        ($r.BundleCoordinate -join ' ') | Should -Match 'resolve-model\.ps1:169'
        ($r.BundleCoordinate -join ' ') | Should -Match 'AdapterTimeBudget\.Tests\.ps1:113'
    }
}
