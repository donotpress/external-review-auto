# THE PROMPT AND THE DELIVERY CLASSIFICATION MUST DESCRIBE THE SAME WORLD.
#
# opus's F12, unresolved across two releases: workflow.ps1's
# Get-EraBackendDelivery classifies agy as delivery mode 'disk-read' -- "the
# model opens the bundle from disk with its own tools" -- while the prompt in
# backends/agy.ps1 told that same model "Do NOT open, read, fetch, list, or run
# anything." Both cannot be true, and every round's metadata and summary reports
# delivery_mode for this seat.
#
# RESOLVED BY EXPERIMENT, 2026-09-02. A 418-byte bundle was written containing a
# random sentinel that appears nowhere in the prompt, and _SpawnAndCaptureOnce
# was called on it with the shipped prompt. The seat replied:
#
#     SENTINEL=ZQ7X-39CEB86379E6
#     HOW=I obtained the bundle content by viewing sentinel-bundle.xml on disk
#         using the view_file tool.
#
# The sentinel was reachable only from disk: this adapter passes the bundle as a
# PATH in argv and nothing else -- stdin is closed immediately, there is no
# attachment mechanism, and the bytes are never inlined. So the classification is
# right, delivery_mode has never lied for this seat, and the PROMPT was the false
# half. (It agrees with the archive: 11 of 11 flagged gemini citations were in
# the merged-bundle frame, which only the model's own reader can produce.)
#
# These tests pin the resolution from both ends, so the next person to "harden"
# the prompt cannot re-forbid the read without a red test.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/AgyPromptHonesty.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'workflow.ps1')
    . (Join-Path $script:Root 'backends/agy.ps1')
    $script:Prompt = Get-AgyReviewPrompt -BundlePath 'C:\tmp\round-1-bundle.xml' -DispatchId 'dispatch-0001'
}

Describe 'the agy prompt does not forbid the read its delivery mode depends on' -Tag Unit {

    It 'is classified disk-read by the plan' {
        (Get-EraBackendDelivery -Backend 'agy').Mode | Should -Be 'disk-read'
    }

    It 'does not tell the model not to open or read' {
        # The exact sentence that shipped, plus the general shape of a BLANKET
        # ban. The first cut of this test forbade '(?i)do not\s+(open|read)\b'
        # outright and failed on the replacement prompt's "do not open any OTHER
        # file" -- which is the restriction worth keeping. The defect was never
        # the word "not"; it was forbidding the read with no exception for the
        # one file the model has to read, so that is what is asserted.
        $script:Prompt | Should -Not -Match 'Do NOT open, read, fetch, list, or run anything'
        $script:Prompt | Should -Not -Match '(?i)Review ONLY the bundle content'
        # Every ban on opening or reading must carry its exception. A negative
        # regex could not say that without also matching the good clause (cut 2
        # of this test used `[^.]*anything` and spanned three commas to reach
        # "do not fetch anything"), so enumerate the bans and check each one.
        $bans = [regex]::Matches($script:Prompt, '(?i)do\s+not\s+(open|read)\s+([^,.;]{0,40})')
        @($bans).Count | Should -BeGreaterThan 0 -Because 'the exploration hardening is still meant to be there'
        foreach ($b in $bans) {
            $b.Groups[2].Value | Should -Match '(?i)\b(other|else)\b' `
                -Because "'$($b.Value)' bans a read with no exception for the one file the seat must read"
        }
    }

    It 'tells the model to open the bundle, because that is the only way it gets it' {
        $script:Prompt | Should -Match '(?i)open TH(AT|IS) ONE FILE'
        $script:Prompt | Should -Match ([regex]::Escape('C:\tmp\round-1-bundle.xml'))
    }

    It 'does not claim the bundle is attached, because nothing attaches it' {
        # The old prompt opened with "All files are in the attached bundle at
        # <path>". No caller of this adapter attaches anything: the path is an
        # argv string, stdin is closed before a byte is written to it.
        $script:Prompt | Should -Not -Match '(?i)attached bundle'
        $script:Prompt | Should -Match '(?i)NOT attached'
    }

    It 'still forbids everything EXCEPT that one file, which is what the hardening was for' {
        # agy is an agentic agent; "review the code at <path>" invited it to go
        # exploring the repo and to narrate tool intent instead of reviewing.
        # That restriction is kept -- it just applies to the other files.
        $script:Prompt | Should -Match '(?i)do not open any other file'
        $script:Prompt | Should -Match '(?i)do not list directories'
        $script:Prompt | Should -Match '(?i)do not fetch'
        $script:Prompt | Should -Match '(?i)do not run any command'
        $script:Prompt | Should -Match '(?i)Output the review itself'
    }

    It 'carries the run id first, so mid-prompt truncation cannot lose it' {
        $script:Prompt | Should -Match '^\[Run ID: dispatch-0001\]'
    }

    It 'is the prompt the adapter actually sends' {
        # NOT a source grep. The adapter's docstring now quotes the OLD prompt in
        # full to explain why it was replaced, so any test that greps agy.ps1 for
        # "Do NOT open, read, fetch, list, or run anything" finds the comment and
        # passes no matter what the live prompt says. The link that matters is
        # that _SpawnAndCaptureOnce builds its $prompt from this function.
        $src = Get-Content -Raw (Join-Path $script:Root 'backends/agy.ps1')
        $code = [regex]::Replace($src, '(?s)<#.*?#>', '')
        $code | Should -Match '\$prompt\s*=\s*Get-AgyReviewPrompt\s'
        # ...and no second prompt literal was left behind next to it.
        $hits = @(($code -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\$prompt\s*=\s*"' })
        $hits.Count | Should -Be 0 -Because "the prompt has one definition; found: $($hits -join ' | ')"
        # AND THAT IT REACHES ARGV. The gemini seat of the panel on this diff
        # pointed out that the two assertions above pass while
        # `$psi.ArgumentList.Add('some hardcoded string')` sits below them: they
        # pin where the prompt is BUILT and say nothing about what is SENT.
        # `--print` is the flag agy takes the prompt after, so assert the pair.
        $code | Should -Match "(?s)ArgumentList\.Add\('--print'\)\s*\r?\n\s*\`$psi\.ArgumentList\.Add\(\`$prompt\)"
    }
}

Describe 'the disk-read classification is what every other surface reports' -Tag Unit {

    It 'says disk-read in the metadata map the round summary is built from' {
        $m = Get-EraBundleDeliveryPlan -ReviewerList @('gemini') `
                -Registry @{ 'gemini' = @{ backend = 'agy' } } -BundleBytes 100000 -BundleTokens 30000
        $m.Seats[0].Mode | Should -Be 'disk-read'
    }

    It 'imposes no channel limit, because the model reads the file itself' {
        $d = Get-EraBackendDelivery -Backend 'agy' -BundleBytes 5000000
        $d.LimitBytes  | Should -BeNullOrEmpty
        $d.LimitTokens | Should -BeNullOrEmpty
        $d.Kind        | Should -Be 'none'
    }
}
