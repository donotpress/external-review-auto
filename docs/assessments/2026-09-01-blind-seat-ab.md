# Does comment-blinding change what a reviewer finds?

**Date:** 2026-09-01
**Origin:** `-BlindSeat` (v2.6) was built on an argument, not a measurement. This
is the measurement.
**Verdict (2026-09-01, first round):** H1 **directionally supported** in both
within-model pairs, on thin margins and n=1 per cell. Not a settled effect. One
genuine cost of blinding was also observed, and the run found a real bug in the
feature.

> **SUPERSEDED THE SAME DAY — read the replication at the bottom of this file
> before quoting anything above it.** Sixteen more cells, a second subject, and a
> blinded re-score of these four leave the effect at **zero** on the only model
> measured at n=4 in both arms; the second subject reverses BOTH pairs; and the
> two scorers of these same four files disagree by more than the effect being
> claimed. The tables in this first section are kept
> unedited because the replication is *about* them; they are no longer the
> project's position.

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

---

# Replication, 2026-09-01 (later the same day)

**Verdict: the effect does not replicate, and the second subject reverses it.**
On the one model measured at n=4 in both arms the blind and sighted premise counts
are **identical** (4.50 vs 4.50), with a within-cell spread (0 to 7) larger than
the entire effect the original table argued for. A second model moves +1.33 at
n=3, within its own standard deviation. And on a **second subject**, both models
move the OTHER way (−1 and −5). Five within-model pairs now exist: two positive,
two negative, one exactly zero. The `opus` pair that carried half the original
claim was not repeated and stays at n=1.

**And the scoring instrument moved the numbers more than the condition did.**
Re-scoring the four original arms blind changed three of their four premise
counts — 1→5, 3→6, 1→4 — so the margins the original table reported (1 vs 0, and
3 vs 1) were smaller than the disagreement between two scorers of the same four
files. `-BlindSeat` is still a reasonable bet on its argument; the measurement
does not support it, and this document should not say that it does.

## What was added, and why this way

The section above ends "What would settle it: repeats … on varied subjects, scored
blind by someone without a stake." Three of those four were addressed:

- **Repeats.** 12 new cells: `deepseek-flash` and `muse-spark`, blind and sighted,
  n=3 each. Against 4 original cells at n=1.
- **A second model pair.** `muse-spark` had never been in this experiment.
- **Blind scoring.** Every arm — the four original ones included — was re-scored by
  a third model (`opencode-go/minimax-m2.7`), one response at a time, against the
  pre-registered definitions **quoted verbatim** and with no arm label present in
  what the scorer saw. The original numbers above were produced by the person who
  built the feature.

- **A second subject.** Six different files from the same server (the database
  layer, the debug-probe and analytics services, the metrics routes, the scrape
  controller, the Mercari scraper — 54,785 tokens, disjoint from the first set),
  run through `era` end-to-end as two rounds with the blind seat swapped.

Only partly addressed: **varied subjects**. The second subject is different code
in the same repository, written by the same hands in the same style. It is a
weaker control for generalisation than a different project would be, and it is
reported as such — though it was enough to reverse both pairs, which is the point
of testing more than one.

Incidentally, the second subject is also the first end-to-end use of the
`blind_seat` / `blinded` / `delivery_bundle_sha256` metadata added alongside this
replication: its arms were read from the round records rather than from a console
log, and the recorded hash of `round-1-bundle-blind.xml` matches the file on disk,
so the control ("both arms read the same code") is now checkable rather than
asserted.

**Control:** the 12 repeats were dispatched against the **exact bundle files round 3
wrote** (`round-3-bundle.xml`, 146,712 B and `round-3-bundle-blind.xml`, 113,279 B)
and its prompt, by calling `Invoke-OpencodeReview` directly rather than re-running
`era`. Re-running `era` would have rebuilt the bundle from the current tree and
reserved a new round, so the repeats would no longer have been reviewing the same
bytes as the cells they are compared against. Nothing about the subject, the
prompt or the stripping differs between the original cells and the repeats.

