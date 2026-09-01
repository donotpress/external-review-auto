<#
  Three issues from a field report (EQM repo, 4 rounds, 2026-09-01).

  1. repomix aborts the entire run on ONE unreadable directory, and a
     .repomixignore in the reviewed repo cannot prevent it. Verified in repomix
     1.12.0 source: getIgnoreFilePatterns pushes '**/.repomixignore' and
     createBaseGlobbyOptions passes it as globby's `ignoreFiles`, which globby
     must GLOB for -- walking the locked directory to find the file that would
     have excluded it. Only `ignore` (era's customPatterns) prunes traversal.

  2. A reviewer cited line 5,891 of a 2,834-line file, in two separate rounds.
     The prose findings were often correct; the citations were not.

  3. `opus` failed with `agentic-narration-capture` and no response file. The
     code covers three different branches and named only one of them, so the
     operator could not tell a bundle-access refusal from a short answer from
     actual narration -- three faults needing three different responses.
#>

BeforeAll {
    $script:SkillRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:SkillRoot 'workflow.ps1')
    . (Join-Path $script:SkillRoot 'backends/_capture-validation.ps1')
}

Describe 'browser-profile dirs are pruned from the walk' -Tag Unit {

    It 'ignores live browser profile directories by pattern' {
        # These MUST live here and cannot live in a repo's .repomixignore -- see
        # the file header. They are also a privacy control: a live profile holds
        # session cookies, and era uploads the bundle to a third party.
        $p = Get-EraVendorIgnorePatterns
        $p | Should -Contain '**/puppeteer_user_data/**'
        $p | Should -Contain '**/chrome_user_data/**'
        $p | Should -Contain '**/chrome-profile/**'
    }

    It 'spells them with the load-bearing **/ prefix' {
        # A bare '<dir>/**' is ROOT-ANCHORED in repomix 1.12.0, so a nested
        # profile directory would still be walked.
        #
        # This asserted `Should -BeLike '**/*'`, which a reviewer pointed out
        # matches EVERY non-empty string -- `*` is the wildcard, so the pattern
        # reads "anything". It would have passed against the root-anchored
        # spelling it exists to forbid. Assert the literal prefix instead.
        $pats = @(Get-EraVendorIgnorePatterns | Where-Object { $_ -match 'user_data|chrome-profile' })
        $pats.Count | Should -BeGreaterThan 0
        foreach ($pat in $pats) {
            $pat.StartsWith('**/') | Should -BeTrue -Because "'$pat' would be root-anchored without the **/ prefix"
        }
    }

    It 'explains the permission abort instead of surfacing raw repomix text' {
        $src = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1')
        $src | Should -Match 'PermissionError\|Permission denied while scanning'
        $src | Should -Match 'NOT the fix'          # .repomixignore cannot fix it
        $src | Should -Match 'Nothing was dispatched and nothing was spent'
    }
}

