# Bundle delivery limits — measuring what each seat can actually receive

**Date:** 2026-08-31
**Origin:** three consecutive 4-seat panels delivered 2 seats. Two independent
causes, one shape: the bundle was larger than the reviewer's delivery channel
could carry, and nothing checked before dispatch.
**Verdict:** real, and entirely preventable at preflight. **Implemented** as
`Get-EraBundleDeliveryPlan` in `workflow.ps1`, armed in `runtimes/era.ps1`
before the cost prompt.

> **This document also records a wrong turn.** Midway through, the opencode
> Read-tool path was retired on evidence that turned out to be a broken
> measuring instrument, and un-retired the same day. The error is the point:
> see *The instrument was broken* below.

## The failures

| date | seat | bundle | outcome |
|---|---|---|---|
| 2026-08-30 | `opus` (claude, stdin) | 2,396,233 B / 711,253 tok | `Prompt is too long`, exit 1 |
| 2026-08-30 | `deepseek-flash` (opencode) | 2,396,233 B | failed |
| 2026-08-30 | `muse-spark` (opencode) | 2,396,233 B | **succeeded** — 7,628 B grounded review |
| 2026-08-25 | `deepseek-flash` | 79,294 B | 600 s timeout, nothing |
| 2026-08-31 | `deepseek-flash` | 74,740 B | 600 s timeout, nothing |
| 2026-08-31 | `deepseek-flash` | 13,433 B | succeeded — 7,957 B review |

era's only pre-dispatch scale gate measured **pre-bundle source** bytes against a
10 MB ceiling — roughly 200x looser than the tightest channel it dispatches to —
and armed only when no `-IncludeFiles` was passed. All three failing rounds were
curated rounds, so it never ran. `era.ps1` computed `$bundleBytes` and never read
it: the one thing era knew about the artifact it was about to upload, it discarded.

## The instrument was broken

The Read-tool path was believed to "never start": every artifact under
`%TEMP%\opencode-stall-debug` is 0 bytes while the error line beside it reports a
non-zero `total bytes`. That contradiction was read as evidence.

It was a bug in the snapshot. `FileStream.Length` counts bytes still sitting in
the write buffer; the snapshot copied the file **without flushing**. Reproduced:

```
218 bytes copied in ->  sink.Length     = 218
                        on-disk length  = 0      <- what the snapshot saw
                        after Flush()   = 218
```

The same 218 as the 2026-08-31 timeout log. Every artifact recorded before the fix
is empty, or cut at a 4,096-byte boundary (one buffer flush), for this reason —
not because the backend was silent.

**On that reading the path was retired.** That was wrong. It removed the only way
to review anything over 50 KiB on an opencode seat, to avoid a failure the stall
detector and timeout already bound. A broken measuring instrument is worse than no
instrument: it does not merely fail to inform, it actively misleads, and it was
used to justify removing a working capability.

## Measuring properly: canaries

A review coming back does **not** prove coverage. A model can read the head, skip
to the instructions at the tail, and write something plausible. So each probe
planted marker lines at widely separated depths and asked for them back verbatim
*before* the review.

### opencode, Read-tool path

| bundle | lines | canaries found | wall | result |
|---|---|---|---|---|
| 109,066 B | 2,066 | 1/1, both seats | 57 s | real reviews, `file:line` cited |
| 314,720 B | 5,226 | 2/2, both seats | 85 s | real reviews |
| 668,389 B | 10,773 | 3/3, both seats | 256 s | real reviews |

668 KB is **13x the attach cap**, coverage confirmed at 25/50/75% depth, on both
default opencode seats — including `deepseek-flash`, whose failures had motivated
the retirement. Ceiling set at 1,048,576 B: between the 668,389 verified here and
the 2,396,233 `muse-spark` has carried once.

### claude CLI, stdin path

Same method, tail canary. A bare "OK" would only prove the request was accepted,
and `--autocompact` defaults to on, so a silently-compacted prompt is exactly the
failure the gate exists to prevent.

