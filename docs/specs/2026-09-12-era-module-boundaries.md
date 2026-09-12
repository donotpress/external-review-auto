# Spec: era module boundaries (spec-only, no code)

Date: 2026-09-12. Purpose: freeze module boundaries BEFORE the MS6 rewrite
and circuit breaker land, so new mechanisms arrive already homed and the
later implementation split is a move, not a redesign. Demanded by the
2026-09-12 plan-review panel (unanimous ordering objection).

## Modules (4)

1. **dispatch** — ThreadJob lifecycle only: spawn, heartbeat poll loop,
   straggler grace + deadline-sidecar deferral, child tree-kill, result
   collection. Owns: `Invoke-ReviewerDispatch` (the wait loop),
   `Stop-EraAdapterChild`, `Get-EraStragglerDeferral`,
   `Test-EraStragglerExpired`, pid/sidecar file conventions.
   Rule: dispatch NEVER interprets failure semantics beyond routing;
   it calls classifiers, it does not contain them.
2. **recovery** — pure classifiers + gates: `Get-EraRecoverableFailures`,
   `Get-EraAnsweredBadlyCodes`, `Get-EraFailureCategory`,
   `Test-EraFallbackNeeded`, `Test-EraStreamFallbackNeeded`,
   `Convert-EraAdapterResultError`, `Resolve-EraAgyFallback`,
   `Get-EraFallbackBundleOverrides`. Rule: no process handles, no file
   writes, no wall-clock reads -- inputs are result hashtables, outputs
   are decisions. Everything here is unit-testable without spawning.
3. **adapters** (`backends/`) — one file per backend CLI: spawn, poll,
   capture, retry-inside, fail-fast, trailers. Rule: an adapter may read
   its own flag files and write its own pid/sidecar/forensic files; it
   may NOT read another backend's state or the dispatcher's. Error codes
   it emits must be registered in recovery's lists (compiler-checked by
   test, not by comment).
4. **bundle** — repomix wrapper + delivery planning + manifest/metadata
   writers: `Invoke-EraRepomix`, `Test-EraRepomixCompleted`,
   `Get-EraBundleDeliveryPlan`, `Write-ReviewMetadata`,
   `Write-ReviewManifest`, `Copy-PrimaryResponseAlias`. Rule: metadata is
   written from result hashtables; writers never re-derive failure causes.

## Interface rules (frozen)

- R1. Results cross dispatch→metadata as plain hashtables with at least
  Preset/ExitCode/Error/Warnings/Response/WallClockSec. New keys are
  additive; readers tolerate absence.
- R2. Failure codes are strings owned by recovery (`Get-EraAnsweredBadlyCodes`
  + the recoverable list). An adapter introducing a code adds it to a new
  `ErrorCodeRegistry.Tests.ps1` asserting every known code has exactly one
  classifier home (answered-badly vs dead-transport vs excluded-with-reason).
  (DetectorCoverage.Tests.ps1 guards the capture detector, a different
  concern -- do not extend it for this.)
- R3. No function in recovery calls `Start-ThreadJob`, `Get-Process`,
  `Stop-Job`, or reads `$env:TEMP` state. No function in dispatch matches
  on `Error` strings except to route to a recovery classifier.
- R4. Cross-module references flow one way: dispatch→recovery,
  dispatch→bundle, adapters→(nothing shared). workflow.ps1's current
  free-for-all ends at the split; until then, new code cites its module
  in the function docstring.

## Placement of in-flight work (binding)

- MS6 rewrite (abandon-path Receive-Job + decode): dispatch (collection
  site) calling recovery (`Convert-EraAdapterResultError`). No TEMP join.
- Circuit breaker (skip-only): dispatch (seat selection) reading a
  machine-scoped state file; streak taxonomy owned by recovery
  (fatal set = dead-transport codes + stall/timeout/empty-capture;
  narration/contract excluded -- seat flaky, backend alive).
- Quota preflight (landed): adapters (reader) + recovery (gate).
  Conforms as-is.
- Deadline sidecar (landed): adapters (publish) + dispatch (honor).
  Conforms as-is.

## Explicitly not decided here

Split mechanics (one commit vs. stacked, file names), differential
bundles (post-split item), convergence-loop driver rules. Those keep
their own specs.
