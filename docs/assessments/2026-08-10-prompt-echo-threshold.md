# Prompt-echo detection — choosing the threshold by measurement

**Date:** 2026-08-10
**Origin:** the 2026-08-09 void round, case (c) — gemini-pro-high hit
`maxOutputTokens=8192` and what landed on disk was THE PROMPT, ECHOED BACK
**Verdict:** real, undetectable by every existing gate, and cleanly separable
from legitimate reviews. **Implemented** as `Test-EraPromptEcho` in
`backends/_capture-validation.ps1`, W=120 / K=40 / threshold 0.15,
**bidirectional**.

> **REVISED 2026-08-11 after the round-5 panel.** The first implementation was
> one-directional and the threshold below was derived from the wrong corpus. See
> "The regression this document caused" at the end. The tables above the
> revision are kept as written, because the error is the point.

## Why nothing already caught it

An echoed prompt slips past every gate the skill had, and each for a different
reason:

| Gate | Why it cannot see an echo |
|---|---|
| `Test-AgenticNarrationCapture` | every branch is gated on the response having **no markdown heading**; an era prompt is full of them |
| Response contract | the prompt necessarily **contains the tokens it requires**, so an echo satisfies it |
| `content_ok` artifact grounding (`7d4ac45`) | the artifact exists — it is just the wrong content |
| Void-round gate (`afbb0d2`) | exit code is 0 and a reviewer "succeeded", so the round is not void |

Measured directly: `Test-ResponseContract` on an echoed prompt returns
`Ok=$true, Missing=[]`.

```
contract tokens: ORDER: | DROP-ENTIRELY: | MISSING:
ECHOED PROMPT passes contract? -> True   missing=[]
NON-ANSWER passes contract?    -> False   missing=[ORDER:,DROP-ENTIRELY:,MISSING:]
```

## The metric

Normalise whitespace and case on both texts. Sample `K` evenly-spaced windows of
`W` characters from the **prompt**; count how many appear verbatim in the
response. `ratio = matched / sampled`.

## The measurement

Corpus: **69 legitimate prompt→response pairs across 28 topics** in the local
`.external-reviews/` tree. That directory is gitignored, so these numbers are
not reproducible from a clean clone — hence this record.

True positives are synthesised from the four `era-grade` prompts: a full echo, a
half echo, and a quarter echo (the model hitting its output cap partway through
echoing — the measured case (c) shape).

| window | legit max | legit p95 | legit pairs > 0 | TP full | TP half | TP quarter |
|---:|---:|---:|---:|---:|---:|---:|
| 20 | 0.150 | 0.100 | 50 / 69 | 1.000 | 0.500 | 0.250 |
| 40 | 0.050 | 0.050 | 21 / 69 | 1.000 | 0.500 | 0.250 |
| 60 | 0.025 | 0.025 | 10 / 69 | 1.000 | 0.500 | 0.250 |
| 80 | **0.000** | 0.000 | **0 / 69** | 1.000 | 0.475 | 0.225 |
| 120 | **0.000** | 0.000 | **0 / 69** | 1.000 | 0.475 | 0.225 |
| 160 | **0.000** | 0.000 | **0 / 69** | 1.000 | 0.475 | 0.225 |
| 240 | **0.000** | 0.000 | **0 / 69** | 1.000 | 0.450 | 0.200 |

**The decay from 50 nonzero pairs at W=20 to zero at W=80 is the important
column.** It shows the metric genuinely measures overlap rather than trivially
returning 0 — which is the obvious way a result like "max 0.000 across 69 pairs"
could be an artifact rather than a finding.

## Why the false-positive risk is lower than it looks

The intuition against this check is that round 2+ reviews quote the previous
round heavily. That case is *in* the corpus and is the reason the corpus was
used rather than a synthetic set: `{{PREVIOUS_ROUND}}` splices whole prior
responses into the prompt, so the era-grade round-2 prompt is **85 KB of mostly
prior review text**, and its reviewers discuss that text at length.

It still measures **0.000**. Reviewers paraphrase, summarise, and re-cite
`file:line`; they do not reproduce 120-character verbatim runs.

## Chosen parameters

`W = 120`, `K = 40`, `threshold = 0.15`.

- W=120 sits in the middle of the clean plateau, which begins at W=80 — 50%
  headroom on the window size itself.
- 0.15 is above **every** legitimate value observed at **any** window size
  (the global max is 0.150 at W=20, where we do not operate), and below the
  worst true positive (a quarter-echo, 0.225).
