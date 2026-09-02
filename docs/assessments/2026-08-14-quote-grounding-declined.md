# Verbatim-quote grounding — measured, declined

**Date:** 2026-08-14
**Origin:** round-7 (opus), *"A tractable gate for the fluent-but-wrong review"* — point `Get-EraPromptEchoRatio` at the **bundle** instead of the prompt, extract every span the reviewer *presented as a quotation*, and test whether it appears in the bundle it was given.
**Verdict:** the falsifiable prediction attached to the proposal is **refuted**. **No change made.** No `quote_total` / `quote_grounded` fields were added to `Write-ReviewMetadata`.

## Why it was worth measuring

It is the best-argued proposal any round has produced, and its logic is sound:

- A wrong-subject review can accidentally cite a real *path*. It cannot
  accidentally quote 40 contiguous characters of code it never saw.
- It is a **positive** signal of wrongness. Every other gate in this skill
  detects *absence* — no artifact, no headings, too short, too much echo. A
  confabulated finding quoting code that does not exist is evidence of the
  thing itself.
- It cannot false-positive on paraphrase, because only spans the reviewer chose
  to fence are scored.
- It reuses a normalise-and-window-containment engine this repo already built
  and calibrated.

Opus also attached the thing that makes a proposal testable rather than
merely persuasive — a prediction that can fail:

> My falsifiable prediction: healthy rounds land above 80% grounded and the
> rounds you already know went wrong fall far below. If the distribution is
> flat, drop the idea; the probe cost five minutes, which is the point.

## The measurement

Every archived round with both a response and its bundle — 38 scored
reviewer-rounds across 25 topics. Line-number prefixes stripped before
comparison (`showLineNumbers = $true` injects `NNN: `), whitespace collapsed,
lowercased.

```
n            : 38
min          : 0%
max          : 18.8%
mean         : 5%
median       : 3.6%

per reviewer:
  deepseek           n=4   mean= 6.1%   min=0%   max=10.3%
  deepseek-flash     n=6   mean= 5.2%   min=0%   max=15.4%
  gemini             n=10  mean= 7.6%   min=0%   max=18.8%
  gemini-pro-high    n=5   mean= 5.2%   min=0%   max=16.7%
  opus               n=11  mean= 3.0%   min=0%   max= 7.1%
```

Predicted: healthy ≥ 80%. Measured: **5% mean, 18.8% best case, nothing above
20%.** The distribution is flat, and it is flat at the wrong end.

## The distribution is flat because the denominator is wrong

A metric that reports "everything is fabricated" about a corpus that
demonstrably is not is measuring the wrong quantity. Round 7's opus response is
in this table at 4.3%, and its blocker 1 was independently reproduced by
measurement in the same session that ran this probe — the finding was real,
precise, and correctly located.

Splitting the quote population says why:

```
KIND       TOTAL    GROUNDED   PCT
fenced     62       2          3.2%     whole fenced blocks
line1      374      30         8.0%     individual >=40-char lines inside fences
inline40   997      48         4.8%     inline spans >=40 chars
inline20   1836     532        29.0%    inline spans >=20 chars
```

Two things fall out:

1. **Most fenced code in these reviews is code the reviewer AUTHORED**, not code
   it quoted — proposed fixes, and the executable checks this repo explicitly
   asks for. Opus named this as a limit ("a reviewer quoting its own *proposed
   fix* legitimately misses") but it is not a tail case here, it is the bulk of
   the population. The better a reviewer follows this repo's own instructions to
   supply runnable probes, the lower it scores. **opus scores lowest of all five
   reviewers precisely because it writes the most probe code.** A metric that
   penalises the behaviour the prompt requests is worse than no metric.

2. **The real citations are short.** Inline spans of 20–40 chars — `era.ps1:1027`,
   a function name, `$effectiveInclude = @()` — ground at 29%, six times the
   rate of the ≥40-char spans the proposal specified. But a 20-char window is
   well inside the range where containment happens by coincidence, so that 29%
   cannot be read as accuracy either. Lowering the floor buys rate by buying
   noise.

## Why not just fix the denominator

The obvious repair is to score only spans the reviewer *presented as
quotations*. Nothing in the response distinguishes them: a fenced
`powershell` block holding a real excerpt and one holding a proposed patch are
byte-identical in form. Separating them needs the reviewer to mark its own
quotes — i.e. a response-contract change, which lands it in the same place as
every other contract feature here: **opt-in, presence-based, and carried by no
built-in prompt**, so it would not fire on a default run.

## The `path:line` variant — also measured, also declined

**Added 2026-08-14, same day.** The section above left this open as "never
measured, cheaper to test"; the interim panel (deepseek-flash) then proposed it
independently with the same shape of prediction — *healthy rounds ground ≥ 80%
of citations, a wrong-subject review fabricates them.* So it was measured too:
extract `path.ext:NNN` citations, check the path exists in the bundle and the
line is within that file's length. 32 reviewer-rounds with ≥ 5 citations.

```
FILE-OK  mean 99.5%   min 83.3%   max 100%
LINE-OK  mean 85.1%   min 0%      max 100%
```

**The file half is saturated.** 99.5% mean, and not one round fell below the
80% the prediction nominated as the failure line. A metric that says everyone is
perfect cannot discriminate. Reviewers cite real filenames because the filenames
are in the prompt and the bundle manifest — getting one wrong takes effort.

**The line half is confounded three ways, and the outliers are artefacts.**
Three rounds scored exactly 0%, which is too clean to be 26 independent
mistakes. It is:

1. **Agentic reviewers read the real tree.** opencode/agy backends have
   filesystem access and cite the file on disk, not the subset in the bundle.
2. **`-Diff` bundles hold a subset.** `era-heavy-investigation` round 2 bundled
   10 files; `workflow.ps1` appears there at 510 lines. Any citation past that
   scores wrong while being perfectly correct about the repo.
3. **Reviewers do not share a citation convention.** Some cite per-file line
   numbers; some cite BUNDLE-relative ones — gemini's interim response cites
   `round-1-bundle.xml#L1983-L2052` explicitly. `backends/opencode.ps1:3021`
   is not a per-file line number in any tree; it is a position in the merged
   document. The same string means different things per reviewer.

So the signal is bundle/tree divergence and convention drift, not fabrication.
**No change made**; no `citation_total` / `citation_grounded` in metadata either.

## What survives

Both grounding variants are now measured and declined, for *different* reasons —
quote grounding because its denominator is dominated by code the reviewer
authored, citation grounding because its file half is saturated and its line
half is confounded. That pair is the useful result: it says the fluent-but-wrong
review is not detectable by checking the reviewer's own references against the
bundle, in either form.

- **Wrong-subject review remains ungated**, and is now the failure mode with no
  detector *and* no proposed detector that survives measurement. A future
  proposal should be tested against the three confounds above before it is
  built: agentic filesystem access, `-Diff` subsets, and citation convention.

  > **THAT INSTRUCTION WAS NOT FOLLOWED, AND CONFOUND 3 SHIPPED AS A FEATURE.**
  > Eighteen days later v2.4 built `Test-EraResponseCitations` — a line-grounding
  > check in exactly this family — and reported every citation past end-of-file
  > as one the reviewer *invented*. None of the three confounds above was tested
  > against it.
  >
  > Confound 3 is the one that bit, and this page had already named the example:
  > `backends/opencode.ps1:3021`, "not a per-file line number in any tree; it is
  > a position in the merged document." Measured 2026-09-01 across 20 arms,
  > **75 of 95 flagged citations (79%) were exactly that** — including
  > `backends/opencode.ps1:3156`, the same file, three weeks later.
  >
  > Fixed in v2.8.1: the two conventions are classified separately and the
  > merged-document ones are translated back.
  >
  > **MEASURED OVER THE WHOLE ARCHIVE (v2.8.2), 62 reviewer-rounds and 1,570
  > citations spanning months and five models** — not the 20 arms of one
  > afternoon that the fix was built on:
  >
  > | | citations | share |
  > |---|---:|---:|
  > | resolve in the file's own frame | 1,415 | 90.1% |
  > | resolve in the BUNDLE's frame — *reported as fabrication* | 128 | 8.2% |
  > | resolve in neither | **27** | **1.7%** |
  >
  > **83% of everything this checker has ever flagged was the wrong frame.** Per
  > model, four of the five that get flagged are flagged *entirely* by it:
  > `deepseek` 50 of 50, `deepseek-flash` 9 of 9, `gemini` 11 of 11, `muse-spark`
  > 47 of 57. Only `opus` never uses the bundle frame — and its 12 unresolvable
  > citations plus muse-spark's 10 are, between them, most of the genuine
  > fabrication in the project's entire history: **22 citations out of 1,570.**
  >
  > Two independent implementations (a standalone analysis and the shipped
  > `Test-EraResponseCitations`) agree to the citation on those numbers.
  >
  > **Confounds 1 and 2 are still not handled, and are now DECLINED on the same
  > evidence.** An agentic seat citing the file on disk, and a `-Diff` subset
  > bundle, can still produce an unresolvable verdict — but everything they could
  > explain lives inside that 1.7%. Machinery to chase it would cost more than
  > the error it removes. Reported advisory, and left alone.
- **Do not reuse `Get-EraPromptEchoRatio` against the bundle** for any variant of
  this without re-running the split above. The engine works; the population it
  would be pointed at is the problem.

## Reproducing

Both probes are **committed**, because this document tells you to re-measure and
that instruction is worthless if the scripts are gone:

```
pwsh tools/probes/quote-grounding.ps1 -Split     # the 5% result and the fenced/inline diagnosis
pwsh tools/probes/citation-grounding.ps1         # the path:line variant
```

They read `.external-reviews/` (gitignored, local-only), so the numbers move as
rounds accumulate — re-running on 2026-08-14 after round 8 gave 4.9% mean over
45 reviewer-rounds and the same fenced/inline shape, against 5.0% over 38 when
first measured. The conclusion is not close to its threshold, so growth does not
threaten it; if it ever does, that is a finding, not a nuisance.

**This section previously read "were throwaway probes."** Round-8 (opus) finding
5 caught that: `2026-08-10-prompt-echo-threshold.md:13-17` records the identical
failure — *"nobody could re-run the calibration because the script was thrown
away and the corpus was not in the repo"* — which is how the first echo
threshold went wrong. Writing "re-measure before revisiting" while deleting the
means to do so repeats it on the same day the repo re-learned it.

As with `2026-08-14-enumerate-once-declined.md`: re-measure before revisiting,
do not re-argue it from the text alone.
