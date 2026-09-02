# The plan and the adapter must agree about opencode's delivery limits.
#
# backends/opencode.ps1 has said, in a comment above its two constants, that
# "OpencodeConstantParity.Tests.ps1 pins the built-in values against the plan's"
# since the 2026-08-31 panel. THAT FILE DID NOT EXIST. What existed was two
# independent tests, one per side, each asserting its own side equals a literal
# by regex over source text -- so a change made to both sides at once, or a
# change to a value neither test happens to spell, drifts silently. The comment
# claimed a guard that was not there, which is category E of the audit prompt
# ("what is claimed in a comment that no code path enforces") pointed at itself.
#
# Plan/adapter drift is this codebase's most expensive shape: the plan says
# "fits", the round is paid for on every other seat, and the adapter then
# refuses or truncates. It has now happened three times (D3's mode/limit drift,
# the attach-cap override, max_bundle_tokens).
#
# So: compare the two sides to EACH OTHER, by calling both.
#
# THE SECOND PAIR IN THIS FILE IS NOT ABOUT BYTES. The v2.8.2 panel named
# MinRunSec=15 in Resolve-OpencodeRunBudget as the same shape in the time
# dimension: it is "one 10s poll of the output loop plus margin", derived from a
# `$pollMs = 10000` local roughly five hundred lines away inside the run loop, by
# a comment and by nothing else. The run loop only ever CHECKS its deadline after
# a WaitForExit($pollMs), so a run launched with less than one poll of budget
# cannot be stopped before its first wake and is already over its deadline when
# that wake arrives: killed there, having overrun the dispatcher on the way, for
# nothing but the bundle prefill it billed going in. Raise the poll to 30s while
# the floor stays 15 and every seat between 15s and 35s left lands in exactly
# that case. Nothing closed that finding, so it is closed here: both numbers now
# come from Get-OpencodePollIntervalMs, and the RULE (the floor covers at least
# one poll, with margin) is asserted below.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/OpencodeConstantParity.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'workflow.ps1')          # the plan
    . (Join-Path $script:Root 'backends/opencode.ps1') # the adapter
}

