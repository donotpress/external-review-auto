# `catch [System.IO.IOException]` IS NOT "the claim file already exists".
#
# Reserve-ReviewRound claims a round number with
# File::Open(..., FileMode::CreateNew, ..., FileShare::None) and treats the
# resulting exception as "another process got there first, try the next number".
# The only exception that means that is a bare IOException. Four of its
# SUBCLASSES do not, and `catch [IOException]` swallows all of them, spinning the
# loop 50 times and then throwing
#
#     "failed to claim a round number after 50 attempts ... Directory may be in
#      an inconsistent state"
#
# for a problem that has nothing to do with contention.
#
# It has already cost a release. f33705a: era could not claim a round at all on a
# repo whose review dir did not exist yet, because CreateNew threw
# DirectoryNotFoundException -- which derives from IOException -- and this catch
# read it as a lost race. That fix created the directory up front. THE PATH BUG
# WAS FIXED AND THE OVER-WIDE CATCH WAS NOT, so the same swallow is still there
# for every other way the open can fail without a collision.
#
# Measured on Windows PowerShell 2026-09-04, calling File::Open directly with
# FileMode::CreateNew and letting `catch [DirectoryNotFoundException]` /
# `catch [IOException]` / `catch` sort the result:
#
#   file already exists   -> System.IO.IOException                 <- the ONLY retry
#   parent dir missing    -> System.IO.DirectoryNotFoundException   } all three
#   drive does not exist  -> System.IO.DirectoryNotFoundException   } derive from
#   path too long         -> System.IO.DirectoryNotFoundException   } IOException
#   path is a directory   -> UnauthorizedAccessException (already propagates)
#
# So the narrowing that matters is one clause, placed before the IOException one.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/RoundClaimRetryScope.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:WorkflowPath = Join-Path $script:Root 'workflow.ps1'
    . $script:WorkflowPath

    # The try/catch that guards the CreateNew claim, from the AST rather than
    # from a regex over the source. A grep for the type name would pass against a
    # clause in a comment, or one in an unrelated function.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:WorkflowPath, [ref]$tokens, [ref]$errors)
    $script:ParseErrors = $errors

    $fn = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                  $n.Name -eq 'Reserve-ReviewRound' }, $true) | Select-Object -First 1
    $script:Fn = $fn

    $script:ClaimTry = if ($fn) {
        $fn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and
                      $n.Body.Extent.Text -match 'CreateNew' }, $true) | Select-Object -First 1
    }

    $script:CatchTypes = if ($script:ClaimTry) {
        @($script:ClaimTry.CatchClauses | ForEach-Object {
            if ($_.IsCatchAll) { '<catch-all>' } else { $_.CatchTypes[0].TypeName.FullName }
        })
    } else { @() }
}

Describe 'the premise: these really are IOExceptions' -Tag Unit {
    # Non-vacuity. If DirectoryNotFoundException did NOT derive from IOException
    # there would be nothing here to fix, so the fix is worth exactly as much as
    # this assertion.
    #
    # Classified the way the production code classifies -- by typed catch clause,
    # in the same order. A generic `catch { $_.Exception }` cannot be used here:
    # PowerShell wraps a .NET method throw in MethodInvocationException and only
    # unwraps it when a TYPED clause matches, so reading the type off the generic
    # clause reports MethodInvocationException for every case and proves nothing.

    BeforeAll {
        function script:Classify {
            param([string]$Path)
            try {
                $fs = [System.IO.File]::Open($Path,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None)
                $fs.Dispose()
                return 'no-throw'
            }
            catch [System.IO.DirectoryNotFoundException] { return 'DirectoryNotFound' }
            catch [System.IO.IOException]                { return "IOException:$($_.Exception.GetType().FullName)" }
            catch                                        { return "other:$($_.Exception.GetType().Name)" }
        }
    }

    It 'a missing parent directory is caught by catch [IOException] when nothing narrower is offered' {
        $base = Join-Path $env:TEMP "era-claimscope-$(New-Guid)"
        try {
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            $path = Join-Path $base 'no-such-dir\round-1-claim.json'

            # With the narrow clause present it is separated out...
            script:Classify $path | Should -Be 'DirectoryNotFound'

            # ...and without it, the old shape swallows it as a collision. This is
            # the defect, executed rather than argued.
            $swallowed = try {
                $fs = [System.IO.File]::Open($path,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None)
                $fs.Dispose(); 'no-throw'
            } catch [System.IO.IOException] { 'retried-as-collision' } catch { 'propagated' }
            $swallowed | Should -Be 'retried-as-collision'
        } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a genuine collision is a bare IOException and stays on the retry path' {
        $base = Join-Path $env:TEMP "era-claimscope-$(New-Guid)"
        try {
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            $path = Join-Path $base 'round-1-claim.json'
            Set-Content -LiteralPath $path -Value '{}' -Encoding UTF8
            script:Classify $path | Should -Be 'IOException:System.IO.IOException' `
                -Because 'narrowing must not cost the case the retry exists for'
        } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a non-existent drive lands in the same narrowed clause' {
        # Measured: Windows reports this as DirectoryNotFoundException too, so one
        # clause covers it. No separate DriveNotFoundException handling is needed.
        script:Classify 'Q:\era-no-such-drive\round-1-claim.json' | Should -Be 'DirectoryNotFound'
    }
}

Describe 'Reserve-ReviewRound retries only a real collision' -Tag Unit {

    It 'parses, and the claim try/catch is findable' {
        @($script:ParseErrors).Count | Should -Be 0
        $script:Fn       | Should -Not -BeNullOrEmpty
        $script:ClaimTry | Should -Not -BeNullOrEmpty -Because 'everything below reads this node'
        @($script:CatchTypes).Count | Should -BeGreaterThan 0
    }

    It 'has a DirectoryNotFoundException clause' {
        $script:CatchTypes | Should -Contain 'System.IO.DirectoryNotFoundException'
    }

    It 'places it BEFORE the IOException clause' {
        # PowerShell takes the first clause whose type matches, and the derived
        # type matches the base one. Ordered after, the narrow clause is dead.
        $dnf = [Array]::IndexOf($script:CatchTypes, 'System.IO.DirectoryNotFoundException')
        $io  = [Array]::IndexOf($script:CatchTypes, 'System.IO.IOException')
        $io  | Should -BeGreaterThan -1 -Because 'the collision retry itself must still be there'
        $dnf | Should -BeGreaterThan -1
        $dnf | Should -BeLessThan $io
    }

    It 'does not swallow it into the retry counter' {
        $dnfClause = $script:ClaimTry.CatchClauses |
            Where-Object { -not $_.IsCatchAll -and
                           $_.CatchTypes[0].TypeName.FullName -eq 'System.IO.DirectoryNotFoundException' }
        $dnfClause.Body.Extent.Text | Should -Not -Match '\$attempt\+\+' `
            -Because 'a path that does not exist will not exist on the 50th attempt either'
        $dnfClause.Body.Extent.Text | Should -Match 'throw'
    }

    It 'still retries a collision, and the loop still works end to end' {
        # The behaviour the narrow clause must not break.
        $dir = Join-Path $env:TEMP "era-claimscope-$(New-Guid)"
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'round-1-claim.json') -Value '{}' -Encoding UTF8
            Reserve-ReviewRound -ReviewDir $dir -Reviewer 'opus' | Should -Be 2
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
