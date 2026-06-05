---
title: /era concurrency + agentic-capture reliability overhaul
date: 2026-06-04
status: ready-to-implement (converged after 4 /era self-review rounds: Gemini 3.1 Pro + Opus)
related_files:
  - backends/agy.ps1
  - workflow.ps1
  - runtimes/era.ps1
  - backends/_registry.json
  - SKILL.md
---

# /era concurrency + agentic-capture reliability overhaul

## 1. Problem statement (data-driven)

A sweep of **302 reviewer-runs** (296 `round-*-metadata.json` files across the skill's
own `.external-reviews/` and a separate project tree) shows all reliability problems
are concentrated in the **agy** backend:

| backend | runs | ok% | hard-fail | tiny-resp (exit 0, <400 chars) |
|---|--:|--:|--:|--:|
| claude | 21 | 95% | 1 | 0 |
| opencode | 43 | 95% | 2 | 0 |
| **agy** | 232 | 87% | 25 | 5 |
| geminiapi | 6 | 67% | 0 | 2 |

By preset, the **default reviewer is the least reliable**: `gemini` (Gemini 3.5 Flash via
agy) = 67% ok over 57 runs (19 hard-fails). `gemini-pro-high` = 94% over 175 runs.
Non-agy presets (`opus`, `deepseek`, `minimax`) = 95–100%.

Two concrete defects:

### Defect A — concurrent agy runs cannot coexist
`backends/agy.ps1` selects a model by mutating the single shared global file
`~/.gemini/antigravity-cli/settings.json` (`Set-AgyModel`, line ~81) and serializes ALL
agy dispatches with a cross-process mutex `Global\era-agy-settings-mutex`
(line ~235) held for the **entire** dispatch. The mutex wait is 60s; a Gemini 3.1 Pro run
takes ~80s. So a second session running `/era Gemini 3.1 Pro` waits 60s, fails to acquire,
and throws *"Could not acquire agy settings mutex within 60s."* Concurrency is impossible
by construction. `workflow.ps1::Test-ConcurrentAgyReviewers` (line ~412) also hard-blocks
two agy reviewers in one process for the same reason.

### Defect B — agentic-loop captures logged as success
agy is an agentic coding agent and `settings.json` has `toolPermission: always-proceed`.
The internal prompt in `_InvokeAgyReviewInternal` (agy.ps1 line ~293) —
*"Review the code at $BundlePath…"* — invites Gemini to open files / run tests instead of
reviewing the bundle. `Get-AgyTranscriptResponse` then captures the first/last
`PLANNER_RESPONSE`, which is tool-intent narration. Observed captured "reviews" include
*"I will view `tests/test_notifications.py`…"* (98 chars), *"I will run the unit tests…"*
(60 chars). These exit **0** and are recorded as successful in metadata
(`Write-ReviewMetadata`, workflow.ps1 line ~594 keys only on `ExitCode -eq 0`), so the data
silently lies and callers consume garbage reviews.

## 2. Key enabling discovery (empirically verified 2026-06-04)

`agy.exe --help` exposes `--model "<display name>"` ("Model for the current CLI session").
Live test on the idle agy install:

```
agy --print --model "Gemini 3.1 Pro (Low)" "Reply with exactly: MODELTEST_OK_4417"
→ exit 0, 10s, response "MODELTEST_OK_4417", own brain session dir created,
  settings.json UNCHANGED (still "Gemini 3.5 Flash (High)")
```

This means model selection can move from *mutate-shared-file-under-global-lock* to
*pass `--model` per process*. The `settings_value` strings in
`_registry.json._agy_model_map` are already exactly the tokens `--model` accepts. agy
`--print` requires stdin closed (the adapter already does this) or it hangs. Other useful
flags confirmed present: `--print-timeout <dur>`, `--log-file`, `--sandbox`, `--add-dir`.
`agy models` requires a TTY (exits -1 when stdout is redirected) — do not depend on it
programmatically.

## 3. Goals / non-goals

**Goals**
1. Two+ sessions can run `/era` against any mix of Gemini models (incl. Gemini 3.1 Pro)
   **concurrently**, with NO Gemini REST (`geminiapi`) and NO Gemini CLI fallback.
2. Eliminate agentic-loop captures: prevent them, and when one still occurs, classify it
   as a **failure** (non-zero), retry once, and record it honestly in metadata.
3. Make the default reviewer reliable.
4. `/era <natural language>` resolves and dispatches correctly regardless of which model is
   driving (Claude, Gemini, an opencode model, etc.).
5. No regressions: existing 124 Pester tests stay green; new behavior gets new tests.

**Non-goals**
- Rewriting non-agy backends (claude/opencode/REST) — they are reliable.
- Removing the REST/Anthropic adapters — they remain as explicit opt-in fallbacks, just no
  longer the recommended path for Gemini.
- Changing the round-reservation / cost-prompt / repomix machinery.
- **opencode concurrency (R2-I6-Opus, explicitly out of scope with evidence):** opencode also
  swaps a shared `model.json`, but its adapter uses an **early-release** state mutex — it
  serializes only the swap+startup, then releases ("[opencode] state mutex released (parallel
  dispatches may proceed)", opencode.ps1:271) so concurrent opencode dispatches already run in
  parallel. This is a fundamentally different (already-mitigated) design than agy's full-run
  lock, so it needs no change here. Removing the agy mutex does not regress it. Any deeper
  opencode hardening is a separate spec.

