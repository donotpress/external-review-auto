# era Response Contract and Reliability Cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop era recording an off-contract reviewer answer as a success, repair the dead convergence signals, parse `git status` correctly, and move the hardcoded token cap into the registry.

**Architecture:** Four pure helpers in `workflow.ps1` plus three small application sites in `era.ps1`, and a behaviour-preserving capability read in the two REST adapters. A contract failure sets `ExitCode=-1` + `ContentOk=$false`, mirroring the existing `opencode` agentic-narration precedent, so every downstream consumer already does the right thing without modification.

**Tech Stack:** PowerShell 7 (pwsh), Pester 5, git, repomix 1.12.0.

## Global Constraints

- **Repo:** `~/.claude/skills/external-review-auto` (own git repo, branch `master`). Paths below are relative to it.
- **Shared tooling used by multiple projects.** Make only the specified changes. No extra refactoring.
- **Test command:** `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -Command "Invoke-Pester -Path tests/ -Output Detailed"`
- **Single file:** `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/<FILE> -Output Detailed"`
- **Baseline before this plan: 426 passed / 0 failed.** Any drop in the passing count is a stop-and-report, not a workaround.
- The suite runs under **Windows** pwsh. Tests dot-source via `. "$PSScriptRoot/../workflow.ps1"`.
- **Use `command grep`, not `grep`,** for any verification containing `$` — the shell's `grep` is a `ugrep` wrapper whose dialect treats `$R` as an anchor and silently matches nothing.
- Commit after each task, ending every message with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `tests/ResponseContract.Tests.ps1` | Create (Task 1) | Contract parsing, matching, enforcement |
| `tests/PorcelainParse.Tests.ps1` | Create (Task 2) | `git status -z` parsing |
| `tests/RegistryCapabilities.Tests.ps1` | Create (Task 3) | `max_tokens` declared and honoured |
| `workflow.ps1` | Modify (Task 4) | 4 new helpers |
| `runtimes/era.ps1` | Modify (Task 5) | Apply contract; fix convergence; use porcelain helper |
| `backends/_registry.json`, `backends/geminiapi.ps1`, `backends/anthropic.ps1` | Modify (Task 6) | Registry `max_tokens` |

**Tasks 1, 2, 3 create disjoint new files — run concurrently.**
**Task 4 must precede Task 5** (Task 5 calls Task 4's functions).
**Task 6 touches only `backends/` — it can run concurrently with Tasks 4 and 5.**

---

### Task 1: Response-contract tests

**Files:** Create `tests/ResponseContract.Tests.ps1`

**Interfaces:**
- Produces the contract for three functions Task 4 implements:
  - `ConvertTo-EraContractNormalized -Text <string> -> [string]`
  - `Get-EraResponseContract -PromptText <string> -> [string[]]`
  - `Test-ResponseContract -Response <string> -Required <string[]> -> [hashtable]` with keys `Ok` ([bool]) and `Missing` ([string[]])

- [ ] **Step 1: Write the failing test file**

Create `tests/ResponseContract.Tests.ps1` with exactly this content:

```powershell
# Tests for the response contract.
#
# Background: adapters check non-empty text plus a finish reason, then return
# ExitCode=0, and Copy-PrimaryResponseAlias promotes on ExitCode alone. A
# reviewer returned ZERO of ten requested verdicts three times and each was
# recorded as a normal success. Worse, the promoted file feeds
# Invoke-PromptTokenSubstitution into round N+1 -- a bad round poisons the next.
#
# Decoration tolerance is not hypothetical. Measured on the 2026-08-09 panel:
# deepseek-flash answered '**P1: DO**' while gemini and opus answered 'P1: DO'.
# A naive check would have failed the sharpest response in the panel.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/ResponseContract.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'
}

Describe 'ConvertTo-EraContractNormalized' -Tag Unit {
    It 'strips markdown decoration' {
        ConvertTo-EraContractNormalized -Text '**P1: DO**' | Should -Be 'p1: do'
    }
    It 'collapses whitespace and lowercases' {
        ConvertTo-EraContractNormalized -Text "ORDER:`n`n   P2" | Should -Be 'order: p2'
    }
    It 'returns empty string for null' {
        ConvertTo-EraContractNormalized -Text $null | Should -Be ''
    }
}

Describe 'Get-EraResponseContract' -Tag Unit {
    It 'parses a marker into required tokens' {
        $p = "# Prompt`n<!-- era-require: ORDER:, DROP-ENTIRELY:, MISSING: -->`n## Output"
        $r = Get-EraResponseContract -PromptText $p
        $r.Count | Should -Be 3
        $r[0] | Should -Be 'ORDER:'
        $r[2] | Should -Be 'MISSING:'
    }

    It 'returns nothing when there is no marker — lenient by default' {
        # Every existing caller must keep working untouched.
        $r = Get-EraResponseContract -PromptText "# Just a normal prompt`nNo marker here."
        @($r).Count | Should -Be 0
    }

    It 'returns nothing for null or empty input' {
        @(Get-EraResponseContract -PromptText $null).Count | Should -Be 0
        @(Get-EraResponseContract -PromptText '').Count    | Should -Be 0
    }

    It 'ignores blank entries in the marker list' {
        $r = Get-EraResponseContract -PromptText '<!-- era-require: A:, , B: -->'
        @($r).Count | Should -Be 2
    }
}

