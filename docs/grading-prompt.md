<!-- era-require: GRADE:, RELIABILITY:, ROBUSTNESS:, SPEED:, EFFICIENCY:, REGRESSIONS:, BLOCKERS: -->

# Grade the /era skill

You are grading this skill. Prior rounds returned **B+, B+, B+, B+, A−** — the
grade sat at B+ for four rounds because each round's named blockers were fixed
and each round surfaced new ones. Treat that history as a prior: the useful
output is the finding, not the letter.

{{CHANGES_SINCE}}

## Rules that make your output worth paying for

1. **Cite `file:line` for every claim.** A finding I cannot locate, I cannot act on.
2. **For each finding, state the smallest executable check that would confirm or
   refute it** — a command, a test assertion, a two-line probe. This matters more
   than the finding itself. Measured on this repo: the failure mode that costs
   most is not a *wrong* finding (those get caught) but a *right* finding
   dismissed after someone read the code and concluded it was fine. A finding
   that ships with a way to run it cannot be waved away.
3. **Say plainly when you cannot verify something from the bundle.** A confident
   wrong finding costs more than a missing one.
4. **Rank your findings, and say which you would DROP ENTIRELY.** I would rather
   delete than add.
5. Do not re-derive the known-open list below; challenge the triage if you disagree.

## Weigh most heavily

1. **Silent success.** Can a round still report success with no usable review?
   Can a rejected answer reach round N+1? This is the class the skill has been
   hardened against for six rounds; a new route into it is the top finding.
2. **Silent failure — the mirror image.** Every detector added is a chance to
   reject a GOOD review. One already did: the prompt-echo detector rejected a
   7,655-char genuine review because it restated its instructions. A detector
   that discards real work is worse than the hole it closes.
3. **Cost.** Caps are advisory under `-Force` (deliberate, see
   `Get-EraCostReport`). Anything that spends without saying so is a finding.
4. **Duplication.** Two definitions of one rule is how they drift apart. Name
   any you find; several have already bitten.

## Known-open, deliberately

- The response contract is **opt-in**; no built-in prompt carries a marker.
- The contract is **presence-based** — `ORDER:` with nothing after it passes.
- Cost caps are **advisory** under `-Force`; era reports and warns, never blocks.
- `opus-api` / `sonnet-api` / `haiku-api` are **live-unverified** (no key on this box).
- Every gate detects **absence** (no artifact, no content, an echo, a dead
  process). A fluent, well-structured, confidently *wrong* review is invisible
  to all of them. If you can propose a tractable gate for that, it is the single
  most valuable thing in your response.

## Output format

```
GRADE: <letter, one sentence>
RELIABILITY: <does it produce a usable review, and admit it when it does not>
ROBUSTNESS: <failure handling, concurrency, edge cases>
SPEED: <wall clock, and anything that wastes it>
EFFICIENCY: <token/cost behaviour, and duplication in the code>
REGRESSIONS: <anything the changes above broke — cite file:line>
BLOCKERS: <numbered; empty if none. A blocker makes a round produce a wrong or
           unusable result — not a nit. For each, give the executable check.>
```

## Previous round

{{PREVIOUS_ROUND}}
