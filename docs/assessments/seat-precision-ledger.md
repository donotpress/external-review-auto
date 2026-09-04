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
