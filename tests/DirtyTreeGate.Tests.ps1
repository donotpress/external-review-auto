# Coverage for the dirty-tree dispatch gate and the manifest git stamping.
# Tags: Unit (manifest) / Integration (gate, drives real era.ps1 + real git)
#
# The feature landed in 9808e80 from a concurrent session with NO tests, in a
# repo where every other behaviour is test-backed. It also turned the suite red
# (556/4) until 67dc65d. This is the coverage it should have shipped with.
#
# Two properties matter and they pull in opposite directions:
#   - it must REFUSE by default, or it is not a gate;
#   - it must not refuse when there is nothing to refuse about (no git, clean
#     tree, or the operator explicitly consented), or it blocks legitimate runs.
# Both directions are asserted here.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/DirtyTreeGate.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'

    function script:New-RealRepo {
        <# A real git repo with one commit, so HEAD resolves and status works. #>
        param([string]$Prefix = 'gate', [switch]$NoGitignore)
        $d = Join-Path $env:TEMP "era-$Prefix-$(New-Guid)"
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Push-Location $d
        try {
            & git init -q 2>&1 | Out-Null
            & git config user.email 't@t.t' 2>&1 | Out-Null
            & git config user.name  'T'     2>&1 | Out-Null
            if (-not $NoGitignore) {
                # era's own artifacts must never count as dirt.
                Set-Content -LiteralPath (Join-Path $d '.gitignore') -Value ".external-reviews/`n" -Encoding UTF8
            }
            Set-Content -LiteralPath (Join-Path $d 'a.md') -Value '# a' -Encoding UTF8
            & git add -A 2>&1 | Out-Null
            & git commit -q -m init 2>&1 | Out-Null
        } finally { Pop-Location }
        return $d
    }

    function script:Invoke-EraIn {
        param([string]$Repo, [string]$ArgLiteral = '', [string]$IncludeFiles = 'a.md,definitely-missing.py', [switch]$PreflightOnly)
        Push-Location $Repo
        try {
            $extra = @()
            if ($PreflightOnly) { $extra += '-PreflightOnly' }
            $out = & pwsh -NoProfile -NonInteractive -File $script:EraPath `
                -TopicSlug 'gate' -Force -IncludeFiles $IncludeFiles `
                @($ArgLiteral -split ' ' | Where-Object { $_ }) @extra 2>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        } finally { Pop-Location }
    }
}