| repomix tokens | bytes | result |
|---|---|---|
| 600,000 | 2,021,400 | **canary returned — prompt reached the model** (68 s) |
| 630,000 | 2,122,470 | `Prompt is too long` (7 s) |
| 660,000 | 2,223,540 | `Prompt is too long` (6 s) |
| 700,000 | 2,358,300 | `Prompt is too long` (6 s) |
| 711,253 | 2,396,233 | `Prompt is too long` — the real failing round |

> **What the canaries prove.** A returned marker proves **retrievability** — the
> channel carried the bytes and the model could locate them — **not** that it read
> the content in between; on the read-tool path a model can find a marker by
> searching. What supports "it reviewed the whole bundle" is the *conjunction*:
> markers at three depths, plus grounded `file:line` citations spread across a
> 10,773-line bundle, plus wall clock scaling with size (57 s → 85 s → 256 s). A
> sound coverage probe would ask a question answerable only by synthesising text
> *between* the markers. That is not what was run. Flagged unanimously by the
> 2026-09-01 design panel.

> **And one soft spot in this bisection.** The canary sat at the **tail** — the
> position most likely to survive any compaction that summarises the middle, i.e.
> exactly the failure it was chosen to detect. The 600k/630k bracket does not rest
> on it (the reject side is a hard `Prompt is too long`, 6 s and unbilled), but the
> *accept* endpoint is n=1 with the weakest available probe position. Head+mid+tail
> markers would retire the caveat.

The CLI carries **≥600,000 and <630,000** repomix tokens. This is *not* the
model's 1M API window — `claude --print` gets appreciably less. The prior ceiling
was a derived 150,000 ("a 200k window less ~25%"), which was **~4x too tight** and
was refusing rounds that work; both halves of that derivation were wrong.

Bisecting was affordable because **rejection happens before inference** — 6 s and
unbilled, against 68 s for the one accepted probe. Ceiling set at 550,000, ~8%
under the accept point for the CLI's own system prompt and tool definitions, which
repomix's count cannot see.

## What is still not known

The Read-tool path is **intermittent, and the cause is unexplained.**
`deepseek-flash` lost rounds at 74,740 B and 79,294 B — sizes the probes above
clear comfortably — so it is neither size nor model.

### The forensic instrument is now VERIFIED, not just claimed (2026-09-01)

This document has said since the flush fix that "the next occurrence will leave a
real artifact". That was an inference from a live .NET repro of the buffering bug,
not an end-to-end test — and every artifact in `opencode-stall-debug` predating
the fix is 0 bytes or exactly 4,096, so the instrument's entire track record was
of producing nothing. Believing an untested claim about an instrument is the
mistake that retired this path once already.

So it was tested. A real `opencode` read-tool dispatch on the 146,712-byte bundle
with `TimeoutSec=40`, forcing the stall branch:

    opencode stalled: no output growth for 9s (... total wall=20.6s, total bytes=42)
    Partial stderr (tail): > build … deepseek-v4-flash
    Full partial saved under …\opencode-stall-debug\stall-20260901-185415-348-pid58008-*.txt

    stall-…-stderr.txt   42 bytes   <- non-empty
    stall-…-stdout.txt    0 bytes   <- genuinely no stdout

**42 bytes on disk against `total bytes=42` in the error line.** That equality is
the whole point: the contradiction that used to be the signature of the broken
instrument (a non-zero byte count beside an empty artifact) is gone, and the tail
in the throw message matches the file. The next real occurrence will leave usable
evidence.

The same probe exercised two other paths in passing — the stall threshold clamped
from 733.56s to 9s to fit the budget, and the first-token deadline **lowered**
120s → 29s to fit the remaining budget — so the ordering
`stall < adapter timeout < dispatcher patience` held on a live run, not only in
unit tests.

### It did not recur across ~24 dispatches on 2026-09-01

