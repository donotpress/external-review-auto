# The stall threshold, measured: 824s, and why the variant name is not in it

**Date:** 2026-09-04
**Status:** measured, changed, tests rewritten
**Corpus:** `opencode.db`, 8,199 assistant turns, 2,038 of them productive
**Probe:** `tools/probes/opencode-silence.py` (re-runs every number below)
**Cost:** nothing. No quota was spent; the whole thing is a local SQLite file.

## The question, and the correction it starts with

`docs/assessments/2026-09-04-opencode-zero-output-diagnosed.md` closes by naming this the
better target: *"era's stall detector counts silent reasoning as a stall … the
validation run exceeded it and was killed while still generating. Fixing it needs
a distribution of real reasoning durations, not a guessed number."*

**The premise was wrong and the conclusion was right.** Taking them in that order,
because the first is the more useful finding.

### The run era killed on 2026-09-04 was not working

That document says the validation run was *"killed for working"* and that
`opencode.db` shows the turn as `completed=NO, output=0`. The database record is
accurate; the inference from it is not. Read in full, turn
`msg_06ba0f905001C6IJETWbMVPtzs`:

```
03:55:09.235  step-start
03:55:09.243  reasoning   text=""   time.start set, NO time.end
04:01:01.945  step-start                       <- 352s later
04:01:02.116  reasoning   text=""   time.start set, NO time.end
              (killed by era at 04:05:39, tokens: input 0, output 0, reasoning 0)
```

Two empty reasoning parts, three hundred and fifty-two seconds apart, and nothing
between them.

**The control that makes this decisive** is that a turn killed *while generating*
does not look like that either. opencode persists a reasoning part incrementally,
so a run torn down mid-think keeps whatever it had produced. Five turns in the
corpus never completed and still hold partial reasoning:

| model | reasoning kept | over |
|---|---|---|
| `deepseek-v4-flash`/`max` | 105,568 chars | 328.5s |
| `ox-alpha-free`/`max` | 68,100 chars | 531.7s |
| `ox-alpha-free`/`max` | 42,677 chars | 309.8s |
| `deepseek-v4-flash`/`max` | 3,545 chars | 8.5s |
| `deepseek-v4-flash`/`max` | 2,999 chars | 4.4s |

The 2026-09-04 turn kept **zero characters across 633 seconds and two step
boundaries**. Six minutes earlier, on the same bundle, the same model wrote 114,762
characters of reasoning in 457.3s. Nothing was arriving here.

So era killed a run that was already in the zero-output state the parked
investigation is about. **The kill was correct.** What the run was doing was not
work; it was the same failure by another route.

The 633 seconds of silence it was killed at also sits above **every productive
turn on a model era dispatches** — the largest of those is 570.2s. (Two turns
elsewhere in the corpus go longer, at 785.0s and 773.7s; both are `ox-alpha-free`,
both are trivially small requests — 291 input tokens producing 279 — so they are
free-tier queueing, not generation. They still bind the floor chosen below.)

### And the detector is still mis-sized, for a different reason

None of that rescues the threshold, because the number that let that kill be
correct was an accident. 620.94s came out of `31,047 bundle tokens × 20 ms`. Had
the same bundle been 100 KB instead of 124 KB the threshold would have been 500s,
and the productive 570.2s turn in this same corpus would have been killed.

And era's live deepseek seat no longer gets that overlay's protection at the small
end at all. `deepseek-v4-flash` was moved from `max` to `high` this morning, which
takes the floor from 600s to **300s** — a value the same registry note called
"still generous". It is not:

> **26 of the 655 productive `deepseek-v4-flash` turns in the corpus — 3.97% —
> have a silent stretch longer than 300s, the longest 570.2s.**

About one working round in twenty-five, on any bundle small enough that the
overlay does not dominate.

## What "silence" actually is

era's detector kills a run after N seconds of no growth in the bytes opencode has
written. So the quantity that decides safety is **not how long a turn takes**. It
is the longest stretch inside it during which opencode writes nothing.

The gap between the two is large, and it is exactly the trap the earlier note fell
into. The turn most often quoted as the reason to raise the threshold ran 693.4s
and emitted 26,525 output tokens. Its longest silent stretch was **570.2s**: the
last 123 seconds were the answer streaming to stdout, which is output growth, which
resets the timer. Sizing off duration overstates the requirement by that tail.

Which parts are visible was measured, not assumed, from era's own captures under
`%TEMP%\opencode-stall-debug`:

| part type | visible to the detector? | evidence |
|---|---|---|
| `tool` | yes | opencode narrates each call to stderr (`→ Read bundle.xml [offset=730]`); those lines are all that the killed runs' stderr artifacts contain |
| `text` | yes, streamed | the 2026-09-02 timeout artifact holds 88 bytes of a mid-turn text part on stdout |
| `reasoning` | **no** | the 2026-09-04 `exitfail` context reports `stdout bytes: 0, stderr bytes: 167` across a 473.8s run whose turn holds one 457.3s reasoning part of 114,762 characters |

