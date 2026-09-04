# The read-tool zero-output failure: a 32,000-token output ceiling

**Date:** 2026-09-04
**Status:** diagnosed from primary evidence; cause fixed; instrument fixed
**History:** five occurrences since 2026-08-31, none diagnosable until now.

## The failure

An `opencode run` on the read-tool path intermittently returns **exit 0 with empty
stdout**. Not a crash, not a stall, not a timeout — era's detectors were correctly
silent because there was nothing to detect. The process reported success.

It cost five reviewer seats across four rounds and resisted diagnosis because the
one throw path it takes wrote no forensic artifact (fixed separately, `98b7e8a`).

## The mechanism, from `opencode.db`

`deepseek-v4-flash` under `--variant max` reasons until it hits a **32,000-token
output ceiling**, then returns a message whose parts are
`{step-start, reasoning, step-finish}` — **no text part at all**. opencode has a
well-formed response containing no text, prints nothing, and exits 0.

The correlation, from the local database:

| output tokens | text chars | outcome |
|---|---|---|
| 31,942 | 11,635 | success — **58 tokens from failing** |
| **32,000** | **0** | failure, 2026-09-04, `cwd=…\era-repro` |
| **32,000** | **0** | failure, 2026-08-31, `cwd=C:\Users\<user>` (a different repo) |
| 39,742 | 12,206 | success |
| up to 66,602 | — | success |

Across 315 assistant turns with output > 1,000 tokens, **exactly two** land on
32,000, both `deepseek-v4-flash` + `max`, and **both have zero text**. Values are
otherwise arbitrary (31,942 / 32,958 / 32,992 / 35,032 …). A model choosing to
stop does not land on a round number twice.

**Why deepseek and not muse-spark.** deepseek folds reasoning INTO `output` — its
`reasoning` field reads 0 while `output` is tens of thousands. muse-spark reports
reasoning separately (11,146 and 11,641 on comparable runs) with `output` of only
2,567–3,877, so it cannot exhaust the output ceiling this way. That is why it is
3/3 clean at `xhigh`.

**This corrects both review seats.** Both were asked whether changing muse-spark
from an ignored `max` to a declared `xhigh` increased its exposure. Both said yes.
**Both were wrong**, for the same reason: they reasoned about effort level without
the token accounting, which was available in the database neither had.

The ceiling is not global — runs routinely exceed 32,000 (66,602 observed). What
sets 32,000 on *some* deepseek+max requests is still unknown. That is now a narrow
question rather than "why does it intermittently fail".

## The change, and why it is not yet a fix


`deepseek-v4-flash` no longer asks for `max`; its map entry is `["low","high"]`.
`high` is declared by opencode for that model and its useful answers are ~3k
tokens. The claim that followed — that the change "costs nothing in stall budget on
any real bundle … only a tiny bundle moves, 570s → 300s" — was **half wrong**. True
for a big bundle, where the overlay dominates (620.94s either way at 124,188
bytes); false for a small one, where 300s kills **3.97%** of this model's
productive turns, up to 570.2s. Moot as of the same day: the stall plan no longer
derives anything from the variant name.

`medium` went too: opencode never declared it, and it was inert only because the
preference loop stopped at `max` first.

**THE BENEFIT IS UNPROVEN, and I claimed otherwise before checking.** The one
validation run at `high` came back with zero stdout and I reported the fix as
falsified. That was wrong. `opencode.db` shows the run's final turn as
`completed=NO, output=0` — **era's own stall detector tree-killed it** at 620.94s
of no output growth. It is inconclusive, not negative. I read "no stdout" and
concluded "the model produced nothing" without checking whether the process was
killed or self-terminated — the exact distinction this entire investigation turns
on, and the second time in one session I drew a confident conclusion from a
partial read.

> **CORRECTED 2026-09-04, and it is the same error a third time.** This paragraph
> and the section below both said the model was *"still generating"* when era
> killed it. It was not. That is an inference from `output=0`, not a reading of
> the record. The turn (`msg_06ba0f905001C6IJETWbMVPtzs`) holds four parts:
> `step-start`, `reasoning` with `text=""` and no `time.end`, then — **352 seconds
> later** — another `step-start` and another empty `reasoning`. Nothing arrived in
> between. And a turn killed *while generating* does not look like that either:
> opencode persists reasoning incrementally, so five never-completed turns in the
> same database still hold 2,999 to 105,568 characters of partial reasoning. This
> one kept **zero** across 633s and two step boundaries, while the sibling run six
> minutes earlier wrote 114,762 characters in 457.3s. era killed a run that was already in the zero-output
> state — the kill was correct. Full working:
> `docs/assessments/2026-09-04-stall-threshold-measured.md`.

## A separate defect the validation run exposed

**era's stall detector counts silent reasoning as a stall.** The threshold measures
OUTPUT GROWTH, and a model in a long reasoning phase produces none — no stdout, no
new tool narration.

> **CORRECTED 2026-09-04.** This section originally read: *"The successful `max`
> runs reasoned 188.1s, 342.5s and 458.6s and finished inside the 620.94s
> threshold. The validation run did not, and was killed for working."* Two things
> in that are wrong. **The 458.6s run was not successful** — it is the
> `finish=length`, `output=32000`, zero-text turn this very document is about, and
> it is where the `exitfail` snapshot came from. Two of the three era-repro
> deepseek trials succeeded, at 188.1s and 342.5s. And **the validation run was not
> killed for working**; see the correction above.

