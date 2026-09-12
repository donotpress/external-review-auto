# Plan: /era skill to minimum A- on all axes

Date: 2026-09-12. Status: proposed (uncommitted working-tree state: see manifest).
Basis: letter-grade assessment 2026-09-11 (overall B+; complexity C, latency C+,
token efficiency B, docs B+, UX B-, recovery B-; all others A-), plus two
meta-review panel rounds (opus + muse-spark + gemini-api) and the 2026-09-11
incident cluster (agy stream interruptions/no-starts, opencode read-tool
silence, repomix exit hang).

Critical path: commit the tree first (done: `d39f97e`, pushed) → circuit
breaker → MS6 → complexity split → differential bundles → docs/UX batch →
live soak → re-grade.

## 1. Circuit breaker for consecutively-failing backends (latency + recovery)

- Problem: three consecutive fatal stalls on one backend (measured twice in
  one week; streak scan over 293 metadata files: agy longest same-backend
  run 7, opencode 12, claude 3) each burn a full seat budget (~600s+)
  before failing identically.
- Change (adjudicated skip-only; REST-first cut): per-dispatch, skip seats
  whose backend shows >=3 consecutive fatal rounds; always dispatch at
  least the healthiest seat (never-zero). Fatal taxonomy (recovery-owned):
  dead-transport codes + stall/timeout/empty/crash = fatal;
  narration/contract/echo = seat flaky, backend alive. Streak state is a
  machine-scoped JSON file (per-topic stores reset and never see
  cross-topic streaks), entries expire after 24h, missing/malformed reads
  fail open to dispatch-everything. Skipped seats record `breaker-skip`
  (recoverable, so a voided round still gets its one REST fallback).
- Bounds: N=3 constant (justified by the streak scan, not tunable until
  soak evidence says otherwise); success or non-fatal failure resets.
- Risk: moderate (panel-assessed): a stuck streak thins panel diversity;
  expiry + never-zero + fail-open reads are the guards.

## 2. MS6: dispatcher-killed seats bypass dead-transport decode (recovery)

- Problem: a seat abandoned by straggler-grace/budget tree-kill recorded
  synthetic `Error='timeout'`, which never passed through
  `Convert-EraAdapterResultError` -- so the round-3 headline case (one Read,
  then 860s of zero stdout) cannot recover via the dead-transport fallback
  built for exactly it.
- Change (adjudicated: in-band, not %TEMP%-join): on the abandon path,
  specify kill → join (bounded 20s unwind, new `Wait-EraJobDone`) →
  `Receive-Job` → run the returned record through the existing
  `Convert-EraAdapterResultError` → fall back to the synthetic `timeout`
  only when nothing structured comes back. Same treatment the grace path
  already gets via shared collection; this closes the budget path, which
  reaped with `Stop-Job` before the adapter's finally could return.
- Requires tests pinning both directions: zero-output abandon decodes to
  `opencode-no-output`; non-zero-output and no-return abandonments stay
  `timeout`.
- Risk: moderate. Touches the timeout synthetic every abandoned seat flows
  through -- the tests above are the guard.

## 3. Complexity split (complexity C → A-, the long pole)

- Problem: `workflow.ps1` (~5,200 lines) plus two trailer formats, two gate
  params, and per-adapter sidecars -- accretion since every incident adds a
  mechanism and nothing is ever removed.
- Change (architectural, needs its own spec): split `workflow.ps1` into
  dispatch / recovery-gates / metadata-reporting / repomix modules; replace
  bespoke trailers+gates with one evidence registry (code → detector →
  channel → recovery).
- Policy commitment until it lands: every further finding deletes or
  consolidates; no new mechanisms.
- Risk: high by nature (touches healthy paths); mitigated by the Pester
  suite plus a live soak. This is the only item requiring full ceremony.

## 4. Differential follow-up bundles (token efficiency B → A-)

- Problem: convergence rounds 2-4 re-uploaded ~95% identical bytes
  (measured 42→68→76KB on one spec) -- the single biggest token line.
- Change: make convergence follow-ups differential by default using the
  existing `-Diff` machinery (delta bundle + prior-round reference),
  reserving full bundles for round 1 and explicit requests.
- Bounds: delivery-size checks still apply per seat; fallback pricing
  unchanged.
- Risk: low-moderate. Reuses measured machinery; mis-scoped deltas are the
  failure mode to test (a seat reviewing a delta must still see enough
  context -- carry the prior round's findings summary, already emitted).

## 5. Docs batch (docs B+ → A-)

Three new documents, no code: (1) one-page architecture overview
(dispatch → recovery → telemetry); (2) tunables reference -- every
`ERA_*` variable with interaction notes (the sidecar exists because two
tunables collided opaquely); (3) error-code catalog -- code → meaning →
recovery → where decoded. Risk: zero (docs only).

## 6. UX batch (UX B- → A-)

1. Rename or alias `ERA_AGY_FALLBACK` (it gates non-agy fallbacks too --
   actively misleading). Keep the old name working.
2. One round-health line on stdout (seats, codes, fallback decision,
   spend) instead of six assembled log lines.
3. Every "skipping" message names its unblock action (e.g. "no fallback
   reviewer available -- `GEMINI_API_KEY` would unlock `gemini-api`").
- Risk: low. Additive output + alias; no behavior change except clearer text.

## 7. Deferred items with owners

- O5 (retry gets remaining budget): extends dead-backend exposure; needs
  evidence or a cap before adopting. Owner: next outage.
- O6 (delete opencode Phase-1 raise): reshuffles a detector whose current
  labeling proved itself forensically; needs its own investigation.
- Convergence-loop budget (loop has no budget while everything else does):
  fold into item 4's spec.
- Live soak: five of six new recovery paths have fired only in tests (only
  the agy stream fallback has fired in production). A- requires a soak log.

## 8. Explicitly out of scope (rejected with reason)

Cost caps, void-round exit-2 semantics, and the one-fallback bound: no
measured defect; load-bearing by design. Windows-side credential stores,
upstream opencode SQLite parallelism, repomix/node exit hangs: external,
not fixable from this tree.
