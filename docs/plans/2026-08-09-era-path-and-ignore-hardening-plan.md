# era Path-Boundary and Ignore-Pattern Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop era bundling vendored `node_modules` trees, stop it misclassifying prefix-sharing sibling directories as in-repo, and stop it deleting the repomix config on a failed run.

**Architecture:** One new pure predicate (`Test-EraPathInsideRoot`) replaces a boundary-less `StartsWith` idiom at seven sites across two files. The shipped repomix ignore patterns gain `**/` prefixes for the three generic junk directories, which forces a matching change to the pattern parser inside `Measure-EraBroadScope`. A success flag makes the `finally` block's config deletion conditional.

**Tech Stack:** PowerShell 7 (pwsh), Pester 5, repomix 1.12.0.

## Global Constraints

- **Repo:** `~/.claude/skills/external-review-auto` (its own git repo, branch `master`). All paths below are relative to it.
- **This is shared tooling used by multiple projects.** Make only the changes this plan specifies. Do not refactor beyond them.
- **Test command (always this exact command):**
  `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -Command "Invoke-Pester -Path tests/ -Output Detailed"`
- **Single-file test command:**
  `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/<FILE> -Output Detailed"`
- **Baseline before this plan: 404 passed / 0 failed.** Any task that reduces the passing count or introduces a failure is a stop-and-report, not a workaround.
- Tests dot-source `workflow.ps1` via `. "$PSScriptRoot/../workflow.ps1"`.
- The suite runs under **Windows** pwsh; literal `C:\...` paths in tests are fine.
- Commit after each task. End every commit message with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `tests/PathInsideRoot.Tests.ps1` | Create (Task 1) | Unit + integration coverage for the path predicate |
| `tests/IgnorePatternDepth.Tests.ps1` | Create (Task 2) | repomix depth semantics + pattern/parser contract |
| `tests/ConfigRetention.Tests.ps1` | Create (Task 3) | Config survives a failed run |
| `workflow.ps1` | Modify (Task 4) | Add the predicate; teach the parser `**/<dir>/**`; use predicate at 2 sites |
| `runtimes/era.ps1` | Modify (Task 5) | Use predicate at 5 sites; `**/` patterns; conditional config delete |

**Tasks 1, 2 and 3 create new files only and touch nothing else — run them concurrently.** Task 4 must complete before Task 5 (Task 5 calls the function Task 4 defines).

---

### Task 1: Path-boundary predicate tests

**Files:**
- Create: `tests/PathInsideRoot.Tests.ps1`

**Interfaces:**
- Consumes: nothing (Task 4 provides the implementation; these tests must fail until then).
- Produces: the contract for `Test-EraPathInsideRoot -Path <string> -Root <string> -> [bool]`, which Task 4 implements and Task 5 calls.

- [ ] **Step 1: Write the failing test file**

Create `tests/PathInsideRoot.Tests.ps1` with exactly this content:

```powershell
# Tests for Test-EraPathInsideRoot.
#
# Background (measured 2026-08-09): era used
# `$full.StartsWith($repoRoot, OrdinalIgnoreCase)` with no directory-separator
# boundary. With repo root C:\a\era-p6, the SIBLING C:\a\era-p6-ext\outside.md
# tested as INSIDE the repo and was relativized to '-ext/outside.md', which then
# failed Test-Path with a confusing "paths not found". The guard fails closed —
# the harm is silent loss of an explicitly requested file, not exfiltration.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/PathInsideRoot.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'
}

Describe 'Test-EraPathInsideRoot' -Tag Unit {
    It 'treats the root itself as inside' {
        Test-EraPathInsideRoot -Path 'C:\repo' -Root 'C:\repo' | Should -BeTrue
    }

    It 'treats a true child as inside' {
        Test-EraPathInsideRoot -Path 'C:\repo\src\a.md' -Root 'C:\repo' | Should -BeTrue
    }

    It 'treats a prefix-sharing SIBLING as outside' {
        # The measured defect.
        Test-EraPathInsideRoot -Path 'C:\repo-ext\outside.md' -Root 'C:\repo' | Should -BeFalse
    }

    It 'treats a sibling that differs only after the root name as outside' {
        Test-EraPathInsideRoot -Path 'C:\Users\Joshua2\x.md' -Root 'C:\Users\Joshua' | Should -BeFalse
    }

    It 'ignores a trailing separator on the root' {
        Test-EraPathInsideRoot -Path 'C:\repo\a.md' -Root 'C:\repo\' | Should -BeTrue
    }

    It 'is case-insensitive' {
        Test-EraPathInsideRoot -Path 'C:\REPO\a.md' -Root 'c:\repo' | Should -BeTrue
    }

    It 'accepts forward slashes' {
        Test-EraPathInsideRoot -Path 'C:/repo/a.md' -Root 'C:\repo' | Should -BeTrue
    }

    It 'returns false when either side is null or empty' {
        Test-EraPathInsideRoot -Path $null            -Root 'C:\repo' | Should -BeFalse
        Test-EraPathInsideRoot -Path 'C:\repo\a.md'   -Root ''        | Should -BeFalse
    }

    It 'does not require the path to exist on disk' {
        Test-EraPathInsideRoot -Path 'C:\repo\nope\never.md' -Root 'C:\repo' | Should -BeTrue
    }
}

Describe 'era.ps1 uses the predicate, not a bare StartsWith' -Tag Unit {
    It 'has no boundary-less StartsWith($repoRoot) left in era.ps1' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Not -Match 'StartsWith\(\$repoRoot'
        $src | Should -Not -Match 'StartsWith\(\$homeFull'
        $src | Should -Match 'Test-EraPathInsideRoot'
    }

    It 'has no boundary-less StartsWith($RepoRoot) left in workflow.ps1' {
        $wf = Get-Content -Raw (Join-Path $script:SkillRoot 'workflow.ps1')
        $wf | Should -Not -Match 'StartsWith\(\$RepoRoot'
    }
}

Describe 'Integration: a prefix-sharing sibling is staged, not misclassified' -Tag Integration {
    It 'stages an out-of-repo file whose parent shares the repo-root prefix' {
        # Repo root  : <tmp>\era-pfx
        # Source file: <tmp>\era-pfx-ext\outside.md   <-- shares the prefix
        $stamp = "$(New-Guid)".Substring(0, 8)
        $repo  = Join-Path $env:TEMP "era-pfx-$stamp"
        $ext   = Join-Path $env:TEMP "era-pfx-$stamp-ext"
        New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path $ext -Force | Out-Null
        try {
            Set-Content -Path (Join-Path $repo 'inrepo.md') -Value '# in-repo'
            $extFile = Join-Path $ext 'outside.md'
            Set-Content -Path $extFile -Value 'OUTSIDE-PREFIX-MARKER'

            # Pair with a missing in-repo path so the run stops at path
            # validation AFTER staging (no repomix, no dispatch).
            $out = & pwsh -NonInteractive -Command @"
Set-Location '$repo'
try {
    & '$($script:EraPath)' -TopicSlug 'pfx-test' -Force -IncludeFiles '$extFile,definitely-missing.py' 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String

            # Before the fix this printed "paths not found ... -ext/outside.md".
            $out | Should -Match 'Staged out-of-repo file'
            $out | Should -Not -Match '\-ext[\\/]outside\.md'
        } finally {
            Remove-Item -Recurse -Force $repo, $ext -ErrorAction SilentlyContinue
        }
    }
}
```

- [ ] **Step 2: Run the file and verify it fails for the right reason**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/PathInsideRoot.Tests.ps1 -Output Detailed"`

Expected: the `Test-EraPathInsideRoot` tests fail with `CommandNotFoundException: The term 'Test-EraPathInsideRoot' is not recognized`. The source-check and integration tests also fail. **Do not implement anything to fix them — Tasks 4 and 5 do that.**

- [ ] **Step 3: Commit the failing tests**