`opus` was not repeated: at $5/Mtok input on a 39,264-token bundle it is ~$0.24 per
cell, against ~$0.006 for `deepseek-flash` and ~$0.004 for `muse-spark`. Its two
original cells stand at n=1 and are reported as such. **The 1-vs-0 margin that
carried half of the original claim therefore has no replication at all.**

## Citation grounding across all 16 arms (exploratory, not pre-registered)

The "Incidental" section above reported 5 fabricated citations from one arm and 0
from three others, at n=1, and correctly declined to claim anything from it. With
16 arms there is enough to say something — but **this was not pre-registered**, the
scoring rule for it was written after seeing the first four numbers, and it is
reported here as exploratory. `Test-EraResponseCitations` was run over every arm
against the line counts of the bundle that arm actually read.

`out-of-range` = the file IS in the bundle and the cited line is past its end, so
the citation cannot be real.

| model | arm | citations checked | out of range | rate |
|---|---|---:|---:|---:|
| opus | blind (n=1) | 17 | 0 | 0% |
| opus | sighted (n=1) | 16 | 0 | 0% |
| deepseek-flash | blind (n=4) | 79 | 0 | **0%** |
| deepseek-flash | sighted (n=4) | 69 | 9 | **13.0%** |
| muse-spark | blind (n=3) | 63 | 26 | 41.3% |
| muse-spark | sighted (n=3) | 55 | 21 | 38.2% |

Two things fall out, and only one of them is about blinding.

1. **Fabrication rate is mostly a property of the model.** `muse-spark` — a seat in
   the shipped default panel — invents roughly **four in ten** of its `file:line`
   citations, in both conditions. One arm (`muse-spark-sighted-r3`) had **15 of 15**
   citations out of range. `deepseek-flash` is an order of magnitude better and
   `opus` produced none at all here. That is a bigger effect than anything else in
   this document and it has nothing to do with `-BlindSeat`.
2. **The one arm-linked signal is `deepseek-flash`'s**, and it is in the direction
   the incidental note guessed: 0 of 79 blind against 9 of 69 sighted. It does
   **not** generalise — `muse-spark` shows no such split. So it is a
   model-and-condition interaction at n=4, not a property of blinding.

None of this changes what a reviewer's prose is worth: the assessment's own
finding, unchanged, is that the reported reviewer was "often CORRECT and twice
novel" while its citations were not. It does mean the citation checker (v2.4) is
doing considerably more work on the default panel than the single confirmation
above suggested.

## How the arms were scored this time

Every arm — the four original cells included — was passed one at a time to
`opencode-go/minimax-m2.7`, a model that appears in none of them, with:

- the two definitions above **quoted verbatim** into the prompt, including the
  "both ⇒ counts as premise" tie-break;
- the review text and nothing else. The scorer was not told the model, the
  condition, or that an experiment existed;
- a fixed output shape (`<n> | PREMISE|DEFECT | <subject>`, then
  `TOTAL= PREMISE= DEFECT=`), so the count is parsed, not interpreted.

This is a weaker instrument than the "someone without a stake" the section above
asked for, and it is a stronger one than what produced the original table. Two
things it does not fix: the definitions themselves are the ones the feature's
author wrote, and a single scorer has no inter-rater agreement to report. Both
were true of the original scoring too, which is the point of re-scoring the
original arms with the same instrument — if the original numbers move, the mover
is the scorer, not the data.

**The original four cells were re-scored, and their numbers are reported below
next to what the author originally recorded.** Where they differ, the re-scored
number is the one used, and the difference is itself reported.

## Result

Premise findings per arm, scored blind by `minimax-m2.7` against the definitions
at the top of this document. Original cells are marked `*` and are shown with the
author's own count in brackets.

