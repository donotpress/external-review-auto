# Unit tests for the cmdc process-spawn backend.
#
# No model is billed here. Most of it is offline; the boundary cases in the last
# Describe DO spawn wsl.exe, because the bug they pin only exists at that
# boundary and a source-level assertion could not have caught either of the two
# fixes that failed before this one. They cost about a second each.
# Live seat behaviour is recorded in
# docs/assessments/2026-09-06-tmux-transport-findings.md §8-§9.

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

    It 'reads stdout and stderr asynchronously before waiting' {
        # A synchronous ReadToEnd on one stream while the child fills the other
        # deadlocks on the pipe buffer. Structural: there is no cheap way to
        # replay a deadlock in a unit test.
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'backends/cmdc.ps1')
        $src | Should -Match 'ReadToEndAsync'
    }
}

Describe 'Get-EraCmdcScriptBody -- asserted on its OUTPUT, not on the source' -Tag Unit {
    # THESE USED TO GREP THE SOURCE and were therefore satisfied by the COMMENTS
    # explaining each flag: `--tools-all` and `bash -lc` both appear in prose a
    # few lines from the code. Deleting the real flag would have left every test
    # green while every seat silently lost its file-read tool. opus, reviewing
    # this backend on 2026-09-04: "these assert a conclusion rather than replaying
    # the mechanism". The body is now a pure function and the tests read it.

    BeforeAll {
        $script:Body = Get-EraCmdcScriptBody -StageWsl '/mnt/c/tmp/stage' -ModelId 'vendor/model:free' -Effort $null
    }

    It 'passes --tools-all, without which a headless run withholds the file-read tool' {
        $script:Body | Should -Match '--tools-all'
    }

    It 'passes -p, so the run is non-interactive' {
        $script:Body | Should -Match '\s-p\s'
    }

    It 'redirects the seat stdin from /dev/null so it cannot eat the script bash is reading' {
        $script:Body | Should -Match '< /dev/null'
    }

    It 'imports the login PATH by value rather than running the seat under a login shell' {
        # A login shell's profile output would land on the seat's STDOUT, which
        # is the review.
        $script:Body | Should -Match "PATH=.*bash -lc"
        $script:Body | Should -Not -Match 'exec bash -lc'
    }

    It 'execs the seat directly -- ONE shell, so single-quoting means something' {
        $script:Body | Should -Match 'exec "\$CMDC"'
        $script:Body | Should -Not -Match 'bash -lc "exec'
    }

    It 'unsets the agent env vars INSIDE the script, where it actually takes effect' {
        # Measured: Windows variables do not cross into WSL unless named in
        # WSLENV, which is unset here -- `CLAUDECODE=1 wsl.exe -- printenv
        # CLAUDECODE` prints nothing. A Windows-side scrub was a no-op, and the
        # test that asserted it was false assurance.
        foreach ($v in 'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'AI_AGENT', 'OPENCODE_YOLO', 'TMUX_PANE') {
            $script:Body | Should -Match "unset[^\n]*\b$v\b"
        }
    }

    It 'omits --effort entirely when no effort is configured' {
        $script:Body | Should -Not -Match '--effort'
    }

    It 'includes --effort, single-quoted, when one is configured' {
        $withEffort = Get-EraCmdcScriptBody -StageWsl '/mnt/c/tmp/stage' -ModelId 'v/m' -Effort 'high'
        $withEffort | Should -Match "--effort 'high'"
    }

    It 'single-quotes a model id containing shell metacharacters' {
        $nasty = Get-EraCmdcScriptBody -StageWsl '/mnt/c/tmp/s' -ModelId 'a$b`c;d' -Effort $null
        $nasty | Should -Match "-m 'a\`$b``c;d'"
    }

    It 'quotes the staging directory it cds into' {
        (Get-EraCmdcScriptBody -StageWsl "/mnt/c/tmp/with space" -ModelId 'v/m' -Effort $null) |
            Should -Match "cd '/mnt/c/tmp/with space'"
    }
}

Describe 'the WSL boundary carries no path, only the script body' -Tag Unit {
    # THE FIX THAT HELD, AFTER TWO THAT DID NOT. Passing the script's path as an
    # argument was measured to break twice, each time somewhere new:
    #   bare          -> `$` and `#` shell-expanded (`era$probe#x` -> `era#x`, 127)
    #   single-quoted -> spaces broke instead: .NET wraps a spaced argument in
    #                    double quotes of its own, so the single quotes went literal
    # Two independent quoting layers compose. The body now goes in on stdin and
    # the argument vector is a constant, so there is nothing left to parse.

    It 'passes only constant arguments to wsl.exe' {
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'backends/cmdc.ps1')
        $src | Should -Match 'RedirectStandardInput\s*=\s*\$true'
        $src | Should -Match 'StandardInput\.Write'
        $src | Should -Not -Match 'ArgumentList\.Add\(\(ConvertTo-EraCmdcWslPath'
    }

    It 'runs a script from a directory containing <label>' -ForEach @(
        @{ label = 'nothing special'; dir = 'erapathtest-plain' }
        @{ label = '$ and #';         dir = 'erapathtest-$a#b' }
        @{ label = 'a space';         dir = 'erapathtest with space' }
        @{ label = 'a single quote';  dir = "erapathtest'q" }
    ) {
        # Exercises the real boundary. Fast (~1s) and needs no model call.
        $full = Join-Path ([System.IO.Path]::GetTempPath()) $dir
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $full -Force | Out-Null
        try {
            $r = Invoke-EraCmdcRun -WorkDir $full -TimeoutSec 30 -ScriptBody 'echo SCRIPT-RAN'
            $r.Rc          | Should -Be 0 -Because "a $label in the staging path must not reach a shell"
            $r.Out.Trim()  | Should -Be 'SCRIPT-RAN'
        } finally { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
    }

}