## 4. Design

### Fix 1 — agy model selection via `--model` (replaces settings.json swap + mutex)
- In `_InvokeAgyReviewInternal`, add `--model <resolved settings_value>` to the agy
  `ArgumentList` when a model is resolved (from `$AgyModelHint`/`$ModelOverride` via
  `Find-AgyModelFromHint`, which already returns `.Settings`).
- **Delete** `Set-AgyModel`, `Restore-AgyOriginalModel`, `Get-CurrentAgyModel`,
  `$script:SavedAgyModel`, `$script:AgyBackupPath`, the `era-agy-settings-mutex` block in
  `Invoke-AgyReview`, and the settings/era-backup crash-recovery block in `era.ps1`
  (lines ~67-76).
- **Delete** `Test-ConcurrentAgyReviewers` and its call (workflow.ps1 ~412, ~444) — with no
  shared file there is nothing to race. Multi-agy-in-one-process becomes allowed; each
  ThreadJob passes its own `--model`.
- Default model when no hint: pass the preset's `agy_model_family`/`agy_model_tier` →
  `settings_value` from `_registry.json` explicitly, rather than relying on whatever
  `settings.json` currently holds. This makes every dispatch deterministic and independent
  of the user's interactive agy model.
- **Cleanup (R1-M1):** once the mutex + settings swap are gone, `Invoke-AgyReview` becomes a
  thin pass-through to `_InvokeAgyReviewInternal`. Merge the two into a single function to
  remove the now-pointless indirection.
- **Default-model resolution (R2-C1, blocking):** `era.ps1` builds `$registryHash` copying
  only `backend/model_id/pricing/supports_file_read/supports_streaming/notes` (lines ~207-216)
  — it drops `agy_model_family`/`agy_model_tier`, so the adapter cannot derive the default
  `settings_value` for `--model`. **Decision:** resolve the token in `era.ps1` and pass it to
  the adapter explicitly. For every agy reviewer, if no `-Model`/`AgyModel` hint resolved a
  token, look up `_registry.json._agy_model_map[<preset.agy_model_family>][<preset.agy_model_tier>].settings_value`
  and pass it via a new `-ResolvedAgyModel` parameter (sibling of `-AgyModelHint`). The adapter
  uses `$ResolvedAgyModel` verbatim for `--model`; it never reads `settings.json` for the model.
- **Also preserve family/tier in `$registryHash` (R4-Gemini-C1):** add `agy_model_family` and
  `agy_model_tier` to the per-preset copy at era.ps1:~207-216 so `$ModelInfo` carries them into
  the adapter. Fix 7's tier-based stall floor needs the family (`-match 'pro'`) and the default
  `settings_value` lookup can use it too. One-line additive change, no schema impact.
- **Migration safety (R2-I4):** do NOT delete the `settings.json.era-backup` crash-recovery
  block in `era.ps1` (lines ~67-76). With swaps gone no new backups are created, so the block
  self-deprecates, but it must remain ONE release to restore any pre-upgrade orphaned backup
  (otherwise a user who crashed before upgrading is stuck on the wrong interactive model
  forever). Add a deprecation comment + a `references/troubleshooting.md` note.

### Fix 2 — concurrent-safe transcript capture
Today `Get-AgyTranscriptResponse` Strategy 1 = "session dirs created since dispatch start".
Under concurrency, process A's post-run scan can see process B's new dir too.
- Tighten correlation: pass `--log-file <unique per-dispatch path>` and, after exit, read
  the session id agy logs there; OR, more simply, record the set of brain dirs immediately
  before *this* spawn and accept only dirs whose `created_at`/mtime falls within this
  process's `[spawn, exit]` window AND whose transcript's first entry timestamp is ≥ this
  dispatch start. When multiple candidates remain, prefer the one whose transcript
  references this dispatch's bundle path.
- **Per-dispatch Run ID correlation (R2-C2, supersedes bundle-path-only matching):** two agy
  reviewers in the SAME process+round (now possible, e.g. `gemini,gemini-pro-low`) share the
  same `$BundlePath` (`round-N-bundle.xml`), so bundle-path matching cannot disambiguate them.
  Generate a unique `$dispatchId` (GUID) inside the adapter, append it to the agy prompt as a
  literal token (`Run ID: <guid>`), and correlate the transcript by that token. The bundle
  path stays as a secondary signal.
- **Signature change (R1-C1 + R2-C2):** add `[string]$BundlePath` AND `[string]$DispatchId`
  parameters to `Get-AgyTranscriptResponse`; pass both from the (merged) adapter. Name the new
  capture mode `'run-id-match'` in the returned `.Strategy` field.
- **Matching predicate (R2-C3, exact):** when scanning a candidate transcript, match if its
  text contains the `$DispatchId` GUID (primary) OR any of:
  `[regex]::Escape($BundlePath)`, `[regex]::Escape($BundlePath -replace '\\','/')`, or the
  JSON-escaped (`\\`) form (secondary). The GUID is collision-proof; the path forms are the
  fallback when the GUID echo is absent.
