# Seat precision ledger

**What this is for.** era has elaborate machinery for checking whether a *citation*
is real — coordinate frames, bundle spans, out-of-range detection — and nothing at
all for whether a *finding* is. Triage already happens on every round; SKILL.md
makes it mandatory. It just evaporates afterwards, so nobody can answer "which seat
should I weight?" after 1,300 responses.

This file is the cheapest thing that fixes that: **one row per triaged finding.**
No schema, no script, no code to rot. It only pays off if it is actually appended
to, which is why the SKILL.md pitfall table now points here.

**How to use it.** After triaging a round, add its rows. A finding is:

- `TRUE` — the defect is real and was confirmed by running something, not by reading.
- `FALSE` — checked and the claim does not hold.
- `DECLINED` — real, but deliberately not acted on, with the reason recorded.
- `UNVERIFIED` — plausible, not checked. Do not count these in precision either way.

**Precision** = TRUE / (TRUE + FALSE), over findings that were actually checked.

**The number that matters is severity-weighted.** A seat whose top-severity finding
is wrong is more expensive than one with a wrong minor note, because the top of the
list is what gets acted on first.

---

## 2026-09-02 · `era-f12-and-two-gaps` · 4-seat panel on the F12 fix

Every finding below was checked by running code, not by reading it.

| seat | # | severity | finding | verdict | how it was settled |
|---|---|---|---|---|---|
| gemini | 1 | HIGH | `$firstTokenSec` never reassigned to `$lowered` | **FALSE** | the assignment is on the line immediately after the log statement the finding quotes |
| gemini | 2 | MEDIUM | bytes→token ratio differs between adapters (3.369 vs /4) | **DECLINED** | real, but the ratio is bundle-specific (3.369 on one bundle, 3.640 on the round that raised it) and the measured effect on that round was zero — both clamp |
| gemini | 3 | MEDIUM | dedupe collapses two coordinate frames | **DECLINED** | measured: 4 collisions in 108 responses, all four the link-text/anchor pair carrying the same number, which is the case where merging is correct |
| gemini | 4 | LOW | source-regex tests pass against broken wiring | **TRUE** | mutation: replaced `Add($prompt)` with a literal — the test passed until fixed |
| gemini | 5 | LOW | `Get-EraBackendDelivery` duplicates the 51200 attach cap | **DECLINED** | real duplication, but an existing boundary test already pins the two sides together |
| muse-spark | 1 | CRITICAL | prompt-file ≠ dispatched prompt, so echo detection misses | **FALSE** | `Test-EraPromptEcho` targets the review instructions, which is exactly what `PromptPath` holds |
| muse-spark | 2 | HIGH | margin not pinned; `floor > pollSec` passes at +1 and +50 | **TRUE** | mutation: margin → +50, caught |
| muse-spark | 3 | HIGH | `L?` false-positive rate unbounded | **DECLINED** | measured: zero new non-frame flags across 108 responses; residual risk recorded |
| muse-spark | 4 | MEDIUM | sweep does not assert lock wait is maximal | **TRUE** | mutation: `lockWait = 0`, caught |
| muse-spark | 7 | LOW | stale "11 of 11" is one preset stated as the backend | **TRUE** | re-derived: `gemini-pro-high` is 11 of 16 |
| opus | 1 | HIGH | the unified floor misses the deadline that binds; at `remaining = 15` Phase 1 kills at the first wake | **TRUE** | swept `Resolve-OpencodeRunBudget` × `Resolve-OpencodeStallPlan`: exactly one budget exposed, and it is the floor itself |
| opus | 2 | HIGH | reachability conjunct asserted nowhere | **TRUE** | the test asserted only `lowered < eff`, never that a wake can reach it |
| opus | 3 | MEDIUM | troubleshooting still tells operators to write "attached bundle" | **TRUE** | nothing is attached for 3 of 4 default seats |
| opus | 5 | MEDIUM | "~61%" is one preset stated for two | **TRUE** | both agy seats together are 27→50, ~46% |
| opus | 7 | LOW | one rule, two adapters, one fixed — inside the commit whose subject is that shape | **TRUE** | mutation: gutted the live prompt, left the comments — the old grep passed |

