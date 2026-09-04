<#
  Per-backend bundle-delivery preflight.

  WHY THIS EXISTS. Three consecutive 4-seat panels delivered 2 seats, for two
  independent reasons with one shape: the bundle was bigger than the seat's
  delivery channel could carry, and nothing checked before dispatch.

    2026-08-30  opus (claude, stdin)  2,396,233-byte bundle -> "Prompt is too long"
    2026-08-31  deepseek-flash        74,740-byte bundle    -> 600s timeout, nothing
    2026-08-25  deepseek-flash        79,294-byte bundle    -> 600s timeout, nothing
    2026-08-31  deepseek-flash        13,433-byte bundle    -> 7,957-byte review OK

  The only pre-existing scale gate measured PRE-BUNDLE SOURCE bytes against a
  10 MB ceiling (~200x looser than the tightest channel era dispatches to) and
  armed only on the repo-wide path. All three failing rounds were curated
  -IncludeFiles rounds, so it never even ran.

  These are pure-function tests: Get-EraBundleDeliveryPlan does no I/O.
#>

BeforeAll {
    $script:SkillRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:SkillRoot 'workflow.ps1')

    $script:Reg = @{
        'opus'           = @{ backend = 'claude';       model_id = 'claude-opus-5' }
        'deepseek-flash' = @{ backend = 'opencode';     model_id = 'opencode-go/deepseek-v4-flash' }
        'muse-spark'     = @{ backend = 'opencode';     model_id = 'opencode-go/muse-spark-1.3-contributor' }
        'gemini'         = @{ backend = 'agy';          model_id = 'gemini-3.6-flash-high' }
        'deepseek-api'   = @{ backend = 'openaicompat'; model_id = 'deepseek-chat' }
        'opus-api'       = @{ backend = 'anthropic';    model_id = 'claude-opus-5' }
    }
}

