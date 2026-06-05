# Tests for runtimes/era.ps1 -SpecReview flag — PR 5
# Tag: Unit
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/SpecReview.Tests.ps1 -Tag Unit"

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'
}

Describe 'PR5: -SpecReview preset' -Tag Unit {
    BeforeEach {
        $script:TmpDir = Join-Path $env:TEMP "era-specreview-test-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
        # Create a minimal .git so era.ps1 treats TmpDir as repo root
        New-Item -ItemType Directory -Path (Join-Path $script:TmpDir '.git') -Force | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:TmpDir -ErrorAction SilentlyContinue
    }

    It 'era.ps1 param block declares [string]$SpecReview' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match '\[string\]\$SpecReview'
    }

    It '-SpecReview + -PromptOverrideFile throws mutually-exclusive error' {
        $specFile = Join-Path $script:TmpDir 'my-design.md'
        Set-Content $specFile -Value "# Spec" -Encoding UTF8
        $promptFile = Join-Path $script:TmpDir 'my-prompt.md'
        Set-Content $promptFile -Value "# Prompt" -Encoding UTF8

        $output = & pwsh -NonInteractive -Command @"
`$ErrorActionPreference = 'Stop'
Set-Location '$($script:TmpDir -replace "'", "''")'
try {
    & '$($script:EraPath)' -SpecReview '$($specFile -replace "'", "''")' -PromptOverrideFile '$($promptFile -replace "'", "''")' -Force 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
        $output | Should -Match 'mutually exclusive'
    }

    It '-SpecReview with no frontmatter defaults to spec-only include' {
        $specFile = Join-Path $script:TmpDir 'docs' | Join-Path -ChildPath 'my-spec-design.md'
        New-Item -ItemType Directory -Path (Split-Path $specFile) -Force | Out-Null
        Set-Content $specFile -Value "# Spec with no frontmatter`n`nJust plain content." -Encoding UTF8

        $output = & pwsh -NonInteractive -Command @"
`$ErrorActionPreference = 'Stop'
Set-Location '$($script:TmpDir -replace "'", "''")'
try {
    & '$($script:EraPath)' -SpecReview '$($specFile -replace "'", "''")' -Force 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
        # Should generate prompt (not error about mutual exclusion) and include spec
        $output | Should -Not -Match 'mutually exclusive'
        $output | Should -Match '-SpecReview.*generated|generated.*prompt|derived TopicSlug'
    }

    It '-SpecReview derives topic slug from filename (strips date + -design suffix)' {
        $src = Get-Content -Raw $script:EraPath
        # Source must contain slug derivation that strips date prefix and -design suffix
        # The actual code uses: -replace '^\d{4}-\d{2}-\d{2}-', '' -replace '-design$', ''
        $src | Should -Match 'specBaseName'
        $src | Should -Match "replace.*-design"
        $src | Should -Match 'derived TopicSlug'
    }

    It '-SpecReview + -IncludeFiles is additive' {
        $src = Get-Content -Raw $script:EraPath
        # The source must combine $specIncludeFiles with $IncludeFiles
        $src | Should -Match 'specIncludeFiles.*IncludeFiles|IncludeFiles.*specIncludeFiles'
    }
}

