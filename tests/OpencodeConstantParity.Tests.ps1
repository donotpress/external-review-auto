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