```bash
cd ~/.claude/skills/external-review-auto
git add tests/PathInsideRoot.Tests.ps1
git commit -m "test(path): red tests for boundary-aware repo-root containment

C:\\a\\era-p6-ext tested as INSIDE C:\\a\\era-p6 because StartsWith has no
directory-separator boundary. Measured while probing P6 staging.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Ignore-pattern depth tests

**Files:**
- Create: `tests/IgnorePatternDepth.Tests.ps1`

**Interfaces:**
- Consumes: `Measure-EraBroadScope -RepoRoot <string> -Include <string[]> -IgnorePatterns <string[]> [-Limit <int>] [-MaxDirs <int>]`, which already exists in `workflow.ps1` and returns a hashtable with keys `FileCount`, `Bytes`, `Truncated`, `Reason`.
- Produces: the contract that the parser recognises **both** `<dir>/**` (root-anchored) and `**/<dir>/**` (any depth), which Task 4 implements.

- [ ] **Step 1: Write the failing test file**

Create `tests/IgnorePatternDepth.Tests.ps1` with exactly this content:

```powershell
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
```

- [ ] **Step 2: Run the file and verify it fails for the right reason**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/IgnorePatternDepth.Tests.ps1 -Output Detailed"`

Expected failures:
- "prunes a nested directory for `**/<dir>/**`" → `FileCount` is 3, not 1 (parser does not recognise the shape yet).
- "ships `**/`-prefixed patterns…" → no match, era.ps1 still has bare patterns.

The "still prunes root-only" and repomix-measurement tests should **pass already** — they assert current, correct behaviour. That is expected; do not change them.

- [ ] **Step 3: Commit the failing tests**

```bash
cd ~/.claude/skills/external-review-auto
git add tests/IgnorePatternDepth.Tests.ps1
git commit -m "test(ignore): red tests for **/<dir>/** depth semantics

Measured: repomix bundles packages/p/node_modules/d/a.md despite
'node_modules/**' -- bare patterns are root-anchored. Adds the pattern/parser
contract test that would have caught the original under-count.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Config-retention tests

**Files:**
- Create: `tests/ConfigRetention.Tests.ps1`

**Interfaces:**
- Consumes: nothing new.
- Produces: the contract that `round-N-config.json` survives a failed run while `round-N-claim.json` is still removed. Task 5 implements it.

- [ ] **Step 1: Write the failing test file**

Create `tests/ConfigRetention.Tests.ps1` with exactly this content:

```powershell
# Tests that a FAILED era run leaves its repomix config behind to diagnose from.
#
# era.ps1's finally block deleted round-N-config.json on success and failure
# alike (PowerShell unwinds `exit` through `finally`), and the manifest that
# would replace it is written only AFTER repomix succeeds. So a failed run left
# no bundle, no manifest and no config. The claim-file deletion two lines above
# is correct -- that is per-process state. The config is a receipt, not a
# tombstone.
#
# The failure used here is the pre-existing "Bundle is empty" guard: an empty
# directory passes Test-Path validation, then matches nothing in repomix.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/ConfigRetention.Tests.ps1"

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'

    function Invoke-FailingEraRun {
        <# Repo whose only include target is an empty dir => "Bundle is empty". #>
        param([string]$Repo)
        New-Item -ItemType Directory -Path (Join-Path $Repo '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Repo 'emptydir') -Force | Out-Null
        & pwsh -NonInteractive -Command @"
Set-Location '$Repo'
try {
    & '$($script:EraPath)' -TopicSlug 'cfg-test' -Reviewer gemini -Force -IncludeFiles 'emptydir' 2>&1 | Out-String
} catch {
    Write-Output "CAUGHT: `$(`$_.Exception.Message)"
}
"@ 2>&1 | Out-String
    }
}

Describe 'Repomix config survives a failed run' -Tag Integration {
    It 'retains round-1-config.json when the run dies at the empty-bundle guard' {
        $repo = Join-Path $env:TEMP "era-cfg-keep-$(New-Guid)"
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        try {
            $out = Invoke-FailingEraRun -Repo $repo
            # Confirm we actually exercised the failure path we think we did.
            $out | Should -Match 'Bundle is empty'
            Test-Path (Join-Path $repo '.external-reviews/cfg-test/round-1-config.json') |
                Should -BeTrue
        } finally { Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue }
    }

    It 'still removes the round-claim file on that same failure' {
        # The claim is per-process state; leaving it would permanently block the
        # round number. This must NOT regress while fixing the config.
        $repo = Join-Path $env:TEMP "era-cfg-claim-$(New-Guid)"
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        try {
            $null = Invoke-FailingEraRun -Repo $repo
            Test-Path (Join-Path $repo '.external-reviews/cfg-test/round-1-claim.json') |
                Should -BeFalse
        } finally { Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue }
    }

    It 'names the retained config in the failure output' {
        $repo = Join-Path $env:TEMP "era-cfg-msg-$(New-Guid)"
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        try {
            $out = Invoke-FailingEraRun -Repo $repo
            $out | Should -Match 'round-1-config\.json'
        } finally { Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue }
    }

    It 'deletes the config only on success (source check)' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match '\$runSucceeded'
        # The delete must be guarded by the flag, not unconditional.
        $src | Should -Match 'if\s*\(\s*\$runSucceeded[^\r\n]*\$configPath'
    }
}
```

- [ ] **Step 2: Run the file and verify it fails for the right reason**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/ConfigRetention.Tests.ps1 -Output Detailed"`

Expected: all four fail. The first because the config was deleted by `finally`; the third because the message does not mention it; the fourth because `$runSucceeded` does not exist. The second ("still removes the claim file") may pass already — it asserts existing correct behaviour and must keep passing.

- [ ] **Step 3: Commit the failing tests**

```bash
cd ~/.claude/skills/external-review-auto
git add tests/ConfigRetention.Tests.ps1
git commit -m "test(config): red tests for retaining the repomix config on failure

A failed run left no bundle, no manifest and no config -- nothing to diagnose
from. The claim-file delete is correct and must keep working; the config delete
is not.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `workflow.ps1` — predicate, parser, and its own two call sites

**Files:**
- Modify: `workflow.ps1` (add function; edit `Measure-EraBroadScope`; edit lines 41 and 203)
- Test: `tests/PathInsideRoot.Tests.ps1`, `tests/IgnorePatternDepth.Tests.ps1`

**Interfaces:**
- Consumes: the contracts from Tasks 1 and 2.
- Produces: `Test-EraPathInsideRoot -Path <string> -Root <string> -> [bool]`, called by Task 5 at five sites in `era.ps1`.

- [ ] **Step 1: Add the predicate**

In `workflow.ps1`, insert this function immediately **before** `function Get-EraTruncatedText {`:

```powershell
function Test-EraPathInsideRoot {
    <#
    .SYNOPSIS
        Boundary-aware containment test: is $Path the same as, or beneath, $Root?

    .DESCRIPTION
        Replaces `$p.StartsWith($root, OrdinalIgnoreCase)`, which has no
        directory-separator boundary. Measured 2026-08-09: with repo root
        C:\a\era-p6, the SIBLING C:\a\era-p6-ext\outside.md tested as inside and
        was relativized to '-ext/outside.md', which then failed Test-Path. The
        old guard failed closed, so the harm was silent loss of an explicitly
        requested file rather than exfiltration.

        Pure string comparison after normalisation -- no filesystem access, so it
        works for paths that do not exist yet.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }

    function Get-Normalized([string]$p) {
        $n = $p
        try { $n = [System.IO.Path]::GetFullPath($p) } catch { }
        return ($n -replace '\\', '/').TrimEnd('/')
    }

    $normPath = Get-Normalized $Path
    $normRoot = Get-Normalized $Root
    if ($normRoot.Length -eq 0) { return $false }

    if ([string]::Equals($normPath, $normRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $normPath.StartsWith($normRoot + '/', [System.StringComparison]::OrdinalIgnoreCase)
}
```

- [ ] **Step 2: Run the predicate tests to verify they pass**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/PathInsideRoot.Tests.ps1 -Output Detailed"`

Expected: the nine `Describe 'Test-EraPathInsideRoot'` tests PASS. The source-check and integration tests still FAIL — Task 5 fixes those.

- [ ] **Step 3: Teach the parser the `**/<dir>/**` shape**

In `Measure-EraBroadScope`, find this block:

```powershell
    $skipDirs = [System.Collections.Generic.HashSet[string]]::new($cmp)
    $skipExts = [System.Collections.Generic.HashSet[string]]::new($cmp)
    foreach ($p in @($IgnorePatterns)) {
        $n = "$p" -replace '\\', '/'
        if ($n -match '^([^*]+)/\*\*$') { [void]$skipDirs.Add($matches[1].TrimEnd('/')); continue }
        if ($n -match '^\*(\.[^*/]+)$') { [void]$skipExts.Add($matches[1]); continue }
    }
```

Replace it with:

```powershell
    # Two shapes, matching repomix exactly:
    #   '<dir>/**'      -> root-anchored; prune that one relative path
    #   '**/<dir>/**'   -> any depth;     prune any directory with that leaf name
    # Nothing used to assert this parser understood the list era hands repomix,
    # which is how the original under-count shipped. See the contract test in
    # tests/IgnorePatternDepth.Tests.ps1.
    $skipDirs     = [System.Collections.Generic.HashSet[string]]::new($cmp)
    $skipDirNames = [System.Collections.Generic.HashSet[string]]::new($cmp)
    $skipExts     = [System.Collections.Generic.HashSet[string]]::new($cmp)
    foreach ($p in @($IgnorePatterns)) {
        $n = "$p" -replace '\\', '/'
        if ($n -match '^\*\*/([^*/]+)/\*\*$') { [void]$skipDirNames.Add($matches[1]); continue }
        if ($n -match '^([^*]+)/\*\*$')       { [void]$skipDirs.Add($matches[1].TrimEnd('/')); continue }
        if ($n -match '^\*(\.[^*/]+)$')       { [void]$skipExts.Add($matches[1]); continue }
    }
```

- [ ] **Step 4: Apply the name-based prune in the walk**

Still in `Measure-EraBroadScope`, find:

```powershell
        foreach ($s in $subDirs) {
            $subRel = ($s.Substring($root.Length).TrimStart('\', '/')) -replace '\\', '/'
            if ($skipDirs.Contains($subRel)) { continue }
```

Replace with:

```powershell
        foreach ($s in $subDirs) {
            if ($skipDirNames.Contains([System.IO.Path]::GetFileName($s))) { continue }
            $subRel = ($s.Substring($root.Length).TrimStart('\', '/')) -replace '\\', '/'
            if ($skipDirs.Contains($subRel)) { continue }
```

- [ ] **Step 5: Replace the two `StartsWith` sites in this file**

There are two textually identical lines (around lines 41 and 203):

```powershell
                if (-not $cp.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
```

Replace **both** occurrences with:

```powershell
                if (-not (Test-EraPathInsideRoot -Path $cp -Root $RepoRoot)) { continue }
```

Preserve each line's original leading indentation (the first is inside a `foreach` at one nesting level, the second is one level deeper). Verify with:
`grep -n 'StartsWith($RepoRoot' workflow.ps1` — expected: no output.

- [ ] **Step 6: Run both test files to verify the unit tests pass**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/PathInsideRoot.Tests.ps1,tests/IgnorePatternDepth.Tests.ps1 -Output Detailed"`

Expected: the `Measure-EraBroadScope` depth tests PASS, the predicate tests PASS, and the `workflow.ps1` half of the source check PASSES. Still failing (Task 5's job): the `era.ps1` source checks, the `**/`-prefixed-pattern test, and the staging integration test.

- [ ] **Step 7: Run the full suite to confirm nothing regressed**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -Command "Invoke-Pester -Path tests/ -Output Detailed"`

Expected: no test that passed at the 404 baseline now fails. Only the Task 1/2/3 tests awaiting Task 5 should be red.

- [ ] **Step 8: Commit**

```bash
cd ~/.claude/skills/external-review-auto
git add workflow.ps1
git commit -m "feat(paths): add Test-EraPathInsideRoot; teach the scope parser **/<dir>/**

Boundary-aware containment replaces a StartsWith with no directory-separator
boundary, which classified C:\\a\\era-p6-ext as inside C:\\a\\era-p6.

The parser now recognises both '<dir>/**' (root-anchored) and '**/<dir>/**' (any
depth), matching repomix. Without this, the '**/' patterns era is about to ship
would stop the measurer pruning node_modules at all.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `runtimes/era.ps1` — five call sites, `**/` patterns, config retention

**Files:**
- Modify: `runtimes/era.ps1`
- Test: all three new test files

**Interfaces:**
- Consumes: `Test-EraPathInsideRoot` from Task 4. `era.ps1` already dot-sources `workflow.ps1`, so no import change is needed.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Replace call site 1 — `-SpecReview` relativize**

Find:

```powershell
    if ($specReviewPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
```

Replace with:

```powershell
    if (Test-EraPathInsideRoot -Path $specReviewPath -Root $repoRoot) {
```

- [ ] **Step 2: Replace call site 2 — staging predicate**

Find:

```powershell
            if (-not [System.IO.Path]::GetFullPath($entry).StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
```

Replace with:

```powershell
            if (-not (Test-EraPathInsideRoot -Path ([System.IO.Path]::GetFullPath($entry)) -Root $repoRoot)) {
```

- [ ] **Step 3: Replace call site 3 — staging relativize**

Find:

```powershell
            if ($full.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
```

Replace with:

```powershell
            if (Test-EraPathInsideRoot -Path $full -Root $repoRoot) {
```

- [ ] **Step 4: Replace call site 4 — `$HOME` mirror**

Find:

```powershell
            if ($full.StartsWith($homeFull, [System.StringComparison]::OrdinalIgnoreCase)) {
```

Replace with:

```powershell
            if (Test-EraPathInsideRoot -Path $full -Root $homeFull) {
```

- [ ] **Step 5: Replace call site 5 — traversal guard**

Find:

```powershell
                -not $resolved.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
```

Replace with:

```powershell
                -not (Test-EraPathInsideRoot -Path $resolved -Root $repoRoot)
```

Verify all five: `grep -n 'StartsWith($repoRoot\|StartsWith($homeFull' runtimes/era.ps1` — expected: no output.

- [ ] **Step 6: Ship the `**/`-prefixed ignore patterns**

Find:

```powershell
    $repomixIgnorePatterns = @('node_modules/**', '.git/**', '__pycache__/**', '*.pyc', '*.duckdb', 'validation_results/**/*.db') + $artifactIgnore
```

Replace with:

```powershell
    # '**/' prefixes because a bare '<dir>/**' is ROOT-ANCHORED in repomix
    # (measured 1.12.0: 'node_modules/**' still bundles
    # packages/p/node_modules/d/a.md). repomix's own defaults spell these the
    # same way. Only node_modules changes real output; the other two are aligned
    # so sibling patterns that look alike behave alike.
    # NOTE: '.external-reviews/**' arrives via $artifactIgnore and stays
    # deliberately ROOT-anchored -- era's artifact dir is always at the repo
    # root, and the staging carve-out enumerates root-relative siblings.
    $repomixIgnorePatterns = @('**/node_modules/**', '**/.git/**', '**/__pycache__/**', '*.pyc', '*.duckdb', 'validation_results/**/*.db') + $artifactIgnore
```

- [ ] **Step 7: Add the success flag**

Find the end of the `try` block — the last statements before `} finally {`:

```powershell
    $firstResult = @($results.Values) | Select-Object -First 1
    if ($firstResult -and $firstResult.WallClockSec) {
        Write-Host "Done. Wall clock: $($firstResult.WallClockSec)s | Tokens: $tokenCount"
    }

} finally {
```

Replace with:

```powershell
    $firstResult = @($results.Values) | Select-Object -First 1
    if ($firstResult -and $firstResult.WallClockSec) {
        Write-Host "Done. Wall clock: $($firstResult.WallClockSec)s | Tokens: $tokenCount"
    }

    # Reached only on a clean run. The finally block below keeps the repomix
    # config when this is not set, so a failed run leaves a receipt.
    $runSucceeded = $true

} finally {
```

- [ ] **Step 8: Make the config deletion conditional**

Find:

```powershell
    # configPath may not be defined if we threw before it was assigned (e.g. in
    # Reserve-ReviewRound), so guard the removal.
    if ($configPath -and (Test-Path $configPath)) { Remove-Item $configPath -Force -ErrorAction SilentlyContinue }
```

Replace with:

```powershell
    # configPath may not be defined if we threw before it was assigned (e.g. in
    # Reserve-ReviewRound), so guard the removal.
    #
    # Deleted ONLY on success. era used to delete it either way (PowerShell
    # unwinds `exit` through `finally`), and the manifest that would replace it
    # is written only after repomix succeeds -- so a failed run left no bundle,
    # no manifest and no config, and nothing to diagnose from. The claim-file
    # delete above stays unconditional: that one really is per-process state.
    if ($runSucceeded) {
        if ($configPath -and (Test-Path $configPath)) { Remove-Item $configPath -Force -ErrorAction SilentlyContinue }
    } elseif ($configPath -and (Test-Path $configPath)) {
        Write-Host "[era] Retained repomix config for diagnosis: $configPath"
    }
```

- [ ] **Step 9: Run all three new test files**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -Command "Invoke-Pester -Path tests/PathInsideRoot.Tests.ps1,tests/IgnorePatternDepth.Tests.ps1,tests/ConfigRetention.Tests.ps1 -Output Detailed"`

Expected: all PASS.

- [ ] **Step 10: Run the full suite**

Run: `"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -Command "Invoke-Pester -Path tests/ -Output Detailed"`

Expected: 0 failed, and a passing count of at least 404 plus the new tests. If any previously-passing test now fails, **stop and report** — do not edit that test to make it pass.

- [ ] **Step 11: Commit**

```bash
cd ~/.claude/skills/external-review-auto
git add runtimes/era.ps1
git commit -m "fix(era): boundary-aware paths, depth-correct ignores, retained config

P4: five StartsWith sites now use Test-EraPathInsideRoot, so a sibling sharing
the repo-root prefix (C:\\a\\era-p6-ext vs C:\\a\\era-p6) is correctly outside
and gets staged instead of relativized to a path that cannot exist. Includes the
\$HOME mirror, which had the same shape.

P2: '**/node_modules/**' etc, because bare patterns are root-anchored in repomix
-- nested vendored trees were being uploaded to three third-party APIs.

P7: the repomix config is deleted only on success. A failed run now leaves a
receipt and says where it is.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage.** Unit 1 (predicate) → Tasks 1, 4, 5. Unit 2 (patterns + parser) → Tasks 2, 4, 5. Unit 3 (config retention) → Tasks 3, 5. All spec test bullets appear: P4's six unit cases plus the `era-p6-ext` integration repro (Task 1); P2's repomix measurement, both parser depths, and the contract test (Task 2); P7's retention, claim-still-deleted, and source check (Task 3).

**Placeholders.** None — every step names exact find/replace text or complete file content.

**Type consistency.** `Test-EraPathInsideRoot -Path -Root -> [bool]` is defined in Task 4 Step 1 and called with those parameter names in Task 4 Step 5 and Task 5 Steps 1–5. `Measure-EraBroadScope`'s return keys (`FileCount`, `Truncated`) match existing usage. `$repomixIgnorePatterns`, `$artifactIgnore`, `$configPath`, `$runSucceeded` are spelled identically everywhere they appear.

**Known non-obvious ordering.** Task 4 must land before Task 5: Task 5's call sites reference the function Task 4 defines. Tasks 1–3 create disjoint new files and are safe to run concurrently.
