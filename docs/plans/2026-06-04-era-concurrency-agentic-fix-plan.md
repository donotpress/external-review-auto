# /era Concurrency + Agentic-Capture Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development to
> implement this plan task-by-task. Each PR is one subagent task. Steps use `- [ ]` tracking.

**Goal:** Make concurrent `/era` Gemini runs possible (incl. Gemini 3.1 Pro) WITHOUT any
Gemini REST or Gemini CLI fallback, eliminate agentic-loop captures, and make the default
reviewer reliable — driven by the data in
`docs/specs/2026-06-04-era-concurrency-agentic-fix-design.md` (converged via /era self-review).

**Source spec:** `docs/specs/2026-06-04-era-concurrency-agentic-fix-design.md`

**Architecture:** all work in `~/.claude/skills/external-review-auto/` (own git repo), on
branch `era-concurrency-agentic-fix`. Resolver portability also touches
`~/.claude/skills/era/SKILL.md` (separate dir).

**Tech stack:** PowerShell 7+ · Pester 5 · agy/claude/opencode CLIs · repomix · git

**Baseline:** 124/124 Pester green at branch point.

**Critical constraints (preserve — tests enforce these):**
- Every CLI adapter MUST keep the `$psi.Environment` scrub loop (all `RequiredScrubVars`),
  `ProcessStartInfo` + `CreateNoWindow=$true` + `UseShellExecute=$false`, and MUST NOT use
  `Start-Process -NoNewWindow` (EnvScrub.Tests.ps1). Removing the model-swap/mutex must NOT
  touch the spawn-hardening block.
- agy `--print` requires `StandardInput.Close()` or it hangs (verified).
- Scope each commit with `git add <path>` (never `git add .`).
- Run `Invoke-Pester -Path tests/` after every PR; must stay green.

**Ordering (sequential — shared files force it):**
PR-A → PR-B → PR-C → PR-D → PR-E. PR-A & PR-B both edit `agy.ps1`+`workflow.ps1`; PR-C edits
`era.ps1` which PR-A also edits. Do NOT parallelize edits to the same file.

---

## PR-A — Core concurrency: `--model` flag, remove mutex/swap, capture disambiguation, stall tuning
**Spec:** Fix 1, Fix 2, Fix 7 · **Risk:** High (rewrites agy dispatch core) · **Files:**
`backends/agy.ps1`, `workflow.ps1`, `runtimes/era.ps1`

### Tasks
- [ ] **A.0:** `grep tests/ -r` for `Set-AgyModel|Restore-AgyOriginalModel|Get-CurrentAgyModel|era-agy-settings-mutex|Test-ConcurrentAgyReviewers`; delete/rewrite any assertions of old swap/mutex behavior (R2-OQ4).
- [ ] **A.1 (TDD first):** Add `tests/AgyModelFlag.Tests.ps1`:
  - `agy.ps1` source adds `--model` to the agy `ArgumentList`.
  - `agy.ps1` no longer references `Set-AgyModel`/`Restore-AgyOriginalModel`/`era-agy-settings-mutex`.
  - `workflow.ps1` no longer defines or calls `Test-ConcurrentAgyReviewers`.
  - `Get-AgyTranscriptResponse` param block includes `$BundlePath` AND `$DispatchId`.
  - `era.ps1` resolves a default agy `settings_value` and passes `-ResolvedAgyModel`.
  Run; confirm RED.
- [ ] **A.2 (Fix 1 / R2-C1 + R4-Gemini-C1):** Preserve `agy_model_family`/`agy_model_tier` in the
  `$registryHash` copy (era.ps1 ~207-216) so `$ModelInfo` carries them (Fix 7 tier floor needs
  family). For each agy reviewer with no resolved hint, look up
  `_registry._agy_model_map[<family>][<tier>].settings_value` and pass it via a new
  `-ResolvedAgyModel` param (sibling of `-AgyModelHint`, threaded through `Invoke-ReviewerDispatch`).
- [ ] **A.3 (Fix 1):** In the adapter, use `$ResolvedAgyModel` (or the resolved hint) to add
  `--model <token>` to `$psi.ArgumentList`. NEVER read `settings.json` for the model. Keep
  stdin close, env scrub, `CreateNoWindow`, async drain untouched (EnvScrub.Tests enforces).
