---
title: /era post-overhaul assessment
date: 2026-06-04
author: Claude (Opus 4.8)
scope: backends/agy.ps1, workflow.ps1, runtimes/era.ps1, runtimes/resolve.ps1, backends/_registry.json
data_window: 2026-05-26 .. 2026-06-04 (313 reviewer-entries across both .external-reviews trees)
overhaul_commit: 5609da8 (master); rollback bookmark = branch era-concurrency-agentic-fix (pre-overhaul master 45e0442)
---

# /era post-overhaul assessment — 2026-06-04

## TL;DR

The overhaul's **structural** changes are sound and visible in the source: the
settings.json swap + cross-process mutex are gone (replaced by a per-process
`--model` flag), Run-ID GUID correlation is implemented correctly, the
agentic-narration detector + single retry is wired pre-write, and the metadata
writer now emits honest `content_ok` / `capture_strategy` / `retry_count` /
`retry_reason` / `first_attempt` fields.

**But the single most important empirical finding is that none of the new
behavior has executed in a recorded run yet.** Across **313 reviewer-entries**
(2026-05-26 → 2026-06-04) in both `.external-reviews` trees, **zero** carry any
of the new metadata fields. Every run that reviewed the overhaul itself
(`era-concurrency-agentic-fix`, 2026-06-04 13:55–14:13) was dispatched by the
*pre-metadata-change* code on disk, so it recorded the old schema. The new
default preset **`gemini-pro-low` has 0 recorded runs**. So the retry path, the
narration detector firing on a real capture, the cost-cap retry-skip, the
run-id-match strategy under genuine concurrency, and the new metadata schema are
all **proven only by unit tests, never by a live dispatch.** The Step-2 dispatch
of this very document is the first real exercise of that path.

## Method

Swept every `round-*-metadata.json` under
`~/.claude/skills/external-review-auto/.external-reviews` and
`~/projects/**/.external-reviews`, flattened to per-reviewer rows, and aggregated
exit-code success by preset/backend. Read the five source files end-to-end for
remaining bugs. Field-presence (`content_ok`) was used to separate
post-overhaul-schema rows from legacy rows.

## Historical reliability (exit_code == 0), all 313 entries

| Preset | n | ok | rate | avg wall (ok) |
|---|---|---|---|---|
| gemini-pro-high | 179 | 173 | **97%** | 84s |
| gemini (3.5 Flash) | 57 | 38 | **67%** | 84s |
| deepseek | 43 | 40 | 93% | 103s |
| opus | 23 | 23 | 100% | 128s |
| gemini-api | 6 | 6 | 100% | 18s |
| haiku | 4 | 3 | 75% | 16s |
| minimax | 1 | 1 | 100% | 102s |

| Backend | n | ok | rate |
|---|---|---|---|
| agy | 236 | 211 | 89% |
| opencode | 44 | 41 | 93% |
| claude | 27 | 26 | 96% |
| geminiapi | 6 | 6 | 100% |

Top failure causes (exit≠0): `<null>` ×10, `agy stalled — no transcript
activity for 90s` ×7, `timeout` ×6, `Could not retrieve agy response` ×2.

### Does this validate the overhaul's premises?

- **Flash 67% is real and confirmed** (38/57). It is by far the least reliable
  preset, and the 90s Flash stall floor is the single most common named failure
  (7 of the stalls). Demoting bare `/era` off Flash onto `gemini-pro-low` is
  justified by this data — *but* see the caveat below: pro-low's reliability is
  assumed from pro-high (97%), not measured.
- **Pro (High) sits at 97%** (173/179), even better than the "94% class" the
  spec claims. The Pro path is the proven workhorse.
- The "I will view X" silent-capture failure mode and the mutex-collision
  failure mode **do not appear as named errors in the historical data** — which
  is exactly the problem the overhaul targets: those failures were *silently
  recorded as successes* (exit 0, short/garbage body), so they're invisible in
  an exit-code aggregate. The new `content_ok` field is the instrument that
  would finally surface them, and it has not yet recorded a single value.

## Source review — what's solid

