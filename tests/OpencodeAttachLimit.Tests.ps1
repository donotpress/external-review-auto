<#
  opencode silently truncates an ATTACHED file at 50 KiB (51200 bytes).

  Measured 2026-08-03 on two real runs: DeepSeek V4 Flash reported its input ending
  at line 1169 of a 9,234-line bundle; `head -1169` of that bundle is 51,191 bytes
  and line 1170 crosses 51,200. So the reviewer saw 10.7% of a 474 KB bundle and
  would have seen 7.3% of a 692 KB one — while still returning a well-formed review,
  so nothing in the pipeline noticed.

  Over the cap the adapter switches to an agentic Read-tool prompt. That was
  briefly retired on 2026-08-31 on the reading that it "hangs and returns
  nothing", and UN-retired the same day: the evidence for the hang was a broken
  snapshot, and canary probes showed both seats covering 668,389-byte bundles in
  full. See backends/opencode.ps1 for both halves of that.

  These pin the source-level contract of the attach-vs-read decision. They are
  static assertions rather than a live opencode run: spawning the CLI in unit tests
  would be slow, networked and non-hermetic, and the thing that regressed is the
  DECISION, not the transport.
#>

BeforeAll {
    $script:SkillRoot = Split-Path -Parent $PSScriptRoot
    $script:Src = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/opencode.ps1')
}

Describe 'opencode attach limit' -Tag Unit {

    It 'declares the 50 KiB cap as an explicit constant' {
        $script:Src | Should -Match '\$OPENCODE_ATTACH_LIMIT_BYTES\s*=\s*51200'
    }

    It 'still measures the bundle against the cap' {
        $script:Src | Should -Match '\$overAttachLimit\s*=\s*\$bundleBytes\s*-gt\s*\$OPENCODE_ATTACH_LIMIT_BYTES'
    }

    It 'switches to the Read tool on size, so the model sees the whole bundle' {
        # `-f` attachment is what truncates; over the cap we must not use it.
        $script:Src | Should -Match '\$useReadTool\s*=\s*\$forceReadTool\s*-or\s*\(\$overAttachLimit'
    }

    It 'refuses only past the point the read path has been verified' {
        $script:Src | Should -Match '\$OPENCODE_READ_TOOL_MAX_BYTES\s*=\s*1048576'
        $script:Src | Should -Match 'throw \("opencode cannot review this bundle'
        # The refusal must say the round cost nothing, so a caller can tell it
        # apart from a void round that already spent money.
        $script:Src | Should -Match 'Nothing was dispatched and nothing was spent'
    }

    It 'still attaches for a small bundle (attach needs no tool calls and is faster)' {
        # useReadTool must depend on the size check, not be hardcoded true.
        $script:Src | Should -Not -Match '\$useReadTool\s*=\s*\$true\s*$'
    }

    It 'measures the real bundle rather than trusting a caller-supplied size' {
        $script:Src | Should -Match 'Get-Item -LiteralPath \$BundlePath\).Length'
    }

    It 'warns loudly if a large bundle is force-attached anyway' {
        # ERA_OPENCODE_READ_TOOL=0 is a diagnostics escape hatch; it must not be silent,
        # because a truncated review looks exactly like a successful one.
        $script:Src | Should -Match 'WARNING: bundle is .*TRUNCATE'
    }

    It 'keeps -f attachment gated behind the not-read-tool branch' {
        $script:Src | Should -Match "if \(-not \`$useReadTool\) \{[\s\S]{0,200}ArgumentList\.Add\('-f'\)"
    }
}