So silence = the gaps around the union of `{tool, text}` intervals.

## The distribution

Productive = the turn completed **and** wrote an answer. Those are the turns a
threshold must not kill.

| model | productive turns | p50 | p95 | p99 | max |
|---|---|---|---|---|---|
| `deepseek-v4-flash` | 655 | 7.9s | 246.3s | 459.6s | **570.2s** |
| `muse-spark-1.2-contributor` | 359 | 13.1s | 54.8s | 109.2s | 152.0s |
| `muse-spark-1.3-contributor` | 62 | 3.7s | 119.4s | 180.6s | 194.7s |
| `ox-alpha-free` | 940 | 17.1s | 135.4s | 462.5s | **785.0s** |
| `minimax-m2.7` | 20 | 16.1s | 37.5s | 38.4s | 38.4s |

What each candidate threshold would have killed:

| threshold | era seats (n=1,078) | all models (n=2,038) |
|---|---|---|
| 120s (`default`) | 87 — **8.07%** | 137 — 6.72% |
| 300s (`high`) | 26 — **2.41%** | 46 — 2.26% |
| 600s (`max`/`xhigh`) | 0 | 2 — 0.10% |
| 824s (new floor) | **0** | **0** |

## Two findings that decide the shape of the fix

### 1. The variant name predicts nothing

`muse-spark` peaks at 194.7s over its 421 productive turns, and that worst case
is an `xhigh` one. `deepseek-v4-flash` at `max` reaches 570.2s over 655. Those are
the *same* tier — two providers' names for "think as long as you like" — three
times apart. What differs is the model and how much it generates.

(Per variant, for completeness: `muse-spark-1.3`/`xhigh` n=18 max 194.7s,
`muse-spark-1.2`/`xhigh` n=106 max 62.8s, `muse-spark-1.2`/`max` n=253 max 152.0s,
`deepseek-v4-flash`/`max` n=628 max 570.2s. era's `high` seat for deepseek has
n=3 and says nothing — which is itself the point: there is no per-variant
measurement to tier on, only a per-model one.)

The tier that cost the most was the fallback. `default` = 120s kills 8.07% of
productive era-seat turns, and that is not hypothetical: it is the 2026-08-22
ox-alpha incident, in which a model with no `variants` entry was killed at 130s
having emitted only its banner. Three registry entries carry a ⭐ warning telling
the next person that omitting a variants list breaks the seat. **Deriving the
threshold from the variant is what made a missing registry line lethal.** All three
notes now carry the correction: the list still decides what era *sends* — with no
entry the resolver returns `default` and no `--variant` flag is passed at all — but
losing it now costs a quieter seat rather than a killed one.

### 2. The bundle overlay multiplied the wrong count by the wrong rate

Its own comment read `20ms/token ~ 50 tok/sec`. That is a **generation** rate. It
was applied to the **input** token count.

| | correlation with silence |
|---|---|
| input (bundle) tokens, `deepseek-v4-flash` | **r = +0.10** |
| output tokens, `deepseek-v4-flash` | **r = +0.83** |

Reading the bundle is prefill, and prefill is cheap. Time-to-first-part for
`deepseek-v4-flash`, by input size:

| input tokens | n | p50 | p95 | max |
|---|---|---|---|---|
| 0–10k | 826 | 1.9s | 8.1s | 94.1s |
| 30–40k | 27 | 6.6s | 33.8s | 42.9s |
| 60–70k | 11 | 11.0s | 35.4s | 35.4s |
| 90–100k | 9 | 30.1s | 229.2s | 229.2s |

That is **0.3 ms/token** at the median and 2.4 ms/token at the single worst
observation. The overlay charged 20. It was roughly sixty-five times too generous
on the axis that barely matters, which is why it papered over the variant bases
being too small on the axis that does.

## The rule that replaces them

```
StallThresholdMs = PREFILL + GENERATION           (then clamped to TimeoutSec − 30)

PREFILL    = 120,000 ms + 3 ms × bundle token
GENERATION =                704,000 ms
```

