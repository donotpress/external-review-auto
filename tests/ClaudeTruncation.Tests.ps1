# Tests for backends/claude.ps1::Test-ClaudeTruncation — the precision-anchored
# truncation detector that scans claude CLI stderr for context-window /
# max-token / response-truncated phrasings.
#
# The OLD regex `(max.tokens|truncat|context.length|output.limit|response.truncat)`
# had two problems these tests guard against:
#   1. `.` matched any character (so "max!tokens" or "maxXtokens" would match)
#   2. No word boundaries (so "truncates", "truncate", "truncation" all matched)
# The new helper uses \b boundaries and explicit \s+ / [\s_-] separators.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'backends/claude.ps1')
}

Describe 'Test-ClaudeTruncation — true positives (real truncation phrases)' {
    It 'matches "<phrase>"' -ForEach @(
        @{ phrase = 'Prompt is too long' }
        @{ phrase = 'Prompt too long' }
        @{ phrase = 'Input too long' }
        @{ phrase = 'Context length exceeded' }
        @{ phrase = 'Context window exceeded' }
        @{ phrase = 'Max tokens exceeded' }
        @{ phrase = 'Maximum tokens exceeded' }
        @{ phrase = 'max-tokens reached' }
        @{ phrase = 'max_tokens limit' }
        @{ phrase = 'Response was truncated' }
        @{ phrase = 'Response truncated' }
        @{ phrase = 'Output was truncated' }
        @{ phrase = 'Output truncated' }
        @{ phrase = 'Truncated at 8192 tokens' }
        @{ phrase = 'Truncated due to context limit' }
        @{ phrase = 'exceeds maximum tokens' }
        @{ phrase = 'exceeds the maximum context' }
    ) {
        Test-ClaudeTruncation $phrase | Should -BeTrue -Because "should detect truncation in '$phrase'"
    }

    It 'matches phrases embedded in larger stderr output' {
        $stderr = "[claude-cli] starting...`r`nError: Prompt is too long.`r`nUse a shorter input."
        Test-ClaudeTruncation $stderr | Should -BeTrue
    }
}

Describe 'Test-ClaudeTruncation — false-positive guards (must NOT match)' {
    It 'does NOT match "<phrase>"' -ForEach @(
        # Prose that incidentally mentions truncation
        @{ phrase = 'The function truncates the buffer'; reason = 'verb form "truncates" not in pattern' }
        @{ phrase = 'You should truncate the path'; reason = 'verb form "truncate" not in pattern' }
        @{ phrase = 'Truncation handling needs review'; reason = 'noun form "Truncation" alone, no verb context' }
        @{ phrase = 'The truncator class is broken'; reason = 'compound word "truncator"' }
        # Pattern matches that should NOT fire because separators are wrong
        @{ phrase = 'max!tokens are weird'; reason = 'OLD regex matched "max.tokens" — new regex requires whitespace/_/-' }
        @{ phrase = 'maxXtokens definition'; reason = 'no separator between max and tokens' }
        @{ phrase = 'context.length is a JS property'; reason = 'OLD regex matched on dot; new requires whitespace' }
        # Generic discussion that mentions tokens / context / output without error context
        @{ phrase = 'Set the max_tokens parameter to 4096'; reason = 'mentions max_tokens but no exceeded/reached/limit verb' }
        @{ phrase = 'Increase the context length setting'; reason = 'no "exceeded" verb' }
        @{ phrase = 'Limit your output for clarity'; reason = 'output + limit but not "output limit reached"' }
        # Empty / null inputs
        @{ phrase = ''; reason = 'empty string' }
        @{ phrase = 'normal stderr line with no truncation phrase'; reason = 'innocent stderr' }
        # A code review response that critiques truncation handling
        @{ phrase = 'The truncation logic in line 42 is correct.'; reason = 'review mentions truncation as topic' }
    ) {
        Test-ClaudeTruncation $phrase | Should -BeFalse -Because "($reason)"
    }
}

Describe 'Test-ClaudeTruncation — edge cases' {
    It 'returns $false for null input' {
        Test-ClaudeTruncation $null | Should -BeFalse
    }

    It 'is case-insensitive (PowerShell -match default)' {
        Test-ClaudeTruncation 'PROMPT IS TOO LONG' | Should -BeTrue
        Test-ClaudeTruncation 'context window exceeded' | Should -BeTrue
        Test-ClaudeTruncation 'MAXIMUM TOKENS EXCEEDED' | Should -BeTrue
    }

    It 'handles multi-line stderr' {
        $multiline = @"
[claude] connecting to api.anthropic.com
[claude] authenticating
[claude] sending request
Error: Context length exceeded the model's limit.
[claude] aborting
"@
        Test-ClaudeTruncation $multiline | Should -BeTrue
    }
}
