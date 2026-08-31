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
| 600,000 | 2,021,400 | **canary returned — full prompt seen** (68 s) |
| 630,000 | 2,122,470 | `Prompt is too long` (7 s) |
| 660,000 | 2,223,540 | `Prompt is too long` (6 s) |
| 700,000 | 2,358,300 | `Prompt is too long` (6 s) |
| 711,253 | 2,396,233 | `Prompt is too long` — the real failing round |

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
clear comfortably — so it is neither size nor model. The leading untested
hypothesis is **concurrency**: three interactive `opencode -c` sessions were live
during the failing dispatches and none were during the probes, and era's run mutex
serialises its own seats but cannot see an operator's session.

This is recorded in `backends/opencode.ps1` and pinned by a test, so the source
carries the failures and not only the passes. With the flush fixed, the next stall
will leave a real artifact.

## Consequences

- Limits are per-backend and live in `backends/_registry.json` as
  `max_bundle_bytes` / `max_bundle_tokens`, so a re-measurement is data.
- An unmeasured channel (`geminiapi`, `openaicompat`) reports "unknown" and is
  **never refused** — inventing a ceiling refuses rounds that would have worked.
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