1. **Concurrency fix (agy.ps1:384–421, workflow.ps1:412–414).** The model is
   passed via `--model <settings_value>` on each `ProcessStartInfo`; nothing
   shared is mutated. The old global mutex and `Resolve-AgyDefaultModelToken`
   collapse are gone, and per-reviewer default resolution
   (workflow.ps1:512–519) genuinely keeps a heterogeneous agy batch
   (`gemini,gemini-pro-low`) on distinct tokens. This is correct and removes the
   60s-mutex-vs-80s-Pro-run deadlock described in the header.
2. **Run-ID correlation (agy.ps1:362–369, 240–255).** A leading
   `[Run ID: <guid>]` is prepended so it survives mid-prompt truncation; capture
   matches the GUID across the *combined* new+existing candidate set with no
   short-circuit on "new dirs exist," which is the right call under concurrency.
   Pass-2 path-form fallback correctly requires a `USER*` anchor line so a stale
   MODEL line quoting the same bundle path can't win.
3. **Narration detector (agy.ps1:72–135).** Uses `(?m)` anchors so a real review
   whose first line is prose but which contains `## ...` later is not
   mis-flagged; the `(none)` empty-review guard is present; the list regex
   `^\s*([-*+]|\d+[.)])` avoids counting `2026:` / `404:` as list markers.
4. **Honest metadata (workflow.ps1:687–793).** Failures now preserve real
   `wall_clock_sec` / `response_chars` instead of zeroing them; `first_attempt`
   cost is folded into the round total so a retry isn't billed as $0.
5. **Resolver (resolve.ps1).** Exact reviewer-keyword match (5609da8) fixes the
   real bug where topic slugs containing `pro`/`api`/`gemini`
   (`improvement-plan`, `api-gateway-spec`) were misrouted to reviewer-spec
   resolution. The stdin-vs-no-arg distinction (`$PSBoundParameters.ContainsKey`)
   genuinely prevents the CI hang.

## Source review — remaining bugs / risks (ranked)

### R1 — (Process risk, highest) New code paths are entirely unexercised live
No metadata row has `content_ok`; `gemini-pro-low` has 0 runs. The retry loop,
narration firing on a real capture, run-id-match under true concurrency, and the
new schema have only unit-test coverage. **Recommendation:** treat the Step-2
dispatch as the canary, and run one deliberate 2-way concurrent
`gemini-pro-low,gemini-pro-high` dispatch plus one run that deliberately induces
a narration capture before trusting the fields in any dashboard.

### R2 — Narration detector can false-positive on terse legitimate reviews
`Test-AgenticNarrationCapture` flags any capture with **no markdown heading, no
list marker, and length < 300** as narration (agy.ps1:132). A legitimately
terse review such as `No correctness issues found; the concurrency fix is
sound.` (no heading/list, <300 chars) would be classified as a bad capture,
trigger a wasteful retry, and — if the retry is also terse — be recorded as
`exit_code = -1` / `content_ok = false`, i.e. a *real review discarded as
failure*. The prompt templates request headings so this is unlikely in practice,
but the floor is a heuristic that can eat a valid short answer. **Recommendation:**
lower the floor or add a "looks like prose sentences about the code, not about
the agent's own actions" check; at minimum, log the discarded body so a
false-positive is recoverable.

### R3 — The adapter's $15 retry cost-cap guard is effectively dead code
`Invoke-AgyReview` hardcodes `$aggregateCap = 15.0` for the retry-skip decision
(agy.ps1:563, 618), but the real per-reviewer cap from `Get-PerReviewerCap` is
$2 (cheap) / $10 (expensive). For a single agy reviewer at Pro-High input
($3.5/M), the projected first+retry cost would have to exceed $15 — i.e. ~2M+
input tokens *per attempt* — before the skip fires. So the guard essentially
never triggers; retries always proceed. Not a correctness bug (retries are
cheap), but the guard gives a false sense of cost protection and the cap value
is inconsistent with the dispatcher's own caps. **Recommendation:** either wire
the real per-reviewer cap into the adapter or delete the guard and document that
the single retry is always taken.