Describe 'Test-ResponseContract' -Tag Unit {
    It 'passes when every required token is present' {
        $v = Test-ResponseContract -Response "ORDER: P1`nMISSING: none" -Required @('ORDER:', 'MISSING:')
        $v.Ok | Should -BeTrue
        @($v.Missing).Count | Should -Be 0
    }

    It 'accepts markdown-decorated headers — the measured deepseek case' {
        $v = Test-ResponseContract -Response '**P1: DO**' -Required @('P1:')
        $v.Ok | Should -BeTrue
    }

    It 'reports each missing token' {
        $v = Test-ResponseContract -Response 'ORDER: P1' -Required @('ORDER:', 'MISSING:', 'DROP:')
        $v.Ok | Should -BeFalse
        $v.Missing | Should -Contain 'MISSING:'
        $v.Missing | Should -Contain 'DROP:'
        $v.Missing | Should -Not -Contain 'ORDER:'
    }

    It 'is lenient when no contract is supplied' {
        (Test-ResponseContract -Response 'anything at all' -Required @()).Ok | Should -BeTrue
        (Test-ResponseContract -Response 'anything at all' -Required $null).Ok | Should -BeTrue
    }

    It 'fails an empty response against a real contract' {
        (Test-ResponseContract -Response '' -Required @('ORDER:')).Ok | Should -BeFalse
    }

    It 'treats a required token containing glob characters literally' {
        # .Contains(), not -like: '[x]' must not be read as a character class.
        $v = Test-ResponseContract -Response 'result [x] done' -Required @('[x]')
        $v.Ok | Should -BeTrue
    }
}

Describe 'era.ps1 enforces the contract at the dispatcher layer' -Tag Unit {
    It 'checks the contract after dispatch and BEFORE the agy fallback' {
        # Placement matters: a contract failure should be able to trigger the
        # existing agy fallback re-dispatch.
        $src = Get-Content -Raw $script:EraPath
        $dispatchIdx = $src.IndexOf('$results = Invoke-ReviewerDispatch')
        $contractIdx = $src.IndexOf('Get-EraResponseContract')
        $fallbackIdx = $src.IndexOf('ERA_AGY_FALLBACK')
        $dispatchIdx | Should -BeGreaterThan 0
        $contractIdx | Should -BeGreaterThan $dispatchIdx
        $contractIdx | Should -BeLessThan $fallbackIdx
    }

    It 'marks a contract failure the same way opencode marks a bad capture' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match "response-contract"
        $src | Should -Match '\$res\.ExitCode\s*=\s*-1'
        $src | Should -Match '\$res\.ContentOk\s*=\s*\$false'
    }
}

