<#
  -BlindSeat: one reviewer sees the code with the narrative removed.

  Proposed by opus in the 2026-09-01 design panel and raised by no other seat.
  The argument: this codebase's comments are unusually strong, and that is
  precisely why a wrong one is dangerous -- it is persuasive. The 150,000-token
  ceiling that was 4x too tight carried a confident account of its own
  derivation, and every reviewer that read it inherited that premise before
  forming its own. A bare number invites "where did this come from?"; an
  explained number suppresses the question.

  Measured on a real 445 KB bundle of this repo: 43% of it was commentary
  (445,036 -> 252,822 bytes, 3,196 comment lines blanked).

  repomix's own --remove-comments cannot do this job here: checked against 1.12.0,
  its StripCommentsManipulator covers 33 extensions and `.ps1` is not one of them,
  and this skill is almost entirely PowerShell.
#>

BeforeAll {
    $script:SkillRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:SkillRoot 'workflow.ps1')

    function New-TestBundle {
        param([string]$Path)
        @'
<file path="src/a.ps1">
  1: # a leading comment
  2: $x = 1   # a trailing comment
  3: <#
  4:   block comment body
  5: #>
  6: Write-Host $x
  7: <# one-liner block #>
  8: $y = 2
</file>
<file path="src/b.py">
  1: # python comment
  2: """
  3: docstring body
  4: """
  5: x = 1
</file>
<file path="src/c.js">
  1: // js comment
  2: /* block
  3:    body */
  4: const a = 1;
</file>
<file path="docs/d.md">
  1: # A Markdown heading
  2: Prose here.
</file>
'@ | Set-Content -LiteralPath $Path -Encoding utf8
    }
}