### R4 — Retry output-token projection deliberately under-estimates
`$projRetryCost` reuses the *bad* attempt's tiny output-token count as the
retry's output estimate (agy.ps1:610–617, acknowledged in-comment). Combined
with R3 this is harmless today, but if R3 is ever fixed to use the real $2 cap,
this under-projection could let a retry slip past a cap it should have hit on a
large bundle. Flagging the coupling, not asking for a fix now.

### R5 — Single-reviewer failed agy run leaves no response.md
On `content_ok = false` the agy adapter returns before the `Set-Content`
(agy.ps1:710 is success-only), so a failed single-reviewer dispatch writes
`round-N-metadata.json` (exit -1) but **no** `round-N-response.md`. Downstream
consumers that read response.md without checking metadata will see "nothing
happened" rather than "failed." `Copy-PrimaryResponseAlias` only runs for
multi-reviewer. Acceptable (it *is* a failure), but worth a one-line note in the
skill docs so callers always check metadata `content_ok`/`exit_code`, not just
file presence.

### R6 — Orphaned claim files still block round numbers (known, unchanged)
`Reserve-ReviewRound` deletes the claim on success/failure via the `finally` in
era.ps1, but a hard kill (Ctrl-C/OOM) still orphans `round-N-claim.json`, which
permanently reserves N for that topic. Documented limitation; the overhaul did
not change it. Low impact.

## Comparison to the old failure modes

| Old failure mode | Overhaul mechanism | Status in this assessment |
|---|---|---|
| Flash 67% reliability | default → gemini-pro-low (Pro class) | Premise confirmed (67% measured); fix plausible but pro-low unmeasured |
| "I will view X" silent capture | `Test-AgenticNarrationCapture` + retry + `content_ok` | Implemented & unit-tested; **never fired on a real capture yet** |
| Mutex collisions under concurrent agy | per-process `--model`, mutex removed | Implemented correctly in source; **no concurrent run recorded post-change** |
| Wrong-session recency capture | Run-ID GUID match, no new-dir short-circuit | Implemented correctly; **no live correlation data yet** |
| Dishonest zeroed failure metadata | preserve wall/chars, fold first_attempt cost | Implemented; only verifiable once a real failure is recorded |

## Second-opinion addendum (Gemini 3.1 Pro High, round-1, run-id-match capture)

The Step-2 dispatch itself became the first live exercise of the new schema:
`content_ok=true`, `capture_strategy="run-id-match"`, `retry_count=0`, 114.6s,
$0.15 — the preferred capture strategy worked on the first real run, retiring
part of R1.

Gemini's one substantive addition, **verified against source**:

- **R7 (new, real) — stalls/timeouts bypass the retry loop.**
  `_SpawnAndCaptureOnce` *throws* on stall/timeout (agy.ps1:472–476, 479–483)
  inside a `try/finally` with no catch. The retry loop calls it with no
  try/catch (agy.ps1:588–590), so a thrown stall/timeout exits `Invoke-AgyReview`
  before attempt 2 — **the single retry only covers *captured* bad output
  (empty-capture / agentic-narration), not stalls or timeouts.** Since stalls (7)
  and timeouts (6) are the most common *named* historical failures, the retry
  does not address them. This is a legitimate scope gap my original write-up
  under-stated by calling the retry "self-healing" without qualifying it to
  captures.
  - **Correction to Gemini:** its framing that the exception "crashes the
    ThreadJob immediately" is **wrong** — the dispatcher's ThreadJob try/catch
    (workflow.ps1:542–559) catches it and returns honest `ExitCode=-1` metadata.
    It does not crash; it fails cleanly. And its "Critical" severity is
    overstated: retrying a stall/timeout means replaying the full bundle after
    already burning the full timeout, which is expensive and often futile, so
    *not* retrying them is a defensible design choice — provided it's documented.
  - **Action:** either (a) document that the retry is capture-only by design, or
    (b) wrap `_SpawnAndCaptureOnce` in try/catch inside the loop and retry a
    stall once with a fresh deadline. (a) is the lower-risk fix.
  - Gemini's cited line numbers (agy.ps1:2482/2368/2374) are hallucinated — the
    file is 729 lines — but the structural claim maps correctly onto the real
    lines above.

