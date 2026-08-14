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

## What survives

The *diagnosis* is worth keeping even though the gate is not:

- **Wrong-subject review remains ungated.** It is still the failure mode with no
  detector, and round 6's `path:line` variant is not refuted by this — it was
  never measured. It is cheaper to test than this was and remains open.
- **Do not reuse `Get-EraPromptEchoRatio` against the bundle** for any variant of
  this without re-running the split above. The engine works; the population it
  would be pointed at is the problem.

## Reproducing

`quote-grounding.ps1` and `quote-grounding2.ps1` (the split) were throwaway
probes; both are ~40 lines and are reproduced in the round-7 response and in
this document's tables. Re-measure before revisiting — as with
`2026-08-14-enumerate-once-declined.md`, do not re-argue it from the text alone.