Describe 'the adapter and the plan agree on opencode delivery limits' -Tag Unit {

    It 'agrees on the attach cap' {
        $adapter = Get-OpencodeDeliveryLimits
        $plan    = Get-EraBackendDelivery -Backend 'opencode' -BundleBytes 1
        $plan.Mode                  | Should -Be 'attach'
        $adapter.AttachLimitBytes   | Should -Be $plan.LimitBytes
    }

    It 'agrees on the read-tool ceiling' {
        $adapter = Get-OpencodeDeliveryLimits
        $plan    = Get-EraBackendDelivery -Backend 'opencode' -BundleBytes 100000
        $plan.Mode                  | Should -Be 'read-tool'
        $adapter.ReadToolMaxBytes   | Should -Be $plan.LimitBytes
    }

    It 'agrees on WHERE the mode changes, at the boundary byte' {
        # Off-by-one here means one side attaches (and silently truncates) while
        # the other reports read-tool.
        $cap = (Get-OpencodeDeliveryLimits).AttachLimitBytes
        (Get-EraBackendDelivery -Backend 'opencode' -BundleBytes $cap).Mode       | Should -Be 'attach'
        (Get-EraBackendDelivery -Backend 'opencode' -BundleBytes ($cap + 1)).Mode | Should -Be 'read-tool'
        (Test-OpencodeOverAttachLimit -BundleBytes $cap       -AttachLimitBytes $cap) | Should -BeFalse
        (Test-OpencodeOverAttachLimit -BundleBytes ($cap + 1) -AttachLimitBytes $cap) | Should -BeTrue
    }

    It 'agrees that a registry override moves the read-tool ceiling and not the attach cap' {
        # The attach cap is where opencode itself truncates: a preset cannot move
        # it, and the plan prints a NOTE saying so. The adapter must not quietly
        # honour on its side a key the plan refuses on the other.
        $mi      = @{ max_bundle_bytes = 60000 }
        $adapter = Get-OpencodeDeliveryLimits -ModelInfo $mi
        $plan    = Get-EraBackendDelivery -Backend 'opencode' -ModelInfo $mi -BundleBytes 80000
        $adapter.ReadToolMaxBytes | Should -Be 60000
        $adapter.ReadToolMaxBytes | Should -Be $plan.LimitBytes
        $adapter.AttachLimitBytes | Should -Be 51200 -Because 'the transport truncates there whatever the registry says'
        (Get-EraBackendDelivery -Backend 'opencode' -ModelInfo $mi -BundleBytes 1).LimitBytes | Should -Be 51200
    }

    It 'refuses to let max_bundle_tokens bind on a byte-bounded channel' {
        # THE TOKEN DIRECTION OF THE SAME DRIFT. The override loop applied
        # max_bundle_tokens to every backend; Get-OpencodeDeliveryLimits reads
        # only max_bundle_bytes. So a token ceiling on an opencode preset made the
        # PLAN refuse a round the ADAPTER would have delivered -- the expensive
        # direction, and D3's shape for the third time. Named independently by
        # both opencode seats of the twin-sweep panel.
        $mi = @{ max_bundle_tokens = 1000 }
        foreach ($bytes in @(1, 100000)) {
            $d = Get-EraBackendDelivery -Backend 'opencode' -ModelInfo $mi -BundleBytes $bytes
            $d.LimitTokens | Should -BeNullOrEmpty -Because "opencode '$($d.Mode)' delivery is bounded in bytes, not tokens"
        }
        $reg = @{ 'oc' = @{ backend = 'opencode'; max_bundle_tokens = 1000 } }
        $p = Get-EraBundleDeliveryPlan -ReviewerList @('oc') -Registry $reg -BundleBytes 100000 -BundleTokens 500000
        $p.OverCount   | Should -Be 0 -Because 'the adapter would have read this bundle without complaint'
        $p.Seats[0].Ok | Should -BeTrue
    }

    It 'still lets max_bundle_tokens bind where the channel really is token-bounded' {
        # claude inlines the bundle as the prompt and the CLI itself rejects on
        # tokens, so the operator's number is enforceable there.
        (Get-EraBackendDelivery -Backend 'claude' -ModelInfo @{ max_bundle_tokens = 100000 }).LimitTokens | Should -Be 100000
    }

    It 'keeps a non-numeric override on both sides rather than one' {
        $mi = @{ max_bundle_bytes = 'lots' }
        (Get-OpencodeDeliveryLimits -ModelInfo $mi).ReadToolMaxBytes | Should -Be 1048576
        (Get-EraBackendDelivery -Backend 'opencode' -ModelInfo $mi -BundleBytes 100000).LimitBytes | Should -Be 1048576
    }
}