- [ ] **A.4 (Fix 1 / R3-C3):** Delete `Set-AgyModel`, `Restore-AgyOriginalModel`,
  `Get-CurrentAgyModel`, `$script:SavedAgyModel`, `$script:AgyBackupPath`, and the
  `Global\era-agy-settings-mutex` block. Merge `Invoke-AgyReview` + `_InvokeAgyReviewInternal`
  into one function, **factoring the spawn→poll→capture body into an inner `_SpawnAndCaptureOnce`
  helper** (returns `@{Response;ExitCode;Strategy;Stderr;WallClockSec}`, no disk write, fresh
  deadline/brain-snapshot/Run-ID per call) so PR-B's retry just loops it ≤2× (R3-Opus-C3).
  Merged adapter MUST keep `-AgyModelHint`/`-ModelOverride`, ADD `-ResolvedAgyModel`, and
  ACCEPT-AND-IGNORE `-OpencodeProvider` (the dispatcher ScriptBlock passes it to every adapter —
  R3-Opus-I4). Preserve the ThreadJob-facing call.
  **Plumbing (R3-Opus-C1):** `-ResolvedAgyModel` must thread through THREE sites in
  `workflow.ps1::Invoke-ReviewerDispatch`: the `Start-ThreadJob -ArgumentList`, the ScriptBlock
  `param(...)`, and the inner `& $fnName … -ResolvedAgyModel $resolvedAgyModel` call.