Describe 'Convergence signals are no longer dead' -Tag Unit {
    It 'selects the primary result by ExitCode, not by the rarely-set ContentOk' {
        # Only agy and opencode ever set ContentOk; geminiapi, anthropic, claude
        # and openaicompat never do, so the old filter selected nothing for a
        # REST-only run.
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Not -Match '\$results\.Values\s*\|\s*Where-Object\s*\{\s*\$_\.ContentOk\s*\}'
        $src | Should -Match '\$_\.ExitCode\s*-eq\s*0'
    }

    It 'derives response length from Response, since no adapter sets ResponseChars' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Not -Match '\$primaryResult\.ResponseChars'
        $src | Should -Match '\$primaryResult\.Response\.Length'
    }
}
```

- [ ] **Step 2: Run and verify RED**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/ResponseContract.Tests.ps1 -Output Detailed"`

Expected: the three `Describe` blocks covering the helpers fail with `CommandNotFoundException`; the `era.ps1` source checks fail on missing text. Do **not** implement anything.

- [ ] **Step 3: Do NOT commit.** The parent session commits all three test files together.

---

### Task 2: Porcelain-parse tests

**Files:** Create `tests/PorcelainParse.Tests.ps1`

**Interfaces:**
- Produces the contract for `Get-EraPorcelainPaths -RepoRoot <string> -> [string[]]`, implemented in Task 4 and called by Task 5.

- [ ] **Step 1: Write the failing test file**

Create `tests/PorcelainParse.Tests.ps1` with exactly this content:

```powershell
# Tests for git status --porcelain parsing.
#
# The old parse stripped three characters and kept the remainder, so a rename
# 'R  old -> new' produced the non-path 'old -> new', and core.quotePath wrapped
# non-ASCII names in quotes that survived into the path. Both then failed
# Test-Path with a confusing "paths not found".
#
# Measured on this box with --porcelain -z, a rename emits TWO NUL-terminated
# fields, DESTINATION FIRST:
#   [R  new.md]  [old.md]  [?? probe.ps1]  [?? untracked.md]
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/PorcelainParse.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"

    function New-GitRepoWithRename {
        param([string]$Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        Push-Location $Root
        try {
            & git init -q 2>&1 | Out-Null
            & git config user.email 't@t.t' 2>&1 | Out-Null
            & git config user.name  'T'     2>&1 | Out-Null
            Set-Content -Path (Join-Path $Root 'old.md') -Value 'a'
            & git add -A 2>&1 | Out-Null
            & git commit -q -m init 2>&1 | Out-Null
            & git mv old.md new.md 2>&1 | Out-Null
            Set-Content -Path (Join-Path $Root 'untracked.md') -Value 'z'
        } finally { Pop-Location }
    }
}

Describe 'Get-EraPorcelainPaths' -Tag Unit {
    It 'returns the rename DESTINATION, never the "old -> new" arrow form' {
        $tmp = Join-Path $env:TEMP "era-porc-ren-$(New-Guid)"
        try {
            New-GitRepoWithRename -Root $tmp
            $paths = Get-EraPorcelainPaths -RepoRoot $tmp
            $paths | Should -Contain 'new.md'
            @($paths | Where-Object { $_ -match '->' }) | Should -BeNullOrEmpty
            # The source path must not be reported as a changed file: it no
            # longer exists, so it would fail Test-Path downstream.
            $paths | Should -Not -Contain 'old.md'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'returns untracked files' {
        $tmp = Join-Path $env:TEMP "era-porc-unt-$(New-Guid)"
        try {
            New-GitRepoWithRename -Root $tmp
            Get-EraPorcelainPaths -RepoRoot $tmp | Should -Contain 'untracked.md'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'handles a path containing spaces without quoting artefacts' {
        $tmp = Join-Path $env:TEMP "era-porc-sp-$(New-Guid)"
        try {
            New-GitRepoWithRename -Root $tmp
            Set-Content -Path (Join-Path $tmp 'a spaced name.md') -Value 'x'
            $paths = Get-EraPorcelainPaths -RepoRoot $tmp
            $paths | Should -Contain 'a spaced name.md'
            @($paths | Where-Object { $_ -match '"' }) | Should -BeNullOrEmpty
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'returns an empty list for a clean repo' {
        $tmp = Join-Path $env:TEMP "era-porc-clean-$(New-Guid)"
        try {
            New-GitRepoWithRename -Root $tmp
            Push-Location $tmp
            try { & git add -A 2>&1 | Out-Null; & git commit -q -m x 2>&1 | Out-Null } finally { Pop-Location }
            @(Get-EraPorcelainPaths -RepoRoot $tmp).Count | Should -Be 0
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'returns an empty list outside a git repo instead of throwing' {
        $tmp = Join-Path $env:TEMP "era-porc-nogit-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            { Get-EraPorcelainPaths -RepoRoot $tmp } | Should -Not -Throw
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}

Describe 'era.ps1 uses the shared porcelain helper' -Tag Unit {
    It 'has no hand-rolled three-character strip left' {
        $src = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtimes/era.ps1')
        $src | Should -Not -Match "replace\s+'\^\.\{3\}'"
        $src | Should -Match 'Get-EraPorcelainPaths'
    }
}
```

