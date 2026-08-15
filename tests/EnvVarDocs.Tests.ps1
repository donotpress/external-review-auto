# Documentation-drift lock for ERA_* environment variables.
# Tag: Unit
#
# Six env vars had shipped undocumented before this test existed
# (ERA_BROAD_MAX_FILES, ERA_BROAD_MAX_BYTES, ERA_BROAD_FORCE,
# ERA_CONVERGENCE_WARNINGS, ERA_OPENCODE_FIRST_TOKEN_SEC,
# ERA_OPENCODE_VARIANT_STATE), and two more were about to
# (ERA_STRAGGLER_GRACE_SEC, ERA_PREVIOUS_ROUND_MAX_CHARS). Nothing connected
# "code reads an env var" to "SKILL.md tells the user it exists", so a knob
# was only discoverable by reading the source.
#
# This asserts the connection in the direction that matters: anything the code
# READS must be documented. The reverse is deliberately NOT asserted -- SKILL.md
# legitimately mentions vars belonging to other tools (OPENCODE_API_KEY,
# ANTHROPIC_API_KEY) and prose can reference a var outside the table.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/EnvVarDocs.Tests.ps1"

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent

    # Every ERA_* var the shipped code actually reads.
    $script:CodeVars = @(
        @('workflow.ps1') +
        (Get-ChildItem -LiteralPath (Join-Path $script:SkillRoot 'runtimes') -Filter '*.ps1' -File |
            ForEach-Object { "runtimes/$($_.Name)" }) +
        (Get-ChildItem -LiteralPath (Join-Path $script:SkillRoot 'backends') -Filter '*.ps1' -File |
            ForEach-Object { "backends/$($_.Name)" })
    ) | ForEach-Object {
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot $_)
        [regex]::Matches($src, 'env:(ERA_[A-Z0-9_]+)') | ForEach-Object { $_.Groups[1].Value }
    } | Sort-Object -Unique

    $script:SkillText = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'SKILL.md')
}

Describe 'Every ERA_* env var the code reads is documented' -Tag Unit {
    It 'finds env vars to check at all (guards against a vacuous pass)' {
        @($script:CodeVars).Count | Should -BeGreaterThan 8
    }

    It 'documents each one in SKILL.md' {
        $undocumented = @($script:CodeVars | Where-Object {
            $script:SkillText -notmatch [regex]::Escape($_)
        })
        @($undocumented) -join ', ' | Should -BeNullOrEmpty
    }

    It 'lists each one in the Environment variables TABLE, not just in prose' {
        # Prose mentions are easy to miss; the table is where a user looks.
        $table = ($script:SkillText -split '### Environment variables')[1]
        $table | Should -Not -BeNullOrEmpty
        # Stop at the next H2 so we only read the table's own section.
        $table = ($table -split "`n## ")[0]
        $missing = @($script:CodeVars | Where-Object { $table -notmatch [regex]::Escape($_) })
        @($missing) -join ', ' | Should -BeNullOrEmpty
    }
}

Describe '-Provider does not claim an effect it does not have' -Tag Unit {
    # Interim round (deepseek-flash), F1. Every adapter declares
    # -OpencodeProvider and every one ignores it by name -- the provider is
    # derived from the resolved model id since the stateless refactor. era.ps1
    # nevertheless printed "[era] Provider override: X", telling the operator it
    # had taken effect.
    #
    # A user-facing flag that prints a confirmation and does nothing is the same
    # class as the silent-success failures this skill exists to prevent, aimed
    # at the operator instead of the reviewer.
    #
    # The flag stays ACCEPTED (deleting it and the $providerOverrides plumbing
    # changes the dispatcher signature); it just stops lying.

    BeforeAll {
        $script:R = Split-Path $PSScriptRoot -Parent
        $script:Era = Get-Content -Raw (Join-Path $script:R 'runtimes/era.ps1')
    }

    It 'no longer reports a plain "Provider override" confirmation' {
        $script:Era | Should -Not -Match 'Write-Host "\[era\] Provider override: \$Provider"'
    }

    It 'says it is inert, and says what to use instead' {
        $line = [regex]::Match($script:Era, '(?m)^\s*Write-Host "\[era\] WARNING: -Provider[^\r\n]*$').Value
        $line | Should -Not -BeNullOrEmpty
        $line | Should -Match 'INERT'
        $line | Should -Match '-Model|-Reviewer' -Because 'an honest warning names the working alternative'
    }

    It 'and the claim is true: every adapter still ignores the parameter' {
        # If an adapter ever WIRES it up, this fails and the warning must go.
        foreach ($b in @('agy','claude','opencode','geminiapi','anthropic','openaicompat')) {
            $src = Get-Content -Raw (Join-Path $script:R "backends/$b.ps1")
            $src | Should -Match '\$OpencodeProvider' -Because "$b declares it"
            # Declared-and-unused: it must not appear in any expression beyond
            # its own param declaration and comments.
            $uses = [regex]::Matches($src, '(?m)^\s*(?!#).*\$OpencodeProvider.*$') |
                Where-Object { $_.Value -notmatch '^\s*\[string\]\$OpencodeProvider' }
            @($uses).Count | Should -Be 0 -Because "$b must still ignore it, or era's warning is now wrong"
        }
    }
}