The defect is real anyway, and it was measured properly rather than argued: the
threshold was set by four guessed constants plus an overlay that multiplied an
INPUT token count by a GENERATION rate. Against 8,199 turns of local history, the
`high` base era's deepseek seat now uses — 300s — kills 3.97% of that model's
productive turns, and the `default` base of 120s kills 8.07% of all era-seat
productive turns. Replaced with a measured `prefill + generation` rule flooring at
824s, above every one of the 2,038 productive turns in the corpus.
**Full working, with the distributions and the cost of the other direction:**
`docs/assessments/2026-09-04-stall-threshold-measured.md`.

## Three defects found in the same round, all confirmed

- **Phase 1 was dead code.** `$now = $stdoutSink.Length + $stderrSink.Length` and
  opencode writes its banner to **stderr** at launch (measured: 176 stderr bytes
  against 2 on stdout), so `$hasSeenOutput` flipped true at the first poll of every
  run and `-not $hasSeenOutput` was never true again. ~46 lines of first-token
  deadline reconciliation were unreachable. Now baselines the first poll's byte
  count and requires growth beyond it.
- **Mutex leak.** The non-viable-budget `throw` sits above the `try/finally` that
  releases `Global\era-opencode-run-mutex`, so it jumped past the release. Self-heals
  via `AbandonedMutexException`, which is meant to be an anomaly rather than the
  routine hand-off.
- **`exitfail` snapshot had no retention pruning** — 3 files per failure, forever.
  Now prunes at 40 like the stall path.

## What this says about my own work

I "fixed" a finding earlier the same night about Phase 1 killing a seat at
`remaining = 15`. I verified the arithmetic with a sweep and mutation-tested the
result. **I never checked whether the branch could execute** — it was guarded by
`-not $hasSeenOutput`, which was permanently false. That is the same error, one
level up, as the finding I was fixing. The floor change is load-bearing now only
because Phase 1 was repaired hours later.

An earlier version of the evidence document also claimed the model "stopped reading
291 lines short of the end". `[offset=1531]` is a chunk START; the model read the
whole bundle. Caught by a reviewer.

## Seat performance on this round

`muse-spark` (Gemini 3.8 Flash) was right and hedged correctly: it accepted the
budget mechanism but flagged that the ceiling was probably "a lower proxy limit
(16k–64k)", tagged it `[UNVERIFIED — needs inspection of opencode.db]`, and named
the exact query that settled it.

`gemini` (3.1 Pro) asserted "**False. Budget exhaustion is physically impossible**"
with no hedge — sound arithmetic (277 tok/s) applied to the wrong ceiling of
131,072. At 32,000 it is 70 tok/s, entirely ordinary.

Same temperament gap as the previous three rounds, now with a measurable cost: the
unhedged seat's confident rejection would have closed the investigation.

## PARKED, 2026-09-04

No further quota is being spent chasing this. The state to resume from:

**Settled.** The response carries a `reasoning` part and no `text` part; opencode
exits 0; era's detectors are correctly silent. Not size-correlated. Not muse-spark
(different token accounting — reasoning is reported separately there, so the output
ceiling cannot be exhausted the same way).

**Open, and it is one question, not a mystery.** What sets a 32,000-token output
ceiling on *some* `deepseek-v4-flash` requests when others reach 66,602? Searched
the opencode binary for free: the only `32000` occurrences are JSON-RPC error codes,
and `maxOutputTokens: l?.maxTokens` shows the limit arrives from model metadata or
the provider rather than a constant in the client. So the answer is on the
opencode-go / zen side, not in anything readable locally.

**The measurement that would close it**, named independently by both review seats
and still not run: capture the raw API exchange (`HTTPS_PROXY` to mitmproxy) and
read `finish_reason` and the `max_tokens` actually sent. If it returns HTTP 200 with
`finish_reason: "length"` and empty content, the ceiling story is proven outright.
One run, and it needs a proxy stood up first.

**Why parking is cheap now.** The forensic instrument works as of `98b7e8a`. Five
occurrences produced no evidence because the snapshot was wired to three throw paths
and this bug takes a fourth. The next occurrence in any ordinary round writes a full
`exitfail-*` capture for nothing. Waiting costs less than probing.

**Do not** re-run the parked repro loop
(`%TEMP%\era-repro\repro.ps1.PARKED`) without asking: `deepseek-flash` is both the
seat that reproduces the bug and the expensive one, and `muse-spark` went 3/3 clean,
so a cheap muse-only variant tests nothing.

**The better target is the defect this hunt exposed**, not the hunt itself: era's
stall detector counts silent reasoning as a stall, and it is fully within our
control. Fixing it needs a distribution of real reasoning durations, not a guessed
number.

> **DONE 2026-09-04**, and the distribution cost nothing — it was already in
> `opencode.db`. See `docs/assessments/2026-09-04-stall-threshold-measured.md` and
> `tools/probes/opencode-silence.py`. The premise this paragraph rested on ("the
> validation run was killed while still generating") did not survive the
> measurement; the defect did, by a different route.