- [ ] **Step 2: Run and verify RED**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/PorcelainParse.Tests.ps1 -Output Detailed"`

Expected: `CommandNotFoundException` for `Get-EraPorcelainPaths`, plus the source check failing.

- [ ] **Step 3: Do NOT commit.**

---

### Task 3: Registry-capability tests

**Files:** Create `tests/RegistryCapabilities.Tests.ps1`

**Interfaces:** none produced; asserts registry data and adapter source.

- [ ] **Step 1: Write the failing test file**

Create `tests/RegistryCapabilities.Tests.ps1` with exactly this content:

```powershell
# Tests that per-preset capabilities live in the registry and every adapter
# honours them.
#
# max_tokens was set only on openaicompat presets and propagated in era.ps1;
# geminiapi and anthropic ignored it and hardcoded 8192. $ModelInfo is already
# passed to every adapter (workflow.ps1:848), so only the values and the reads
# were missing.
#
# Scope is deliberately max_tokens ONLY. attach_limit_bytes and
# supports_structured_output stay out until forced structured output consumes
# them -- speculative generality otherwise.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/RegistryCapabilities.Tests.ps1"

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:Registry  = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/_registry.json') | ConvertFrom-Json
}

Describe 'Registry declares max_tokens for REST presets' -Tag Unit {
    It 'every geminiapi and anthropic preset declares max_tokens' {
        $missing = @()
        foreach ($p in $script:Registry.PSObject.Properties) {
            if ($p.Name -like '_*') { continue }
            if ($p.Value.backend -notin @('geminiapi', 'anthropic')) { continue }
            if (-not $p.Value.max_tokens) { $missing += $p.Name }
        }
        $missing | Should -BeNullOrEmpty
    }

    It 'declares 8192 — the value the adapters already hardcoded, so this is behaviour-preserving' {
        foreach ($p in $script:Registry.PSObject.Properties) {
            if ($p.Name -like '_*') { continue }
            if ($p.Value.backend -notin @('geminiapi', 'anthropic')) { continue }
            [int]$p.Value.max_tokens | Should -BeGreaterThan 0
        }
    }
}

Describe 'Adapters honour the registry value' -Tag Unit {
    # Same shape as tests/ProcessTreeKill.Tests.ps1: assert the invariant across
    # every adapter that has the capability, not just one.
    It 'geminiapi reads $ModelInfo.max_tokens and does not hardcode the cap' {
        $src = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/geminiapi.ps1')
        $src | Should -Match '\$ModelInfo\.max_tokens'
        $src | Should -Not -Match 'maxOutputTokens\s*=\s*8192'
    }

    It 'anthropic reads $ModelInfo.max_tokens and does not hardcode the cap' {
        $src = Get-Content -Raw (Join-Path $script:SkillRoot 'backends/anthropic.ps1')
        $src | Should -Match '\$ModelInfo\.max_tokens'
        $src | Should -Not -Match 'max_tokens\s*=\s*8192'
    }

    It 'both adapters keep 8192 as the fallback when the registry is silent' {
        foreach ($f in @('backends/geminiapi.ps1', 'backends/anthropic.ps1')) {
            $src = Get-Content -Raw (Join-Path $script:SkillRoot $f)
            $src | Should -Match '8192'
        }
    }
}
```

