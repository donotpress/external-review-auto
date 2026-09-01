# The FOURTH implementation of "an ambiguous model hint must not resolve
# non-deterministically" -- and the only one that never worked at all.
#
# The sweep this file belongs to fixed the opencode branch of
# Resolve-ModelFromHint and aligned era.ps1's agy tie-break with
# resolve-model.ps1's. It then declared the rule closed. The opus seat of the
# panel run on that very diff answered "where do two implementations still
# disagree?" with a fourth copy nobody had counted: Find-AgyModelFromHint in
# backends/agy.ps1, reachable from Invoke-AgyReview whenever -AgyModelHint or
# -ModelOverride is set.
#
# It carried all three of the defects the other three had been fixed for --
# unsorted `$map.Keys`, a stable Sort-Object inheriting that order, no ambiguity
# warning -- plus one nobody had seen:
#
#   THE ACCUMULATOR WAS NAMED $matches, WHICH IS AN AUTOMATIC VARIABLE.
#
# PowerShell overwrites $Matches on every successful `-match`, and the loop
# condition is a `-match`. Measured:
#
#   $matches = @()
#   foreach ($x in @('alpha','beta','gamma')) { if ($x -match 'a') { $matches += @{ N = $x } } }
#   => type Hashtable, Count 2, content @{ N = 'gamma'; 0 = 'a' }
#
# So the list was never a list. It became a HASHTABLE holding the LAST match's
# fields plus regex capture group 0; `.Count` counted hashtable KEYS; and
# `$matches | Sort-Object TierRank -Descending | Select -First 1` piped a single
# hashtable, so the sort had nothing to sort. Tier preference -- the function's
# entire stated purpose, and the reason "prefer highest tier" is in its comment
# -- was dead. The function returned whichever entry the hashtable happened to
# enumerate last.
#
# The comment above the sort said "if tie, prefer first added (family order)".
# A hashtable has no insertion order to prefer, so it documented behaviour that
# could not exist, over code that was not doing what the line above it claimed.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/AgyHintResolverFourth.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'backends/agy.ps1')
}

Describe 'Find-AgyModelFromHint' -Tag Unit {

    It 'returns a LIST-derived best, not the last thing it happened to see' {
        # The red: pre-fix this returned an entry chosen by hashtable enumeration
        # order, so the tier could be anything. A hint matching a whole family
        # must resolve to that family's HIGHEST tier, every time.
        $r = Find-AgyModelFromHint -Hint 'gemini 3.1 pro'
        $r          | Should -Not -BeNullOrEmpty
        $r.Tier     | Should -Be 'high' -Because 'the highest tier wins when the hint names no tier'
        $r.Settings | Should -Not -BeNullOrEmpty
    }

    It 'resolves the same hint the same way in SEPARATE PROCESSES' {
        # IN-PROCESS REPETITION PROVES NOTHING HERE, and the first version of this
        # test did exactly that and passed against the broken resolver. A
        # hashtable's enumeration order is fixed for the life of one process; it
        # varies BETWEEN processes. Measured on the shipped registry, five
        # consecutive pwsh processes, hint 'gemini':
        #
        #   Gemini 3.5 Flash (High)
        #   Gemini 3.5 Flash (High)
        #   Gemini 3.6 Flash (High)
        #   Gemini 3.1 Pro (High)
        #   Gemini 3.1 Pro (High)
        #
        # Three different models for one hint, and the caller is billed for
        # whichever one the hashtable felt like enumerating last. That is the
        # exact defect v2.4.1 said it had fixed, in the copy nobody counted.
        #
        # Forking is the only instrument that can see it, which is presumably why
        # three previous fixes to this rule never did.
        $script = Join-Path ([System.IO.Path]::GetTempPath()) ("agy-hint-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.ps1')
        try {
            Set-Content -LiteralPath $script -Encoding utf8 -Value @"
. '$($script:Root -replace "'", "''")/backends/agy.ps1'
foreach (`$h in @('gemini','pro','flash')) {
    `$r = Find-AgyModelFromHint -Hint `$h
    "`$h=`$(if (`$r) { `$r.Settings } else { '<null>' })"
}
"@
            $runs = @(1..5 | ForEach-Object {
                (& pwsh -NoProfile -ExecutionPolicy Bypass -File $script) -join '|'
            })
            (@($runs | Sort-Object -Unique)).Count | Should -Be 1 `
                -Because "one hint must name one model whatever order the registry hashtable enumerates in: saw $($runs -join '  //  ')"
        } finally { Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue }
    }

    It 'agrees with the other three implementations of this rule' {
        # One rule, four copies. This is the only assertion that would have caught
        # the copies drifting, and none of the three previous fixes made it.
        . (Join-Path $script:Root 'runtimes/resolve-model.ps1')
        $reg = Get-Content -Raw (Join-Path $script:Root 'backends/_registry.json') | ConvertFrom-Json
        foreach ($hint in @('gemini 3.1 pro', 'gemini 3.1 pro low', 'gemini')) {
            $viaAdapter  = Find-AgyModelFromHint -Hint $hint
            $viaResolver = Resolve-ModelFromHint -Hint $hint -Registry $reg
            if ($viaResolver -and $viaResolver.Provider -eq 'agy') {
                $viaAdapter.Settings | Should -Be $viaResolver.ModelId `
                    -Because "hint '$hint' must name one agy model, whichever copy of the rule is asked"
            }
        }
    }

    It 'does not leave the automatic $Matches variable standing in for its result' {
        # Direct regression guard on the collision itself: if the accumulator is
        # ever renamed back, a hint matching two entries returns a hashtable whose
        # Count is a key count rather than a match count.
        $src = Get-Content -Raw (Join-Path $script:Root 'backends/agy.ps1')
        $src | Should -Not -Match '(?m)^\s*\$matches\s*=\s*@\(\)'
    }

    It 'still refuses a hint that normalises to nothing' {
        Find-AgyModelFromHint -Hint '.*'  | Should -BeNullOrEmpty
        Find-AgyModelFromHint -Hint '???' | Should -BeNullOrEmpty
        Find-AgyModelFromHint -Hint '  '  | Should -BeNullOrEmpty
    }
}