Describe 'Get-EraBackendDelivery' -Tag Unit {

    It 'reports the measured 50 KiB attach cap for a bundle under it' {
        $d = Get-EraBackendDelivery -Backend 'opencode' -BundleBytes 40000
        $d.Mode       | Should -Be 'attach'
        $d.LimitBytes | Should -Be 51200
    }

    It 'switches to read-tool above the attach cap, with a far higher ceiling' {
        # Verified 2026-08-31 with canaries at 25/50/75% depth: both opencode seats
        # covered 109,066 / 314,720 / 668,389-byte bundles in full. Reporting
        # 'attach' here would make the round summary lie about how the bundle
        # actually reached the seat -- the one thing that field is for.
        $d = Get-EraBackendDelivery -Backend 'opencode' -BundleBytes 300000
        $d.Mode       | Should -Be 'read-tool'
        $d.LimitBytes | Should -Be 1048576
    }

    It 'bounds claude by tokens, because the bundle is inlined as the prompt' {
        $d = Get-EraBackendDelivery -Backend 'claude'
        $d.Mode        | Should -Be 'stdin'
        $d.LimitTokens | Should -BeGreaterThan 0
        # A byte cap would be the wrong unit here: the failure is a context
        # overflow, and 2.4 MB of XML is not 2.4 MB of context.
        $d.LimitBytes  | Should -BeNullOrEmpty
    }

    It 'uses the MEASURED claude ceiling, inside the bisected bracket' {
        # Measured 2026-08-31: `claude --print` returned a tail canary at 600,000
        # repomix tokens and said "Prompt is too long" at 630,000. A ceiling above
        # 600,000 would dispatch rounds that cannot run; one at the old derived
        # 150,000 refuses rounds that demonstrably work. Both are regressions.
        $d = Get-EraBackendDelivery -Backend 'claude'
        $d.LimitTokens | Should -BeGreaterThan 150000
        $d.LimitTokens | Should -BeLessOrEqual 600000
        $d.Basis       | Should -Match 'measured 2026-08-31'
    }

    It 'accepts the 500k-token bundle the old derived ceiling would have refused' {
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('opus') -Registry $script:Reg `
            -BundleBytes 1684500 -BundleTokens 500000
        $p.OverCount | Should -Be 0
    }

    It 'imposes no channel limit on agy, which opens the file from disk' {
        $d = Get-EraBackendDelivery -Backend 'agy'
        $d.Mode        | Should -Be 'disk-read'
        $d.LimitBytes  | Should -BeNullOrEmpty
        $d.LimitTokens | Should -BeNullOrEmpty
    }

    It 'says "unknown" rather than guessing for an unmeasured provider' {
        # Inventing a ceiling is how you refuse a round that would have worked.
        $d = Get-EraBackendDelivery -Backend 'openaicompat'
        $d.Mode        | Should -Be 'inline-api'
        $d.LimitBytes  | Should -BeNullOrEmpty
        $d.LimitTokens | Should -BeNullOrEmpty
        $d.Basis       | Should -Match 'not been measured'
    }

    It 'lets a registry entry override an overridable limit' {
        # So a newly measured ceiling is DATA, not a code change. -BundleBytes puts
        # the seat on the READ-TOOL path, which is the ceiling a preset may tune;
        # the attach cap below it is where opencode itself truncates and is not a
        # preset tunable (see the fixed-limit test below).
        $d = Get-EraBackendDelivery -Backend 'opencode' -BundleBytes 100000 -ModelInfo @{ max_bundle_bytes = 200000 }
        $d.LimitBytes | Should -Be 200000
        $d.Basis      | Should -Match 'registry'
        $d.Kind       | Should -Be 'chosen'
    }

    It 'refuses to let a registry entry move the fixed attach cap' {
        # The plan used to apply the override to whichever mode was active. On an
        # attach round that made the plan and the adapter disagree about the same
        # registry key, and an override BELOW 51,200 refused rounds the adapter
        # would have delivered.
        $d = Get-EraBackendDelivery -Backend 'opencode' -BundleBytes 40000 -ModelInfo @{ max_bundle_bytes = 4096 }
        $d.Mode       | Should -Be 'attach'
        $d.LimitBytes | Should -Be 51200
    }
}

Describe 'Get-EraBundleDeliveryPlan' -Tag Unit {

    It 'passes the 13,433-byte bundle that really worked' {
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('deepseek-flash') -Registry $script:Reg `
            -BundleBytes 13433 -BundleTokens 3400
        $p.OverCount | Should -Be 0
        $p.Seats[0].Ok | Should -BeTrue
    }

    It 'sends a 74,740-byte bundle by read-tool rather than refusing it' {
        # This one DID stall on 2026-08-31, which is what got the read-tool path
        # retired. Retiring it was wrong: a 109,066-byte bundle came back fully
        # covered on this same seat, so the stall was not about size. Refusing here
        # would remove the only way to review anything over 50 KiB on opencode.
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('deepseek-flash') -Registry $script:Reg `
            -BundleBytes 74740 -BundleTokens 19000
        $p.OverCount     | Should -Be 0
        $p.Seats[0].Mode | Should -Be 'read-tool'
    }

    It 'covers the three sizes verified end-to-end with canaries' {
        foreach ($b in @(109066, 314720, 668389)) {
            $p = Get-EraBundleDeliveryPlan -ReviewerList @('deepseek-flash','muse-spark') `
                -Registry $script:Reg -BundleBytes $b -BundleTokens ([int]($b/3.65))
            $p.OverCount | Should -Be 0 -Because "a $b-byte bundle was verified covered on both seats"
        }
    }

    It 'still refuses past the point anything has been verified' {
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('deepseek-flash') -Registry $script:Reg `
            -BundleBytes 2396233 -BundleTokens 711253
        $p.OverCount   | Should -Be 1
        $p.Seats[0].Ok | Should -BeFalse
    }

    It 'catches the 2,396,233-byte bundle that really overflowed opus' {
        # repomix's OWN count for that round was 711,253 tokens, and the CLI
        # rejected it. Use the real number, not a bytes/4 estimate.
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('opus') -Registry $script:Reg `
            -BundleBytes 2396233 -BundleTokens 711253
        $p.OverCount   | Should -Be 1
        $p.Seats[0].Ok | Should -BeFalse
        $p.Seats[0].Reason | Should -Match 'tokens'
    }

    It 'would have caught the real 4-seat panel: 2 doomed of 4' {
        # The exact 2026-08-30 round. opus and both opencode seats cannot carry
        # it; agy reads from disk and is fine. This is the round the gate exists
        # to have refused.
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('opus','gemini','deepseek-flash','muse-spark') `
            -Registry $script:Reg -BundleBytes 2396233 -BundleTokens 711253
        $p.OverCount | Should -Be 3
        ($p.Seats | Where-Object { $_.Preset -eq 'gemini' }).Ok | Should -BeTrue
    }

    It 'reports the tightest byte limit across the selected panel' {
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('opus','gemini','deepseek-flash') `
            -Registry $script:Reg -BundleBytes 1000 -BundleTokens 250
        $p.TightestBytes | Should -Be 51200
    }

    It 'reports the read-tool ceiling as the tightest once past the attach cap' {
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('opus','gemini','deepseek-flash') `
            -Registry $script:Reg -BundleBytes 300000 -BundleTokens 82000
        $p.TightestBytes | Should -Be 1048576
    }

    It 'never refuses a seat whose channel has no measured limit' {
        # An unmeasured ceiling must not become a refusal.
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('gemini','deepseek-api') -Registry $script:Reg `
            -BundleBytes 50000000 -BundleTokens 12000000
        $p.OverCount | Should -Be 0
    }

    It 'survives a preset that is not in the registry' {
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('does-not-exist') -Registry $script:Reg `
            -BundleBytes 999999 -BundleTokens 250000
        $p.Seats[0].Backend | Should -Be 'unknown'
        $p.Seats[0].Ok      | Should -BeTrue
    }

    It 'names each seat, its channel and its verdict in the printed notice' {
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('opus','deepseek-flash') -Registry $script:Reg `
            -BundleBytes 2396233 -BundleTokens 711253
        $text = $p.Lines -join "`n"
        $text | Should -Match 'deepseek-flash.*read-tool'
        $text | Should -Match 'CANNOT FIT'
        $text | Should -Match 'opus.*stdin'
    }

    It 'moves a follow-up round to read-tool when carried-forward text crosses the cap' {
        # ERA_PREVIOUS_ROUND_MAX_CHARS is 80,000 chars, and the substituted
        # previous round goes into the prompt, which repomix embeds in the
        # bundle. So a round-2 opencode seat can cross the 51,200-byte attach cap
        # with ZERO change to the source files. The gate measures the built
        # bundle rather than the sources, which is the only layer that sees this.
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('deepseek-flash') -Registry $script:Reg `
            -BundleBytes 84000 -BundleTokens 21000
        $p.Seats[0].Mode | Should -Be 'read-tool'
    }
}

Describe 'the plan agrees with what the adapter will actually do' -Tag Unit {

    AfterEach { Remove-Item Env:\ERA_OPENCODE_READ_TOOL -ErrorAction SilentlyContinue }

    It 'predicts attach when ERA_OPENCODE_READ_TOOL=0 forces it over the cap' {
        # THE SILENT-TRUNCATION HOLE. The adapter honours the env var and attaches,
        # so the model sees the first 50 KiB; the plan used to decide from size
        # alone and reported read-tool / limit 1,048,576 / fits, and the metadata
        # recorded delivery_mode='read-tool'. A well-formed review of 17% of the
        # bundle, with content_ok=true and every new safeguard blind to it.
        $env:ERA_OPENCODE_READ_TOOL = '0'
        $d = Get-EraBackendDelivery -Backend 'opencode' -BundleBytes 300000 `
                -ForcedOpencodeMode 'attach'
        $d.Mode       | Should -Be 'attach'
        $d.LimitBytes | Should -Be 51200

        $p = Get-EraBundleDeliveryPlan -ReviewerList @('deepseek-flash') -Registry $script:Reg `
                -BundleBytes 300000 -BundleTokens 82000
        $p.Seats[0].Mode | Should -Be 'attach'
        $p.OverCount     | Should -Be 1 -Because 'a forced attach over the cap cannot deliver the bundle'
    }

    It 'predicts read-tool when ERA_OPENCODE_READ_TOOL=1 forces it under the cap' {
        $env:ERA_OPENCODE_READ_TOOL = '1'
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('deepseek-flash') -Registry $script:Reg `
                -BundleBytes 10000 -BundleTokens 2700
        $p.Seats[0].Mode | Should -Be 'read-tool'
    }

    It 'uses size alone when the env var is unset' {
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('deepseek-flash') -Registry $script:Reg `
                -BundleBytes 300000 -BundleTokens 82000
        $p.Seats[0].Mode | Should -Be 'read-tool'
        $p.OverCount     | Should -Be 0
    }

    It 'the adapter and the plan carry the SAME built-in constants' {
        # Two implementations of one rule. Editing either copy alone used to keep
        # both suites green; if the adapter's ceiling drops below the plan's, the
        # gate passes a bundle the adapter throws on -- a free preflight refusal
        # upgraded into a billed void round.
        #
        # WAS a regex scrape of the adapter's source for two literal assignments,
        # which is also why backends/opencode.ps1's own comment pointed at a
        # DIFFERENT file ("OpencodeConstantParity.Tests.ps1") that did not exist:
        # the guard was real but nobody could find it from the code it guards.
        # The adapter now exposes the values, so both sides are CALLED. The
        # override direction and the mode crossover are covered in
        # tests/OpencodeConstantParity.Tests.ps1.
        . (Join-Path $script:SkillRoot 'backends/opencode.ps1')
        $adapter = Get-OpencodeDeliveryLimits
        $adapter.AttachLimitBytes | Should -Not -BeNullOrEmpty
        $adapter.ReadToolMaxBytes | Should -Not -BeNullOrEmpty

        (Get-EraBackendDelivery -Backend 'opencode' -BundleBytes 1).LimitBytes      | Should -Be $adapter.AttachLimitBytes
        (Get-EraBackendDelivery -Backend 'opencode' -BundleBytes 100000).LimitBytes | Should -Be $adapter.ReadToolMaxBytes
    }
}

Describe 'an unmeasured channel is never refused' -Tag Unit {

    It 'does not enforce a ceiling on anthropic' {
        # It carried 750,000 "derived from a 1M window less ~25%" -- the identical
        # derivation this release documents as having been ~4x wrong for the claude
        # CLI, and a direct violation of this function's own stated policy. An
        # invented number that can refuse is worse than no number.
        $d = Get-EraBackendDelivery -Backend 'anthropic'
        $d.LimitTokens | Should -BeNullOrEmpty
        $d.LimitBytes  | Should -BeNullOrEmpty
        $d.Basis       | Should -Match 'not been measured'

        $p = Get-EraBundleDeliveryPlan -ReviewerList @('opus-api') -Registry $script:Reg `
                -BundleBytes 50000000 -BundleTokens 12000000
        $p.OverCount | Should -Be 0
    }
}