- [ ] **Step 2: Run and verify RED**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/RegistryCapabilities.Tests.ps1 -Output Detailed"`

Expected: the registry test fails (no `max_tokens` on those presets) and both adapter source checks fail.

- [ ] **Step 3: Do NOT commit.**

---

### Task 4: `workflow.ps1` — four helpers

**Files:** Modify `workflow.ps1`

**Interfaces:**
- Produces: `ConvertTo-EraContractNormalized`, `Get-EraResponseContract`, `Test-ResponseContract`, `Get-EraPorcelainPaths` — all called by Task 5.

- [ ] **Step 1: Add the helpers**

Insert all four functions immediately **before** `function Test-EraPathInsideRoot {`:

```powershell
function ConvertTo-EraContractNormalized {
    <#
    .SYNOPSIS
        Normalise text for decoration-tolerant contract matching.

    .DESCRIPTION
        Measured on the 2026-08-09 panel: deepseek-flash answered '**P1: DO**'
        while gemini and opus answered 'P1: DO'. A literal check would have
        failed the sharpest response in the panel, so strip markdown decoration
        before comparing.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text -replace '[*`_#]', ''
    $t = $t -replace '\s+', ' '
    return $t.Trim().ToLowerInvariant()
}

function Get-EraResponseContract {
    <#
    .SYNOPSIS
        Read a prompt's declared response contract.

    .DESCRIPTION
        A prompt declares what its answer must contain with a marker line:

            <!-- era-require: ORDER:, DROP-ENTIRELY:, MISSING: -->

        The contract travels WITH the prompt, so a -PromptOverrideFile carries
        its own and no extra parameter is needed. No marker means lenient --
        exactly the behaviour before this existed, so existing callers are
        untouched.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$PromptText)
    if ([string]::IsNullOrEmpty($PromptText)) { return @() }
    if ($PromptText -notmatch '(?im)<!--\s*era-require:\s*(.+?)\s*-->') { return @() }
    return @($matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-ResponseContract {
    <#
    .SYNOPSIS
        Does a reviewer's response contain everything the prompt required?

    .DESCRIPTION
        Nothing verified that an answer matched the request: adapters checked
        non-empty text plus a finish reason, then returned ExitCode=0. A reviewer
        returned zero of ten requested verdicts three times and each was recorded
        as a normal success -- and the promoted response feeds the NEXT round's
        prompt, so a bad round poisons its successor.

        Uses .Contains() rather than -like, so a required token containing '[' or
        '*' is matched literally instead of being read as a glob.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Response,
        [AllowNull()][string[]]$Required
    )
    $req = @($Required | Where-Object { $_ })
    if ($req.Count -eq 0) { return @{ Ok = $true; Missing = @() } }

    $haystack = ConvertTo-EraContractNormalized -Text $Response
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $req) {
        $needle = ConvertTo-EraContractNormalized -Text $r
        if (-not $needle) { continue }
        if (-not $haystack.Contains($needle)) { $missing.Add($r) }
    }
    return @{ Ok = ($missing.Count -eq 0); Missing = @($missing) }
}