## Fixes applied & live validation (2026-06-04, post-review)

**Live validation (retires most of R1):**
- First-ever `gemini-pro-low` run recorded (`era-post-overhaul-assessment`,
  `era-concurrency-live-val`): `content_ok=true`, `capture_strategy=run-id-match`,
  `retry_count=0`.
- Concurrent single-process `gemini-pro-low,gemini-pro-high` batch ran with
  **two distinct `--model` tokens** (`gemini-3.1-pro-low` + `gemini-3.1-pro-high`
  — the heterogeneous batch did not collapse), both captured via `run-id-match`,
  both `content_ok=true`. The mutex-removal and Run-ID-correlation paths are now
  proven under genuine concurrency, not just unit tests.
- `content_ok` / `capture_strategy` / `retry_count` now populate in real metadata
  (they did so for the first time on these runs).

**R7 — FIXED.** `Invoke-AgyReview`'s retry loop now wraps `_SpawnAndCaptureOnce`
in try/catch (agy.ps1). A thrown stall/timeout is classified as a bad attempt
with `retry_reason='stall-or-timeout'` and retried once (within the
half-budget-per-attempt window); two consecutive stalls return an honest
`ExitCode=-1` / `content_ok=false`. The single retry now covers the most common
historical failures (stalls + timeouts), not just captures. Regression tests:
`tests/RetryLoop.Tests.ps1`.

**R3 — FIXED.** The adapter's hardcoded `$15` retry cost-cap is replaced by the
real per-reviewer cap (`$2` cheap / `$10` expensive), mirroring
`Get-PerReviewerCap`. A retry that would breach the reviewer's own cap is now
skipped honestly (records `first_attempt` spend). Tests cover both the skip and
the proceed-under-cap path.

**Convergence-loop findings (re-reviewed via `/era Gemini 3.1 Pro`):**

- **R8 — FIXED (found live, round 2).** A "bundle-not-available" refusal capture
  ("I cannot review the bundle content because it was not included … please paste
  the content") slipped through as `content_ok=true`: >300 chars (clears the
  length floor) and no narration verb. `Test-AgenticNarrationCapture` now has a
  Branch 3 that flags a no-heading bundle-unavailable refusal. This both makes the
  metadata honest AND triggers the single retry (the failure is intermittent — the
  identical prompt succeeded on rounds 1 and 3). Tests in AgenticCapture.Tests.ps1.

- **C1 — FIXED defensively (round 3 claim partly refuted).** Gemini claimed
  `transcript.jsonl` (token-truncated) is scanned before `transcript_full.jsonl`,
  losing review text. **Refuted as stated:** PowerShell `Sort-Object` is
  culture-aware and orders `transcript_full.jsonl` FIRST (verified empirically and
  via a passing capture test), so the full copy is actually returned. But relying
  on collation is fragile, so the capture candidate set now includes ONLY
  `transcript_full.jsonl` (always present; matches the existing-session path).
  Verified: truncation is real (4108 vs 7143 chars in a live transcript), so the
  defensive fix removes a genuine latent risk. Test in
  Get-AgyTranscriptResponse.Tests.ps1.

- **C2 — FIXED (round 3, real).** `$agyProc.Kill()` on stall/timeout killed only
  the `agy.cmd` wrapper, orphaning the `node.exe` agent. Now `Kill($true)` tears
  down the whole tree (PS7). Tests in AgyModelFlag.Tests.ps1.

- **Minor1 — FIXED (round 3, real).** `Reserve-ReviewRound`'s
  `New-Item -ErrorAction SilentlyContinue` masked a genuine dir-creation failure,
  causing a misleading 50-spin "failed to claim a round number" error; it now
  surfaces the real cause immediately.

- **I1 — REFUTED (round 3 hallucination).** Gemini claimed `Get-FileHash
  -LiteralPath $f` is called on a repo-relative path without joining `$RepoRoot`.
  False: `Write-ReviewManifest` hashes ABSOLUTE bundle/prompt paths, and the
  `sources` / `Get-ReviewDiff` blocks already `Join-Path $RepoRoot`. No change.
  (Gemini's line numbers were hallucinated in every round — agy.ps1 is 729 lines,
  it cited 2281/2560; verify structurally, never on its citations.)