- [ ] **A.5 (Fix 1 / R2-I4):** In `era.ps1`, KEEP the `settings.json.era-backup` recovery
  block (lines ~67-76) for one release — add a deprecation comment ("self-deprecating: no new
  backups are created once swaps are gone; restores any pre-upgrade orphan"). Add a
  `references/troubleshooting.md` note. Leave the opencode model.json recovery intact.
- [ ] **A.6:** In `workflow.ps1`, delete `Test-ConcurrentAgyReviewers` and its call.
- [ ] **A.7 (Fix 2 / R2+R3):** Add `[string]$BundlePath` + `[string]$DispatchId` to
  `Get-AgyTranscriptResponse`. In the merged adapter, `$dispatchId=[guid]::NewGuid()`, PREFIX the
  agy prompt with `[Run ID: $dispatchId]` (leading, survives truncation), pass both params.
  **Qualify a candidate by scanning its RAW transcript text for the GUID** (the GUID is in the
  USER entry, NOT a PLANNER_RESPONSE — R3-C2), capped at last ~5 MB/5000 lines (R3-I3); then
  return the **FIRST PLANNER_RESPONSE whose line index is AFTER the USER line carrying this GUID**
  (R4-Opus-C1 — "last" is wrong in a reused transcript with two dispatches). PROBE-CONFIRMED: GUID
  lands in `source=USER_EXPLICIT type=USER_INPUT`; answer is `source=MODEL type=PLANNER_RESPONSE`.
  Secondary match via literal `.Contains()` (R4-nit): `$BundlePath`, `$BundlePath -replace '\\','/'`,
  `$BundlePath.Replace('\','\\')`. **COMBINE new+existing candidate sets, select by GUID — do NOT
  short-circuit on new-dirs-exist (R3-C3, agy.ps1:152).** **Make `$BundlePath`/`$DispatchId`
  OPTIONAL — when both null, fall back to the original recency/temporal heuristic so legacy
  callers + existing tests pass (R4-Gemini-C2).** `.Strategy='run-id-match'`. Tests: two overlapping
  dispatches, identical bundle path, Run-ID-only disambiguation; TWO GUIDs in one transcript;
  null-params fallback; path-form matches.
- [ ] **A.8 (Fix 7 / R2-I3 + R3-C1-BUG):** **Remove the 360 s hard-deadline cap** at
  agy.ps1:370 (`[Math]::Min($TimeoutSec-10,360)` → `$TimeoutSec-5`) — it currently kills runs at
  6 min regardless of scaling (REAL pre-existing bug). Adapter gets `$TimeoutSec` (scaled), not
  `$BundleTokens`: named constants `$proStallSec=180`/`$flashStallSec=90`;
  `$stallSec=[Math]::Max($tierFloor,[int]($TimeoutSec*0.25))`, `$firstActivitySec=$stallSec`;
  tier via registry `agy_model_family` contains `pro`. Optionally add `--print-timeout ${TimeoutSec}s`.
  Tests: deadline tracks `$TimeoutSec` (no 360 clamp); stall respects Pro floor.
- [ ] **A.9:** `Invoke-Pester -Path tests/` → all green (incl. EnvScrub, Registry).
- [ ] **A.10:** Commit (scoped): `feat(era): per-session agy --model selection + Run-ID capture; remove settings.json swap+mutex for true concurrency`.

---

## PR-B — Agentic-capture prevention, detection, retry, honest metadata
**Spec:** Fix 3, Fix 4 · **Risk:** Medium · **Files:** `backends/agy.ps1`, `workflow.ps1`

### Tasks
- [ ] **B.1 (TDD):** Add `tests/AgenticCapture.Tests.ps1` for a `Test-AgenticNarrationCapture`
  helper: TRUE positives (`"I will view tests/x.py…"`, `"Let me run the unit tests"`, 60-char
  no-heading); FALSE positives MUST pass (a real review with `## Critical issues` even if it
  opens "First, I will look at…"; a terse "(none)" review with headings). Confirm RED.
- [ ] **B.2 (R2-C1 + R3-Gemini-I2):** Detector, **all patterns `(?m)`/`(?im)` multiline**. Flag if
  **(no `(?m)^\s*#{1,6}\s` heading AND narration-match
  `(?im)^\s*(I will|I'll|Let me|I need to|First,?\s+I)\b.*\b(view|open|read|run|check|inspect|look)\b`)**
  OR **(no heading AND no `(?m)^\s*([-*+]|\d+[.)])` list marker AND len<300)**. (R4-Opus-I3: use
  that precise list regex, NOT `[-*+\d]` which mis-flags "2026 update:".) (List-gate applies ONLY to
  the length branch — else an agentic "I will check:\n- a\n- b" with a list slips through.) Treat a
  `(none)`-only response as valid (R3-OQ2). Tests: TRUE positives ("I will view x.py", file-listing
  narration); FALSE positives (real review opening "First, I will look at…" then `## Critical issues`;
  terse `(none)` review).
- [ ] **B.3:** Harden the internal agy prompt: "All files are in the attached bundle at
  `$BundlePath`. Do NOT open, read, fetch, list, or run anything. Review ONLY the bundle and
  output the review directly." (Citing `file:line` in findings is fine.)
- [ ] **B.4 (`--sandbox` probe):** Live-test whether `agy --print --sandbox` can still read
  the bundle file. If yes, add `--sandbox`; if it blocks reads, leave it off and rely on
  prompt+detection. Record the outcome in `references/internals.md`.
- [ ] **B.5 (R2-I2/R3-C3 — retry INSIDE adapter, pre-write):** wrap `_SpawnAndCaptureOnce` (from
  A.4) in a ≤2-iteration loop in the merged adapter; classify each in-memory result; only the
  final attempt writes `$ResponsePath` (NOT in `Invoke-ReviewerDispatch` — double-writes/cost).
  Retry uses the SAME resolved model + hardened prompt. If #2 still bad → return
  `ExitCode=-1, Error='agentic-narration-capture'`. Record discarded-attempt tokens/cost in
  `first_attempt:{}` AND add to the round total (R3-Opus-I5). **Budget (R4-Opus-C2):** cap each
  attempt's `$hardDeadline` to HALF the dispatcher budget so 2 attempts fit inside `TimeoutSec`
  (dispatcher Wait-Job unchanged). **Cost cap (R4-Opus-I4):** skip the retry (fail honestly) if
  `first_attempt_cost + projected_retry_cost > AggregateCap`.
- [ ] **B.6 (Fix 4 / R2-I2):** In `Write-ReviewMetadata`, add `content_ok`, `capture_strategy`,
  `retry_count`, `retry_reason`. ONE entry per reviewer/round; `content_ok` = FINAL state; on a
  successful retry preserve the discarded first attempt under `first_attempt:{strategy,chars}`.
  Generalize `Copy-GeminiResponseAlias` → `Copy-PrimaryResponseAlias` (first successful
  reviewer, gemini preferred); keep old name as a thin wrapper one release. Update metadata
  test expectations.
- [ ] **B.7:** `Invoke-Pester -Path tests/` green.
- [ ] **B.8:** Commit: `fix(era): detect+retry agentic-loop captures; content_ok metadata; unified response alias`.

---

## PR-C — Reliable default reviewer + frontmatter quote hardening
**Spec:** Fix 5, Fix 8a · **Risk:** Low · **Files:** `runtimes/era.ps1`, `backends/_registry.json`, `SKILL.md`

### Tasks
- [ ] **C.1 (TDD):** Tests: bare `/era` (no `-Reviewer`) default resolves to Gemini 3.1 Pro
  (Low) path; `-SpecReview` frontmatter `related_files` entries wrapped in quotes are parsed
  WITHOUT the quotes (extend `SpecReview.Tests.ps1`). Confirm RED.
- [ ] **C.2 (Fix 5 / R2-I1-Opus):** Change `era.ps1:33` default from `@('gemini')` to
  `@('gemini-pro-low')`. Explicit `-Reviewer gemini` still → Flash via registry. Update SKILL.md
  Prerequisites/Quick-examples/patterns-table (they say default = `gemini`).
- [ ] **C.3 (Fix 8a / R2-I3):** In the `-SpecReview` frontmatter parser: (a) apply
  `.Trim().Trim('"',"'")` in BOTH the YAML block-list branch and the inline `Related:` branch;
  (b) ADD a YAML inline-list branch matching `(?m)^related_files:\s*\[(.+)\]`, split on commas,
  trim quotes. Tests: block-list-with-quotes, inline-list, inline `Related:` with quotes.
- [ ] **C.4:** `Invoke-Pester -Path tests/` green.
- [ ] **C.5:** Commit: `feat(era): default bare /era to reliable Gemini 3.1 Pro (Low); strip quotes in spec frontmatter paths`.

---

## PR-D — Cross-model resolver portability
**Spec:** Fix 6 · **Risk:** Low (additive) · **Files:** `runtimes/resolve.ps1` (new),
`SKILL.md`, `~/.claude/skills/era/SKILL.md`

### Tasks
- [ ] **D.1 (TDD):** Add `tests/Resolve.Tests.ps1`: each documented `/era` pattern → expected
  typed flags; PLUS the contract test (R1-OQ1 + R2-I5): (a) every emitted flag key is a real
  `era.ps1` parameter via `(Get-Command ../runtimes/era.ps1).Parameters.Keys`; (b) every
  `-Model` value emitted resolves to a non-null model in era.ps1's Layer-2 resolver. Confirm RED.
- [ ] **D.0 (precursor, R3-Opus-I6 + R4-Opus-I5):** Extract era.ps1's Layer-2 `-Model` resolution
  loop (~229-381) into a dot-sourceable `Resolve-ModelFromHint` in era.ps1 (era.ps1 calls it).
  **Scope rewrite is mandatory:** make `$script:_MatchMode` a function PARAMETER and
  `_Canon`/`_CanonMatch` function-local — else two-pass exact/substring matching silently
  regresses. Add an acceptance test that exact `mimo-v2.5` still resolves (the shorter-canonical
  trap). Contract test resolves era.ps1 path via `$PSScriptRoot` (R4-Gemini-I1). Full Pester green.
- [ ] **D.2:** Implement `runtimes/resolve.ps1`: input via positional arg AND stdin (R3-Gemini-OQ);
  output = ONLY the JSON of typed era.ps1 flags (suppress all intermediate pipeline output with
  `$null =`/`[void]` — R3-Gemini-I3). Port Layer-1 rules from `era/SKILL.md` (filler strip,
  patterns table, highest-tier/latest-minor/family→top defaults, topic-vs-reviewer split). Read
  `_registry.json` for tokens (single source of truth). Unmatched → `{"error":"unresolved","input":"…"}`
  (non-throwing). Do NOT merge Layer-2 (covered by D.0 + contract test).
- [ ] **D.3:** Update `~/.claude/skills/era/SKILL.md` and external-review-auto `SKILL.md` to
  instruct ANY agent (Claude/Gemini/opencode/etc.) to call `resolve.ps1` for parsing, so the
  spell behaves identically regardless of the driving model. Keep the human-readable table.
- [ ] **D.4:** `Invoke-Pester -Path tests/` green.
- [ ] **D.5:** Commit: `feat(era): portable resolve.ps1 so /era resolves identically across driving models`.

---

## PR-E — DROPPED (Fix 8b cut from this spec; see spec §4 Fix 8b). Tracked as a follow-up.

---

## Final acceptance
- [ ] Two concurrent `/era` Gemini 3.1 Pro dispatches (separate processes) BOTH return real
  reviews — live smoke test (the original bug).
- [ ] An agentic "I will view X" capture is classified failure + retried, never logged as
  success; `content_ok=false` recorded.
- [ ] Bare `/era` uses Gemini 3.1 Pro (Low), no REST/CLI fallback anywhere in the default path.
- [ ] `resolve.ps1` returns identical flags for the same input regardless of caller.
- [ ] Full Pester suite green (124 existing + new), EnvScrub/Registry unaffected.
- [ ] No `Set-AgyModel` / `era-agy-settings-mutex` / `Test-ConcurrentAgyReviewers` remain.