function Get-EraPorcelainPaths {
    <#
    .SYNOPSIS
        Changed-file paths from `git status`, parsed correctly.

    .DESCRIPTION
        The old parse stripped three characters and kept the remainder, so a
        rename 'R  old -> new' yielded the non-path 'old -> new', and
        core.quotePath wrapped non-ASCII names in quotes that survived into the
        path. Both then failed Test-Path with a confusing "paths not found".

        --porcelain -z emits NUL-terminated records with no quoting and no
        escaping. Measured on this box, a rename emits TWO fields, destination
        first:
            [R  new.md]  [old.md]  [?? probe.ps1]  [?? untracked.md]
        So for an R or C status, skip the following field -- it is the source
        path, which no longer exists and would fail Test-Path downstream.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @() }

    Push-Location $RepoRoot
    try {
        $raw = (& git status --porcelain -z 2>$null) -join ''
    } catch {
        return @()
    } finally {
        Pop-Location
    }
    if ([string]::IsNullOrEmpty($raw)) { return @() }

    $fields = @($raw -split "`0" | Where-Object { $_ -ne '' })
    $paths  = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $fields.Count; $i++) {
        $rec = $fields[$i]
        if ($rec.Length -lt 4) { continue }
        $xy   = $rec.Substring(0, 2)
        $path = $rec.Substring(3).Trim()
        if ($path) { $paths.Add($path) }
        # Rename/copy records carry a second field: the source path.
        if ($xy -match '[RC]') { $i++ }
    }
    return @($paths)
}

```

- [ ] **Step 2: Run both affected test files**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/ResponseContract.Tests.ps1,tests/PorcelainParse.Tests.ps1 -Output Detailed"`

Expected: every `Describe` covering the four helpers PASSES. The `era.ps1` source checks still FAIL — Task 5 fixes those.

- [ ] **Step 3: Commit**

```bash
cd ~/.claude/skills/external-review-auto
git add workflow.ps1
git commit -m "feat(contract): add response-contract and porcelain helpers

Test-ResponseContract is decoration-tolerant because it has to be: on the
2026-08-09 panel deepseek-flash answered '**P1: DO**' while gemini and opus
answered 'P1: DO', so a literal check would have failed the sharpest response.

Get-EraPorcelainPaths uses --porcelain -z, whose records are NUL-terminated with
no quoting. Measured: a rename emits two fields, destination first.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `runtimes/era.ps1` — enforce the contract, repair convergence, use the helper

**Files:** Modify `runtimes/era.ps1`

**Interfaces:** Consumes all four Task 4 functions. `era.ps1` already dot-sources `workflow.ps1`.

- [ ] **Step 1: Enforce the contract after dispatch**

Find this line (it appears once):

```powershell
    # --- Item #1 (v1.10): agy auto-fallback on capture failure ---
```

Insert the following block immediately **before** it:

```powershell
    # --- Response contract (P1) ---------------------------------------------
    # Nothing verified that an answer matched the request: adapters check
    # non-empty text plus a finish reason, then return ExitCode=0, and
    # Copy-PrimaryResponseAlias promotes on ExitCode alone. A reviewer returned
    # zero of ten requested verdicts three times, each recorded as a success --
    # and the promoted file feeds Invoke-PromptTokenSubstitution into round N+1,
    # so a bad round poisons the next one.
    #
    # A failure is marked exactly the way opencode marks a bad agentic capture
    # (ExitCode=-1 + ContentOk=$false), so every existing consumer already does
    # the right thing: the alias skips it, the metadata writer records
    # content_ok=false, and the agy fallback below re-dispatches. The response
    # file stays on disk -- it is evidence, not garbage; only its promotion to
    # canonical is withheld.
    #
    # Runs BEFORE the fallback block so a contract failure can trigger it.
    $contractRequired = @(Get-EraResponseContract -PromptText (Get-Content -Raw $promptPath -ErrorAction SilentlyContinue))
    if ($contractRequired.Count -gt 0) {
        Write-Host "[era] Response contract: $($contractRequired -join ', ')"
        foreach ($k in @($results.Keys)) {
            $res = $results[$k]
            if (-not $res -or $res.ExitCode -ne 0) { continue }
            $verdict = Test-ResponseContract -Response $res.Response -Required $contractRequired
            if (-not $verdict.Ok) {
                $miss = ($verdict.Missing -join ', ')
                Write-Host "[era] $k FAILED the response contract; missing: $miss"
                $res.ExitCode    = -1
                $res.ContentOk   = $false
                $res.Error       = 'response-contract'
                $res.RetryReason = "response-contract: missing $miss"
                $res.Warnings    = @($res.Warnings) + "Response contract failed; missing: $miss"
                $results[$k] = $res
            }
        }
    }

