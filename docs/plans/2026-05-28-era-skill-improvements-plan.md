# /era Skill Improvements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Streamline the `/external-review-auto` (a.k.a. `/era`) skill — cut SKILL.md token weight ~4k, fix 3 input-handling bugs, add 3 ergonomic shortcuts. Cross-platform robustness must be preserved (Claude Code / Copilot CLI / Codex / Gemini CLI; agy / Claude CLI / opencode / 3 REST backends).

**Architecture:** All work lives in `~/.claude/skills/external-review-auto/` (its own git repo — DO NOT TOUCH UNCOMMITTED MAINTAINER WORK ALREADY IN-FLIGHT THERE). Doc reorganization (PR 1) moves content into `references/` subdir; PowerShell bug fixes (PR 2) touch `runtimes/era.ps1`; new flags (PR 3-5) extend `era.ps1` + `workflow.ps1`.

**Tech Stack:** PowerShell 7+ · repomix · agy/Claude/opencode CLIs · git

**Source spec:** `~/.claude/skills/external-review-auto/docs/specs/2026-05-28-era-skill-improvements-design.md` (converged after 2 Gemini 3.1 Pro review rounds to READY TO IMPLEMENT). A copy is also at `docs/superpowers/specs/2026-05-28-era-skill-improvements-design.md` in the trading repo for reference.

**Critical constraint:** the era skill repo at `~/.claude/skills/external-review-auto/` has uncommitted modifications from the maintainer that are NOT part of this work. Every commit in this plan must be scoped to specific files this plan touches (use `git add <path>` never `git add .`).

---

## Reading guide

5 PRs. Suggested order (per spec §5 + reviewer-confirmed):

1. **PR 1 — Doc split (Proposal A):** highest user-facing impact, lowest risk. Pure content relocation.
2. **PR 2 — Bug fixes (Proposals B + C + D):** unblocks `-Diff`, prevents silent comma-string failures, validates paths before repomix.
3. **PR 3 — `{{PREVIOUS_ROUND}}` template token (Proposal E):** removes manual "summarize previous round" boilerplate for round-N>1 dispatches.
4. **PR 4 — `-AutoDetect` flag (Proposal F):** opt-in, additive; benefits human callers; LLM callers unaffected.
5. **PR 5 — `-SpecReview` preset (Proposal G):** one-flag invocation for the most common workflow.

**No risk gates required between PRs** — each is independently shippable. Author may parallelize PR 3, 4, 5 if desired.

---

## PR 1 — SKILL.md split

**Risk:** Low (content-only reorganization)
**User-visible?** Yes — SKILL.md becomes ~2,000 tokens (down from ~6,000)

### Scope

Per spec §4.A:

- Keep in `SKILL.md` (~2,000 tokens): Prerequisites, backends table, "How it works" (brief), Usage + flags table, LLM-driven file selection, LLM-driven prompt, Quick examples, Prompt templates, Critical constraints, pointers to references
- Move to `references/internals.md`: Hardening guarantees, Variant resolution, Safe opencode invocation, Stall detector internals, Resolver gotcha, Module layout, Parallel dispatches mechanics
- Move to `references/troubleshooting.md`: All 9 edge cases + post-PR-2 entries for the 3 bugs fixed in this round

### Tasks

- [ ] **Task 1.1:** Read current `SKILL.md` end-to-end. Map each section to keep/relocate per spec §4.A table.
- [ ] **Task 1.2:** Create `references/internals.md` with the 7 relocated sections under clear H1/H2 headers. Each section: copy verbatim from current SKILL.md.
- [ ] **Task 1.3:** Create `references/troubleshooting.md` with all 9 edge cases under "## Edge cases" + reserved section "## Known errors (post-fix reference)" for PR 2's bugs.
- [ ] **Task 1.4:** Rewrite `SKILL.md` keeping only the spec-§4.A-designated sections. Add explicit pointers at the bottom:
  ```markdown
  ## See also
  - `references/internals.md` — hardening details, opencode variant resolution, parallel-dispatch mechanics, maintainer notes
  - `references/troubleshooting.md` — edge cases and known errors with fixes
  ```
