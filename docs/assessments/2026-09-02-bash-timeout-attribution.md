# The driving tool's timeout did not kill that round

**Date:** 2026-09-02
**Status:** attribution retracted; the hazard it was reaching for is real and re-documented
**Origin:** commit `1119d3b`, written from a symptom without checking the round's artifacts.

## What was claimed

`1119d3b` added ten lines to `SKILL.md`, `references/troubleshooting.md` and
`runtimes/opencode.md` asserting that the `bash` tool's default
`timeout: 120000ms` `SIGTERM`s the `pwsh` dispatch mid-panel, leaving
`round-N-*.pid` and no `.md`, and that this was *"the exact failure that lost
`deepseek-flash` on `bulk-refresh-vpn-headless` round 1 (`451s` still in grace at
`120s` kill)"*. Prescribed fix: pass `timeout: 1800000`.

## Why it is wrong

**The round's own artifacts refute it.** From
`ebay-quantity-monitor/.external-reviews/bulk-refresh-vpn-headless/`:

| artifact | mtime | offset from `started` |
|---|---|---|
| `round-1-claim.json` (`started` 08:48:40Z) | 03:48:40 | — |
| `round-1-muse-spark-response.md` | 03:53:32 | **+292 s** |
| `round-1-gemini-response.md` | 03:56:27 | **+467 s** |
| `round-1-metadata.json` | *absent* | — |

era.ps1 writes those `.md` files. A 120 s kill lands at 03:50:40; two reviews were
written 172 s and 347 s after it. **era was alive at +467 s.** Round 3 of the same
topic then completed with `wall_clock_sec: 228.5`, also past 120 s.

The parenthetical is additionally incoherent on its face: a run cannot be at 451 s
when the kill is at 120 s.

**The prescribed fix does not bind.** Measured: `timeout: 1800000` was accepted and
the foreground wait ended at **600 s**. There is no foreground setting on Claude
Code that covers an 1800 s panel.

**The mechanism does not reproduce for the case described.** A `pwsh` child, standing
in for the dispatch:

| requested timeout | child | outcome |
|---|---|---|
| default `120000` | 200 s | moved to background, **ran to completion**, `RC=0` |
| `1800000` (capped 600 s) | 640 s | moved to background, **ran to completion**, `RC=0` |

Neither was `SIGTERM`ed. (A bash `find` under the same 120 s default *was* killed,
exit 143, so killing happens for some command shapes — but not for the spawned-`pwsh`
case the entry is about, which is the only case that matters here.)

## What is real, and is now documented instead

A long panel outlives any foreground wait a driving tool will give it. The failure
that follows is not a kill — it is the **driver concluding the round died** and
re-dispatching, which pays for the seats twice. That is consistent with what the
directory shows: round 2 was started at 03:59, two and a half minutes after
gemini's review had already landed in round 1, and produced nothing either.

So the guidance is now: **dispatch in the background and poll**, a timeout message
is not evidence of death, `round-N-metadata.json` is the signature of a finished
round, and an orphaned claim file consumes a round number without blocking anything
(never delete claims by glob — that would take out a concurrent round's).

## What is NOT known

**What actually aborted rounds 1 and 2 has not been established.** It was not a
120 s timeout. Beyond that the artifacts do not say, and no cause is offered here.
This project has already published one confident causal story written from an
absence — see `2026-09-01-review-archive-false-alarm.md` — and had to retract it in
a release. The correct output of this investigation is a bounded negative result.

## Caveat on the measurements

They were taken on Claude Code on 2026-09-02. A different driver (opencode's own
`bash` tool) or a different harness version may kill rather than detach, and may
allow a larger foreground timeout. The `runtimes/opencode.md` placement of the
original note was therefore reasonable; the `SKILL.md` line, which addresses any
driving LLM, was not. Nothing here has been verified against opencode's tool.
