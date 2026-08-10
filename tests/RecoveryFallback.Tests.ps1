# Which failures can the ONE bounded fallback re-dispatch actually recover?
#
# The trigger was inline in era.ps1 and read:
#
#   $failedAgy      = backend -eq 'agy'  AND ExitCode -ne 0
#   $failedContract = Error   -eq 'response-contract'
#
# Its own comment says the widening exists so that "a REST or opencode reviewer
# that returned off-contract output" no longer "spent the whole round with zero
# usable result and no recovery -- flagged by two of three round-2 reviewers".
#
# Measured 2026-08-10: the intent is not met in the DEFAULT configuration. No
# shipped prompt carries an `era-require` marker (the contract is deliberately
# opt-in), so `response-contract` never fires on a default run and the only live
# trigger is `backend -eq 'agy'`. Every other honest capture failure spends the
# round unrecovered:
#
#   opencode narration capture   Error='agentic-narration-capture'  -> no recovery
#   claude / REST non-review     Error='agentic-narration-capture'  -> no recovery
#   prompt echo, any non-agy     Error='prompt-echo'                -> no recovery
#
# That is case (b) of the 2026-08-09 void round: deepseek-flash failed after
# reading the bundle and nothing was re-dispatched. Reporting it honestly was
# fixed this session; recovering from it was not.
#
# A free-text adapter exception (network fault, bad model id, rate limit) is
# deliberately NOT recoverable -- re-dispatching those doubles the latency and
# the bill for a failure a second attempt cannot fix.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/RecoveryFallback.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'workflow.ps1')
    $script:EraPath = Join-Path $script:Root 'runtimes/era.ps1'

    $script:Reg = @{
        gemini           = @{ backend = 'agy' }
        'gemini-api'     = @{ backend = 'geminiapi' }
        opus             = @{ backend = 'claude' }
        'deepseek-flash' = @{ backend = 'opencode' }
        'deepseek-http'  = @{ backend = 'openaicompat' }
    }
    function script:Ok      { @{ ExitCode = 0;  Error = $null } }
    function script:Failed  { param([string]$Err) @{ ExitCode = -1; Error = $Err } }
}

Describe 'Get-EraRecoverableFailures' -Tag Unit {
    It 'recovers a flaky agy capture regardless of its error string (the original case)' {
        $r = Get-EraRecoverableFailures -ReviewerList @('gemini') `
            -Results @{ gemini = script:Failed 'stall-or-timeout' } -Registry $script:Reg
        @($r) | Should -Contain 'gemini'
    }

    It 'recovers a contract failure on a non-agy backend (the round-2 widening)' {
        $r = Get-EraRecoverableFailures -ReviewerList @('gemini-api') `
            -Results @{ 'gemini-api' = script:Failed 'response-contract' } -Registry $script:Reg
        @($r) | Should -Contain 'gemini-api'
    }

    It 'recovers an opencode narration capture — case (b) of the 2026-08-09 void round' {
        $r = Get-EraRecoverableFailures -ReviewerList @('deepseek-flash') `
            -Results @{ 'deepseek-flash' = script:Failed 'agentic-narration-capture' } -Registry $script:Reg
        @($r) | Should -Contain 'deepseek-flash'
    }

    It 'recovers a prompt echo on a non-agy backend' {
        $r = Get-EraRecoverableFailures -ReviewerList @('opus') `
            -Results @{ opus = script:Failed 'prompt-echo' } -Registry $script:Reg
        @($r) | Should -Contain 'opus'
    }

    It 'does NOT recover a free-text adapter exception — a retry cannot fix a 503' {
        $r = Get-EraRecoverableFailures -ReviewerList @('gemini-api') `
            -Results @{ 'gemini-api' = script:Failed 'Gemini API call failed: 503 Service Unavailable' } `
            -Registry $script:Reg
        @($r) | Should -Not -Contain 'gemini-api'
    }

    It 'does NOT recover a bad model id or an auth failure' {
        $r = Get-EraRecoverableFailures -ReviewerList @('opus','deepseek-http') -Results @{
            opus            = script:Failed 'claude CLI failed (exit=1, model=nope): unknown model'
            'deepseek-http' = script:Failed 'OpenAI-compat API call failed: 401 Unauthorized'
        } -Registry $script:Reg
        @($r).Count | Should -Be 0
    }

    It 'does not recover a reviewer that succeeded' {
        $r = Get-EraRecoverableFailures -ReviewerList @('gemini','opus') `
            -Results @{ gemini = script:Ok; opus = script:Ok } -Registry $script:Reg
        @($r).Count | Should -Be 0
    }

    It 'is safe when a reviewer has no result at all' {
        $r = Get-EraRecoverableFailures -ReviewerList @('gemini','opus') `
            -Results @{ gemini = script:Ok } -Registry $script:Reg
        @($r).Count | Should -Be 0
    }

    It 'lists an agy contract failure once, not twice' {
        # It matches BOTH criteria; the fallback must not see a duplicate.
        $r = Get-EraRecoverableFailures -ReviewerList @('gemini') `
            -Results @{ gemini = script:Failed 'response-contract' } -Registry $script:Reg
        @($r).Count | Should -Be 1
    }

    It 'returns an empty set, not $null, when nothing is recoverable' {
        $r = Get-EraRecoverableFailures -ReviewerList @() -Results @{} -Registry $script:Reg
        @($r).Count | Should -Be 0
    }

    It 'picks the recoverable ones out of a mixed panel' {
        $r = Get-EraRecoverableFailures -ReviewerList @('gemini','opus','deepseek-flash','gemini-api') -Results @{
            gemini           = script:Ok
            opus             = script:Failed 'prompt-echo'
            'deepseek-flash' = script:Failed 'agentic-narration-capture'
            'gemini-api'     = script:Failed 'Gemini API call failed: timeout'
        } -Registry $script:Reg
        @($r) | Should -Contain 'opus'
        @($r) | Should -Contain 'deepseek-flash'
        @($r) | Should -Not -Contain 'gemini-api'
        @($r) | Should -Not -Contain 'gemini'
    }
}

Describe 'era.ps1 drives the fallback from that one decision' -Tag Unit {
    BeforeAll { $script:EraSrc = Get-Content -Raw $script:EraPath }

    It 'calls Get-EraRecoverableFailures instead of re-deriving the trigger inline' {
        $script:EraSrc | Should -Match 'Get-EraRecoverableFailures'
        # The inline duplicates must be gone, or the two definitions drift.
        $script:EraSrc | Should -Not -Match '\$failedAgy\s*='
        $script:EraSrc | Should -Not -Match '\$failedContract\s*='
    }

    It 'decides recoverability BEFORE pricing and dispatching the fallback' {
        $decide = $script:EraSrc.IndexOf('Get-EraRecoverableFailures')
        $price  = $script:EraSrc.IndexOf('Get-PerReviewerCap -Pricing $fbPricing')
        $decide | Should -BeGreaterThan 0
        $price  | Should -BeGreaterThan $decide
    }

    It 'still bounds the fallback to ONE dispatch' {
        # Widening WHAT is recoverable must not widen HOW MANY re-dispatches run.
        # Count CALLS, not mentions -- the comments name it too.
        ([regex]::Matches($script:EraSrc, '=\s*Invoke-ReviewerDispatch')).Count | Should -Be 2
    }

    It 'still prices the fallback against its per-reviewer cap' {
        # The cost guard from rounds 2-4 must survive this change untouched.
        $script:EraSrc | Should -Match 'Get-PerReviewerCap -Pricing \$fbPricing'
        $script:EraSrc | Should -Match '\$fbCost -gt \$fbCap'
    }
}
