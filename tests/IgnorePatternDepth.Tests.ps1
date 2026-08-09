# Tests for repomix ignore-pattern DEPTH semantics, and for the parser in
# Measure-EraBroadScope that has to agree with them.
#
# Measured 2026-08-09 against repomix 1.12.0:
#   repomix --include "**/*.md" --ignore "node_modules/**" \
#           --no-gitignore --no-default-patterns
#   → BUNDLES packages/p/node_modules/d/a.md
# A bare '<dir>/**' is anchored at cwd. repomix's own default list spells these
# '**/node_modules/**'; the prefix would be redundant if bare matched at depth.
#
# The parser in Measure-EraBroadScope reads the SAME list era hands repomix.
# Nothing asserted that the consumer understood the producer, which is how the
# original under-count shipped. The contract test at the bottom closes that.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/IgnorePatternDepth.Tests.ps1"

$script:HasRepomix = $null -ne (Get-Command repomix -ErrorAction SilentlyContinue)

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'

    function New-NestedVendorRepo {
        param([string]$Root)
        New-Item -ItemType Directory -Path (Join-Path $Root 'packages/p/node_modules/d') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Root 'node_modules') -Force | Out-Null
        Set-Content -Path (Join-Path $Root 'root.md') -Value '# root source'
        Set-Content -Path (Join-Path $Root 'packages/p/node_modules/d/a.md') -Value 'VENDORED-NESTED'
        Set-Content -Path (Join-Path $Root 'node_modules/top.md') -Value 'VENDORED-TOP'
    }
}

Describe 'Measure-EraBroadScope understands both pattern depths' -Tag Unit {
    It 'prunes a nested directory for **/<dir>/**' {
        $tmp = Join-Path $env:TEMP "era-depth-nested-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-NestedVendorRepo -Root $tmp
            $s = Measure-EraBroadScope -RepoRoot $tmp -Include @('**/*.md') `
                    -IgnorePatterns @('**/node_modules/**')
            # Only root.md survives.
            $s.FileCount | Should -Be 1
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'still prunes root-only for a bare <dir>/**' {
        $tmp = Join-Path $env:TEMP "era-depth-root-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-NestedVendorRepo -Root $tmp
            $s = Measure-EraBroadScope -RepoRoot $tmp -Include @('**/*.md') `
                    -IgnorePatterns @('node_modules/**')
            # root.md + the nested one repomix would bundle. Root-level pruned.
            $s.FileCount | Should -Be 2
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}

Describe 'repomix actually excludes the nested tree (real measurement)' -Tag Integration -Skip:(-not $script:HasRepomix) {
    It 'bundles root.md but not packages/p/node_modules/d/a.md' {
        $tmp = Join-Path $env:TEMP "era-depth-rmx-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-NestedVendorRepo -Root $tmp
            $cfg    = Join-Path $tmp 'cfg.json'
            $bundle = Join-Path $tmp 'bundle.xml'
            @{
                output  = @{ filePath = $bundle; style = 'xml'; showLineNumbers = $true }
                include = @('**/*.md')
                ignore  = @{
                    useGitignore = $false
                    useDefaultPatterns = $false
                    customPatterns = @('**/node_modules/**')
                }
            } | ConvertTo-Json -Depth 10 | Set-Content -Path $cfg -Encoding utf8

            Push-Location $tmp
            try { $null = repomix -c $cfg 2>&1 } finally { Pop-Location }

            $paths = @([regex]::Matches((Get-Content -Raw $bundle), '<file path="([^"]+)"') |
                       ForEach-Object { $_.Groups[1].Value })
            $paths | Should -Contain 'root.md'
            @($paths | Where-Object { $_ -like '*node_modules*' }) | Should -BeNullOrEmpty
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}

Describe 'Pattern/parser contract' -Tag Unit {
    It 'every shipped ignore pattern parses into a shape the measurer recognises' {
        # Reads the LIVE list out of era.ps1 so the producer and consumer cannot
        # drift apart silently again.
        $src = Get-Content -Raw $script:EraPath
        $src -match '\$repomixIgnorePatterns\s*=\s*@\(([^)]*)\)' | Should -BeTrue
        $patterns = @([regex]::Matches($matches[1], "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $patterns.Count | Should -BeGreaterThan 0

        $recognised = @('^\*\*/[^*/]+/\*\*$', '^[^*]+/\*\*$', '^\*\.[^*/]+$')
        $unparsed = @($patterns | Where-Object {
            $p = $_
            -not ($recognised | Where-Object { $p -match $_ })
        })
        # 'validation_results/**/*.db' is a known, deliberate exception: it names
        # an extension the include globs never match, so the measurer ignoring it
        # only over-counts, which is the safe direction.
        @($unparsed | Where-Object { $_ -ne 'validation_results/**/*.db' }) | Should -BeNullOrEmpty
    }

    It 'ships **/-prefixed patterns for the three generic junk directories' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match "'\*\*/node_modules/\*\*'"
        $src | Should -Match "'\*\*/\.git/\*\*'"
        $src | Should -Match "'\*\*/__pycache__/\*\*'"
    }

    It 'keeps .external-reviews ROOT-anchored on purpose' {
        # era's artifact dir is always at the repo root, and the staging
        # carve-out enumerates root-relative siblings. Prefixing it would leave a
        # nested tree ignored with no staging exception.
        $wf = Get-Content -Raw (Join-Path $script:SkillRoot 'workflow.ps1')
        $wf | Should -Match "'\.external-reviews/\*\*'"
        $wf | Should -Not -Match "'\*\*/\.external-reviews/\*\*'"
    }
}