| model | condition | n | premise findings | mean | defect (mean) | total (mean) |
|---|---|---:|---|---:|---:|---:|
| `opus` | blind | 1 | 5* [author: 1] | 5.00 | 5.00 | 10.00 |
| `opus` | sighted | 1 | 0* [author: 0] | 0.00 | 9.00 | 9.00 |
| `deepseek-flash` | **blind** | **4** | 6* [author: 3], 7, 0, 5 | **4.50** | 8.00 | 12.50 |
| `deepseek-flash` | **sighted** | **4** | 4* [author: 1], 7, 5, 2 | **4.50** | 5.50 | 10.00 |
| `muse-spark` | blind | 3 | 4, 6, 7 | 5.67 | 9.00 | 14.67 |
| `muse-spark` | sighted | 3 | 2, 7, 4 | 4.33 | 6.00 | 10.33 |

Within-model blind − sighted premise deltas: `deepseek-flash` **+0.00**
(sd 2.69 / 1.80), `muse-spark` **+1.33** (sd 1.25 / 2.05), `opus` **+5.00** (n=1,
no sd).

### The second subject reverses both pairs

Same instrument, same models, six different files (54,785 tokens: the database
layer, the debug-probe and analytics services, the metrics routes, the scrape
controller, the Mercari scraper), run through `era` as two rounds with the blind
seat swapped. Arms read from each round's own `blind_seat` / `blinded` metadata,
not from prose.

| model | condition | premise | defect | total |
|---|---|---:|---:|---:|
| `deepseek-flash` | blind | **8** | 5 | 13 |
| `deepseek-flash` | sighted | **9** | 13 | 22 |
| `muse-spark` | blind | **2** | 16 | 18 |
| `muse-spark` | sighted | **7** | 8 | 15 |

Deltas: `deepseek-flash` **−1**, `muse-spark` **−5**. **Both pairs move the
opposite way from subject 1**, and `muse-spark`'s reversal (−5) is larger than any
positive result anywhere in this document.

Across all five within-model pairs now measured — two positive, two negative, one
exactly zero — there is no consistent direction to report.

### What this changes

1. **The falsification rule from the original round is not met, decisively.**
   That round's support was "both within-model pairs move the same way". There are
   now five pairs: **+5.00** (opus, n=1), **+1.33** (muse-spark subject 1, n=3),
   **+0.00** (deepseek-flash subject 1, n=4), **−1** (deepseek-flash subject 2),
   **−5** (muse-spark subject 2). Two up, two down, one flat. The honest reading is
   **no measured effect**, not a small one — and the second subject reversing both
   pairs is what a direction that was noise looks like.

2. **The variance was invisible at n=1 and is the whole story at n=4.**
   `deepseek-flash` blind produced 6, 7, **0** and 5 premise findings on *the same
   bytes with the same prompt*. Any single pair drawn from those cells can show
   a large effect in either direction. The original 3-vs-1 is one such draw.

3. **Two scorers of the same four files disagree by more than the reported
   effect.** The author scored `opus`-blind at 1 premise finding; the blinded
   third-party scorer found 5 in the same text. Both applied the definitions in
   this document. Where a measurement's instrument moves it further than its
   treatment does, the treatment has not been measured yet.

4. **Blinding did increase raw output**, which nobody predicted and which is not
   pre-registered: blind arms produced more findings in total (12.50 vs 10.00 and
   14.67 vs 10.33) and more *defect* findings, not only more premise ones. That
   is consistent with a stripped bundle simply being smaller and easier to read
   end-to-end, and it is a confound the original design does not control for.

### What did not change

The **cost** of blinding recorded above stands: a sighted seat found a defect
discoverable only because a comment stated the intent the code violated. Nothing
here bears on it, and it remains the reason to blind exactly one seat.

### Still not settled, and what it would take

Varied subjects (every cell here reads the same six files), a scorer with no
stake in either direction, and enough repeats per cell to see past a standard
deviation of ~2 findings. At the observed spread, distinguishing a 1-finding
effect needs on the order of 30+ cells per condition, which at `opus` prices is
the expensive part. Nothing in this document justifies more than the claim
`-BlindSeat` shipped with: a reasonable bet, on an argument, with weak evidence.
