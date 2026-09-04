# A SPEND-GUARD MUST NOT BE BUILT ON A MECHANISM THAT SILENTLY DROPS.
#
# -PreflightOnly shipped on 2026-09-04 as ERA_PREFLIGHT_ONLY alone, and a WSL
# caller lost $0.66 to it the same day on a round they meant to price-check:
#
#   ERA_PREFLIGHT_ONLY=1 pwsh ... era.ps1 ...
#
# sets a LINUX environment variable; `pwsh` on a WSL PATH execs pwsh.EXE; and
# ERA_* is not in WSLENV. Measured: the variable arrives EMPTY, so era dispatched
# a real 4-seat round. references/troubleshooting.md had documented that boundary
# for weeks -- the guard was built on the one mechanism known not to cross the
# boundary this skill always runs across.
#
# THE DIRECTION IS WHAT MAKES IT SERIOUS, and it is the rule this file encodes: a
# safety flag that fails open does not refuse, it SPENDS. Anything whose job is to
# prevent spending must travel as an ARGUMENT, because arguments cross.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/PreflightOnly.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root    = Split-Path $PSScriptRoot -Parent
    $script:EraPath = Join-Path $script:Root 'runtimes/era.ps1'
    $script:Src     = Get-Content -Raw $script:EraPath
    $script:Code    = [regex]::Replace($script:Src, '(?s)<#.*?#>', '')
}

Describe 'the preflight stop is reachable as a switch' -Tag Unit {

    It 'declares -PreflightOnly as a real parameter' {
        # Parsed, not grepped: a [switch] in a comment would satisfy a regex.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:EraPath, [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        $params | Should -Contain 'PreflightOnly'
    }

    It 'is a switch, so it survives the WSL -> pwsh.exe boundary as an argument' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:EraPath, [ref]$null, [ref]$null)
        $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PreflightOnly' }
        $p.StaticType.Name | Should -Be 'SwitchParameter'
    }

    It 'stops on the switch alone, with no env var set' {
        # The regression in one line: if this only tested the env var it would
        # have passed on the day the bug shipped.
        $script:Code | Should -Match '\$PreflightOnly\s+-or\s+\$env:ERA_PREFLIGHT_ONLY'
    }

    It 'keeps the env var as a secondary path rather than dropping it' {
        # Callers already inside pwsh (the test forks) can still use it.
        $script:Code | Should -Match 'ERA_PREFLIGHT_ONLY'
    }

    It 'stops BEFORE the dispatch call, not after' {
        # The whole value is that nothing is spent. If the guard sat below
        # Invoke-ReviewerDispatch it would be a very expensive no-op.
        $guardIdx    = $script:Code.IndexOf('$PreflightOnly -or $env:ERA_PREFLIGHT_ONLY')
        $dispatchIdx = $script:Code.IndexOf('Invoke-ReviewerDispatch -ReviewerList $approvedList')
        $guardIdx    | Should -BeGreaterThan 0
        $dispatchIdx | Should -BeGreaterThan 0
        $guardIdx    | Should -BeLessThan $dispatchIdx
    }

    It 'documents the WSL trap where an operator will look' {
        $skill = Get-Content -Raw (Join-Path $script:Root 'SKILL.md')
        $skill | Should -Match '(?s)ERA_PREFLIGHT_ONLY.{0,600}WSLENV'
        $skill | Should -Match '`-PreflightOnly`'
    }
}

Describe 'the tests that fork era do not dispatch' -Tag Unit {

    It 'uses the switch, not the env var, in every fork' {
        # These forks used the env var for one commit. Inside pwsh that works, so
        # the suite was green -- which is exactly how the WSL hole stayed open.
        # Pin the robust form.
        foreach ($f in @('tests/BroadScopeGate.Tests.ps1','tests/AutoDetect.Tests.ps1')) {
            $t = Get-Content -Raw (Join-Path $script:Root $f)
            $t | Should -Match '-PreflightOnly' -Because "$f forks a real era.ps1"
            $t | Should -Not -Match "env:ERA_PREFLIGHT_ONLY" -Because "$f should not rely on the WSL-fragile path"
        }
    }

    It 'leaves no fork of era.ps1 that could reach a live dispatch' {
        # Any fork with neither -PreflightOnly nor -IncludeFiles nor -Doctor can
        # reach Invoke-ReviewerDispatch and spend money.
        $offenders = @()
        foreach ($f in (Get-ChildItem (Join-Path $script:Root 'tests') -Filter '*.Tests.ps1')) {
            foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
                if ($line -notmatch "EraPath\)'\s+") { continue }
                if ($line -match '-PreflightOnly' -or $line -match '-Doctor' -or $line -match '-IncludeFiles') { continue }
                $offenders += "$($f.Name): $($line.Trim())"
            }
        }
        $offenders -join "`n" | Should -BeNullOrEmpty
    }
}