- [ ] **Task 1.5:** Add a top-of-file comment to the new `SKILL.md`:
  ```
  <!-- 2026-05-28: SKILL.md split. Hardening/troubleshooting/internals
       relocated to references/. If you reach for "edge case #7" by section
       name, check references/troubleshooting.md. -->
  ```
- [ ] **Task 1.6:** Verify the new `SKILL.md` is ≤2,000 tokens (use a tokenizer or estimate via word-count×1.3).
- [ ] **Task 1.7:** Manual smoke test: invoke `/era` against a small test topic in a fresh Claude Code session; confirm skill loads cleanly with the smaller SKILL.md and that invocation succeeds without consulting `references/`.
- [ ] **Task 1.8:** Commit: `docs: SKILL.md split — relocate hardening/internals to references/ (PR 1 of skill-improvements)`. Scope commit to `SKILL.md`, `references/internals.md`, `references/troubleshooting.md` ONLY.

---

## PR 2 — Bug fixes (`-Diff`, Test-Path ordering, comma-string detection)

**Risk:** Low (isolated to era.ps1 input validation)
**User-visible?** Yes — `-Diff` now works; silent comma-string failures become loud helpful errors

### Tasks

- [ ] **Task 2.1 (Proposal B — `-Diff` SwitchParameter bug):** Read `runtimes/era.ps1`. Locate the `[switch]$Diff` parameter declaration and every site where it's referenced. Find the source of the "Cannot convert 'System.Collections.Hashtable' to 'SwitchParameter'" error — most likely a splat `@params` that includes `Diff` as a bare hashtable key without a value. Fix: explicitly set `Diff = $true` or remove from splat. Verify by re-running the failed round-2 dispatch from session: `pwsh era.ps1 -TopicSlug project-b -Diff -Force`.
- [ ] **Task 2.2 (Proposal C — Test-Path before repomix):** In `era.ps1`, before invoking repomix on `-IncludeFiles`, add a validation loop:
  ```powershell
  Push-Location $repoRoot
  try {
      $missing = @($IncludeFiles | Where-Object { -not (Test-Path $_) })
      if ($missing) {
          throw "ERROR: -IncludeFiles paths not found relative to repo root ($repoRoot): $($missing -join ', ')"
      }
  } finally {
      Pop-Location
  }
  ```
  Place BEFORE the `Running repomix...` log line. Exit cleanly without writing a bundle.