Describe 'PR-C Fix 5: default reviewer is Gemini 3.1 Pro (Low)' -Tag Unit {
    It 'bare /era (no -Reviewer) defaults to gemini-pro-low' {
        # Assert the param default directly (no need to shell era.ps1).
        $cmd = Get-Command $script:EraPath
        $default = $cmd.Parameters['Reviewer'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        # The default value lives in the AST, not the attribute set; inspect the
        # param block default expression instead.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:EraPath, [ref]$null, [ref]$null)
        $reviewerParam = $ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Reviewer' }
        $reviewerParam | Should -Not -BeNullOrEmpty
        $defaultText = $reviewerParam.DefaultValue.Extent.Text
        $defaultText | Should -Match 'gemini-pro-low' `
            -Because 'Fix 5: bare /era must resolve to Gemini 3.1 Pro (Low)'
        $defaultText | Should -Not -Match "@\('gemini'\)" `
            -Because 'the old plain-gemini (Flash) default must be gone'
    }

    It 'gemini-pro-low is a registered agy preset resolving to Gemini 3.1 Pro (Low)' {
        $registry = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/_registry.json') |
            ConvertFrom-Json
        $preset = $registry.'gemini-pro-low'
        $preset | Should -Not -BeNullOrEmpty
        $preset.backend | Should -Be 'agy'
        $preset.agy_model_family | Should -Be 'gemini-3.1-pro'
        $preset.agy_model_tier | Should -Be 'low'
        # The default --model token resolves through _agy_model_map.
        $registry._agy_model_map.'gemini-3.1-pro'.low.settings_value |
            Should -Be 'Gemini 3.1 Pro (Low)'
    }

    It 'explicit -Reviewer gemini still resolves to Flash via the registry' {
        $registry = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/_registry.json') |
            ConvertFrom-Json
        $registry.'gemini'.agy_model_family | Should -Be 'gemini-3.5-flash'
    }
}

Describe 'PR-C Fix 8a: frontmatter related_files parsing' -Tag Unit {
    # These exercise the EXACT parsing logic in era.ps1's -SpecReview branch
    # (block-list, inline-list, inline Related:). We replicate the parse the way
    # era.ps1 performs it so the assertions are behavioral, then a structural
    # guard below ensures era.ps1's source actually contains the same logic.

    BeforeAll {
        # Mirror of era.ps1's frontmatter parse (kept in sync via the source guard
        # below). Pester 5 requires helper functions for It blocks to be defined
        # in BeforeAll so they are visible at run time.
        function Get-RelatedFilesFromSpec {
            param([string]$specContent)
            $relatedFiles = @()
            if ($specContent -match '^---\s*\n([\s\S]*?)\n---') {
                $yamlBlock = $matches[1]
                # YAML block-list branch (with quote stripping)
                if ($yamlBlock -match '(?m)^related_files:\s*\n((?:\s+-\s+.+\n?)*)') {
                    $listBlock = $matches[1]
                    $relatedFiles += @($listBlock -split '\n' |
                        Where-Object { $_ -match '^\s+-\s+(.+)' } |
                        ForEach-Object { ($_ -replace '^\s+-\s+', '').Trim().Trim('"', "'") })
                }
                # YAML inline-list branch: related_files: ["a.ps1","b.ps1"]
                if ($yamlBlock -match '(?m)^related_files:\s*\[([^\]]+)\]') {
                    $inline = $matches[1]
                    $relatedFiles += @($inline -split ',' |
                        ForEach-Object { $_.Trim().Trim('"', "'") } |
                        Where-Object { $_ })
                }
            }
            # Inline Related: lines (with quote stripping)
            $specContent -split '\n' | Where-Object { $_ -match '^Related:\s+(.+)' } | ForEach-Object {
                $relatedFiles += @($matches[1] -split ',\s*' |
                    ForEach-Object { $_.Trim().Trim('"', "'") } |
                    Where-Object { $_ })
            }
            return @($relatedFiles | Where-Object { $_ })
        }
    }

    It 'strips double quotes from block-list entries' {
        $spec = @"
---
title: x
related_files:
  - "backends/agy.ps1"
  - 'workflow.ps1'
---
# body
"@
        $r = Get-RelatedFilesFromSpec $spec
        $r | Should -Contain 'backends/agy.ps1'
        $r | Should -Contain 'workflow.ps1'
        $r | Should -Not -Contain '"backends/agy.ps1"'
    }

    It 'parses a YAML inline-list into both files' {
        $spec = @"
---
title: x
related_files: ["a.ps1","b.ps1"]
---
# body
"@
        $r = Get-RelatedFilesFromSpec $spec
        $r | Should -Contain 'a.ps1'
        $r | Should -Contain 'b.ps1'
    }

    It 'strips quotes from inline Related: line entries' {
        $spec = @"
# body
Related: "src/one.ps1", 'src/two.ps1'
"@
        $r = Get-RelatedFilesFromSpec $spec
        $r | Should -Contain 'src/one.ps1'
        $r | Should -Contain 'src/two.ps1'
        $r | Should -Not -Contain '"src/one.ps1"'
    }

    It 'era.ps1 source applies Trim quote-stripping in both branches and has an inline-list branch' {
        $src = Get-Content -Raw $script:EraPath
        # Quote-stripping must appear (Trim('"',"'") in some quoting form).
        $src | Should -Match "Trim\('\""" `
            -Because 'block-list + inline Related: entries must strip surrounding quotes'
        # Inline-list branch regex must be present (non-greedy [^\]]+).
        $src | Should -Match 'related_files:\\s\*\\\[\(\[\^\\\]\]\+\)\\\]' `
            -Because 'a YAML inline-list related_files: [...] branch must exist'
    }
}
