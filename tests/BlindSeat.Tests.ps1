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
        ($script:Lines | Where-Object { $_ -match 'docstring body' }).Count     | Should -Be 0
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
        $script:WfSrc | Should -Match '\[hashtable\]\$BundleOverrides = @\{\}'
        $script:WfSrc | Should -Match '\$seatBundle = if \(\$BundleOverrides\.ContainsKey\(\$r\)'
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