- [ ] **Task 2.3 (Proposal D — comma-string detection):** In the same `-IncludeFiles` validation block:
  ```powershell
  $commaFlagged = @($IncludeFiles | Where-Object { $_ -match ',' })
  if ($commaFlagged) {
      throw @"
  ERROR: -IncludeFiles element(s) contain a comma: $($commaFlagged -join '; ')
  Did you mean PS-array syntax 'a','b','c' (separate quoted elements) instead
  of a single comma-string 'a,b,c'? If you genuinely need a literal comma in a
  filename, escape with `, (PS grave-comma escape).
  "@
  }
  ```
- [ ] **Task 2.4:** Add `tests/Invoke-Era.Tests.ps1` Pester cases (or extend existing test file):
  - `Test: -Diff flag does not throw SwitchParameter error`
  - `Test: missing -IncludeFiles paths produce specific error before repomix runs`
  - `Test: comma-string -IncludeFiles produces specific error message`
  Run: `pwsh -Command "Invoke-Pester -Path tests/Invoke-Era.Tests.ps1 -Tag Unit"`
- [ ] **Task 2.5:** Update `references/troubleshooting.md` "Known errors (post-fix reference)" section: add entries for the three bug fixes describing pre-fix symptom + post-fix expectation, so future debugging finds them.
- [ ] **Task 2.6:** Commit: `fix(era): -Diff param binding + Test-Path ordering + comma-string fail-fast (PR 2 of skill-improvements)`. Scope to `runtimes/era.ps1`, `tests/*`, `references/troubleshooting.md` ONLY.

---

## PR 3 — `{{PREVIOUS_ROUND}}` template token

**Risk:** Medium (touches workflow.ps1 prompt-construction logic)
**User-visible?** Yes — round-N>1 prompts can opt into auto-include

### Tasks

- [ ] **Task 3.1:** Read `workflow.ps1` round-reservation + prompt-construction logic. Identify where the prompt is written to disk (`round-N-prompt.md`).
- [ ] **Task 3.2:** Add a substitution step. After the prompt file is finalized but before repomix runs:
  ```powershell
  $promptText = Get-Content $promptFile -Raw
  if ($promptText -match '\{\{PREVIOUS_ROUND\}\}') {
      $previousN = $roundN - 1
      $previousFile = Join-Path $reviewDir "round-$previousN-response.md"
      $previousClaim = Join-Path $reviewDir "round-$previousN-claim.json"
      if (Test-Path $previousFile) {
          $previousText = Get-Content $previousFile -Raw
          $substitution = "## Previous round's review (round $previousN)`n`n$previousText"
      } elseif (Test-Path $previousClaim) {
          $substitution = "[Round $previousN is in flight; not yet available]"
      } else {
          $substitution = "[Round $previousN response not found]"
      }
      $promptText = $promptText -replace '\{\{PREVIOUS_ROUND\}\}', [regex]::Escape($substitution).Replace('\','\\')
      Set-Content -Path $promptFile -Value $promptText -Encoding UTF8
  }
  ```
  (Verify regex escaping is correct — PS `-replace` uses .NET regex; literal text needs `[regex]::Escape`.)
- [ ] **Task 3.3:** Tests:
  - `Test: prompt without {{PREVIOUS_ROUND}} is unchanged`
  - `Test: round-2 prompt with token gets round-1-response.md substituted`
  - `Test: round-2 prompt with token, round-1 in flight, gets [in flight] string`
  - `Test: round-2 prompt with token, round-1 missing entirely, gets [not found] string`
- [ ] **Task 3.4:** Document in SKILL.md (under "LLM-driven prompt" section): "For round N > 1, include `{{PREVIOUS_ROUND}}` anywhere in your prompt to auto-substitute round-(N-1)'s response."
- [ ] **Task 3.5:** Commit: `feat(era): {{PREVIOUS_ROUND}} template token for round-N>1 prompts (PR 3 of skill-improvements)`. Scope to `workflow.ps1`, `SKILL.md`, `tests/*`.

---

## PR 4 — `-AutoDetect` flag

**Risk:** Low (additive, opt-in)
**User-visible?** Yes — human callers get one-flag file curation

### Tasks

- [ ] **Task 4.1:** Add `[switch]$AutoDetect` to era.ps1's param block.
- [ ] **Task 4.2:** When `-AutoDetect` is passed AND `-IncludeFiles` is not (or as additive merge):
  ```powershell
  if ($AutoDetect) {
      $gitAvailable = (Get-Command git -ErrorAction SilentlyContinue) -and (git rev-parse --is-inside-work-tree 2>$null)
      if (-not $gitAvailable) {
          throw "ERROR: -AutoDetect requires git and a git work tree. Pass -IncludeFiles explicitly."
      }
      $uncommitted = git status --porcelain | ForEach-Object { ($_ -split '\s+', 2)[1] }
      $recentCommit = git diff --name-only HEAD~1..HEAD
      $candidates = @($uncommitted; $recentCommit) | Sort-Object -Unique | Where-Object { $_ }
      if (-not $Force) {
          Write-Host "Auto-detected candidate files:"
          $candidates | ForEach-Object { Write-Host "  $_" }
          $confirm = Read-Host "Proceed with these? [y/N]"
          if ($confirm -notmatch '^[Yy]$') { throw "Aborted by user." }
      }
      $IncludeFiles = @($IncludeFiles; $candidates) | Sort-Object -Unique | Where-Object { $_ }
  }
  ```
- [ ] **Task 4.3:** Tests:
  - `Test: -AutoDetect throws if git not on PATH`
  - `Test: -AutoDetect throws if not in git work tree`
  - `Test: -AutoDetect + -Force skips confirmation prompt`
  - `Test: -AutoDetect + -IncludeFiles X is additive (X + auto-detected)`
- [ ] **Task 4.4:** Document in SKILL.md "All flags" table.
- [ ] **Task 4.5:** Commit: `feat(era): -AutoDetect flag using git HEAD~1 + uncommitted (PR 4 of skill-improvements)`. Scope to `runtimes/era.ps1`, `SKILL.md`, `tests/*`.

---

## PR 5 — `-SpecReview` preset

**Risk:** Low (additive)
**User-visible?** Yes — one-flag invocation for spec reviews

### Tasks

- [ ] **Task 5.1:** Add `[string]$SpecReview` to era.ps1 param block. Mutually-exclusive with `-PromptOverrideFile` — explicit error if both passed:
  ```powershell
  if ($SpecReview -and $PromptOverrideFile) {
      throw "-SpecReview and -PromptOverrideFile are mutually exclusive. -SpecReview generates the prompt from a template; -PromptOverrideFile uses your prompt verbatim. Pick one."
  }
  ```
- [ ] **Task 5.2:** When `-SpecReview <path>` is passed:
  1. Read the spec file at `<path>`.
  2. Parse optional frontmatter for related files. Look for a `Related:` line or a YAML frontmatter block with `related_files:` key. If neither present, default to `IncludeFiles = @($SpecReview)` only.
  3. Construct the prompt from the spec-review template (currently embedded in SKILL.md — consider extracting to `references/templates/spec-review.md` as a follow-up).
  4. Auto-derive `-TopicSlug` from spec filename (strip date prefix + `-design.md` suffix) if not explicitly passed.
- [ ] **Task 5.3:** Behavior matrix:
  | `-SpecReview` | `-IncludeFiles` | `-PromptOverrideFile` | Behavior |
  |---|---|---|---|
  | ✓ | ✗ | ✗ | Generate prompt from template; bundle spec + related files |
  | ✓ | ✓ | ✗ | Same prompt; bundle spec + related + user-extras (additive) |
  | ✓ | ✗ | ✓ | **ERROR** (mutually exclusive) |
  | ✓ | ✓ | ✓ | **ERROR** |
  | ✗ | * | * | Existing behavior unchanged |
- [ ] **Task 5.4:** Tests:
  - `Test: -SpecReview alone generates prompt and bundles spec file`
  - `Test: -SpecReview + -PromptOverrideFile errors mutually-exclusive`
  - `Test: -SpecReview + -IncludeFiles is additive`
  - `Test: -SpecReview with no frontmatter defaults to spec-only`
  - `Test: -SpecReview derives topic slug from filename`
- [ ] **Task 5.5:** Document in SKILL.md with an example:
  ```powershell
  # Old (14+ IncludeFiles entries + custom prompt):
  pwsh era.ps1 -TopicSlug project-b -Mode assessment -Reviewer gemini -PromptOverrideFile ... -IncludeFiles file1,file2,...
  # New:
  pwsh era.ps1 -SpecReview docs/superpowers/specs/2026-05-28-project-b-design.md -Reviewer gemini -Model 'gemini 3.1 pro'
  ```
- [ ] **Task 5.6:** Commit: `feat(era): -SpecReview preset for one-flag spec review dispatch (PR 5 of skill-improvements)`. Scope to `runtimes/era.ps1`, `SKILL.md`, `tests/*`.

---

## Final acceptance (across all 5 PRs)

- [ ] `SKILL.md` is ≤2,000 tokens (PR 1)
- [ ] All edge cases from old SKILL.md are findable in `references/troubleshooting.md` (PR 1)
- [ ] `-Diff` flag works without SwitchParameter error (PR 2)
- [ ] `-IncludeFiles "a,b,c"` (quoted comma-string) produces helpful error, never silent empty bundle (PR 2)
- [ ] Missing `-IncludeFiles` paths produce error BEFORE repomix runs (PR 2)
- [ ] `{{PREVIOUS_ROUND}}` token in round-N>1 prompts auto-substitutes (PR 3)
- [ ] `-AutoDetect` flag works with confirmation prompt OR `-Force` (PR 4)
- [ ] `-SpecReview docs/spec.md -Reviewer gemini` works without `-IncludeFiles` or `-PromptOverrideFile` (PR 5)
- [ ] Existing /era invocations from the trading repo (and any other downstream user) still work — backwards-compatible (all PRs)
- [ ] Pester tests all green: `pwsh -Command "Invoke-Pester -Path tests/ -Tag Unit"`