Describe 'era.ps1 closes the paths that bypassed the gate' -Tag Unit {

    BeforeAll { $script:EraSrc2 = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1') }

    It 'delivery-checks the agy fallback before re-dispatching' {
        # The fallback was priced and contract-checked but never delivery-checked,
        # and it fires only when EVERY seat failed -- plausibly BECAUSE of delivery.
        # The response to a delivery failure was one more unchecked upload.
        $script:EraSrc2 | Should -Match '\$fbPlan = Get-EraBundleDeliveryPlan -ReviewerList @\(\$fallbackPreset\)'
        $planIdx = $script:EraSrc2.IndexOf('$fbPlan = Get-EraBundleDeliveryPlan')
        $dispIdx = $script:EraSrc2.IndexOf('$fbResults = Invoke-ReviewerDispatch')
        $planIdx | Should -BeGreaterThan 0
        $dispIdx | Should -BeGreaterThan $planIdx
    }

    It 'fails CLOSED when repomix token parsing misses' {
        # $tokenCount = 0 passed every token ceiling, disarming the gate for exactly
        # the bundle it was built to catch.
        #
        # ...and the byte fallback that replaced it had its OWN silent fail-open
        # underneath: $bundleBytesForEstimate was seeded to 0 behind a `catch {}`,
        # so an unreadable bundle skipped the estimate AND its warning. It is now
        # $null on failure -- "not measured" and "measured zero" are different
        # facts and only one of them may disarm a gate.
        $script:EraSrc2 | Should -Match '\$tokenCount -le 0 -and \$null -ne \$bundleBytesForEstimate -and \$bundleBytesForEstimate -gt 0'
        $script:EraSrc2 | Should -Match 'could not parse a token count from repomix'
        $script:EraSrc2 | Should -Not -Match '\$bundleBytesForEstimate = 0'
    }

    It 'refuses the round when the bundle it just wrote cannot be sized' {
        # $bundleBytes fed Get-EraBundleDeliveryPlan and used to be `else { 0 }`,
        # and a zero reports that the bundle FITS every channel -- including the
        # opencode attach cap, above which it is silently truncated. Raised by the
        # opus seat of the twin-sweep panel as the load-bearing copy of a
        # fail-open this release had already deleted from two adapters.
        $script:EraSrc2 | Should -Not -Match '\$bundleBytes = if \(Test-Path -LiteralPath \$bundlePath\) \{ \(Get-Item -LiteralPath \$bundlePath\)\.Length \} else \{ 0 \}'
        $script:EraSrc2 | Should -Match 'its size cannot be measured'
    }
}

Describe 'Get-EraDeliveryModeMap' -Tag Unit {

    It 'flattens the plan to preset -> mode for the summary and the metadata' {
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('opus','gemini','deepseek-flash') `
            -Registry $script:Reg -BundleBytes 1000 -BundleTokens 250
        $m = Get-EraDeliveryModeMap -Plan $p
        $m['opus']           | Should -Be 'stdin'
        $m['gemini']         | Should -Be 'disk-read'
        $m['deepseek-flash'] | Should -Be 'attach'   # 1,000-byte bundle -> under the cap
    }

    It 'returns an empty map for a null plan rather than throwing' {
        (Get-EraDeliveryModeMap -Plan $null).Count | Should -Be 0
    }
}

Describe 'era.ps1 arms the preflight' -Tag Unit {

    BeforeAll { $script:EraSrc = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1') }

    It 'runs the plan against the ACTUAL bundle, not the pre-bundle sources' {
        $script:EraSrc | Should -Match 'Get-EraBundleDeliveryPlan -ReviewerList \$reviewerList'
        $script:EraSrc | Should -Match '-BundleBytes \(\[long\]\$bundleBytes\)'
    }

    It 'refuses with exit 1 (nothing spent), not exit 2 (round already paid for)' {
        $script:EraSrc | Should -Match 'Stop-EraWithError \("Refusing this round'
    }

    It 'gates the override behind its own switch, not -Force' {
        # -Force is cost consent and the skill's normative dispatch line passes it
        # on every call; folding them together leaves the gate inert for the only
        # caller the skill documents.
        $script:EraSrc | Should -Match '\[switch\]\$ForceBundleSize'
        $script:EraSrc | Should -Match '\$ForceBundleSize\.IsPresent -or \(\$env:ERA_BUNDLE_FORCE -eq .1.\)'
    }

    It 'runs before the cost prompt, so a refusal costs nothing' {
        $planIdx = $script:EraSrc.IndexOf('Get-EraBundleDeliveryPlan -ReviewerList')
        $costIdx = $script:EraSrc.IndexOf('$approvedList = Invoke-CostPrompt')
        $planIdx | Should -BeGreaterThan 0
        $costIdx | Should -BeGreaterThan $planIdx
    }

    It 'still warns per doomed seat when the override is used' {
        $script:EraSrc | Should -Match 'Expect this seat to fail or to review only part of the bundle'
    }
}
