# Tests for the regexes that are easy to break silently:
#   - Empty-bundle detection (era.ps1)
#   - ANSI escape stripping (claude.ps1, opencode.ps1)

BeforeAll {
    # Pester 5 scopes Describe-level variables to discovery only — runtime
    # It blocks can't see them. Put the regexes in $script: scope so they
    # are visible during both discovery (for -ForEach) and execution.
    $script:FileTagRegex = '<file\s+[^>]*>'
    $script:AnsiStrip    = '\x1b\[\??[0-9;]*[a-zA-Z]'
}

Describe 'Empty-bundle regex (counts <file> opening tags)' {
    Context 'should ABORT on empty bundle' {
        It 'matches 0 in a bundle with no <file> children' {
            $bundle = @'
<files>
This section contains the contents of the repository's files.
</files>
'@
            ([regex]::Matches($bundle, $script:FileTagRegex)).Count | Should -Be 0
        }

        It 'matches 0 in a completely empty string' {
            ([regex]::Matches('', $script:FileTagRegex)).Count | Should -Be 0
        }
    }

    Context 'should PROCEED on bundle with files' {
        It 'matches 1 for a single-file bundle' {
            $bundle = @'
<files>
<file path="foo.py" charCount="100">
print("hello")
</file>
</files>
'@
            ([regex]::Matches($bundle, $script:FileTagRegex)).Count | Should -Be 1
        }

        It 'matches N for an N-file bundle' {
            $bundle = @'
<files>
<file path="a.py" charCount="10">a</file>
<file path="b.py" charCount="10">b</file>
<file path="c.py" charCount="10">c</file>
</files>
'@
            ([regex]::Matches($bundle, $script:FileTagRegex)).Count | Should -Be 3
        }

        It 'does NOT match the <files> wrapper itself' {
            # The wrapper is `<files>` (no whitespace before `>`), the children
            # are `<file path="..." charCount="...">`. The regex requires \s+
            # after `<file` so it can't match the wrapper.
            $bundle = '<files></files>'
            ([regex]::Matches($bundle, $script:FileTagRegex)).Count | Should -Be 0
        }

        It 'matches even when attributes contain unusual chars' {
            $bundle = '<file path="foo bar/baz.py" charCount="42" extra="x">content</file>'
            ([regex]::Matches($bundle, $script:FileTagRegex)).Count | Should -Be 1
        }
    }
}

Describe 'ANSI escape strip regex (CSI SGR + CSI private-mode)' {
    It 'strips standard SGR codes (ESC[0m, ESC[1;31m)' {
        $input = "$([char]27)[1;31mred text$([char]27)[0m normal"
        ($input -replace $script:AnsiStrip, '') | Should -Be 'red text normal'
    }

    It 'strips CSI private-mode enable (ESC[?1003h — mouse tracking)' {
        $input = "$([char]27)[?1003hsome output$([char]27)[?1003l"
        ($input -replace $script:AnsiStrip, '') | Should -Be 'some output'
    }

    It 'strips CSI private-mode cursor hide (ESC[?25l) and show (ESC[?25h)' {
        $input = "$([char]27)[?25lhidden$([char]27)[?25hshown"
        ($input -replace $script:AnsiStrip, '') | Should -Be 'hiddenshown'
    }

    It 'strips single-letter CSI like ESC[K and ESC[J' {
        $input = "before$([char]27)[Kafter$([char]27)[Jdone"
        ($input -replace $script:AnsiStrip, '') | Should -Be 'beforeafterdone'
    }

    It 'leaves non-ANSI text intact' {
        $input = 'hello world 1 2 3 [not-ansi] [0m-without-esc'
        ($input -replace $script:AnsiStrip, '') | Should -Be $input
    }

    It 'is idempotent' {
        $input = "$([char]27)[1;31mtext$([char]27)[?1003h"
        $once = $input -replace $script:AnsiStrip, ''
        $twice = $once -replace $script:AnsiStrip, ''
        $once | Should -Be $twice
    }

    It 'handles mixed SGR and CSI-private in the same string' {
        $input = "$([char]27)[?1003h$([char]27)[1;31mERROR$([char]27)[0m$([char]27)[?1003l clean"
        ($input -replace $script:AnsiStrip, '') | Should -Be 'ERROR clean'
    }
}
