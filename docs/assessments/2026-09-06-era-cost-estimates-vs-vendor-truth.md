# era's cost estimates understate the real bill ~3.2x

**Date:** 2026-09-06
**Tool:** `tools/token-truth.py` (added with this document)
**Sample:** 12 CLI seat-dispatches across 4 rounds of the `tmux-transport` review
**Status:** measured. The opencode half rests on the vendor's own recorded cost;
the claude half is computed and is weaker evidence (§4).

---

## 1. Why this was measured at all

It was a by-product. The tmux-transport design (`docs/specs/2026-09-06-…`)
proposes an A/B against era's process-spawn backends, and the first question was
which numbers such a comparison could use. era's own metadata cannot do it:
input cost is derived from era's **own** repomix token count
(`workflow.ps1:2957,3007`) and output from `ceil(chars/4)` in each adapter. That
is the *same estimator on both arms*, so an A/B built on era's metadata would
compare the estimator with itself — the vacuity class this repo keeps catching in
its own probes.

So the reader was pointed at the vendors' records instead. Validating it against
known rounds is what produced the finding below.

## 2. The measurement

| round | seat | era `est_cost_total_usd` | vendor | ratio |
|---|---|---|---|---|
| 1 | deepseek-flash | 0.0018 | 0.0131 | 7.3x |
| 1 | opus | 0.1237 | 0.3819 | 3.1x |
| 1 | muse-spark | 0.0013 | 0.0039 | 3.0x |
| 2 | opus | 0.1498 | 0.4703 | 3.1x |
| 2 | deepseek-flash | 0.0027 | 0.0304 | 11.2x |
| 2 | muse-spark | 0.0017 | 0.0053 | 3.1x |
| 3 | opus | 0.1342 | 0.3862 | 2.9x |
| 3 | muse-spark | 0.0018 | 0.0045 | 2.5x |
| 3 | deepseek-flash | 0.0022 | 0.0120 | 5.5x |
| 4 | deepseek-flash | 0.0025 | 0.0277 | 11.1x |
| 4 | muse-spark | 0.0019 | 0.0085 | 4.5x |
| 4 | opus | 0.1415 | 0.4670 | 3.3x |
| | **total** | **$0.5651** | **$1.8107** | **3.2x** |

## 3. Why

**Two causes, and neither is a bug in the estimator's arithmetic.**

1. **Reasoning tokens are invisible to era.** Across these 12 seats the vendors
   recorded **126,912** reasoning/thinking tokens. era counts **zero** of them,
   because it estimates output from the *characters of the final response* and
   reasoning never appears there. deepseek-flash spent 31,628 reasoning tokens in
   round 2 against a 2,931-token visible answer — an 11.8:1 ratio the estimate
   cannot see.
2. **Agentic turns are invisible too.** An opencode seat reads the bundle, runs
   `rg`, and re-reads — every one of those assistant turns bills output tokens
   that never reach the response file. deepseek-flash in round 1 recorded 9,691
   output tokens for a 6,146-character review.

This also explains the per-seat spread: `muse-spark` (2.5-4.5x) is closest
because it reasons less and tool-calls less; `deepseek-flash` (5.5-11.2x) is
worst on both counts.

## 4. What this evidence is and is not

- **The opencode rows are strong.** `cost` is opencode's **own** recorded figure
  from `opencode.db`, not something derived here.
- **The claude rows are weaker.** claude's transcripts record token counts but no
  cost, so those figures are computed from `backends/_registry.json` pricing.
  They inherit any error in that table.
- **`gemini`/`agy` is absent entirely.** No vendor record store is known for it,
  so a third of the default panel is unmeasured here. The 3.2x total is over the
  seats that could be measured, not over the whole panel.
- **n=12, one repo, one day.** The direction is not in doubt; the multiplier is
  a sample, not a constant.

## 5. What it affects

**Corrected 2026-09-06, same day, after reading the code rather than assuming
it.** An earlier draft of this section said the per-reviewer and aggregate caps
"gate on a number that ran ~3x low", implying a live ceiling admitting ~3x more
than intended. **That is wrong, and the repo had already settled it.**
`Get-EraCostReport`'s own docstring records the 2026-08-11 decision:
`Invoke-CostPrompt` returns the full reviewer list immediately when
`Get-ForceMode` is true, with **no cap check at all** — and SKILL.md instructs
every caller to pass `-Force`. The `$2`/`$10` per-reviewer caps and the `$15`
aggregate therefore **never fire in documented usage**. They are advisory, and
deliberately so: measured across 43 recorded rounds, the worst round was $1.76
against the $15 cap and the worst single reviewer $1.71 against its $10 cap, so a
ceiling "would have bought nothing while a wrong one could refuse a legitimate
large round."

**Does the 3.2x correction overturn that decision? No — and it is worth doing the
arithmetic rather than assuming.** Those 43 rounds were recorded in
estimate-units, so the real figures are ~3x higher: worst round ≈ $5.6 against
$15, worst reviewer ≈ $5.5 against $10. Still no breach, on either cap, even
corrected. The conclusion survives its own correction.

**What the gap actually costs is visibility, not enforcement** — which is exactly
what the 2026-08-11 decision named as "the real gap". A reader of era's cost line
was being told a number ~3x below the bill. That is now stated at the point the
number is printed (`workflow.ps1:1499`).

**The numbers in that docstring should be read as estimate-units.** Anyone
re-deriving a safety margin from "worst round $1.76" will be about 3x optimistic;
the docstring now says so.

**No change is proposed here.** This records the gap; whether to correct the
estimator (add a reasoning multiplier per model), to reconcile after the fact
from the vendor records, or to leave it and re-label the number an
"output-text estimate" is a separate decision with its own trade-offs.

## 6. The instrument, and three artifacts it produced first

`tools/token-truth.py` attributes a seat to a vendor session by (working
directory, model, time window) and **refuses rather than guesses**: zero matches
report `unmatched`, more than one `ambiguous`. Every number above comes from a
row that matched exactly once.

Three defects were caught during validation, each of which had produced a clean,
plausible-looking number:

1. **Two opencode databases.** era spawns the **Windows** opencode
   (`C:/Users/Joshua/.local/share/opencode/`); the WSL binary uses
   `/home/joshua/.local/share/opencode/`. The first version read only the WSL one
   and reported **zero sessions** for every round — while correctly finding
   sessions from an earlier day, which is the only reason the zero was not
   believed. A tmux-transported seat would run the WSL opencode, so an A/B reader
   that knows one database would silently report nothing for one arm.
2. **Aliased project directories.** `~/.claude/projects` holds both
   `-mnt-c-Users-Joshua-…` and `-mnt-c-users-joshua-…`, two symlinks resolving to
   the same Windows directory. Globbing over names counted every claude
   transcript twice and reported `AMBIGUOUS (2 transcripts)` for a seat that ran
   once. Fixed by deduping on `realpath`.
3. **Duplicate turn records.** A seat transcript writes the same assistant turn
   twice — identical usage, once with empty content and once with the text — so
   summing records **doubled every claude figure**. This one is the most
   instructive: it produced "opus understated 10x", which is a believable number,
   and was caught only by printing per-turn detail and noticing two rows with
   byte-identical usage. The corrected figure is ~5x on output tokens and ~3.1x
   on cost.

The pattern in all three is the one this repo has recorded before: **a fact about
the instrument, reported as a fact about the subject.** Only the per-item detail
caught them; none of the totals looked wrong.