Describe 'The dirty-tree gate refuses by default' -Tag Integration {
    It 'refuses when a tracked file is modified, and says why' {
        $repo = New-RealRepo 'dirty'
        try {
            Set-Content -LiteralPath (Join-Path $repo 'a.md') -Value '# modified' -Encoding UTF8
            $r = Invoke-EraIn -Repo $repo
            $r.Output   | Should -Match 'REFUSING TO DISPATCH'
            $r.ExitCode | Should -Be 1
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'counts an untracked-but-not-ignored file as dirt' {
        # This is the case that broke two tests: `git status --porcelain` lists
        # untracked files, so a stray new file is enough to refuse.
        $repo = New-RealRepo 'untracked'
        try {
            Set-Content -LiteralPath (Join-Path $repo 'stray.md') -Value 'new' -Encoding UTF8
            (Invoke-EraIn -Repo $repo).Output | Should -Match 'REFUSING TO DISPATCH'
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does NOT burn a round number or leave artifacts when it refuses' {
        # The commit message calls this out explicitly: an earlier cut gated
        # just before repomix, so a refusal still allocated a round and left a
        # stray round-N-config.json behind.
        $repo = New-RealRepo 'noburn'
        try {
            Set-Content -LiteralPath (Join-Path $repo 'a.md') -Value '# modified' -Encoding UTF8
            Invoke-EraIn -Repo $repo | Out-Null
            $reviewDir = Join-Path $repo '.external-reviews'
            if (Test-Path -LiteralPath $reviewDir) {
                @(Get-ChildItem -LiteralPath $reviewDir -Recurse -File -ErrorAction SilentlyContinue) |
                    Should -BeNullOrEmpty -Because 'a refusal must not allocate a round'
            }
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'The gate stands down when it should' -Tag Integration {
    It '-AllowDirtyTree proceeds past the gate' {
        $repo = New-RealRepo 'allow'
        try {
            Set-Content -LiteralPath (Join-Path $repo 'a.md') -Value '# modified' -Encoding UTF8
            $r = Invoke-EraIn -Repo $repo -ArgLiteral '-AllowDirtyTree'
            $r.Output | Should -Not -Match 'REFUSING TO DISPATCH'
            # It should now reach include validation — the control that proves
            # it got PAST the gate rather than failing earlier for another reason.
            $r.Output | Should -Match 'definitely-missing\.py'
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'ERA_ALLOW_DIRTY=1 is equivalent to the switch' {
        $repo = New-RealRepo 'envallow'
        $prior = $env:ERA_ALLOW_DIRTY
        try {
            Set-Content -LiteralPath (Join-Path $repo 'a.md') -Value '# modified' -Encoding UTF8
            $env:ERA_ALLOW_DIRTY = '1'
            $r = Invoke-EraIn -Repo $repo
            $r.Output | Should -Not -Match 'REFUSING TO DISPATCH'
            $r.Output | Should -Match 'definitely-missing\.py'
        } finally {
            if ($null -ne $prior) { $env:ERA_ALLOW_DIRTY = $prior }
            else { Remove-Item Env:\ERA_ALLOW_DIRTY -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '-Force does NOT bypass the gate' {
        # Same rationale as -ForceBroadScope: -Force means "skip the COST
        # prompt", and the skill's normative dispatch line passes it on every
        # call, so folding them together would leave the gate inert for the only
        # documented caller. Invoke-EraIn already passes -Force.
        $repo = New-RealRepo 'forcenot'
        try {
            Set-Content -LiteralPath (Join-Path $repo 'a.md') -Value '# modified' -Encoding UTF8
            (Invoke-EraIn -Repo $repo).Output | Should -Match 'REFUSING TO DISPATCH'
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a clean tree passes straight through' {
        $repo = New-RealRepo 'clean'
        try {
            $r = Invoke-EraIn -Repo $repo
            $r.Output | Should -Not -Match 'REFUSING TO DISPATCH'
            $r.Output | Should -Match 'definitely-missing\.py'
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "era's own .external-reviews artifacts never count as dirt" {
        # --porcelain omits ignored files; .gitignore lists .external-reviews/.
        # Without this, era would refuse on its own previous round's output.
        $repo = New-RealRepo 'artifacts'
        try {
            New-Item -ItemType Directory -Path (Join-Path $repo '.external-reviews\prev') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo '.external-reviews\prev\round-1-response.md') `
                -Value 'prior round' -Encoding UTF8
            (Invoke-EraIn -Repo $repo).Output | Should -Not -Match 'REFUSING TO DISPATCH'
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'is skipped entirely outside a git work tree' {
        # A bare directory with no .git: nothing to be dirty about, and era must
        # still work for non-git callers.
        $repo = Join-Path $env:TEMP "era-nogit-$(New-Guid)"
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'a.md') -Value '# a' -Encoding UTF8
        try {
            $r = Invoke-EraIn -Repo $repo
            $r.Output | Should -Not -Match 'REFUSING TO DISPATCH'
            $r.Output | Should -Match 'definitely-missing\.py'
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'The gate ignores era-owned artifacts even when nothing gitignores them' -Tag Integration {
    # 2026-09-08: a freshly staged copy has no .gitignore, so Get-EraGitState's
    # reliance on porcelain (which omits only IGNORED files) made a
    # -PreflightOnly run arm the gate against the next dispatch: era refused on
    # its OWN .external-reviews/ directory. Era-authored paths are filtered
    # explicitly, the same way Compare-EraSeatContainment already filters them.
    It "era's own .external-reviews directory never counts as dirt" {
        $repo = New-RealRepo 'ownartifacts' -NoGitignore
        try {
            New-Item -ItemType Directory -Path (Join-Path $repo '.external-reviews\prev') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo '.external-reviews\prev\round-1-response.md') `
                -Value 'prior round' -Encoding UTF8
            (Invoke-EraIn -Repo $repo).Output | Should -Not -Match 'REFUSING TO DISPATCH'
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a -PreflightOnly run does not arm the gate against the next run' {
        $repo = New-RealRepo 'preflightarm' -NoGitignore
        try {
            $first = Invoke-EraIn -Repo $repo -PreflightOnly -IncludeFiles 'a.md'
            $first.Output   | Should -Not -Match 'REFUSING TO DISPATCH'
            $first.ExitCode | Should -Be 0
            $second = Invoke-EraIn -Repo $repo -PreflightOnly -IncludeFiles 'a.md'
            $second.Output   | Should -Not -Match 'REFUSING TO DISPATCH'
            $second.ExitCode | Should -Be 0
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'real untracked dirt still refuses when nothing is gitignored' {
        # Guard the other direction: the exclusion must cover era's own
        # directory and nothing else.
        $repo = New-RealRepo 'realdirt' -NoGitignore
        try {
            Set-Content -LiteralPath (Join-Path $repo 'stray.md') -Value 'new' -Encoding UTF8
            (Invoke-EraIn -Repo $repo).Output | Should -Match 'REFUSING TO DISPATCH'
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Write-ReviewManifest stamps git state' -Tag Unit {
    BeforeEach {
        $script:Root = Join-Path $env:TEMP "era-stamp-$(New-Guid)"
        $script:RD   = Join-Path $script:Root '.external-reviews\t'
        New-Item -ItemType Directory -Path $script:RD -Force | Out-Null
        $script:Bundle = Join-Path $script:RD 'b.xml'
        Set-Content -LiteralPath $script:Bundle -Value 'x' -Encoding UTF8
    }
    AfterEach { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'records head/branch and clean=true on a clean state' {
        $state = [pscustomobject]@{ Head = 'abc123'; Branch = 'master'; Dirty = @() }
        $mp = Write-ReviewManifest -ReviewDir $script:RD -Round 1 -TopicSlug 't' `
                -Files @($script:Bundle) -GitState $state
        $m = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json
        $m.git_head   | Should -Be 'abc123'
        $m.git_branch | Should -Be 'master'
        $m.git_clean  | Should -BeTrue
    }

    It 'records clean=false and the dirty list on a dirty state' {
        $state = [pscustomobject]@{ Head = 'def456'; Branch = 'wip'; Dirty = @(' M a.md', '?? b.md') }
        $mp = Write-ReviewManifest -ReviewDir $script:RD -Round 1 -TopicSlug 't' `
                -Files @($script:Bundle) -GitState $state
        $m = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json
        $m.git_clean | Should -BeFalse
        @($m.git_dirty).Count | Should -Be 2
    }

    It 'omits the fields entirely when there is no git state' {
        # Non-git callers must be unaffected — the manifest should not sprout
        # null git_* keys that downstream consumers then have to special-case.
        $mp = Write-ReviewManifest -ReviewDir $script:RD -Round 1 -TopicSlug 't' -Files @($script:Bundle)
        $names = (Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json).PSObject.Properties.Name
        $names | Should -Not -Contain 'git_head'
        $names | Should -Not -Contain 'git_clean'
    }
}

Describe 'staged rounds record and verify their origin' {
    # 2026-09-08 provenance fix: a staged round anchors to a fresh git init
    # whose SHA exists nowhere. The recipe leaves .era-origin naming the real
    # tree; Write-ReviewManifest carries it through and VERIFIES it with
    # cat-file, so an unverified anchor cannot replace an unresolvable one.
    function script:New-StagedRepo {
        param([string]$Prefix = 'staged', [string]$OriginHead = $null, [string]$OriginBody = $null)
        $d = Join-Path $env:TEMP "era-$Prefix-$(New-Guid)"
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Push-Location $d
        try {
            & git init -q 2>&1 | Out-Null
            & git config user.email 't@t.t' 2>&1 | Out-Null
            & git config user.name  'T'     2>&1 | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'a.md') -Value '# a' -Encoding UTF8
            & git add -A 2>&1 | Out-Null
            & git commit -q -m init 2>&1 | Out-Null
            $head = (& git rev-parse HEAD 2>$null).Trim()
        } finally { Pop-Location }
        $rd = Join-Path $d '.external-reviews\t'
        New-Item -ItemType Directory -Path $rd -Force | Out-Null
        $bundle = Join-Path $rd 'b.xml'
        Set-Content -LiteralPath $bundle -Value 'x' -Encoding UTF8
        if ($OriginBody) {
            Set-Content -LiteralPath (Join-Path $d '.era-origin') -Value $OriginBody -Encoding UTF8
        } elseif ($OriginHead) {
            $h = if ($OriginHead -eq 'REAL') { $head } else { $OriginHead }
            Set-Content -LiteralPath (Join-Path $d '.era-origin') `
                -Value "origin_repo: $d`norigin_head: $h`norigin_branch: master`norigin_dirty: 0`n" -Encoding UTF8
        }
        return [pscustomobject]@{ Dir = $d; ReviewDir = $rd; Bundle = $bundle; Head = $head }
    }

    function script:Write-StagedManifest {
        param($Repo)
        $mp = Write-ReviewManifest -ReviewDir $Repo.ReviewDir -Round 1 -TopicSlug 't' `
            -Files @($Repo.Bundle) -RepoRoot $Repo.Dir
        return Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json
    }

    It 'carries staged_from_* through the manifest and resolves the origin' {
        $r = New-StagedRepo 'carry' -OriginHead 'REAL'
        try {
            $m = Write-StagedManifest $r
            $m.staged | Should -BeTrue
            $m.staged_from_head   | Should -Be $r.Head
            $m.staged_from_repo   | Should -Be $r.Dir
            $m.staged_from_branch | Should -Be 'master'
            $m.staged_from_dirty  | Should -Be '0'
            $m.staged_from_resolvable | Should -BeTrue
        } finally { Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'marks an unresolvable origin LOUD instead of asserting it' {
        $r = New-StagedRepo 'unres' -OriginHead 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
        try {
            $m = Write-StagedManifest $r
            $m.staged | Should -BeTrue
            $m.staged_from_resolvable | Should -BeFalse
        } finally { Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a malformed .era-origin adds no origin fields' {
        $r = New-StagedRepo 'malformed' -OriginBody 'garbage{{{'
        try {
            $m = Write-StagedManifest $r
            $m.staged | Should -BeTrue
            $m.PSObject.Properties.Name | Should -Not -Contain 'staged_from_head'
            $m.PSObject.Properties.Name | Should -Not -Contain 'staged_from_resolvable'
        } finally { Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'no .era-origin means no staged fields at all' {
        $r = New-StagedRepo 'plain'
        try {
            $m = Write-StagedManifest $r
            $m.PSObject.Properties.Name | Should -Not -Contain 'staged'
        } finally { Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a staged -PreflightOnly round says its origin out loud' -Tag Integration {
        # The recipe gitignores .era-origin (it is provenance, not review
        # material), so mirror that here; the gate must stay silent on it.
        $r = New-StagedRepo 'sayit' -OriginHead 'REAL'
        try {
            # Mirror the recipe: the provenance file is gitignored AND
            # committed, so the gate sees a clean tree. An uncommitted
            # .gitignore is itself dirt, which is correctly refused.
            Set-Content -LiteralPath (Join-Path $r.Dir '.gitignore') `
                -Value ".external-reviews/`n.era-origin`n" -Encoding UTF8
            Push-Location $r.Dir
            try {
                & git add -A 2>&1 | Out-Null
                & git commit -q -m stage 2>&1 | Out-Null
            } finally { Pop-Location }
            $out = Invoke-EraIn -Repo $r.Dir -PreflightOnly -IncludeFiles 'a.md'
            $out.Output   | Should -Match 'staged round'
            $out.Output   | Should -Not -Match 'NOT RESOLVABLE'
            $out.ExitCode | Should -Be 0
        } finally { Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