Not a designed experiment, but worth recording as a denominator: the day's work
put roughly two dozen read-tool dispatches through this path — 12 A/B repeats at
113,279 and 146,712 B, a 4-seat panel at 371,628 and 614,256 B, four
second-subject seats at ~185,000 B, and this probe — with **zero unexplained
stalls**. One seat ran 451s, and the new budget instrumentation showed why: 400s
of it was the run-lock queue, not a stall. That is the first time a slow
read-tool seat has been explained rather than filed under this heading.

### The concurrency hypothesis was tested, and it failed

Two independent reviewers proposed the same experiment, so it was run: one fixed
65,196-byte bundle, one fixed prompt, the adapter called directly (no repomix, no
round machinery), 10 trials per arm.

| arm | condition | stalls | mean wall | max wall |
|---|---|---|---|---|
| A | no other opencode process | **0 / 10** | 14.5 s | 28.3 s |
| B | `opencode serve` holding the DB + 22 external `opencode run` contenders | **0 / 10** | 13.0 s | 22.5 s |

`database is locked` never appeared in either arm, and arm B was marginally
*faster*. The mid-bundle canary came back in every trial that produced text. So
the run mutex's known blind spot — an operator's own session — is **not** what
killed those rounds.

**What this does not settle.** The trials finish in ~13 s while the historical
failures burned the full 600 s, so this does not reproduce the failing regime.
Ten trials with zero events bounds the per-arm stall rate at roughly 26% (rule of
three), so a rarer mechanism would not have appeared. The cause remains unknown —
with concurrency now the *least*-supported explanation rather than the leading
one.

**Incidental:** half the trials in each arm were rejected as
`agentic-narration-capture`. Inspecting the raw text, the rejected responses
contain no narration at all — they are correct, canary-verified answers of 280
characters, against accepted ones of 301 and 324. The detector's length floor is
doing the rejecting and the error code is naming the wrong cause. The floor is
working as designed on a deliberately-tiny answer; the *label* misattributes it.

This is recorded in `backends/opencode.ps1` and pinned by a test, so the source
carries the failures and not only the passes. With the flush fixed, the next stall
will leave a real artifact.

## Consequences

- Limits are per-backend and live in `backends/_registry.json` as
  `max_bundle_bytes` / `max_bundle_tokens`, so a re-measurement is data.
  **This claim was false when first published.** `era.ps1` projects the registry
  into `$registryHash` field by field and did not copy those two keys, so the
  override branch could never fire on a real dispatch. The unit test passed
  `-ModelInfo` straight to the pure function and therefore proved the function
  worked while saying nothing about the wiring. Found by all four seats of the
  2026-08-31 review panel; fixed in v2.3.1 with an end-to-end test that runs the
  real `era.ps1` against a real edited registry, and a negative control
  confirming that test fails against the pre-fix code.
  The lesson is the same one this document already records one section earlier:
  **a measurement taken through the layer you are not testing proves nothing.**
- An unmeasured channel (`geminiapi`, `openaicompat`, and since v2.3.1
  `anthropic`) reports "unknown" and is **never refused** — inventing a ceiling
  refuses rounds that would have worked. v2.3 violated its own policy here:
  `anthropic` carried an enforceable 750,000 derived as "a 1M window less ~25%",
  the identical derivation this document calls ~4x wrong for the claude CLI.
- Refusal is `exit 1`: nothing dispatched, nothing spent, free to re-run. Distinct
  from a void round's `exit 2`, which already cost money.
- The round summary names each seat's delivery mode and failure category, and
  `round-N-metadata.json` records `delivery_mode` and `bundle_bytes`.

## Re-measuring after a CLI or provider upgrade

Both ceilings are version-dependent and each endpoint of the claude bracket is
n=1. All slices came from a single XML corpus, so it is untested whether the
accept point shifts with bundle content. If a round near a ceiling fails
unexpectedly, that is the first assumption to re-test. Repeat the canary
bisection and update the registry.