**Round totals (checked findings only):**

| seat | TRUE | FALSE | precision | top-severity finding |
|---|---|---|---|---|
| opus | 5 | 0 | **5/5** | TRUE |
| muse-spark | 3 | 1 | 3/4 | **FALSE** (CRITICAL) |
| gemini | 1 | 1 | 1/2 | **FALSE** (HIGH) |
| deepseek-flash | — | — | — | did not return (abandoned at 787 s) |

**What one round can and cannot say.** n=1. This cannot rank the seats. What it
does establish, because it is a count and not an impression: **two of the three
top-severity findings in this round were false**, both stated with full confidence,
and both would have been actioned by a driver that trusted severity ordering. That
is the failure mode this ledger exists to make visible. It also shows the panel
earning its cost — opus found a real defect in a fix that had been mutation-tested
an hour earlier, which no single-reviewer setup would have caught.

**Caveat on this round specifically:** the seat with 5/5 was reviewing a diff
written by the same model family that then triaged it. Treat cross-family verdicts
as the more informative ones as data accumulates.

---

## 2026-09-04 · `direction-paths-2026-09-04` rounds 2–3 · availability, not precision

These two rounds produced **no findings about era** — they were era pointed at
another repo — so there are no verdict rows. What they produced is the other half
of what this file is for, and the first round's totals table already has a column
for it: **whether the seat came back at all.**

| round | seat | outcome |
|---|---|---|
| 2 | `deepseek-flash` (opencode, read-tool) | **did not return** — three `Read <bundle>` lines, no review, exit −1 at 570.5 s on a 124,188-byte bundle |
| 2 | remaining seats | returned |
| 3 | all seats | returned |

Round 2's loss is the fifth occurrence of the read-tool zero-output failure and
the one that finally produced evidence, because `98b7e8a` had just wired the
`exitfail` snapshot to the fourth throw path the bug actually takes. Diagnosed the
same night — see the round below.

Measured while writing that fix, and it belongs here because it bounds every
availability number in this file: across 629 rounds with metadata there are **50
opencode read-tool seat-runs and 5 failures — 10%**, and they are not confined to
`deepseek-flash`. `muse-spark` failed in the same round, both at ~70 s. Wall
clocks across the five: 67.4, 72.8, 395.9, 570.5, 786.9 s.

---

## 2026-09-04 · `opencode-readtool-zero-output` · 2-seat panel on the diagnosis

Two seats, `gemini` (3.1 Pro) and `muse-spark` (identified in that round's
assessment as Gemini 3.8 Flash). Both were asked whether the
`max → xhigh` change on muse-spark had increased its exposure to the zero-output
failure, and both were shown the same evidence.

| seat | # | severity | finding | verdict | how it was settled |
|---|---|---|---|---|---|
| gemini | 1 | HIGH | *"**False. Budget exhaustion is physically impossible**"* — no hedge | **FALSE** | sound arithmetic (277 tok/s) against the wrong ceiling of 131,072. At the real 32,000 it is 70 tok/s, entirely ordinary. Settled from `opencode.db`. |
| gemini | 2 | MEDIUM | the `xhigh` change increased muse-spark's exposure | **FALSE** | token accounting: muse-spark reports reasoning separately (~11k) with output ~3k, so it cannot exhaust an output ceiling the way deepseek can (deepseek folds reasoning into `output`). 3/3 clean at `xhigh`. |
| gemini | 3 | HIGH | Phase 1 is dead code — the banner on stderr makes `$hasSeenOutput` true at the first poll | **TRUE** | measured on a real capture: 176 stderr bytes against 2 on stdout |
| muse-spark | 1 | MEDIUM | the ceiling is probably a lower proxy limit, 16k–64k — tagged `[UNVERIFIED — needs inspection of opencode.db]`, with the query named | **TRUE** | 32,000, inside the range it gave. The seat named the exact query that settled it. |
| muse-spark | 2 | MEDIUM | the `xhigh` change increased muse-spark's exposure | **FALSE** | same token accounting as gemini 2. Both seats wrong, for the same reason: they reasoned about effort level without the accounting, which was in a database neither had. |
| muse-spark | 3 | HIGH | Phase 1 is dead code | **TRUE** | found independently of gemini 3, same evidence |
| muse-spark | 4 | MEDIUM | the non-viable-budget `throw` jumps past the mutex release | **TRUE** | the `throw` sits above the `try/finally`; released before the throw now |
| muse-spark | 5 | LOW | the `exitfail` snapshot has no retention pruning — 3 files per failure, forever | **TRUE** | about code added earlier the same night; prunes at 40 like the stall path |
| both | — | HIGH | **the fix they proposed for Phase 1** — count stdout only | **DECLINED** | the finding was right and the prescription was wrong: stdout-only would have killed the validation run at 621 s with the wrong diagnosis. Baselining the first poll's byte count instead let the stall detector report it accurately. |