Describe 'an unmeasurable bundle does not become a 50 KiB attach' -Tag Unit {

    It 'refuses rather than reporting zero bytes' {
        # THE FAIL-OPEN. `try { (Get-Item $BundlePath).Length } catch { 0 }` made
        # an unreadable bundle look like an EMPTY one, so $overAttachLimit was
        # false, the adapter attached it, and opencode truncated at 51,200 bytes
        # -- returning a well-formed review of a fragment with content_ok true.
        # That is the exact silent-truncation failure the cap exists to prevent,
        # reached through a catch that turns a failure into a benign value. Same
        # shape as the token-count gate and Get-EraBundleLineCounts.
        { Get-OpencodeBundleBytes -BundlePath (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-era-bundle.xml') } |
            Should -Throw -ExpectedMessage '*cannot size the bundle*'
    }

    It 'returns the real size when it can read it' {
        $f = Join-Path ([System.IO.Path]::GetTempPath()) ("era-sz-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
        try {
            Set-Content -LiteralPath $f -Value ('x' * 1234) -NoNewline -Encoding ascii
            Get-OpencodeBundleBytes -BundlePath $f | Should -Be 1234
        } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the run floor and the poll interval are one number, not two' -Tag Unit {

    It 'derives the floor from the poll interval' {
        # MEASURED, on a copy of the adapter with Get-OpencodePollIntervalMs
        # raised to 30000 and Resolve-OpencodeRunBudget's MinRunSec default
        # re-hardcoded to its old literal 15 -- i.e. the decoupling restored:
        #
        #   AdapterTimeBudget.Tests.ps1        18 passed, 1 failed
        #   OpencodeConstantParity.Tests.ps1   11 passed, 2 failed
        #
        # Three assertions out of thirty-two see it, and all three are new here.
        # NOT this one: with the default re-hardcoded, Get-OpencodeMinRunSec is
        # still derived and still returns 35 >= 30, so a comparison of the two
        # DERIVED functions passes. It catches the other mutation -- somebody
        # re-typing a literal INSIDE Get-OpencodeMinRunSec -- and the two
        # behavioural tests below catch this one. Both are needed; neither
        # covers the other.
        $pollSec = (Get-OpencodePollIntervalMs) / 1000.0
        (Get-OpencodeMinRunSec) | Should -BeGreaterOrEqual $pollSec `
            -Because 'a run with less than one poll left is woken once, at the end of its budget, having written nothing'
        # Margin, not just coverage: exactly one poll leaves no time between the
        # spawn and that wake. The original literal encoded 5s of it.
        (Get-OpencodeMinRunSec) | Should -BeGreaterThan $pollSec

        # AND THE MARGIN ITSELF, which the first cut of this test left free. The
        # muse-spark seat of the panel on this change pointed out that
        # `floor > pollSec` is satisfied by +1 and by +50 alike, so a diff moving
        # the margin to 50 would ship under the banner "the run floor and the
        # poll interval are one number". A larger floor refuses seats that would
        # have worked, which is this repository's expensive direction.
        #
        # The 5 is a POLICY number and says so in Get-OpencodeMinRunSec's own
        # docstring -- it is what the original literal 15 encoded against a 10s
        # poll, and nobody has measured it. This assertion is not evidence that
        # 5 is right. It is the friction: changing it is a decision, and a
        # decision should have to edit a test that says so.
        (Get-OpencodeMinRunSec) | Should -BeGreaterOrEqual ([int]([Math]::Ceiling($pollSec) + 5)) `
            -Because 'the margin is one poll + 5s of policy; moving it is a deliberate act, not a side effect'
    }

    It 'is also high enough that the lowered first-token deadline is reachable' {
        # THE SECOND CONSTRAINT, and the one the first cut of this rule missed.
        # Phase 1 lowers the first-token deadline to int(effective * 0.6) when it
        # would otherwise exceed the budget, and Phase 1 is checked BEFORE the
        # timeout branch. If that lowered value is under one poll, the very first
        # wake kills the run under "no response within Ns -- possible limit/popup
        # block" instead of the honest budget-exhaustion message -- the exact
        # mis-attribution this family of fixes exists to remove.
        #
        # MEASURED before the fix: at remaining=15 (the then-floor, and the value
        # the viability test below pins as Viable) the lowering returned 9 against
        # a first wake at 10s. At 16 it returned 10 and the `-gt` was false. So
        # exactly one budget was exposed, and it was the floor itself. Found by
        # the opus seat of the panel on the change that introduced this file's
        # second Describe.
        $pollSec = (Get-OpencodePollIntervalMs) / 1000.0
        $floor   = Get-OpencodeMinRunSec
        $lowered = [Math]::Max(1, [int]($floor * 0.6))
        $lowered | Should -BeGreaterOrEqual $pollSec `
            -Because "a seat handed exactly the floor (${floor}s) must not be killed at its first wake: the lowering gives it ${lowered}s against a ${pollSec}s poll"
    }

    It 'holds that reachability at every budget it calls viable' {
        # The sweep, because the boundary is not the only place it can break.
        $pollSec = (Get-OpencodePollIntervalMs) / 1000.0
        foreach ($rem in 1..90) {
            $b = Resolve-OpencodeRunBudget -TimeoutSec $rem -ElapsedSec 3
            if (-not $b.Viable) { continue }
            $lowered = [Math]::Max(1, [int]($b.EffectiveSec * 0.6))
            $lowered | Should -BeGreaterOrEqual $pollSec `
                -Because "a ${rem}s seat is called viable with $($b.EffectiveSec)s left, which lowers the first-token deadline to ${lowered}s -- under one ${pollSec}s poll"
        }
    }

    It 'reserves at least one poll behind the lock wait at every budget' {
        # The behavioural half. Resolve-OpencodeRunBudget never returns MinRunSec,
        # so observe it: what the lock wait leaves behind IS the floor.
        $pollSec = (Get-OpencodePollIntervalMs) / 1000.0
        foreach ($budget in @(60, 120, 300, 600, 1200, 1800)) {
            $b = Resolve-OpencodeRunBudget -TimeoutSec $budget -ElapsedSec 0
            ($b.RemainingSec - ($b.LockWaitMs / 1000)) | Should -BeGreaterOrEqual $pollSec `
                -Because "a ${budget}s seat must keep one poll's worth of run time behind the lock wait"
        }
    }

    It 'puts the viability boundary on the same number' {
        # One floor for both questions -- see the Resolve-OpencodeRunBudget
        # docstring on why the two-number version was the expensive shape.
        $floor = Get-OpencodeMinRunSec
        (Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec (600 - $floor)).Viable     | Should -BeTrue
        (Resolve-OpencodeRunBudget -TimeoutSec 600 -ElapsedSec (600 - $floor + 1)).Viable | Should -BeFalse
    }

    It 'has no second poll literal left in the run loop' {
        # A SOURCE ASSERTION, and this file distrusts those on principle -- so it
        # is here for one reason only: the poll interval is consumed by a local
        # inside a function that spawns a process, and there is no way to observe
        # it without running opencode. What it guards is narrow and real: that the
        # run loop calls the shared definition rather than re-typing a literal
        # next to it. The three tests above catch a DIVERGENCE once it exists;
        # this one catches the copy-paste that creates one.
        #
        # WHAT IT CANNOT SEE, named by the muse-spark seat of the panel on this
        # change: `$tmp = 10000; $pollMs = $tmp` launders the literal through one
        # variable and passes both directions below. That is not a gap worth
        # closing here -- a scan that chased assignments would be a parser -- but
        # it IS the reason this test is scoped to "no second literal ON THIS
        # LINE" and is not offered as a guarantee that the interval has one
        # source. The behavioural tests above are the guarantee.
        #
        # CODE LINES ONLY, AND THAT TOOK TWO GOES. Cut 1 scanned the raw file
        # and failed on the docstring above Get-OpencodePollIntervalMs, which
        # quotes the literal it exists to have removed. Cut 2 skipped lines
        # starting with '#' and failed on the SAME line, because that docstring
        # is a `<# ... #>` block whose interior lines start with prose. A source
        # assertion tripping over prose about itself, twice, in two comment
        # syntaxes -- which is exactly why this file distrusts them and why this
        # one is scoped to a single copy-paste rather than to the rule.
        $src  = Get-Content -Raw (Join-Path $script:Root 'backends/opencode.ps1')
        $code = [regex]::Replace($src, '(?s)<#.*?#>', '')
        # Both directions read the STRIPPED source, so neither can be satisfied
        # or tripped by a comment.
        $code | Should -Match '\$pollMs\s*=\s*Get-OpencodePollIntervalMs'
        $codeHits = @(
            ($code -split "`r?`n") |
                Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\$pollMs\s*=\s*\d' }
        )
        $codeHits.Count | Should -Be 0 `
            -Because "the poll interval has exactly one definition; found: $($codeHits -join ' | ')"
    }
}