Describe 'Remove-EraBundleComments' -Tag Unit {

    BeforeAll {
        $script:In  = Join-Path ([System.IO.Path]::GetTempPath()) ("blind-in-"  + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
        $script:Out = Join-Path ([System.IO.Path]::GetTempPath()) ("blind-out-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
        New-TestBundle -Path $script:In
        $null = Remove-EraBundleComments -BundlePath $script:In -OutputPath $script:Out
        $script:Lines = [System.IO.File]::ReadAllLines($script:Out)
    }
    AfterAll { Remove-Item -LiteralPath $script:In, $script:Out -Force -ErrorAction SilentlyContinue }

    It 'preserves EVERY line number' {
        # LOAD-BEARING. era validates file:line citations against the bundle, so a
        # stripped seat whose lines had shifted would have every citation flagged
        # as fabricated -- the feature would poison its own output.
        $before = Get-EraBundleLineCounts -BundlePath $script:In
        $after  = Get-EraBundleLineCounts -BundlePath $script:Out
        $after.Count | Should -Be $before.Count
        foreach ($k in $before.Keys) { $after[$k] | Should -Be $before[$k] -Because "$k must keep its line numbering" }
    }

    It 'keeps the file count and the overall line count identical' {
        ([System.IO.File]::ReadAllLines($script:In)).Count | Should -Be $script:Lines.Count
    }

    It 'blanks whole-line comments in every supported language' {
        ($script:Lines | Where-Object { $_ -match '^\s*1:\s*# a leading comment' }).Count | Should -Be 0
        ($script:Lines | Where-Object { $_ -match 'python comment' }).Count               | Should -Be 0
        ($script:Lines | Where-Object { $_ -match 'js comment' }).Count                   | Should -Be 0
    }

    It 'blanks block comment bodies, and closes on a one-line block' {
        ($script:Lines | Where-Object { $_ -match 'block comment body' }).Count | Should -Be 0
        # Python triple-quotes are NO LONGER handled, deliberately: a line scanner
        # cannot tell an opening docstring delimiter from a closing one, and the
        # common `x = """multi-line"""` shape made the CLOSER look like an opener,
        # started a phantom block, and blanked live code. Three reviewers flagged
        # it. A surviving docstring is the safe failure.
        ($script:Lines | Where-Object { $_ -match 'docstring body' }).Count     | Should -Be 1
        ($script:Lines | Where-Object { $_ -match 'block\s*$|body \*/' }).Count | Should -Be 0
        # `<# one-liner block #>` must NOT open a block that swallows $y = 2.
        ($script:Lines | Where-Object { $_ -match '\$y = 2' }).Count | Should -Be 1
    }

    It 'leaves the code alone' {
        ($script:Lines | Where-Object { $_ -match '\$x = 1' }).Count      | Should -Be 1
        ($script:Lines | Where-Object { $_ -match 'Write-Host \$x' }).Count | Should -Be 1
        ($script:Lines | Where-Object { $_ -match 'const a = 1;' }).Count | Should -Be 1
    }

    It 'does not treat a Markdown heading as a comment' {
        # `#` opens a heading in .md, not a comment. Stripping it would delete the
        # document structure of every design doc in the bundle.
        ($script:Lines | Where-Object { $_ -match 'A Markdown heading' }).Count | Should -Be 1
    }

    It 'leaves a TRAILING comment in place, as documented' {
        # Stripping those needs a real parser; mangling a `#` inside a string
        # literal would corrupt the code under review, which is the worse failure.
        ($script:Lines | Where-Object { $_ -match 'a trailing comment' }).Count | Should -Be 1
    }
}

Describe '-BlindSeat wiring' -Tag Unit {

    BeforeAll {
        $script:EraSrc = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1')
        $script:WfSrc  = Get-Content -Raw (Join-Path $script:SkillRoot 'workflow.ps1')
    }

    It 'gives ONE seat an alternate bundle and leaves the others on the normal one' {
        # Otherwise the round stops being an A/B and becomes a different round.
        #
        # WAS three `Should -Match` assertions on workflow.ps1's source text.
        # Both the 2026-09-01 audit panel and the blinded seat recovered from it
        # named this test by line as one that "passes if the function body is
        # `return` and the string literal remains" -- and it did exactly that
        # while the fallback path it covers was broken. Assert the lookup instead.
        $ov = @{ 'muse-spark' = 'blind.xml' }
        Get-EraSeatBundle -Preset 'muse-spark' -BundleOverrides $ov -BundlePath 'normal.xml' | Should -Be 'blind.xml'
        Get-EraSeatBundle -Preset 'opus'       -BundleOverrides $ov -BundlePath 'normal.xml' | Should -Be 'normal.xml'
        Get-EraSeatBundle -Preset 'deepseek-flash' -BundleOverrides $ov -BundlePath 'normal.xml' | Should -Be 'normal.xml'
        # The seat bundle is what the ThreadJob is actually handed.
        $script:WfSrc | Should -Match '-ArgumentList @\(\$adapterPath, \$seatBundle,'
    }

    It 'builds the stripped bundle AFTER repomix, from the finished bundle' {
        $repoIdx  = $script:EraSrc.IndexOf('instructionFilePath = $promptPath')
        $blindIdx = $script:EraSrc.IndexOf('Remove-EraBundleComments -BundlePath $bundlePath')
        $blindIdx | Should -BeGreaterThan $repoIdx -Because 'the stripped copy must be byte-comparable to what the other seats see'
    }

    It 'warns rather than silently doing nothing when the named seat is not dispatched' {
        $script:EraSrc | Should -Match "is not in this round's reviewer list"
    }

    It 'records why repomix cannot do this job here' {
        # .ps1 is absent from repomix 1.12.0's StripCommentsManipulator, so the
        # native option is a no-op on almost every file in this repo.
        $script:WfSrc | Should -Match 'covers 33 extensions and `\.ps1` is not among them'
    }
}

Describe 'a block opener with code after the closer is not a comment line' -Tag Unit {

    It 'keeps an inline JSDoc type annotation and the code it annotates' {
        # FOUND BY USING THE FEATURE. -BlindSeat on a real JS server blanked
        #     /** @type {*} */ (obj.browserInstance).isConnected()
        # as a whole-line comment, leaving `x &&` dangling above a `) {`. The
        # blinded reviewer opened its review by saying the expression was
        # unreadable. An inline annotation is a block comment whose entire purpose
        # is to sit in front of code on the same line.
        $in  = Join-Path ([System.IO.Path]::GetTempPath()) ("bs-in-"  + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ("bs-out-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
        try {
            @'
<file path="src/m.js">
  1: if (
  2:   a &&
  3:   /** @type {*} */ (obj.inst).isConnected()
  4: ) {
  5: /* a real whole-line block comment */
  6:   go();
  7: }
</file>
'@ | Set-Content -LiteralPath $in -Encoding utf8
            $null = Remove-EraBundleComments -BundlePath $in -OutputPath $out
            $lines = [System.IO.File]::ReadAllLines($out)

            ($lines | Where-Object { $_ -match 'isConnected\(\)' }).Count | Should -Be 1 -Because 'the annotated expression is code'
            ($lines | Where-Object { $_ -match 'a real whole-line block comment' }).Count | Should -Be 0
            ($lines | Where-Object { $_ -match 'go\(\);' }).Count | Should -Be 1
        } finally { Remove-Item -LiteralPath $in, $out -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps code that follows a block-comment CLOSER on the same line' {
        # THE MIRROR CASE, and it shipped in e5d465e WITHOUT a test -- the fix
        # for the opener above got one, the fix for the closer did not, which is
        # the same "twin left behind" shape one level up.
        #
        # `*/ doSomething();` was blanked wholesale by the $inBlock branch, which
        # emitted a bare prefix for every line until the block ended. That
        # deletes live code from the bundle the blinded reviewer is asked to
        # judge.
        $in  = Join-Path ([System.IO.Path]::GetTempPath()) ("bsc-in-"  + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ("bsc-out-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
        try {
            @'
<file path="src/n.js">
  1: /* opens here
  2:    still inside the comment
  3: */ doSomething();
  4: after();
</file>
<file path="src/o.ps1">
  1: <# opens here
  2:    still inside
  3: #> Write-Host 'live'
  4: Get-Thing
</file>
'@ | Set-Content -LiteralPath $in -Encoding utf8
            $null = Remove-EraBundleComments -BundlePath $in -OutputPath $out
            $lines = [System.IO.File]::ReadAllLines($out)

            ($lines | Where-Object { $_ -match 'doSomething\(\);' }).Count      | Should -Be 1 -Because 'code after */ is code'
            ($lines | Where-Object { $_ -match "Write-Host 'live'" }).Count     | Should -Be 1 -Because 'code after #> is code'
            ($lines | Where-Object { $_ -match 'after\(\);' }).Count            | Should -Be 1 -Because 'the block must have CLOSED on line 3'
            ($lines | Where-Object { $_ -match 'Get-Thing' }).Count             | Should -Be 1
            ($lines | Where-Object { $_ -match 'still inside' }).Count          | Should -Be 0
            ($lines | Where-Object { $_ -match 'opens here' }).Count            | Should -Be 0
        } finally { Remove-Item -LiteralPath $in, $out -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the stripper resolves its paths the way the citation reader does' -Tag Unit {

    It 'reads a relative bundle path against the PowerShell location, not the process CWD' {
        # THE TWIN OF THE Get-EraBundleLineCounts FAIL-OPEN (e5d465e finding 8).
        # That function got a Resolve-Path because Test-Path is PowerShell-aware
        # while [System.IO.File] resolves against the PROCESS working directory,
        # which Set-Location and Push-Location do not change. era.ps1 does
        # Push-Location $repoRoot.
        #
        # Remove-EraBundleComments reads the SAME bundle with the SAME API,
        # eleven lines further down the same file, and got nothing. Its failure
        # is louder (a raw FileNotFoundException out of a function whose caller
        # has no catch) but it is the same defect and the same fix.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("bs-cwd-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        $null = New-Item -ItemType Directory -Path $dir
        $oldCwd = [Environment]::CurrentDirectory
        try {
            @'
<file path="src/a.ps1">
  1: # a comment
  2: $x = 1
</file>
'@ | Set-Content -LiteralPath (Join-Path $dir 'b.xml') -Encoding utf8
            Push-Location -LiteralPath $dir
            # The shape era produces: PowerShell is in $dir, the process is not.
            [Environment]::CurrentDirectory = [System.IO.Path]::GetTempPath()
            $null = Remove-EraBundleComments -BundlePath 'b.xml' -OutputPath 'out.xml'
            $lines = Get-Content -LiteralPath (Join-Path $dir 'out.xml')
            ($lines | Where-Object { $_ -match 'a comment' }).Count | Should -Be 0
            ($lines | Where-Object { $_ -match '\$x = 1' }).Count   | Should -Be 1
        } finally {
            [Environment]::CurrentDirectory = $oldCwd
            Pop-Location
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