- **Read window (R2-I1 + R3):** the correlation scan must NOT use `-Tail 200`. The `$DispatchId`
  GUID lives in the **USER prompt entry**, not a `PLANNER_RESPONSE` — so the existing
  PLANNER_RESPONSE-only loop (agy.ps1:161) will never see it. **Qualify the candidate by
  scanning the transcript's RAW text for the GUID**, then take the LAST `PLANNER_RESPONSE` as
  the answer. Bound the read at the last ~5 MB / 5000 lines (R3-Opus-I3) to avoid loading a
  pathologically large shared transcript whole.
- **EMPIRICALLY CONFIRMED (R4 probe, 2026-06-04):** `agy --print "[Run ID: <guid>] …"` echoes
  the GUID verbatim into the transcript's `USER_EXPLICIT`/`USER_INPUT` entry (line 1); the answer
  is the `MODEL`/`PLANNER_RESPONSE` entry. So the correlation scheme is sound. Implementer: the
  exact entry types are `source=USER_EXPLICIT type=USER_INPUT` (carries the GUID) and
  `source=MODEL type=PLANNER_RESPONSE` (the answer).
- **Ordering within a reused transcript (R4-Opus-C1):** a Strategy-2 reused session can hold
  `USER[A]…RESP[A]…USER[B]…RESP[B]`. "Last PLANNER_RESPONSE" would wrongly give A dispatch B's
  answer. Correct rule: find the line index of the USER entry containing THIS `$DispatchId`, then
  return the FIRST `PLANNER_RESPONSE` whose line index is greater (and before the next USER
  entry). Test with two GUIDs in one transcript.
- **Backward-compat fallback (R4-Gemini-C2):** make `$BundlePath`/`$DispatchId` optional; when
  both are null/empty (existing tests, legacy callers) fall back to the original
  new-session-dir / temporal-floor heuristic so current tests keep passing.
- **Matching uses `.Contains()` not regex (R4-Opus-nit2):** the path forms are literal strings;
  substring `.Contains()` avoids regex escaping pitfalls. `--sandbox` is OUT (R4-Gemini live
  probe: it hangs indefinitely; rely on prompt-hardening + detection only).
- **No Strategy short-circuit under concurrency (R3-Gemini-C3):** the current
  `$candidates = if ($newSessionTranscripts) {…} else {$existingSessionTranscripts}`
  (agy.ps1:152) means if process B created a new dir, process A only scans new dirs and skips
  the existing-session scan — missing its own transcript when A reused a session. Fix: build a
  COMBINED candidate set (new + existing), then select by `$DispatchId` match; only fall back
  to recency when no GUID match exists.
- **Run ID placement (R3-Opus-nit3):** prefix the prompt with `[Run ID: <guid>]` (leading, not
  trailing) so it survives mid-prompt truncation. JSON-escaped path form via
  `$BundlePath.Replace('\','\\')` (R3-Gemini-nit1), not regex.
- Add a regression test simulating two overlapping dispatches with interleaved session dirs
  AND identical bundle paths, disambiguated only by Run ID; plus a test covering all three
  path-form matches.

### Fix 3 — agentic-loop prevention + detection
- **Prevent:** harden the internal agy prompt to be explicit and tool-forbidding:
  *"All files are in the attached bundle at `$BundlePath`. Do NOT open, read, fetch, list,
  or run anything. Review ONLY the bundle content and output the review directly."* Evaluate
  `--sandbox` to harden further (must confirm it does not block reading the bundle file).
- **Detect (R1-I1 + R2-C1 — gating mandatory, multiline-correct):** classify a capture as a
  non-review ONLY when BOTH hold: (a) it has **no** markdown heading and **no** list marker,
  AND (b) it either matches the narration pattern OR is shorter than a configurable floor
  (default 300 chars). **All anchored patterns MUST use the `(?m)` multiline flag** — without
  it PowerShell `^` matches only the very start of the whole response, so a real review whose
  first line is prose but which contains `## Critical issues` later would be mis-flagged.
  Exact patterns: heading `(?m)^\s*#{1,6}\s`, list `(?m)^\s*[-*+\d]`, narration
  `(?im)^\s*(I will|I'll|Let me|I need to|First,?\s+I)\b.*\b(view|open|read|run|check|inspect|look)\b`.
- **Detection-loophole fix (R3-Gemini-I2):** an agentic capture that *lists files it will open*
  ("I will check these:\n- a\n- b") DOES have a list marker and would slip past a gate that
  requires "no list marker" for the narration branch. So the list-marker gate applies ONLY to
  the length-floor branch. Final logic: flag if **(no heading AND narration-match)** OR
  **(no heading AND no list-marker AND len<floor)**.
- **List-marker regex precision (R4-Opus-I3):** use `(?m)^\s*([-*+]|\d+[.)])` — NOT
  `(?m)^\s*[-*+\d]` (which matches "2026 update:" / "404 errors:" as a list, opening a false
  negative). Matches `- `, `* `, `+ `, `1.`, `1)` only.
- **Retry budget vs dispatcher timeout (R4-Opus-C2):** the merged adapter may spawn twice at
  adaptive `$TimeoutSec`, but `Invoke-ReviewerDispatch` only waits `TimeoutSec+30` (workflow.ps1
  ~553) → Wait-Job could kill the retry mid-write. **Decision:** each attempt's `$hardDeadline`
  is capped to HALF the dispatcher budget (so two attempts fit within `TimeoutSec`); the
  dispatcher Wait-Job is unchanged. (Halving per-attempt is preferable to doubling the global
  wait — keeps failures loud and bounded.)