- **I2 — ACKNOWLEDGED, not changed (round 3, real but intentional).** The 2-second
  liveness poll globs all brain session dirs. It must: the dispatch's own session
  dir is unknown until capture, and a reused-session dispatch's transcript lives
  in a pre-existing dir, so scoping the poll to new dirs would miss it. Low
  impact; left as-is with this rationale.

**Round 4 (convergence).** Re-review of the fully-fixed source returned **Critical:
(none)**, **Missing: (none)**, and an explicit confirmation that R7/R3/R8/C1/C2/
Minor1 are "structurally sound, well-tested, and correctly implemented." Only two
optional nits remained, both since fixed:
- *DRY:* the identical `$firstAttempt` hashtable in the cap-skip and proceed
  branches is now built once above the cap check (behavior-identical; covered by
  the existing cap-skip/retry tests).
- *Resolver:* the `use` splitter now breaks on the LAST `use` so a topic
  containing the word "use" (e.g. `fix use of deprecated api use gemini`) keeps its
  full slug instead of mis-routing the remainder into reviewer resolution. New test
  in Resolve.Tests.ps1.

**Round 5.** A deeper pass surfaced a long tail of real-but-minor issues (none
hallucinated this round — all verified against source):
- *C5.1 — FIXED (real, data loss):* `era.ps1`'s crash-recovery `catch` blocks
  deleted the `.era-backup` when the restore `Copy-Item` failed, permanently
  losing the user's pre-crash settings. The catch now KEEPS the backup and warns
  so a later run can retry. (Blast radius is the deprecated one-release migration
  path, but the fix is trivially correct.)
- *I5.1 — FIXED (real, diagnostic):* the Tier-1 stall throw read `$errFile` before
  the async stderr copy was flushed, yielding an empty "stderr:" message; it now
  drains+flushes the sink first.
- *I5.2 — FIXED (real, correctness):* a bare `reasoner` hint was in
  `$reviewerKeywords` but resolved to `{error:unresolved}`; the DeepSeek branch now
  also triggers on `reasoner`. New test in Resolve.Tests.ps1.
- *C5.2 — REAL, DEFERRED (documented):* on a failed dispatch, `Write-ReviewMetadata`
  bills the FINAL attempt's input as `$0` (only the discarded first attempt's cost
  is folded in). This under-reports failed-run spend. A correct fix must avoid
  double-counting the cap-skip case (which the existing test pins at exactly the
  first-attempt cost) and so needs an adapter-contract change; deferred rather than
  rushed. Tracked here as a known accounting limitation.
- *M5.1 — already known:* the retry output-token projection under-estimates (= R4,
  acknowledged in-code; input dominates at the cap, so low impact).

**Round 6.** Critical: (none) again. This round also served as a live retry proof:
the dispatch hit an agentic-narration capture on attempt 1, retried
(`retry_count=1`, `retry_reason="agentic-narration-capture"`), succeeded, and the
metadata folded the discarded first attempt's $0.156 into the round total — the
R7/R3/first_attempt machinery working end-to-end in production. Findings were a
fourth tier of edge cases:
- *L6.1 — FIXED (real, narrow leak):* if `_SpawnAndCaptureOnce`'s loop exits at
  `$hardDeadline` (not a Tier-1/2 stall) and agy's `--print-timeout` fails to
  self-terminate, the process tree was orphaned (Kill($true) was only on the stall
  branches). The `finally` now tree-kills any still-alive process. Extends C2.
- *Known long tail (documented, not fixed):* WallClockSec isn't summed across
  retries and a thrown stall reports 0s (metrics only); `Get-ReviewDiff` labels a
  file dropped from `-IncludeFiles` as "Deleted" to the model (diff-semantics nit);
  `-AutoDetect` doesn't strip Git's C-style quotes on space-containing filenames
  (edge case). All cosmetic/edge; none affect core review correctness.

