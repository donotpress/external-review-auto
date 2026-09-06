# Unit tests for the cmdc process-spawn backend.
#
# Offline only. Nothing here spawns wsl.exe or bills a model; the live behaviour
# is recorded in docs/assessments/2026-09-06-tmux-transport-findings.md §8.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'backends/cmdc.ps1')
}

Describe 'ConvertTo-EraCmdcWslPath' -Tag Unit {

    It 'maps <win> to <expected>' -ForEach @(
        @{ win = 'C:\Users\Joshua\AppData\Local\Temp\x'; expected = '/mnt/c/Users/Joshua/AppData/Local/Temp/x' }
        @{ win = 'D:\a\b';                               expected = '/mnt/d/a/b' }
        @{ win = 'c:/already/forward';                   expected = '/mnt/c/already/forward' }
    ) {
        ConvertTo-EraCmdcWslPath -WindowsPath $win | Should -Be $expected
    }

    It 'leaves a path that is already WSL-shaped alone' {
        # Guards the tests above against a mapper that rewrites everything.
        ConvertTo-EraCmdcWslPath -WindowsPath '/mnt/c/already' | Should -Be '/mnt/c/already'
    }

    It 'lowercases only the drive letter, not the path' {
        # A DrvFs path is case-preserving; mangling the rest would silently point
        # the seat at a directory that does not exist.
        ConvertTo-EraCmdcWslPath -WindowsPath 'C:\Users\Joshua\MixedCase' |
            Should -Be '/mnt/c/Users/Joshua/MixedCase'
    }
}

Describe 'ConvertTo-EraCmdcQuoted' -Tag Unit {

    It 'wraps a plain value in single quotes' {
        ConvertTo-EraCmdcQuoted -Value 'abc' | Should -Be "'abc'"
    }

    It 'neutralises the metacharacters that broke the WSL boundary' {
        # These are the exact characters that produced four separate-looking bugs
        # (references/wsl-argument-boundary.md): a comment marker, a command
        # separator, an expansion, and a backslash escape. Inside single quotes
        # bash expands none of them.
        $q = ConvertTo-EraCmdcQuoted -Value 'a#b;c$d`e\f'
        $q | Should -Be "'a#b;c`$d``e\f'"
    }

    It 'closes and reopens around an embedded single quote' {
        # The one character single-quoting cannot contain. Getting this wrong
        # ends the quoted string early and hands the rest to the shell as code.
        ConvertTo-EraCmdcQuoted -Value "it's" | Should -Be "'it'\''s'"
    }
}

Describe "the cmdc adapter's contract with the dispatcher" -Tag Unit {

    It 'exposes Invoke-CmdcReview, which is what TitleCase(backend) resolves to' {
        $computed = "Invoke-$((Get-Culture).TextInfo.ToTitleCase('cmdc'))Review"
        $computed | Should -Be 'Invoke-CmdcReview'
        Get-Command Invoke-CmdcReview -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'declares the parameters the dispatcher always splats' {
        $p = (Get-Command Invoke-CmdcReview).Parameters
        foreach ($n in 'BundlePath', 'PromptPath', 'ResponsePath', 'ModelInfo', 'TimeoutSec',
                       'AgyModelHint', 'ModelOverride', 'OpencodeProvider') {
            $p.ContainsKey($n) | Should -BeTrue -Because "workflow.ps1 splats -$n at every adapter"
        }
    }

    It 'does NOT declare -PidFile' {
        (Get-Command Invoke-CmdcReview).Parameters.ContainsKey('PidFile') | Should -BeFalse
    }

    It 'writes the response with -LiteralPath' {
        # tests/PathBrackets pins this for every backend; asserted here too so a
        # regression names this file.
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'backends/cmdc.ps1')
        $src | Should -Match 'Set-Content -LiteralPath \$ResponsePath'
        $src | Should -Not -Match 'Set-Content\s+-Path\s+\$ResponsePath'
    }

    It 'passes --tools-all, without which a headless run withholds the file-read tool' {
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'backends/cmdc.ps1')
        $src | Should -Match '--tools-all'
    }

    It 'runs the seat under a login shell' {
        # cmdc is `#!/usr/bin/env node` and node is absent from the non-login PATH
        # wsl.exe provides; resolving cmdc's own path is not sufficient.
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'backends/cmdc.ps1')
        $src | Should -Match 'bash -lc'
    }

    It 'reads stdout and stderr asynchronously before waiting' {
        # A synchronous ReadToEnd on one stream while the child fills the other
        # deadlocks on the pipe buffer.
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'backends/cmdc.ps1')
        $src | Should -Match 'ReadToEndAsync'
    }

    It 'scrubs the agent env vars every CLI adapter scrubs' {
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'backends/cmdc.ps1')
        foreach ($v in 'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'AI_AGENT', 'OPENCODE_YOLO') {
            $src | Should -Match "'$v'"
        }
    }
}
