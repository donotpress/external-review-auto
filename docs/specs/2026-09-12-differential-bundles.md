# Spec: differential convergence bundles, v2 (HIGH risk — behind split+soak)

Date: 2026-09-12, v2 rewritten post-panel. v1's warrant ("make THAT the
default, not build it") was measured false on three load-bearing claims
(manifest carries no per-file content; prior-round void-ness is not
computed at bundle time; the citation checker does not exist and its probe
declined). This version states the new construction honestly.

## Problem (unchanged)

Convergence rounds re-upload ~95% identical bytes on one topic (single
sample: 42→68→76KB). The loop has no budget while everything else does.

## What exists vs. what must be built

EXISTS (`runtimes/era.ps1:1321+`, opt-in `-Diff`): delta file computation
(`Get-ReviewDiff`), prior-panel text aggregation (in-flight-aware, skips
rejected, honors `ERA_PREVIOUS_ROUND_MAX_CHARS`, suppresses panel-on-panel
duplication), deletions-only early return, `-FullBundle`-shaped full path.

MUST BE BUILT (the v1 gap): (a) prior-round void computation at bundle
time (all `Get-EraVoidRoundReport` call sites take the current round +
this run's results; reconstruct from prior manifest + artifacts);
(b) a terminal-verdict rule (below); (c) prompt assembly for the
carried context; (d) the default-flip itself with opt-out.

## Dissent 1 (citation grounding): prompt carries paths, no checker

Accepted opus: no verification gate is built. The committed probe shows
FILE-OK saturated at 99.5% (nothing to gain) and LINE-OK confounded three
ways, two untouched by any union. Disposition: the diff prompt lists the
prior round's file paths so reviewers orient; no grounding gate, no
manifest-span extension, no cumulative frame (that machinery served the
cut checker). Stale-override and shared-convention issues die with it.

## Dissent 2 (false converge): the verdict round is always full

Convergent demand (all three reviewers): intermediate follow-ups may stay
differential, but a round that closes criticals or issues a terminal
"converged / looks good" verdict runs on a FULL bundle. Structurally
assertable without trusting the model (round shape in manifest), unlike
quote-to-close instructions and shrink heuristics, which remain as
advisory only. Cross-file breakage outside the delta is covered by
construction: the verdict round sees everything.

## Always-carried context (normative, for differential intermediates)

1. Prior round's critical findings ride in-prompt; omission is a failure
   (test asserts full critical blocks survive, not headings alone --
   headings pass with bodies truncated).
2. Empty delta is not a round (existing early return, now also under flip).
3. Void prior or missing prior manifest → full bundle + log line (new
   recovery paths; both land in the soak ledger).
4. Cap-truncation guard: carried criticals must survive
   `ERA_PREVIOUS_ROUND_MAX_CHARS` truncation or the round goes full.

## Default-flip scope (narrowed)

Flip applies ONLY when: round ≥2 AND prior round delivered ≥1 usable
review (computed, per above) AND delta non-empty AND verdict round is
not requested. `-FullBundle` (new) forces full either way. No change to
round 1, void/deleted paths, or explicit `-Diff` (which becomes the
default's implementation -- one code path, pinned by test).

## Tests required (all Pester, no live models)

1. Prompt-carry: full critical blocks (not headings) present; void-prior
   forces full (with the prior report built from artifacts, not assumed).
2. Close-out: a critical-closing round is full-shaped, never diff-shaped.
3. Deletions-under-flip: default flip on deletions-only hits the early
   return (today a deletions-only round-3 yields a full bundle; post-flip
   it must yield no round, loudly -- behavior change under test).
4. Missing-manifest: diff requested without prior manifest → full + log.
5. Cap-truncation: criticals surviving the char cap, else full.
6. No-drift: `-Diff` explicit and default-flip byte-identical for same
   inputs. 7. Rollback: `-FullBundle` reproduces today's
   round-N-without-`-Diff` bytes (round-1 shape is the WRONG baseline:
   headerText and `{{PREVIOUS_ROUND}}` differ by round).

## Rollout

Behind the module split (touches repomix + prompt + metadata) and the
soak. Re-grade token efficiency on measured round-2+ byte deltas across
≥3 topics -- the single-sample figure above motivates, never justifies.