**Convergence.** Critical findings: 1 (r1) → 0 (r4) → 0 (r5) → 0 (r6). Severity
decayed monotonically — real bugs (r1–r3) → minor real issues (r5) → cosmetic/edge
(r6). Every real claim was verified against source before acceptance; two were
refuted on inspection (I1 and C1-as-stated, both round 3; Gemini hallucinated line
numbers every round — always verify structurally). An adversarial reviewer never
asymptotes to literally zero findings, so the operative convergence criterion is
**"no remaining finding affects the correctness of the core review path,"** reached
by round 4 and confirmed stable through round 6. Stopping here: further rounds would
only surface progressively-smaller cosmetic items at real $/latency cost. Deferred
real items (C5.2 failure-path input cost; L6.x metrics/diff/quoting) are recorded
above as a known backlog.

**Suite:** ~240 Pester tests passing (224 prior + new: RetryLoop ×5, R8 ×4,
C1 ×2, C2 ×2, resolver ×2). All fixes landed under TDD (red→green) except the
diagnostic/error-path one-liners (C5.1, I5.1, L6.1), which are guarded by the
existing C2 source-pattern tests and verified by inspection.

**Deliberately NOT changed:** R2 (narration <300-char floor) — softening it risks
detection regressions; left as a documented heuristic. R5 (no response.md on a
failed single-reviewer run) and R6 (orphaned claim files) — documented behaviors,
low impact.

## Cross-backend validation (claude + opencode), 2026-06-04

The agy path got the deep treatment; the other two native-process backends were
audited and smoke-tested with the cheap models (cost-conscious):

- **claude backend (Haiku 4.5):** live `/era -Reviewer haiku` → `exit 0`,
  `content_ok=true`, `capture_method=direct`, 44.5s, **$0.008**. This backend is
  structurally *more* robust than agy: the bundle is piped via stdin and the review
  is read straight from stdout — no transcript polling, no Run-ID correlation, no
  agentic tool-loop, so the whole class of agy capture failures cannot occur here.
  Historically 100% (opus 23/23). Honest-metadata fields default correctly
  (`capture_strategy=null`, `content_ok` mirrors a clean exit).
- **opencode backend (DeepSeek V4 Flash):** live `/era -Reviewer deepseek -Model
  'deepseek v4 flash'` → `exit 0`, `content_ok=true`, variant auto-resolved to
  `max`, 104.1s, **$0.004**. The state.json swap + disk backup + early-restore +
  startup mutex all functioned. This is the most complex adapter and still uses a
  `Global\era-opencode-state-mutex` to serialize the ~3s startup window (necessary
  because opencode resolves model/variant from a shared state file) — so concurrent
  opencode *startups* serialize, though inference then runs in parallel. Well
  defended (30s mutex timeout, abandoned-mutex handling, crash recovery — the latter
  now hardened by C5.1). Historically 93% (deepseek 40/43).

**Fix applied — process-tree kill on claude + opencode (same class as agy C2/L6.1).**
Both adapters used a bare `$proc.Kill()` on timeout/stall (`claude.ps1`,
`opencode.ps1` ×2), which terminates only the cmd/npm shim and orphans the child
`node.exe`. Both now use `Kill($true)` plus a defensive tree-kill in `finally`. A
new cross-adapter invariant test (`tests/ProcessTreeKill.Tests.ps1`) asserts all
three native-process adapters tree-kill and carry no bare `.Kill()`.

**Residual, by design (not bugs):** neither claude nor opencode has the
agentic-narration detector or the single-retry self-heal that agy now has. For
claude this is fine (direct stdout, no tool loop — nothing to narrate). For
opencode there is a *latent* gap: it reads the bundle via a Read tool call, so a
tool-intent narration / empty capture is theoretically possible and would not be
detected or retried. It has not been observed (deepseek 93%), but it's the one
place opencode is less defended than the post-overhaul agy path.

## Opencode adapter — dedicated `/era Gemini 3.1 Pro` review (2026-06-04)

Ran a focused Pro review of `opencode.ps1` (+ `_registry.json`). Every claim
verified against source (two empirically tested in pwsh):