```

- [ ] **Step 2: Repair the convergence signals**

Find:

```powershell
    $primaryResult = @($results.Values) | Where-Object { $_.ContentOk } | Select-Object -First 1
    $currentResponseChars = if ($primaryResult) { $primaryResult.ResponseChars } else { 0 }
```

Replace with:

```powershell
    # Filter on ExitCode, not ContentOk: only agy and opencode ever set that key,
    # so a REST-only run selected nothing. And no adapter sets ResponseChars at
    # all -- the length is computed later in the metadata writer -- so this was
    # always 0 and two of the three convergence signals could never fire.
    # A contract-failed reviewer is ExitCode=-1, so it is correctly excluded.
    $primaryResult = @($results.Values) | Where-Object { $_.ExitCode -eq 0 } | Select-Object -First 1
    $currentResponseChars = if ($primaryResult -and $primaryResult.Response) { $primaryResult.Response.Length } else { 0 }
```

- [ ] **Step 3: Replace the first porcelain parse (around line 350)**

Find:

```powershell
        $uncommitted = @(& git status --porcelain 2>$null |
            Where-Object { $_ -match '^\S\S\s+(.+)$' -or $_ -match '^\s+(.+)$' } |
            ForEach-Object { ($_ -replace '^.{3}', '').Trim() } |
            Where-Object { $_ })
```

There are **two** occurrences with different indentation. Replace the one indented with **8 spaces** with:

```powershell
        $uncommitted = @(Get-EraPorcelainPaths -RepoRoot $repoRoot)
```

- [ ] **Step 4: Replace the second porcelain parse (around line 909)**

The remaining occurrence is indented with **8 spaces** inside the `-AutoDetect` block. Replace it with:

```powershell
        $uncommitted = @(Get-EraPorcelainPaths -RepoRoot $repoRoot)
```

Verify both are gone: `command grep -n "replace '\^\.{3}'" runtimes/era.ps1` — expected: no output.

- [ ] **Step 5: Run the three new test files**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/ResponseContract.Tests.ps1,tests/PorcelainParse.Tests.ps1 -Output Detailed"`

Expected: all PASS.

- [ ] **Step 6: Run the full suite**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -Command "Invoke-Pester -Path tests/ -Output Detailed"`

Expected: 0 failed. If a previously-passing test now fails, **stop and report** — do not edit that test.

Pay attention to `tests/AutoDetect.Tests.ps1` and `tests/IncludeFilesEmpty.Tests.ps1`, which exercise `-AutoDetect` and are the most likely to notice the porcelain change.

- [ ] **Step 7: Commit**

```bash
cd ~/.claude/skills/external-review-auto
git add runtimes/era.ps1
git commit -m "fix(era): enforce the response contract; repair dead convergence signals

A reviewer returned zero of ten requested verdicts three times and each was
recorded as a normal success. A contract failure is now marked exactly as
opencode marks a bad capture (ExitCode=-1 + ContentOk=\$false), so the alias
skips it, metadata records content_ok=false, and the agy fallback re-dispatches
-- no consumer needed changing. Opt-in per prompt via an era-require marker, so
default behaviour is unchanged.

Convergence: \$primaryResult filtered on ContentOk, which only agy and opencode
set, and read ResponseChars, which NO adapter sets -- so the length signals could
never fire. Now ExitCode plus Response.Length.

Porcelain parsing moves to the shared -z helper, fixing renames and quoted paths.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Registry capabilities (`backends/`)

**Files:** Modify `backends/_registry.json`, `backends/geminiapi.ps1`, `backends/anthropic.ps1`

**Interfaces:** none produced. Touches only `backends/` — safe to run concurrently with Tasks 4 and 5.

- [ ] **Step 1: Add `max_tokens` to the five REST presets**

In `backends/_registry.json`, add `"max_tokens": 8192,` to each preset whose `backend` is `geminiapi` or `anthropic`. There are exactly five: `gemini-api`, `gemini-api-pro`, `opus-api`, `sonnet-api`, `haiku-api`.

Place the key alongside the existing `backend` key in each object, matching the file's existing indentation and comma style. 8192 is the value both adapters already hardcode, so this is behaviour-preserving.