**Round totals (checked findings only):**

| seat | TRUE | FALSE | precision | top-severity finding |
|---|---|---|---|---|
| muse-spark | 4 | 1 | 4/5 | TRUE |
| gemini | 1 | 2 | 1/3 | **FALSE** (HIGH) |

**Two conclusions of this round's own were also wrong, and are corrected in
`docs/assessments/2026-09-04-stall-threshold-measured.md`:** that era's stall
detector killed the validation run *"while the model was still generating"* (the
turn holds two empty reasoning parts 352 s apart and 0 output tokens, and turns
killed mid-generation demonstrably keep their partial reasoning — the kill was
correct), and that the successful runs *"reasoned 188.1 s, 342.5 s and 458.6 s"*
(the 458.6 s run is the `finish=length`, zero-text failure this document is about).
Neither came from a seat. Both are mine, and both are the same error the round
already caught itself making twice: a confident conclusion from a partial read.

---

## Across rounds: the temperament gap

The most useful thing in this file is not any one seat's precision. It is that the
same shape keeps recurring:

**`gemini` states a mechanism with full confidence and no hedge, and the mechanism
does not hold. `muse-spark` marks what it has not checked, and names the
measurement that would settle it.**

Two reproductions are sourced inside this repository:

| round | gemini | muse-spark |
|---|---|---|
| 2026-09-02 `era-f12-and-two-gaps` | top finding HIGH, **FALSE**, stated flatly — the assignment it says is missing is on the very next line | top finding CRITICAL, **FALSE** too; but its `L?` finding was written as a bounded risk rather than a claim, and measuring it (zero new non-frame flags across 108 responses) is what let it be declined with a number instead of an argument |
| 2026-09-04 `opencode-readtool-zero-output` | *"physically impossible"*, unhedged, **wrong** | *"probably a lower proxy limit (16k–64k)"*, tagged `[UNVERIFIED]` with the query named, **right** |

`docs/assessments/2026-09-04-opencode-zero-output-diagnosed.md` calls this "the
same temperament gap as the previous three rounds". **That claim is recorded here,
not re-derived** — those three rounds predate this ledger and their findings were
never written down per seat, which is the gap this file exists to close going
forward. Do not cite it as five reproductions; two are auditable.

**Why it matters and what it costs.** On the 2026-09-04 round the unhedged
rejection would have closed the investigation — the ceiling story is the whole
diagnosis, and gemini said it was physically impossible. n is small and this cannot
rank the seats on precision alone. What it can say, because it is a count, is that
**both of gemini's top-severity findings across the two auditable rounds were
false**, and in both rounds the hedged item was the one that survived checking.
Weight the confidence, not just the finding.

**Two standing caveats.** Several of these rounds reviewed diffs written by the
same model family that then triaged them; cross-family verdicts remain the more
informative ones. And in the 2026-09-04 round both seats are Gemini-family —
`2026-09-04-opencode-zero-output-diagnosed.md` identifies `muse-spark` as Gemini
3.8 Flash and `gemini` as 3.1 Pro — so that round contrasts tiers and temperaments,
not vendors.