- **C-FileShare — FIXED (real, also fixed agy).** `[System.IO.File]::Create` opens
  with `FileShare.None`, so the stall snapshot's `Get-Content` (and the agy Tier-1
  stderr read I'd just added) always failed silently → "<no stdout>/<no stderr>".
  Verified live (`Get-Content` throws "in use"). All three adapters now open
  capture sinks with `FileShare.ReadWrite`. Test: `BackendCaptureHardening.Tests.ps1`.
- **C-Kill(bool) on PS5.1 — REFUTED for our runtime, hardened anyway.** The
  reviewer warned `Process.Kill($true)` doesn't exist on Windows PowerShell 5.1
  (.NET Framework) and would silently no-op. Verified: we run **pwsh 7.6.2 Core**
  where `Kill(bool)` exists, and the skill is pwsh-7-only by design. Made that
  explicit with `#Requires -Version 7.0` in `era.ps1` (fail fast on 5.1 rather than
  swallow a missing-method exception).
- **Important: false-success on tool refusal — FIXED (the planned #2 port).**
  Confirmed real: opencode reads the bundle via a Read tool, so a refusal or
  tool-narration can exit 0 and be recorded as a successful review. The
  agy narration/refusal detector is now extracted to a shared
  `backends/_capture-validation.ps1`, dot-sourced by both agy and opencode;
  opencode applies it and returns an honest `ExitCode=-1` / `ContentOk=false` on a
  non-review. (No in-adapter retry yet — opencode's state-swap/mutex startup isn't
  structured for a clean replay; caller re-dispatches. Tracked as follow-up.)
- **Mutex `WaitOne` outside try/finally — partially real, NOT changed.** The
  reviewer called it a permanent deadlock; it isn't — the existing
  `AbandonedMutexException` handler recovers an abandoned mutex on the next
  dispatch (with a warning). Low value; left as-is.
- **Reasoning-model 120s base (unmapped variants), single-quote bundle path,
  slash-less model id, 5s early-restore race, Read-tool truncation — REAL, DEFERRED
  (documented).** Edge/tuning cases, none on the success path of the validated
  flow. The single deepest one (Read-tool bundle access) is the root cause behind
  both the false-success gap and the truncation risk; switching opencode to
  stdin-piped bundle (like the claude backend) would remove that whole class — the
  recommended next structural change.

**Re-smoke after the changes:** opencode (DeepSeek V4 Flash) still dispatches clean
(`exit 0`, `content_ok=true`). Suite: 255 passing.

## Opencode bundle-access prototype — `-f` attach (replaces the Read-tool), 2026-06-04

Prototyped and live-tested the deepest opencode robustness change: stop telling the
model to *Read* the bundle (an agentic action it can refuse/narrate/truncate) and
instead **attach the bundle file directly** via `opencode run -f <file>`.

- **`opencode run` has `-f, --file` ("file(s) to attach to message")** — the
  native, deterministic way to put the bundle in context (the equivalent of the
  claude backend's stdin pipe). Probe-confirmed: a `-f`'d file with a planted
  `SECRET_REVIEW_TOKEN` was echoed back verbatim and its planted bug named, on
  DeepSeek V4 Flash.
- **Arg-order gotcha:** `-f` is a greedy yargs ARRAY, so the message must be the
  FIRST positional and `-f <bundle>` LAST, or `-f` swallows the prompt ("File not
  found: Review ..."). Encoded in the adapter + a regression test.
- **Implemented** as the new default in `opencode.ps1` (prompt = "Review the
  attached bundle... do not call any tools"; `-f $BundlePath`), with
  `ERA_OPENCODE_READ_TOOL=1` as a rollback. Model/variant selection (state.json
  swap + mutex) is untouched.
- **Live result (DeepSeek V4 Flash, attach mode default):** `exit 0`,
  `content_ok=true`, a genuine structured review of the bundle — and **~2.5–3.5×
  faster** (29.4s vs 73–104s for the Read-tool runs, since there's no tool
  round-trip). It even found a real bug in this session's own `reasoner` resolver
  fix (`reasoner` was missing from the `noOtherFamily` guard, so `"reasoner pro"`
  mis-routed to gemini — now fixed with a test).
- **Why this matters:** `-f` removes the false-success root cause *and* the
  Read-tool truncation risk in one move, and is faster. Combined with the
  narration detector (kept as a backstop), opencode's robustness gap vs the
  post-overhaul agy/claude paths is essentially closed.
- **Noted for later (not done):** `opencode run` also accepts `--variant`, which
  could replace the entire state.json-swap + mutex machinery with a plain CLI flag
  — a large simplification, deferred as its own change.

Suite after this work: 259 passing.

## Opencode stateless refactor (branch `era-opencode-stateless`), 2026-06-04

Investigated whether `opencode run`'s `--variant` CLI flag could replace the
entire `state.json`-swap + `Global` mutex machinery. Empirical findings (pwsh,
DeepSeek V4 Flash, with the user's state backed up/restored each probe):

- **`-m` selects the model standalone** — `recent[0]` was `minimax/MiniMax-M3` yet
  `-m opencode-go/deepseek-v4-flash` ran deepseek. No `recent[0]` shadowing.
- **`opencode run -m` does NOT mutate `model.json`** — controlled before/after
  hash: unchanged. The swap/restore/mutex/crash-recovery protected a file the run
  never touches.
- **`--variant` is accepted** (documented flag) but **not validated** (an invalid
  value runs fine), and `low` vs `max` showed no measurable difference — so variant
  control is best-effort at most. We still resolve `$chosenVariant` from the
  registry: it's passed via `--variant` AND drives the stall-threshold tuning
  (which is real and matters).

**Refactor (on the branch):** removed the `Global\era-opencode-state-mutex`, the
`model.json` snapshot/mutate/disk-backup, the early-restore, and the inner+outer
restore finallys — replacing it all with `-m <model> --variant <chosen>` flags.
`opencode.ps1` went **502 → ~245 lines**. This deletes every opencode concern the
Gemini review raised (mutex abandonment, double-release, the 5s early-restore
race) and the slash-less-model crash, and lets concurrent opencode startups run in
parallel. Kept: hidden console, env scrub, FileShare sinks, variant-aware stall
tuning + forensic snapshot, tree-kill, the `-f` attach, and the non-review detector.

**Live validation:** two **concurrent** DeepSeek V4 Flash dispatches both succeeded
(`exit 0`, `content_ok`, real 5032/2239-char reviews, 16–25s) with **no mutex
serialization**, and the user's `model.json` hash was **byte-identical before and
after** (no `.era-backup` created). Suite: **263 passing**.

**Caveat for review:** if `--variant` is in fact a no-op, reasoning models run at
their provider-default effort instead of `max`. No measurable quality difference
was observed, and the stall-tuning still uses the resolved variant, so impact looks
negligible — but that's the one behavior this branch changes vs the old swap.

**Option B insurance (opt-in, default OFF).** As belt-and-suspenders, setting
`ERA_OPENCODE_VARIANT_STATE=1` ALSO writes the resolved variant into the user's
`state.json` variant map (in addition to `--variant`), in case some provider honors
the state file rather than the flag. It's restored **byte-identical** afterward
(`ReadAllBytes`/`WriteAllBytes` — a ConvertTo-Json round-trip would reflow the file;
caught + fixed by the live test) under a brief `era-opencode-variant-mutex`. With
the env unset, opencode stays fully stateless (the default, validated above). Live:
B-enabled run wrote `variant=max`, produced a real review, and left `model.json`
byte-identical. Residual: concurrent opt-in B runs share a small restore-race
window — acceptable for an off-by-default path writing deterministic values.

## Bottom line

Direction and code quality are good; the overhaul fixes the right things and the
source is careful and well-commented. The **gap is evidentiary, not structural**:
the project shipped a measurement instrument (`content_ok` & friends) and a
self-healing retry without yet producing a single data point from either, and
made `gemini-pro-low` the default without a single recorded pro-low run. The
highest-value next step is not more code — it is **live validation**: a concurrent
pro-low/pro-high run, a deliberately-induced narration capture, and confirmation
that the new fields populate as designed. Secondary: fix or delete the dead $15
retry guard (R3) and soften the <300-char narration floor (R2).
