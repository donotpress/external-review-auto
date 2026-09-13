# Soak acceptance criteria: what "done" means for unproven recovery paths

Date: 2026-09-12. Status: proposed. A recovery path is DONE when it has
fired live once with a round artifact to point at -- green mocks are
necessary, not sufficient. The ledger lives here; append rows, never rewrite.

## Ledger

| Path | Status | Round ref | Evidence |
|---|---|---|---|
| agy-stream-interrupted → REST fallback | FIRED 2026-09-11 | skill `era-skill-review` round 1 | gemini died double-stall; `gemini-api` delivered 1,438 chars in 32.5s (~$0.11) |
| sidecar deferral (grace honors adapter deadline) | MECHANISM FIRED, save unproven | skill `era-plan-review` round 1 | log: "deferring abandonment (grace now fires at 742s)"; seat died anyway -- deferral proven, kill-avoidance not |
| opencode-no-output → fallback | UNPROVEN | -- | needs a zero-stdout opencode death with usable round-mates |
| void-prior → full fallback | UNPROVEN | -- | new path from the differential spec; fires on first void-prior follow-up |
| missing-manifest → full fallback | UNPROVEN | -- | new path from the differential spec; fires on first manifest-less follow-up |
| agy-quota-exhausted fast-fail | DUE | -- | flag live till ~2026-09-15; fires on next gemini dispatch (~0s instead of ~600s stall) |
| repomix adopt-or-retry | UNPROVEN | -- | needs a repomix timeout with completion banner |
| repomix tail-marker rejection | UNPROVEN | -- | needs a timeout with truncated flush |
| breaker skip | UNPROVEN | -- | needs a 3-streak on any backend (all backends watched automatically via round results; agy currently preempted by the quota flag) |
| Tier-1 baseline + no-start warning | UNPROVEN | -- | needs an agy no-start since O1 landed |

## Done definition (all must hold)

1. Every UNPROVEN row above has a round ref, OR a dated note WITH AN OWNER
   explaining why the condition never arose during the soak window.
   Absence-with-reason counts; silence does not; adequacy disputes go to
   the named owner.
2. Latency proof: at least one breaker skip or deferral with budget saved
   measured as dispatch-elapsed delta against that backend's last
   unprotected stall recorded in round metadata (labeled reconstruction
   -- the unprotected path is counterfactual by definition, so name the
   baseline round explicitly).
3. No recovery path fired spuriously: every live fire links to a genuine
   failure in that round's metadata (no fallback on a healthy seat, no
   skip of a servable backend).
4. Soak window: minimum 10 dispatched rounds AND 14 days, whichever is
   LATER. A 2-day burst does not close a soak meant to catch rare stalls.

## Status vocabulary (exhaustive)

- UNPROVEN: never fired live. DUE (with expiry date) and BLOCKED (needs
  unwatched instrumentation -- opencode/claude streaks until the breaker
  watches them) are sub-states, not escapes: on expiry or instrumentation
  they become UNPROVEN proper and fall under criterion 1.
- MECHANISM FIRED: code ran but the save is unproven (e.g. deferral fired,
  seat died anyway) -- tracked under criterion 1 like UNPROVEN.
- FIRED: delivered the save with a round ref. The single terminal state.

## Paths (ledger)

Row "opencode `deadline` sidecar published" is CUT: files-present is
deployment fact, unit-testable, not a recovery path to soak.
Added rows: void-prior → full fallback, missing-manifest → full fallback
(new recovery paths from the differential spec -- they fire during soak
and need somewhere to land). Claude-seat death uses the standard
machinery (WSL retry, then the same fallback every other seat gets);
no separate row needed -- say so here instead of opening one.

## Out of scope for the ledger

Healthy-round behavior (covered by suites), spend totals (metadata holds
them), model-quality judgments about fallback reviews (thin is fine;
absent is the failure).