- Firing requires 6 of 40 sampled 120-char windows to appear verbatim — a
  legitimate review would have to reproduce six separate 120-character runs of
  its own prompt.

## Known limits, recorded deliberately

- **Hard cutoff below `W*2` (240 normalised chars).** A prompt that short is not
  judged at all: it cannot be distinguished from a legitimate brief answer that
  restates the question. Fails open by design.
- **Partial-echo sensitivity scales with prompt length and entropy.** A quarter
  echo of a 3 KB prompt fires; a quarter echo of a 600-char prompt does not. A
  *repetitive* prompt matches its own prefix everywhere and fires more readily.
  Only the hard cutoff is pinned by test — the fuzzy boundary is not a stable
  thing to assert, and pretending otherwise would make the suite brittle.
- **Echo below ~1/8 of the prompt is not caught by this check.** A response that
  short is generally caught by the narration detector's 300-char length floor
  instead.

## Where it runs

All six adapters, on the model's own text **before** any truncation banner is
prepended (the banners are 180–200 chars of this skill's own prose and would
otherwise dilute the ratio and inflate the length floor). A hit is
`ExitCode=-1`, `ContentOk=$false`, `Error='prompt-echo'`, the reason in
`Warnings`, and **no artifact written** — an echo is the prompt we already have,
so unlike a genuine bad capture there is no evidence in it worth keeping, and
leaving it off disk keeps it away from the `round-N-*-response.md` glob
entirely.


---

# The regression this document caused

**Found by:** the round-5 grading panel (opus), hours after the detector shipped.
**Status:** fixed — the ratio is now computed in both directions and both must
clear the threshold.

## What was wrong

The corpus above is 69 pairs drawn from `.external-reviews/`, and I treated it
as representative. It is not. The geometry of the metric is:

```
false positive requires a contiguous verbatim run of
    WindowChars + 5 * span / (Samples - 1)   characters
```

- Against the 3–85 KB hand-written prompts most of the corpus is built from,
  that is **~11,000 contiguous characters**. Hence the honest 0.000.
- Against era's **own default template** (~628 chars normalised, `era.ps1:886-915`),
  it is **~195 characters**. Two adjacent sentences of that template are 314.

**34 of the 50 historical prompts are under 2,000 characters; 28 are under
1,000.** The short regime is the dominant one in practice, and it is the one I
did not measure. This document even names the axis — *"partial-echo sensitivity
scales with prompt length and entropy"* — and then tests only the safe end of it.

Reproduced: a **7,655-character genuine review** with 70 file:line findings,
which restated 314 characters of its own instructions at the top, was flagged as
an echo. Cost of that false positive: `ExitCode=-1`, **no artifact written** (the
echo path deliberately writes nothing, so the good review is destroyed with no
copy on disk), a billed fallback dispatch, and on a solo run `exit 2` on a round
that had a usable review in hand.

Fixing silent-success produced silent-failure.

## The fix

An echo is prompt-shaped in **both** directions; a review that merely quotes its
instructions is prompt-shaped in one. Sample windows from the prompt into the
response *and* from the response into the prompt, and require both.

| case | forward | reverse | verdict |
|---|---|---|---|
| full echo | ~1.00 | ~1.00 | flagged |
| quarter echo | ~0.23 | ~1.00 | flagged |
| review quoting 314 chars of a 628-char prompt inside a 7,655-char answer | ~0.30 | ~0.05 | **passes** |

## Re-derived, this time in both regimes

| prompt regime | pairs | legit max (both directions) | full echo | half echo | quarter echo |
|---|---:|---:|---:|---:|---:|
| short (<2,000 ch) | 34 | **0.000** | 1.000 | 0.375 | n/a¹ |
| long (≥2,000 ch) | 39 | **0.000** | 1.000 | 0.500–0.950 | 0.250–0.450 |

¹ A quarter of a ~628-char prompt falls under the 240-char guard and is not
judged at all. That is correct: a response that short is a non-review and
belongs to the narration detector's 300-char length floor, not here.

0.15 remains the threshold — now above every legitimate value in **both**
regimes and below the worst measurable true positive.

## The lesson, stated plainly

The measurement was rigorous and the conclusion was wrong, because the sample
was drawn from the regime I happened to have data for rather than the regime the
code ships in. A threshold is only as good as the distribution it was fitted to,
and "69 real pairs" sounded like enough evidence to stop looking.