| constant | where it comes from |
|---|---|
| 120,000 ms floor | time-to-first-part over all 8,146 turns that produced one: p50 4.1s, p95 22.2s, **p99 47.7s**. The distribution's max is a single 431.4s free-tier queue. |
| 3 ms per bundle token | the measured prefill slope: 0.3 ms/token at the median, **2.4 ms/token** at the worst single observation (229.2s at ~95k input). 3 sits above the worst one seen. |
| 32,000 output tokens | `deepseek-v4-flash`'s observed output ceiling. Three turns in the corpus sit at exactly 32000, all `finish=length`, and **all three returned zero text** — that is the zero-output bug. It is not a universal cap (one run reached 66,602), but the two tails are not independent: the run that reached 66,602 did so at 7.8 ms/token and was silent for 512.3s, well inside the bound. Pairing the largest output ever seen with the slowest rate ever seen would give 1,518s and would be pricing a run that has never happened. |
| 22 ms per output token | the slowest per-output-token rate over the 81 turns that emitted more than 8k tokens: p50 9.6, p95 18.1, p99 22.0, **max 22.8**. |

Floor **824s**; 917s on the 124,188-byte bundle these rounds keep using.

**Checked, not asserted:** zero of the 2,038 productive turns in the corpus have a
silent stretch longer than 824s, and the largest is 785.0s.

## The other direction, stated plainly

The threshold exists to catch real hangs, and raising it has to be argued against
that. Two things make the cost small, and one of them is uncomfortable.

**It is bounded by the clamp.** 824s against era's typical 600–900s seat budget is
clamped to `budget − 30`. On most rounds the stall now fires thirty seconds before
the timeout instead of minutes before it. Both paths write the same forensic
snapshot; what is lost is a slightly earlier failure and a more specific label.

**Silence does not discriminate, and no threshold makes it.** The 89 turns in the
corpus that completed with no answer at all have silences of p50 121.1s, p90
319.6s, max 688.6s — **the same range the working turns occupy**, with 42 of the 89
under 120s. There is no cut that keeps the failures and lets the work through. So
the defensible choice is the one that never kills work, and leaves the failures to
the checks that actually identify them: the exit code, and the empty-capture test.

**The corollary, followed up the same day — and it was half wrong.** This section
originally said the budget question was only about letting the stall fire on its
own terms, needing budgets past ~854s, and left it. Measured against era's own
round archive (629 rounds, 1,175 seat-runs, `tools/probes/era-seat-budget.py`),
that framing missed the part that mattered:

- The budget essentially **never binds on work that succeeds** — 1 of 978
  productive seat-runs ever exceeded it, and only 19 reached 80% of it. So the
  "raise budgets so the stall can fire" argument buys nothing on its own.
- But the floor is not only a timeout. **It is the clamp on the stall threshold.**
  At a 600s floor the clamp is 569s, and a productive `deepseek-v4-flash` turn in
  `opencode.db` went silent for **570.2s on a 7,794-token input** — squarely on
  the floor — before delivering 11,520 characters of review. The clamp would have
  killed it 1.2 seconds early. So the guessed floor was silently overriding the
  measured appetite on the most common round shape.

Floor raised **600s → 700s**, putting the clamp at 670s: clears 570.2s by 99.8s
(17.5%), and kills 0 of the 404 productive floor-regime seat-runs against 3 at the
old clamp. **Not** raised to 854s — that would stop the clamping entirely, but the
824s appetite is a global bound including big-output runs and free-tier queue
stalls that do not occur at floor bundle sizes. Buying unused headroom costs +254s
on every wedged seat instead of +100s, and 11.8% of floor-regime seat-runs are
non-productive.

**And the bundle-size scaling is the wrong model at the small end, which this
made obvious.** A live round on 2026-09-04 took **430 seconds on a 1,229-token
bundle**; `bundleTokens × 0.02` would have granted it 24s. Only the floor stands
between that round and a false timeout. The scaling term is not wrong for large
bundles, but below ~35k tokens it predicts nothing — the same category error the
stall overlay had, one level up. Left as it is, with the floor doing the work and
this note recording why.

## What this corrects in the record

- `backends/_registry.json`, `deepseek-v4-flash._variants_note`: "tree-killed …
  **while the model was still generating**". It was not generating. Corrected in
  place, with the part-level evidence.
- The same note: 'high' "costs nothing in stall budget … only a tiny bundle moves,
  570s → 300s, **still generous**". 300s kills 3.97% of productive turns on that
  model. Moot now — the variant no longer enters the arithmetic — but it was wrong
  when written.
- `docs/assessments/2026-09-04-opencode-zero-output-diagnosed.md`: "The successful
  `max` runs reasoned 188.1s, 342.5s and 458.6s". The 458.6s run was **not**
  successful — it is the `finish=length`, `output=32000`, zero-text turn that the
  `exitfail` snapshot was taken from. Two of the three era-repro deepseek trials
  succeeded, at 188.1s and 342.5s.

## Reproducing

```bash
cp ~/.local/share/opencode/opencode.db /tmp/oc-snap.db   # live file returns "disk I/O error"
python3 tools/probes/opencode-silence.py /tmp/oc-snap.db
```