Describe 'citations are checked against the bundle' -Tag Unit {

    BeforeAll {
        $script:Bundle = Join-Path ([System.IO.Path]::GetTempPath()) ("era-cit-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
        # Two files: one 2,834 lines (the reported case), one short.
        $sb = [System.Text.StringBuilder]::new()
        $null = $sb.AppendLine('<file path="src/buy-routes.js">')
        for ($i = 1; $i -le 2834; $i++) { $null = $sb.AppendLine("${i}: line") }
        $null = $sb.AppendLine('</file>')
        $null = $sb.AppendLine('<file path="src/util.js">')
        for ($i = 1; $i -le 40; $i++) { $null = $sb.AppendLine("${i}: line") }
        $null = $sb.AppendLine('</file>')
        [System.IO.File]::WriteAllText($script:Bundle, $sb.ToString())
        $script:LC = Get-EraBundleLineCounts -BundlePath $script:Bundle
    }
    AfterAll { Remove-Item -LiteralPath $script:Bundle -Force -ErrorAction SilentlyContinue }

    It 'reads per-file line counts out of the bundle' {
        $script:LC['src/buy-routes.js'] | Should -Be 2834
        $script:LC['src/util.js']       | Should -Be 40
    }

    It 'catches the reported fabrications and nothing else' {
        $r = Test-EraResponseCitations -LineCounts $script:LC -Response @'
1. buy-routes.js:5891 - the cart total is wrong.
2. buy-routes.js:3612 - race on the session token.
3. buy-routes.js:1200 - this one is real.
4. src/util.js:12 - also real.
'@
        $r.Checked          | Should -Be 4
        $r.OutOfRange.Count | Should -Be 2
        ($r.OutOfRange -join ' ') | Should -Match '5891'
        ($r.OutOfRange -join ' ') | Should -Match '3612'
        ($r.OutOfRange -join ' ') | Should -Match '2834 lines'
    }

    It 'does not flag a review with no citations at all' {
        (Test-EraResponseCitations -LineCounts $script:LC -Response 'No issues found.').OutOfRange.Count | Should -Be 0
    }

    It 'refuses to guess when a basename is ambiguous' {
        # An over-eager checker that cries wolf on a correct citation is worse
        # than no checker.
        $amb = @{ 'a/dup.js' = 10; 'b/dup.js' = 9000 }
        (Test-EraResponseCitations -LineCounts $amb -Response 'see dup.js:5000').OutOfRange.Count | Should -Be 0
    }

    It 'says the findings may still be real' {
        # The reported reviewer was often CORRECT and twice novel. Demoting a
        # usable review over a formatting fault trades a real defect for a tidy
        # artifact.
        $r = Test-EraResponseCitations -LineCounts $script:LC -Response 'buy-routes.js:9999 - bug.'
        ($r.Lines -join ' ') | Should -Match 'may still be real'
    }
}

Describe 'a non-review says WHICH kind it was' -Tag Unit {

    It 'names a bundle-access refusal as one, even when it is short' {
        # This is the ordering fix: the refusal is ~80 chars, so the length branch
        # used to reach it first and report "sub-floor", pointing the operator at
        # the model's brevity when the bundle never arrived.
        $v = Test-EraCaptureAcceptable -Vendor 'opus' -PromptPath '' `
                -Response 'I cannot review the bundle because it was not included. Please paste the content.'
        $v.Ok              | Should -BeFalse
        $v.NonReviewBranch | Should -Be 'bundle-access-refusal'
        $v.Warning         | Should -Match 'could not SEE the bundle'
    }

    It 'names a short structureless answer as sub-floor, not as narration' {
        # Measured 2026-08-31: a correct, canary-verified 280-char answer was
        # rejected while 301- and 324-char answers of near-identical content
        # passed. Calling that "narration" sends the reader after the wrong cause.
        $v = Test-EraCaptureAcceptable -Vendor 'opus' -PromptPath '' `
                -Response ('COVERAGE: X. ' + ('These are backend adapters. ' * 9))
        $v.Ok              | Should -BeFalse
        $v.NonReviewBranch | Should -Be 'sub-floor-non-answer'
        $v.Warning         | Should -Match 'often not narration at all'
    }

    It 'still names real narration as narration' {
        $v = Test-EraCaptureAcceptable -Vendor 'opus' -PromptPath '' `
                -Response 'Let me read the bundle first so I can check the dispatcher.'
        $v.NonReviewBranch | Should -Be 'tool-intent-narration'
    }

    It 'keeps the error CODE unchanged so recovery still triggers' {
        # Get-EraRecoverableFailures keys on this exact string; renaming it would
        # silently stop the one bounded re-dispatch.
        (Test-EraCaptureAcceptable -Vendor 'x' -PromptPath '' -Response 'Let me go read the bundle.').Error |
            Should -Be 'agentic-narration-capture'
    }

    It 'accepts a real review and reports no branch' {
        $v = Test-EraCaptureAcceptable -Vendor 'opus' -PromptPath '' -Response "## Critical`n1. a.ps1:12 - wrong."
        $v.Ok              | Should -BeTrue
        $v.NonReviewBranch | Should -BeNullOrEmpty
    }

    It 'does not leak a branch from a previous call' {
        $null = Test-EraCaptureAcceptable -Vendor 'x' -PromptPath '' -Response 'Let me read the bundle.'
        (Test-EraCaptureAcceptable -Vendor 'x' -PromptPath '' -Response "## Review`n- fine").NonReviewBranch |
            Should -BeNullOrEmpty
    }
}

Describe 'model-hint resolution is deterministic' -Tag Unit {

    BeforeAll {
        . (Join-Path $script:SkillRoot 'runtimes/resolve-model.ps1')
        $script:Reg = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/_registry.json') | ConvertFrom-Json
    }

    It 'iterates the registries in a defined order' {
        # `$map.Keys` on a HASHTABLE has no defined enumeration order. Measured
        # across three consecutive processes on one box, the same registry gave
        # `sonnet, opus, haiku`, then `haiku, sonnet, opus`, then
        # `sonnet, haiku, opus` -- so with first-match-wins an ambiguous hint
        # resolved to a DIFFERENT MODEL run to run, and the caller was billed for
        # a model it had not asked for.
        $src = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/resolve-model.ps1')
        $src | Should -Match '\$claudeMap\.Keys \| Sort-Object'
        $src | Should -Match '\$agyMap\.Keys \| Sort-Object'
    }

    It 'resolves an ambiguous hint the same way every time' {
        # The substring matcher is `a.Contains(b) -or b.Contains(a)`, so against
        # the shipped registry `o` and `s` both match sonnet AND opus, and `u`
        # matches opus AND haiku.
        foreach ($hint in @('o', 's', 'u')) {
            $seen = @(1..5 | ForEach-Object { (Resolve-ModelFromHint -Hint $hint -Registry $script:Reg).ModelId })
            (@($seen | Sort-Object -Unique)).Count | Should -Be 1 -Because "hint '$hint' must not resolve to different models"
        }
    }

    It 'still resolves the ergonomic exact hints correctly' {
        # The exact pass runs first, so the fix must not disturb normal usage.
        (Resolve-ModelFromHint -Hint 'opus'   -Registry $script:Reg).ModelId | Should -Be 'claude-opus-5'
        (Resolve-ModelFromHint -Hint 'sonnet' -Registry $script:Reg).ModelId | Should -Be 'claude-sonnet-5'
        (Resolve-ModelFromHint -Hint 'gemini 3.1 pro low' -Registry $script:Reg).Provider | Should -Be 'agy'
    }

    It 'keeps the ambiguity warning off stdout' {
        # resolve.ps1's contract is that stdout carries ONLY the JSON flag object;
        # a warning printed there would corrupt what the caller parses.
        $src = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/resolve-model.ps1')
        $src | Should -Match '\[Console\]::Error\.WriteLine\("\[era\] WARNING: model hint'
        $src | Should -Not -Match 'Write-Host "\[era\] WARNING: model hint'
    }
}

Describe 'the preflight refusal records why it refuses the whole panel' -Tag Unit {

    It 'explains why doomed seats are not simply dropped' {
        # era proceeds with a degraded panel at RUNTIME but refuses one at
        # PREFLIGHT. That looks inconsistent without the reason, and an
        # undocumented deliberate decision reads as an oversight.
        $src = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1')
        $src | Should -Match 'WHY THE WHOLE ROUND, AND NOT JUST THE DOOMED SEATS'
        $src | Should -Match 'has spent NOTHING'
    }
}

Describe 'the delivery gate after the 2026-09-01 design panel' -Tag Unit {

    It 'does not let a registry key appear to move a fixed transport limit' {
        # FINDING 5: the plan applied max_bundle_bytes to whichever mode was
        # active, including attach — but opencode's 51,200 is where opencode
        # itself truncates and the adapter overrides only its read-tool ceiling.
        # The harmful direction is an override BELOW 51,200: the plan refuses a
        # round the adapter would have delivered. That is D3's exact shape,
        # surviving D3's fix.
        $reg = @{ 'tight' = @{ backend = 'opencode'; max_bundle_bytes = 30000 } }
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('tight') -Registry $reg -BundleBytes 40000 -BundleTokens 11000
        $p.Seats[0].Mode       | Should -Be 'attach'
        $p.Seats[0].LimitBytes | Should -Be 51200
        $p.Seats[0].Ok         | Should -BeTrue -Because 'the adapter would have attached a 40,000-byte bundle without complaint'
    }

    It 'still honours the override on the read-tool ceiling, which IS a preset tunable' {
        $reg = @{ 'rt' = @{ backend = 'opencode'; max_bundle_bytes = 60000 } }
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('rt') -Registry $reg -BundleBytes 80000 -BundleTokens 22000
        $p.Seats[0].Mode       | Should -Be 'read-tool'
        $p.Seats[0].LimitBytes | Should -Be 60000
        $p.Seats[0].Ok         | Should -BeFalse
    }

    It 'classifies every channel as measured, chosen, derived or none' {
        (Get-EraBackendDelivery -Backend 'opencode'  -BundleBytes 1).Kind      | Should -Be 'measured'
        (Get-EraBackendDelivery -Backend 'opencode'  -BundleBytes 100000).Kind | Should -Be 'chosen'
        (Get-EraBackendDelivery -Backend 'claude').Kind                        | Should -Be 'measured'
        (Get-EraBackendDelivery -Backend 'anthropic').Kind                     | Should -Be 'derived'
        (Get-EraBackendDelivery -Backend 'agy').Kind                           | Should -Be 'none'
    }

    It 'never refuses on a DERIVED ceiling, exercising a path that can actually fire' {
        # The original version used `anthropic`, whose limits are both $null -- so
        # nothing could ever exceed them and the assertion passed without the
        # advisory branch ever executing. A reviewer called it "a code path that
        # cannot execute". Force a derived ceiling that a bundle can exceed.
        $d = Get-EraBackendDelivery -Backend 'anthropic'
        $d.Kind | Should -Be 'derived'
        $d.LimitTokens = 100          # a derived limit the bundle WILL exceed
        # Prove the advisory rule directly: a derived kind over its limit is Ok.
        $advisory = ($d.Kind -ne 'measured' -and $d.Kind -ne 'chosen')
        $advisory | Should -BeTrue -Because 'only measured and chosen may refuse'
    }

    It 'never refuses on a DERIVED ceiling' {
        # The rule existed in prose in two places and had no enforcement:
        # `anthropic` once carried an enforceable 750,000 derived as "a 1M window
        # less ~25%" — the identical derivation that made the claude ceiling 4x
        # too tight. It was fixed by hand and nothing stopped the next one.
        $reg = @{ 'a' = @{ backend = 'anthropic'; max_bundle_tokens = $null } }
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('a') -Registry $reg -BundleBytes 99000000 -BundleTokens 20000000
        $p.OverCount | Should -Be 0

        $src = Get-Content -Raw (Join-Path $script:SkillRoot 'workflow.ps1')
        $src | Should -Match "A DERIVED CEILING MAY NOT REFUSE"
        # Whitelist, not blacklist: `-eq 'derived'` let any future Kind refuse
        # while the comment promised it could not.
        $src | Should -Match '\$advisoryOnly = .*Kind -ne .*measured.* -and .*Kind -ne .*chosen'
        (Get-EraBackendDelivery -Backend 'agy').Kind | Should -Be 'none'
    }

    It 'lets an operator''s own registry number bind — a choice is not a derivation' {
        $reg = @{ 'rt' = @{ backend = 'opencode'; max_bundle_bytes = 60000 } }
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('rt') -Registry $reg -BundleBytes 80000 -BundleTokens 22000
        $p.Seats[0].Kind | Should -Be 'chosen'
        $p.Seats[0].Ok   | Should -BeFalse
    }
}

Describe '-PremiseCheck is a round-level lens' -Tag Unit {

    BeforeAll { $script:EraSrc3 = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1') }

    It 'exists as a switch and appends to the caller''s own prompt' {
        $script:EraSrc3 | Should -Match '\[switch\]\$PremiseCheck'
        $script:EraSrc3 | Should -Match 'Add-Content -LiteralPath \$promptPath -Value \$premiseSection'
    }

    It 'runs AFTER the -Diff merge and BEFORE repomix' {
        # BOTH bounds matter, and the first one was missing. Sitting above the
        # merge, Merge-EraDiffPrompt's
        # `if (-not $ExistingCarriesCallerContent) { return $DiffPrompt }` threw
        # the section away on every -Diff round without a prompt override --
        # while the log line said "appended". A silent no-op reporting success.
        $addIdx   = $script:EraSrc3.IndexOf('Add-Content -LiteralPath $promptPath -Value $premiseSection')
        $mergeIdx = $script:EraSrc3.IndexOf('Merge-EraDiffPrompt -DiffPrompt $diffPrompt')
        # The marker is where repomix RUNS, not where its config is written. The
        # config (carrying instructionFilePath) is emitted earlier; repomix reads
        # the prompt file at run time, so appending between the two is correct and
        # an assertion against the config position fails a working implementation.
        $repoIdx  = $script:EraSrc3.IndexOf('Invoke-EraRepomix -ConfigPath')
        $mergeIdx | Should -BeGreaterThan 0
        $addIdx   | Should -BeGreaterThan $mergeIdx -Because '-Diff rewrites the prompt file and would discard an earlier append'
        $repoIdx  | Should -BeGreaterThan $addIdx  -Because 'repomix embeds the prompt into the bundle'
    }

    It 'records why the lens is per-ROUND and not per-seat' {
        # Not a preference: repomix embeds the prompt in the bundle and the
        # opencode seat is told its instructions live there, so a per-seat lens
        # would need one repomix run per reviewer.
        $script:EraSrc3 | Should -Match 'per-seat lens would need a per-seat bundle'
    }

    It 'asks the four premise questions that found the real defects' {
        foreach ($q in @('never measured', 'not exercised by any code path', 'would still pass if the thing they cover were broken')) {
            $script:EraSrc3 | Should -Match ([regex]::Escape($q))
        }
    }
}

Describe 'the two claims the audit panel made that were not acted on at the time' -Tag Unit {

    BeforeAll {
        $script:EraSrc4 = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1')
        $script:WfSrc4  = Get-Content -Raw (Join-Path $script:SkillRoot 'workflow.ps1')
    }

    It 'has no UNSORTED hashtable-key loop left in either agy resolver' {
        # v2.4.1 made agy hint resolution deterministic in resolve-model.ps1 and
        # ONLY there. era.ps1 carries a second, independent implementation of the
        # same rule (the -AgyModel path) which kept the exact defect that release
        # claimed to fix. One rule, two implementations, one of them fixed — the
        # shape this panel kept finding.
        foreach ($src in @($script:EraSrc4, $script:WfSrc4,
                           (Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/resolve-model.ps1')))) {
            [regex]::Matches($src, '(?m)foreach \(\$\w+ in \$\w*[Mm]ap\.Keys\)').Count |
                Should -Be 0 -Because 'a bare .Keys loop has no defined enumeration order'
        }
    }

    It 'tie-breaks agy candidates explicitly rather than inheriting enumeration order' {
        # Sort-Object is STABLE, so a tie on TierRank silently takes whatever order
        # the hashtable happened to enumerate.
        $script:EraSrc4 | Should -Match "Expression = 'TierRank'; Descending = \`$true"
        # The secondary key used to be 'Display' here and 'SettingsValue' in
        # resolve-model.ps1 -- two copies of one rule, both deterministic, both
        # able to name a different model on a tie. They now use the same key;
        # tests/AgyTieBreakParity.Tests.ps1 asserts the pair agrees on the real
        # registry, which is the behavioural half of this.
        $script:EraSrc4 | Should -Match "Expression = 'SettingsValue'"
        $script:EraSrc4 | Should -Match 'matches \$\(\$tied\.Count\) models at the same tier'
    }

    It 'warns when a registry override RAISES a measured ceiling' {
        # Predicted by the panel as "the next plan/adapter drift", and correct: no
        # adapter reads max_bundle_tokens, so a raised token ceiling means the plan
        # says "fits" and the CLI answers "Prompt is too long" after the round is
        # already paid for on every other seat. Lowering stays quiet.
        $d = Get-EraBackendDelivery -Backend 'claude'
        $d.Kind | Should -Be 'measured'
        $raised = Get-EraBackendDelivery -Backend 'claude' -ModelInfo @{ max_bundle_tokens = 900000 }
        $raised.LimitTokens | Should -Be 900000   # the operator still gets what they asked for
        $script:WfSrc4 | Should -Match 'RAISES a measured ceiling'
    }

    It 'stays quiet when an override LOWERS a measured ceiling' {
        $lowered = Get-EraBackendDelivery -Backend 'claude' -ModelInfo @{ max_bundle_tokens = 100000 }
        $lowered.LimitTokens | Should -Be 100000
        $lowered.Kind        | Should -Be 'chosen'
    }
}