- **Retry vs approved cost cap (R4-Opus-I4):** a retry replays the full bundle input the user
  already approved 1× for. **Decision:** before retrying, if `first_attempt_cost +
  projected_retry_cost > AggregateCap`, SKIP the retry and fail honestly (don't silently double
  spend). Otherwise retry. Record both attempts' tokens as specified below.
- **"(none)" valid form (R3-Opus-OQ2):** a legitimately empty review may be just "(none)" with
  no heading/list and <300 chars. The narration branch won't match it (no narration verbs),
  but the length branch would. Guard: treat a response that is exactly/▢primarily `(none)` (or
  the template's section skeleton) as valid; the length-floor only fires when there's neither a
  heading nor a recognized empty-form token.
- **Retry location (R2-C2-Opus / R2-I2 — mandatory):** the retry lives INSIDE the merged
  adapter, against the in-memory `$response`, BEFORE anything is written to `$ResponsePath`.
  Do NOT retry at the `workflow.ps1::Invoke-ReviewerDispatch` level — a dispatcher-level retry
  would overwrite `$ResponsePath` and double-count cost/ThreadJob lifecycle. Flow: capture →
  classify → if bad, re-dispatch once with the SAME resolved model (incl. any `-Model`
  override) + hardened prompt → classify again → only the final attempt's text reaches disk.
  If attempt #2 still fails, the adapter returns `ExitCode=-1, Error='agentic-narration-capture'`
  so the dispatcher records an honest failure.
- **Structural decomposition (R3-Opus-C3, required):** the current spawn→poll→finally→scan is
  ~150 lines of straight-line code. Extract it into an inner helper `_SpawnAndCaptureOnce`
  returning `@{Response; ExitCode; Strategy; Stderr; WallClockSec; …}` with NO disk write and
  its OWN fresh deadline/brain-snapshot/Run-ID per attempt. The outer (merged) function loops
  ≤2 times, classifies each result, and writes `$ResponsePath` exactly once at the end. Without
  this, a naive recursive retry double-sets deadlines and re-snapshots brain dirs.
- **`--dangerously-skip-permissions` decision (R3-Opus-I2 + R4 probe):** keep the flag
  (dropping it risks prompt-time permission stalls in `--print`), and rely on prompt-hardening +
  detection as the barrier. **`--sandbox` is OUT — empirically confirmed it hangs indefinitely
  (R4-Gemini live probe).** Do not add it. Record this in `internals.md`.
- **Retry cost honesty (R3-Opus-I5):** the discarded first attempt still spent ~bundle input
  tokens. Record its `input_tokens/output_tokens/est_cost_total_usd` inside `first_attempt:{}`
  AND add them to the round's top-level cost so cap-accounting isn't understated.

### Fix 4 — honest metadata + unified response alias
- Add to each reviewer entry in `Write-ReviewMetadata`: `content_ok` (bool), `capture_strategy`
  (e.g. `run-id-match`/`new-session-dir`/`temporal-floor`), `retry_count`, `retry_reason`.
- **Retry semantics (R2-I2-Opus):** exactly ONE entry per reviewer per round. `content_ok`
  reflects the FINAL state: if the retry succeeded, `content_ok=true`, `retry_count=1`,
  `retry_reason='agentic-narration-capture'`, and the discarded first attempt's
  strategy/chars are preserved under a `first_attempt:{...}` sub-object so the audit trail
  isn't lost. If both attempts failed, `content_ok=false`, `exit_code` nonzero.
- **R1-I2 — generalize the response alias:** `Copy-GeminiResponseAlias` only writes the
  unified `round-N-response.md` when the reviewer list contains `gemini`. With the new
  default (Fix 5) and multi-reviewer runs that omit `gemini` (e.g. `deepseek,minimax`), no
  unified file is produced and downstream consumers that read `round-N-response.md` break.
  Generalize: rename to `Copy-PrimaryResponseAlias` and copy the **first successful**
  reviewer's response to `round-N-response.md`. **New signature (R3-Opus-I1):**
  `Copy-PrimaryResponseAlias -ReviewDir -Round -ReviewerList -Results` (whole results dict).
  **Deterministic preference (R3-Gemini-nit2):** (1) exact `gemini`, (2) any preset containing
  `gemini`, (3) first successful reviewer in the approved list. **Call-site (R3-Gemini-C4):**
  era.ps1:781 currently gates on `if ($results['gemini'])` — under the new `gemini-pro-low`
  default that key is null and the alias is skipped. Change the call to
  `Copy-PrimaryResponseAlias … -Results $results` unconditionally. Keep `Copy-GeminiResponseAlias`
  as a one-release wrapper that maps `$GeminiResult` → `@{ gemini = $GeminiResult }`.

### Fix 5 — reliable default
- **Mechanic (R2-I1-Opus, explicit):** change the param default at `era.ps1:33` from
  `[string[]]$Reviewer = @('gemini')` to `@('gemini-pro-low')`. This is clean: a bare `/era`
  → Gemini 3.1 Pro (Low) (reliable, ~3× cheaper than High, no REST/CLI), while an explicit
  `-Reviewer gemini` still resolves to Flash via the registry. Update SKILL.md
  Prerequisites/Quick-examples and the `/era` patterns table (they currently state the
  default is `gemini`).

### Fix 6 — cross-model resolver portability
- Extract the natural-language→flags resolver rules (currently prose in `era/SKILL.md`)
  into a deterministic helper `runtimes/resolve.ps1` that takes the raw `/era` input string
  and emits the typed `era.ps1` flags (JSON). Any agent on any platform can shell out to it,
  so resolution is identical whether Claude, Gemini, or an opencode model is driving.
- **Two distinct layers (R2-I5-Opus):** Layer 1 = raw `/era <english>` → typed flags
  (`-Reviewer`, `-Model`, `-TopicSlug`); this is what `resolve.ps1` owns and what the LLM
  currently does ad-hoc. Layer 2 = `era.ps1`'s `-Model <hint>` → concrete `model_id/provider`
  (era.ps1 lines ~229-381; **extract this loop into a dot-sourceable `Resolve-ModelFromHint`
  function in era.ps1 (R3-Opus-I6/Gemini-I4) so the contract test can call it directly without
  forking pwsh**. **R4-Opus-I5 — the extraction MUST rewrite scope:** the current loop uses
  `$script:_MatchMode` and the closures `_Canon`/`_CanonMatch` that read it (era.ps1 ~240-290);
  lifting into a function changes `$script:` semantics. Make `_MatchMode` a function parameter
  and `_Canon`/`_CanonMatch` function-local, else two-pass exact/substring matching silently
  regresses. Add an acceptance test that exact `mimo-v2.5` still resolves correctly (the classic
  shorter-canonical-of-longer trap). The contract test must resolve era.ps1's path via
  `$PSScriptRoot`, not a hardcoded relative path (R4-Gemini-I1)). These are different stages and
  are NOT merged (merging the mature
  Layer-2 two-pass resolver is high-risk for little gain). **Drift is prevented structurally:**
  both layers read `_registry.json` as the single source of truth for model tokens, AND the
  contract test (below) asserts every `-Model` value `resolve.ps1` can emit actually resolves
  in `era.ps1`'s Layer 2. Document this rationale in the spec/internals so it isn't "theatre".
- **Invalid input:** `resolve.ps1` on unmatched input emits `{"error":"unresolved","input":"…"}`
  (non-throwing) so callers can fall back to asking the user; it never guesses.
- `era/SKILL.md` keeps the human-readable table but instructs agents to call `resolve.ps1`
  when unsure. Tests: patterns table → expected flags; AND a contract test that
  (a) every flag key emitted is a real `era.ps1` parameter
  (`(Get-Command ../runtimes/era.ps1).Parameters.Keys`), and
  (b) every `-Model` value emitted resolves to a non-null model in era.ps1's Layer 2.

### Fix 7 — stall-timeout tuning
- 7 of 25 agy hard-fails were "no transcript activity for 90s". Pro median wall is ~80s.
  `$firstActivitySec`/`$stallSec` are fixed 90 (agy.ps1 ~368). **The adapter does NOT receive
  `$BundleTokens` (R2-I3) — only the already-bundle-scaled `$TimeoutSec`.** So scale off that
  plus model tier: `$stallSec = [Math]::Max($tierFloor, [int]($TimeoutSec * 0.25))`,
  `$firstActivitySec = $stallSec`, where `$tierFloor = 180` when the resolved model is Pro-tier
  (family/token matches `pro`) else `90`. Define `$proStallSec=180`/`$flashStallSec=90` as
  named constants near the top of the function (R2-nit-2; registry-driven tuning is a future
  nice-to-have, not required now). Tier detection should key on the registry `agy_model_family`
  (contains `pro`) rather than substring-matching the display string (R3-Opus-nit2), so a future
  non-`pro` premium tier doesn't silently fall back to the Flash floor.
- **Real pre-existing bug (R3-Gemini-C1, MUST fix):** the hard deadline is
  `[Math]::Min($TimeoutSec - 10, 360)` (agy.ps1:370) — it caps every agy run at 360 s even when
  `$TimeoutSec` scaled to 696 s+, killing large-bundle Pro runs mid-think (a direct cause of
  some of the 25 hard-fails). Remove the 360 cap: `AddSeconds($TimeoutSec - 5)`. Optionally pass
  `--print-timeout ${TimeoutSec}s` as a belt-and-suspenders backstop (R3-Opus-nit6) instead of
  leaving the §2 mention unused. Add a test asserting the deadline tracks `$TimeoutSec` with no
  360 clamp.

### Fix 8a — frontmatter path hardening (R1-C2 + R2-I3-Opus)
`era.ps1`'s `-SpecReview` frontmatter parser (line ~126) does
`($_ -replace '^\s+-\s+', '').Trim()` and does NOT strip surrounding quotes, so a
`related_files:` entry written as `- "backends/agy.ps1"` keeps its quotes → `Test-Path`
fails → dispatch crashes. Apply `.Trim().Trim('"',"'")` during extraction in BOTH the
YAML block-list branch and the inline `Related:` branch. **Also (R2-I3) add a YAML
inline-list branch:** match `(?m)^related_files:\s*\[(.+)\]`, split on commas, trim quotes —
otherwise `related_files: ["a.ps1","b.ps1"]` (valid YAML) silently yields an empty list. Add
test cases for block-list-with-quotes, inline-list, and inline `Related:` with quotes.

### Fix 8b — DROPPED from this spec (R2-nit-4)
A built-in `-Command report` aggregator is out of scope for a concurrency/reliability spec and
would require widening the `[ValidateSet('', 'update-models')]` on `$Command` (era.ps1:37) plus
an output-schema decision. Tracked as a separate follow-up; NOT implemented here.

## 5. Affected files
- `backends/agy.ps1` — Fixes 1,2,3,7 (largest change); accept-and-ignore `-OpencodeProvider`
  in the merged adapter so the dispatcher ScriptBlock's uniform arg-list doesn't crash
  (R3-Opus-I4); keep `-AgyModelHint`/`-ModelOverride` params + add `-ResolvedAgyModel`.
- `workflow.ps1` — Fix 1 (remove Test-ConcurrentAgyReviewers; thread `-ResolvedAgyModel`
  through `Invoke-ReviewerDispatch`'s `Start-ThreadJob -ArgumentList` AND the inner `& $fnName`
  call — R3-Opus-C1), 4 (metadata fields + `Copy-PrimaryResponseAlias`)
- `runtimes/era.ps1` — Fix 1 (KEEP settings crash-recovery one release; resolve
  `-ResolvedAgyModel`), 4 (alias call-site at :781 — R3-Gemini-I4), 5 (default), 6 (extract
  `Resolve-ModelFromHint`), 8a (frontmatter). Collateral: fix the stale `-Full` reference in
  the round-2 "Use -Full" message (R3-Opus-nit5).
- `backends/_registry.json` — Fix 5 note; **update `notes` for `gemini`/`gemini-pro-high`/
  `gemini-pro-low` from "settings.json swap" → "`--model` flag (per-dispatch, concurrent-safe)"**
  (R3-Opus-nit4). No schema change.
- `runtimes/resolve.ps1` (new — positional arg AND stdin input, suppress all non-JSON pipeline
  output via `$null =`/`[void]`; R3-Gemini-I3/OQ) + `SKILL.md` / `era/SKILL.md` — Fix 6
- `tests/*` — new regression tests per fix
- `references/internals.md`, `references/troubleshooting.md` — doc updates (incl. `--sandbox`
  probe outcome + `.era-backup` deprecation note)

## 6. Testing plan (TDD)
- New `tests/AgyModelFlag.Tests.ps1` — asserts `--model <settings_value>` is added to the
  agy ArgumentList for a resolved hint, and that no settings.json mutation function is
  referenced anymore.
- New `tests/AgenticCapture.Tests.ps1` — narration-pattern detector: true positives
  ("I will view X") and false positives (a real "(none)" review, a short legit review with
  headings).
- Extend `Get-AgyTranscriptResponse.Tests.ps1` — concurrent overlapping-dir disambiguation.
- New `tests/Resolve.Tests.ps1` — patterns table → flags.
- `Registry.Tests.ps1` / `EnvScrub.Tests.ps1` — keep green (EnvScrub still applies: the
  spawn-hardening block in agy.ps1 is preserved; only model-swap/mutex code is removed).
- **Removed/updated tests (R2-OQ4):** grep `tests/` for references to `Set-AgyModel`,
  `Restore-AgyOriginalModel`, `Get-CurrentAgyModel`, `era-agy-settings-mutex`, and
  `Test-ConcurrentAgyReviewers`; delete or rewrite any that assert the old swap/mutex
  behavior. (Current inventory shows no dedicated test file for these, but verify before
  removing the functions so a hidden assertion doesn't break.)
- New cases for Fix 3 must include the `(?m)` multiline regression (a real review whose first
  line is prose but contains `## Critical issues` later must NOT be flagged).
- Live smoke (manual, not CI): (a) `agy --print --sandbox "read <bundle>"` probe to decide
  Fix 3 `--sandbox`; (b) 2× concurrent `/era` Gemini 3.1 Pro from two processes → both
  produce independent real reviews; (c) same-process `-Reviewer gemini,gemini-pro-low` → two
  distinct reviews correlated by Run ID.

## 7. Risks / rollback
- **`--model` token drift:** if agy renames model display strings, `--model` errors. Mitigate
  by validating the resolved token against `_registry.json` and surfacing a clear error.
- **`--sandbox` may block bundle reads:** confirm with a live test before enabling; if it
  blocks, rely on the prompt hardening + detection alone.
- **Removing the mutex** could expose a different shared resource (e.g. agy's own
  conversation history). Mitigate via per-dispatch `--log-file` and the new conversation each
  `--print` creates. Verify with the concurrent smoke test.
- Rollback is per-fix: each lands as its own commit on the feature branch; revert the commit.

## 8. Open questions (resolve during review, do not block)
- Does `--sandbox` permit reading the bundle file path passed in the prompt? **(Resolve with
  a live test during implementation; if it blocks bundle reads, ship prompt-hardening +
  detection only and do NOT enable `--sandbox`.)**
- Best default-reviewer choice that honors "no REST/CLI fallback" yet is 95%+ — Gemini 3.1
  Pro (Low) (budget) vs (High)? **Decision: default bare `/era` → Gemini 3.1 Pro (Low)**
  (94% reliability class, ~3× cheaper than High at $1.5/$5.0 per M). Explicit `gemini`
  keyword still reaches Flash for callers who ask for it.
- `content_ok=false` retry policy: **retry agy once with the SAME resolved model**
  (incl. any user `-Model` override — R1-OQ2) + the hardened prompt, then fail honestly.
  Switching to a different backend is a caller decision, not automatic.
- `resolve.ps1` ↔ `era.ps1` param contract (R1-OQ1): add a contract test in
  `Resolve.Tests.ps1` asserting every flag name `resolve.ps1` emits is a real `era.ps1`
  parameter, so the two cannot silently drift.

## 9. Review resolution log

### Round 1 — Gemini 3.1 Pro (High) via agy
(DeepSeek via **opencode** failed — the opencode agent harness used its Read tool to page
through the bundle and the opencode adapter returned `exit=-1`. Note: this is the *opencode*
backend being agentic, NOT REST DeepSeek, and it failed CLOSED (honest -1), unlike the agy
silent-success bug Fix 3 targets. Fix 3's narration detector is agy-specific and does not need
to cover opencode.)
All findings validated against the real code before incorporating:
- **C1 (missing `$BundlePath` param)** — VALID, code confirmed `Get-AgyTranscriptResponse`
  lacks it. → folded into Fix 2.
- **C2 (frontmatter quotes not stripped)** — VALID, era.ps1:126 confirmed. → new Fix 8a.
- **I1 (narration regex false positives)** — VALID; spec already gated but wording was weak.
  → Fix 3 rewritten to make the heading/list gate mandatory (BOTH conditions).
- **I2 (no unified response when reviewer list lacks `gemini`)** — VALID, confirmed
  `Copy-GeminiResponseAlias` is gemini-only. → folded into Fix 4.
- **M1 (merge inner/outer agy functions)** — VALID after mutex removal. → folded into Fix 1.
- **M2 (default globs exclude .ts/.js/.go)** — REJECTED as out-of-scope + intentional:
  era.ps1:565 documents skipping ts/tsx/js as a deliberate repo-by-repo decision; callers
  pass `-IncludeFiles`. Not changing default-glob policy in a concurrency/reliability spec.
- **OQ1/OQ2** — resolved above in §8.

### Round 2 — Gemini 3.1 Pro (High) + Claude Opus 4.7 (both succeeded)
Higher-quality round; all findings validated against code before incorporating:
- **R2-C1 (registryHash drops agy family/tier → no default `--model`)** — VALID (era.ps1
  207-216 confirmed). → Fix 1: resolve token in era.ps1, pass `-ResolvedAgyModel`.
- **R2-C1/C3 (narration regex needs `(?m)`)** — VALID (PS `^` is single-line by default).
  → Fix 3 patterns now all `(?m)`/`(?im)`.
- **R2-C2 (same-process same-bundle collision)** — VALID. → Fix 2: per-dispatch GUID Run ID
  correlation, supersedes bundle-path-only.
- **R2-C3-Opus (path-match predicate under-specified)** — VALID. → Fix 2: exact 3-form
  predicate (escaped, forward-slashed, JSON-escaped) as secondary to the GUID.
- **R2-C2-Opus/I2 (retry must be in adapter, not dispatcher)** — VALID (dispatcher retry
  double-writes `$ResponsePath` + cost). → Fix 3: retry inside merged adapter pre-write.
- **R2-I1 (`-Tail 200` may miss prompt/Run-ID entry)** — VALID. → Fix 2: read full file for
  correlation, still take LAST PLANNER_RESPONSE.
- **R2-I1-Opus (Fix 5 mechanic)** — VALID. → default `@('gemini-pro-low')`.
- **R2-I2-Opus (content_ok on retry)** — VALID. → Fix 4: single entry, `retry_count`,
  `first_attempt:{}` sub-object.
- **R2-I3 (Fix 7 no `$BundleTokens` in adapter)** — VALID (confirmed). → scale off `$TimeoutSec`
  + Pro/Flash tier floor (180/90).
- **R2-I3-Opus (YAML inline-list frontmatter)** — VALID. → Fix 8a adds inline-list branch.
- **R2-I4 (orphaned `.era-backup` after removing recovery)** — VALID. → Fix 1: keep recovery
  block one release (self-deprecating).
- **R2-I5-Opus (resolve.ps1 vs era.ps1 -Model drift)** — VALID concern. → Fix 6: two-layer
  clarification + registry as single source + contract test asserts emitted -Model resolves.
- **R2-I6-Opus (opencode also races)** — VALID to call out; REJECTED as in-scope: opencode
  uses an early-release mutex (opencode.ps1:271) and already runs concurrently. → §3 non-goals
  note with evidence.
- **R2-C3-Gemini (report ValidateSet)** — mooted: **Fix 8b dropped** entirely.
- **Nits** (strategy name `run-id-match`, named stall constants, SKILL.md agentic blockquote
  update, removed-tests subsection) — incorporated into the relevant fixes / §6.

**Convergence status after R2:** not yet — R2 found multiple blocking implementation gaps that
are now resolved in-spec. Run R3 to confirm only polish/repeats remain.

### Round 3 — Gemini 3.1 Pro (High) + Claude Opus 4.7 (both succeeded)
Two genuine PRE-EXISTING bugs found plus implementation-precision items. All validated:
- **R3-Gemini-C1 (360 s hard-deadline cap defeats timeout scaling — REAL BUG)** — VALID
  (agy.ps1:370). → Fix 7: remove the cap.
- **R3-Gemini-C3 (Strategy-1 short-circuit skips existing-session scan under concurrency — REAL
  BUG)** — VALID (agy.ps1:152). → Fix 2: combine candidate sets, select by Run ID.
- **R3-Opus-C2 / Gemini-C2 (Run ID lives in USER entry, not PLANNER_RESPONSE)** — VALID
  (agy.ps1:161). → Fix 2: qualify candidate by raw-text GUID scan, then take last PLANNER_RESPONSE.
- **R3-Opus-C1 (`-ResolvedAgyModel` 3-layer plumbing)** — VALID. → §5 + plan enumerate the
  dispatcher ScriptBlock ArgumentList + `& $fnName` edits.
- **R3-Opus-C3 (retry needs structural decomposition)** — VALID. → Fix 3: extract
  `_SpawnAndCaptureOnce`, outer loops ≤2, single disk write.
- **R3-Gemini-C4 (alias call-site gated on `$results['gemini']`)** — VALID (era.ps1:781). →
  Fix 4: unconditional `Copy-PrimaryResponseAlias`.
- **R3-Gemini-I2 (narration "no list marker" loophole)** — VALID. → Fix 3: list-gate applies
  only to the length branch.
- **R3-Opus-I1 (alias signature + compat wrapper arg-shape)** — VALID. → Fix 4 signature.
- **R3-Opus-I2 (`--dangerously-skip-permissions` semantics)** — VALID. → Fix 3: keep + detect,
  add `--sandbox` only if probe passes.
- **R3-Opus-I3 (unbounded `-Raw` read)** — VALID. → Fix 2: cap ~5 MB/5000 lines.
- **R3-Opus-I4 (`-OpencodeProvider` passed to agy adapter)** — VALID. → §5: merged adapter
  accepts-and-ignores it.
- **R3-Opus-I5 (retry cost hidden)** — VALID. → Fix 3: include first_attempt tokens in total.
- **R3-Opus-I6 / Gemini-I4 (contract test needs extracted Layer-2 fn)** — VALID. → Fix 6:
  extract `Resolve-ModelFromHint`.
- **R3-Gemini-I3 (resolve.ps1 pipeline pollution) / OQ (stdin)** — VALID. → §5 resolve.ps1 note.
- **Nits** (Run-ID leading prefix, `.Replace('\','\\')`, registry `notes` update, `-Full`
  collateral, tier via `agy_model_family`, multi-line inline-list YAML limitation, "(none)"
  valid form) — incorporated into the relevant fixes.
- **Open questions** (merged-adapter keeps `-AgyModelHint`/`-ModelOverride`: YES, plus
  `-ResolvedAgyModel`; remove `$script:SavedAgyModel` but keep era.ps1 recovery: confirmed) —
  resolved in §5/Fix 1.

**Convergence status after R3:** findings are now implementation-precision (all folded in) plus
two latent bugs (folded in). Run R4 to confirm only nits/repeats remain; if so, declare
converged and proceed — TDD in execution will catch residual detail.

### Round 4 — Gemini 3.1 Pro (High) + Claude Opus 4.7 (both succeeded)
No new architectural objections. Findings were precision refinements + one blocking empirical
unknown, now resolved by live probe. All validated:
- **R4-Opus-C1 (last-PLANNER_RESPONSE unsound in reused transcript)** — VALID. → Fix 2: take
  FIRST PLANNER_RESPONSE after the GUID's USER line.
- **R4-Opus-C2 (retry budget vs Wait-Job)** — VALID. → Fix 3: cap each attempt deadline to half
  the dispatcher budget.
- **R4-Opus-I1 / OQ1 (does agy echo Run ID verbatim?)** — **RESOLVED by live probe: YES**, in
  `USER_EXPLICIT/USER_INPUT`. Fix 2 confirmed sound; no `--log-file` fallback needed.
- **R4-Opus-I3 (list regex `\d` too loose)** — VALID. → Fix 3: `(?m)^\s*([-*+]|\d+[.)])`.
- **R4-Opus-I4 (retry breaches approved cost cap)** — VALID. → Fix 3: skip retry if it would
  exceed `AggregateCap`.
- **R4-Opus-I5 (Resolve-ModelFromHint extraction breaks `$script:_MatchMode`)** — VALID. →
  Fix 6: parameterize `_MatchMode`, localize closures, mimo-v2.5 acceptance test.
- **R4-Opus-I2 (default = 5× input price, not just "3× cheaper than High")** — VALID framing. →
  Fix 5 + release-notes note; per-reviewer cap stays `$2` (input < `$10/M`).
- **R4-Gemini-C1 (registryHash drops family/tier)** — VALID. → Fix 1: preserve them in the copy.
- **R4-Gemini-C2 (new params break legacy callers)** — VALID. → Fix 2: optional params, fall back.
- **R4-Gemini-I1 (contract-test hardcoded path)** — VALID. → Fix 6: use `$PSScriptRoot`.
- **R4-Gemini-OQ (`--sandbox`)** — **RESOLVED by live probe: hangs → do NOT use.** → Fix 3.
- **Nits** (inline-list `\[([^\]]+)\]` non-greedy, `.Contains()` for path match, add
  `Get-CurrentAgyModel` to grep list, Copy preference = first SUCCESSFUL in preference order,
  named-constant clarification, multi-line-narration test comment) — folded into the fixes.

**CONVERGED after R4.** R4 produced zero new architectural findings; all items were precision
refinements (incorporated) and the two open empirical questions were settled by live probe.
Further rounds would surface only micro-nits; remaining detail is owned by TDD during execution.
**Status: READY TO IMPLEMENT.**