Validate the JSON still parses:
`"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Get-Content -Raw backends/_registry.json | ConvertFrom-Json | Out-Null; 'JSON OK'"`

- [ ] **Step 2: Make geminiapi read the registry**

In `backends/geminiapi.ps1`, immediately before the request body is built (before the line containing `maxOutputTokens   = 8192`), add:

```powershell
    # Capability from the registry, falling back to the value this adapter used
    # to hardcode. Raising a cap is now a config edit, not a code edit.
    $maxTokens = if ($ModelInfo.max_tokens) { [int]$ModelInfo.max_tokens } else { 8192 }
```

Then replace `maxOutputTokens   = 8192` with:

```powershell
            maxOutputTokens   = $maxTokens
```

And replace the truncation warning string `"Response hit maxOutputTokens=8192; consider raising or tightening the prompt."` with:

```powershell
"Response hit maxOutputTokens=$maxTokens; consider raising max_tokens for this preset in backends/_registry.json or tightening the prompt."
```

- [ ] **Step 3: Make anthropic read the registry**

In `backends/anthropic.ps1`, immediately before the request body is built (before the line containing `max_tokens = 8192`), add:

```powershell
    # Capability from the registry, falling back to the value this adapter used
    # to hardcode. Raising a cap is now a config edit, not a code edit.
    $maxTokens = if ($ModelInfo.max_tokens) { [int]$ModelInfo.max_tokens } else { 8192 }
```

Then replace `max_tokens = 8192` with:

```powershell
        max_tokens = $maxTokens
```

And replace the truncation warning string `"Response hit max_tokens=8192; consider raising or tightening the prompt."` with:

```powershell
"Response hit max_tokens=$maxTokens; consider raising max_tokens for this preset in backends/_registry.json or tightening the prompt."
```

- [ ] **Step 4: Run the capability tests**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/RegistryCapabilities.Tests.ps1 -Output Detailed"`

Expected: all PASS.

- [ ] **Step 5: Run the registry and backend test files**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/Registry.Tests.ps1,tests/ProcessTreeKill.Tests.ps1,tests/RegistryCapabilities.Tests.ps1 -Output Detailed"`

Expected: all PASS. `ProcessTreeKill.Tests.ps1` asserts an invariant across the adapters you just edited — it must stay green.

- [ ] **Step 6: Commit**

```bash
cd ~/.claude/skills/external-review-auto
git add backends/_registry.json backends/geminiapi.ps1 backends/anthropic.ps1
git commit -m "feat(registry): move the hardcoded token cap into per-preset capabilities

max_tokens was set only on openaicompat presets; geminiapi and anthropic ignored
the registry and hardcoded 8192. \$ModelInfo already reaches every adapter, so
only the values and the reads were missing. Declared at 8192 -- the value both
adapters already used -- so this is behaviour-preserving, and raising a cap is
now a config edit.

Scope is deliberately max_tokens only. attach_limit_bytes and
supports_structured_output stay out until forced structured output consumes
them.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage.** Unit 1 (contract) → Tasks 1, 4, 5. Unit 2 (convergence) → Tasks 1, 5. Unit 3 (porcelain) → Tasks 2, 4, 5. Unit 4 (registry) → Tasks 3, 6. Every spec test bullet has a test: contract parsing/absence/decoration/missing/enforcement, convergence selection and length, rename/spaces/clean/no-git, registry declaration and both adapter reads.

**Placeholders.** None — every step gives exact find/replace text or complete file content.

**Type consistency.** `Test-ResponseContract` returns `@{ Ok; Missing }` in Task 4 and is consumed as `$verdict.Ok` / `$verdict.Missing` in Task 5. `Get-EraResponseContract` returns `string[]`, consumed via `.Count` and `-join`. `Get-EraPorcelainPaths -RepoRoot` matches both call sites. `$maxTokens` is spelled identically in both adapters.

**Ordering.** Tasks 1–3 are disjoint new files (concurrent). Task 4 precedes Task 5. Task 6 is `backends/`-only and independent of 4 and 5.
