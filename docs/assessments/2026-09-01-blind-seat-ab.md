# Does comment-blinding change what a reviewer finds?

**Date:** 2026-09-01
**Origin:** `-BlindSeat` (v2.6) was built on an argument, not a measurement. This
is the measurement.
**Verdict:** H1 **directionally supported** in both within-model pairs, on thin
margins and n=1 per cell. Not a settled effect. One genuine cost of blinding was
also observed, and the run found a real bug in the feature.

> Pre-registered before either round was dispatched, because the author built the
> feature and wanted a positive result. The scoring rule below is the one written
> in advance, unmodified.

## Design

Subject: `unified-puppeteer-server`, 6 core files (~147 KB bundle), never audited
by the author. Same files, same prompt, both rounds. No `-PremiseCheck`: the
variable under test is blinding alone against a normal review prompt.

    Round 3:  -Reviewer opus,deepseek-flash  -BlindSeat opus
    Round 4:  -Reviewer opus,deepseek-flash  -BlindSeat deepseek-flash

Each round has one blind and one sighted seat, and across rounds each model
appears in both conditions — two WITHIN-MODEL pairs, controlling for the fact that
models differ from each other regardless of sight.

## Definitions (fixed in advance)

A **premise finding** questions whether something the code assumes is TRUE: an
unjustified constant, an unstated environmental assumption, an invariant nothing
enforces, or "how do you know X?". A **defect finding** asserts the code does the
wrong thing given its assumptions. Both ⇒ counts as premise.

## Result

| pair | condition | premise | defect | total |
|---|---|---:|---:|---:|
| opus | **blind** | **1** | 9 | 10 |
| opus | sighted | 0 | 9 | 9 |
| deepseek-flash | **blind** | **3** | 7 | 10 |
| deepseek-flash | sighted | 1 | 6 | 7 |

Both pairs move the same way. Per the pre-registered falsification rule that is
support, not a split — but 1-vs-0 is one finding, and n=1 per cell can show a
direction and never an effect size.

Premise findings unique to a blind arm: a configured health-check timeout nothing
reads; a classifier whose retry guidance is never consulted; `warmup()` and
`_trackMetrics` as no-op stubs reporting success; `checkCache` hard-coding
`healthy: true`.

## The cost of blinding, observed

deepseek **sighted** found *"overflow error is retried despite the comment
forbidding it"* — a defect discoverable **only** because the comment stated the
intended behaviour and the code violated it. Strip the comment and the finding
disappears: there is nothing left to contradict.

That is the argument against blinding every seat, and it is why the feature
blinds exactly one.

## Incidental

- The citation checker (v2.4) flagged **5 fabricated citations** from
  deepseek-sighted (`scraping-service.js:2704` in a 664-line file) and **0** from
  the other three arms. First confirmation of that feature against live output.
- deepseek-blind produced 0 out-of-range citations against sighted's 5. n=1;
  noted, not claimed.

## The run found a bug in the feature

The first attempt measured against a **broken instrument**. `Remove-EraBundleComments`
treated any line starting with a block-comment opener as a comment, so

    /** @type {*} */ (this.browserManager.browserInstance).isConnected()

— an inline JSDoc annotation whose entire purpose is to precede code — had its
code deleted, leaving `x &&` dangling above a `) {`. Three lines in one file. The
blinded reviewer opened its review by saying the expression was unreadable.

Fixed (a block that opens and closes on one line with code after the closer is not
a comment line), tested, and both rounds re-run on a clean bundle before scoring.
Scoring the first attempt would have been the exact failure this project has spent
two days fixing: trusting a measurement taken through a broken instrument.

## What would settle it

Repeats. Two pairs at n=1 with a 1-finding margin is a direction, not a result.
Ten rounds per cell on varied subjects, scored blind by someone without a stake,
would give an effect size. Until then `-BlindSeat` is a reasonable bet with weak
supporting evidence, and the docs should not say more than that.
