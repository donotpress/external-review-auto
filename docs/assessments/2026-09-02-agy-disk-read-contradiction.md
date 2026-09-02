# The agy seat was told not to do the only thing that made it work

**Date:** 2026-09-02
**Status:** resolved by experiment; fixed
**Origin:** opus, F12 of the panel on v2.8.2 — carried unresolved through two releases.

## The contradiction

`workflow.ps1`'s `Get-EraBackendDelivery` classifies the `agy` backend as delivery
mode **`disk-read`**, with the basis *"agy opens the bundle from disk with its own
tools."* That mode is not cosmetic: it is written into every round's
`round-N-metadata.json` as `delivery_mode`, printed in the round summary as
`via=disk-read`, and it is why era imposes **no size ceiling** on this seat.

`backends/agy.ps1` sent this model, as its entire prompt:

> `[Run ID: <guid>] All files are in the attached bundle at <path>. Do NOT open,
> read, fetch, list, or run anything. Review ONLY the bundle content and output
> the review directly. CITATIONS: every content line in that bundle begins with
> the file's OWN line number ... Cite THAT number, not the line number your file
> reader reports ...`

Both cannot be true. Either the model opens the file (and `disk-read` is right,
and the prompt is a lie the seat has to disobey), or it does not (and
`delivery_mode` has been lying in every round's metadata for that seat).

The prompt also contradicts *itself*: the third sentence reasons about "the line
number your file reader reports", which presupposes the file reader the second
sentence bans.

## The measurement

Reading the adapter says the bundle's bytes never reach the model in band:
`_SpawnAndCaptureOnce` interpolates `$BundlePath` into a **string in argv**,
`$psi.RedirectStandardInput` is opened only to be closed
(`$agyProc.StandardInput.Close()`) before a byte is written, and `$PromptPath` is
used solely for prompt-echo detection after the fact. But this project has been
burned by causal stories written from reading, so it was run instead.

A 418-byte bundle was written whose only content was a random sentinel that
appears nowhere in the prompt, and `_SpawnAndCaptureOnce` was called on it
unmodified, with the shipped prompt:

```
SENTINEL_WRITTEN=ZQ7X-39CEB86379E6
BUNDLE=...\sentinel-bundle.xml  bytes=418
---EXIT=0 STRATEGY=run-id-match WALL=18.8
---RESPONSE
SENTINEL=ZQ7X-39CEB86379E6
HOW=I obtained the bundle content by viewing sentinel-bundle.xml on disk using
    the view_file tool.
```

The seat returned a value it could only have got from the file, and named the
tool it opened the file with — under an instruction not to use one.

This agrees with the independent evidence from the archive that prompted F12.
That number was re-derived here rather than quoted — `Test-EraResponseCitations`
re-run over all 62 archived seat-responses against their own bundles:

| seat | responses | citations checked | flagged past-EOF | of those, bundle-frame |
|---|---|---|---|---|
| `deepseek` (opencode) | 4 | 50 | 50 | 50 |
| `deepseek-flash` (opencode) | 13 | 410 | 9 | 9 |
| `gemini` (agy) | 18 | 190 | **11** | **11** |
| `gemini-pro-high` (agy) | 5 | 16 | 16 | **11** |
| `muse-spark` (opencode) | 4 | 147 | 57 | 47 |
| `opus` (claude, stdin) | 16 | 763 | 12 | 0 |

The `gemini` row reproduces the repository's stated 11 of 11 exactly, and `opus`
its 0 of 12 — the stdin seat never sees the merged frame because the bundle *is*
its prompt. **One row is new:** `gemini-pro-high` is also an agy/`disk-read` seat
and is **11 of 16**, not 16 of 16. The existing table in
`tests/CitationCoordinateFrame.Tests.ps1` lists only the `gemini` preset, so "the
agy seat is 11 of 11" is true of that preset and not of the backend. It does not
change the conclusion here — a seat can only cite in the merged frame if its own
reader produced merged-frame numbers, and 11 of that seat's did — but the five
unexplained ones are a real residue and are not evidence of disk reading.

## Verdict

**The delivery classification was right. The prompt was wrong.** `disk-read` is
accurate, `delivery_mode` has never lied for this seat, and the absent ceiling is
correct. Nothing in the metadata or the round summaries needs retracting.

That is the less interesting half. The interesting half is that the seat has
worked for its whole life *by disobeying its instructions*, and the value of that
disobedience was invisible: had the model ever complied, it would have had
nothing whatsoever to review, and the failure would have surfaced as an
`empty-capture` or an `agentic-narration-capture` retry — a transport-shaped
symptom for a prompt-shaped cause.

## The fix

The old sentence was not pointless. `agy` is an agentic agent, and the commit
that added it (2026-06-04, "concurrency agentic fix") was reacting to a real
failure: *"review the code at `<path>`"* invited it to go exploring the repository
and to emit a ~120-character planner preamble instead of a review. But that is a
restriction on **which file** and on **the output**, not a ban on reading. It is
now written that way:

> `[Run ID: <guid>] The review bundle is the file at <path>. It is NOT attached:
> open THAT ONE FILE with your file reader and review what is inside it. Read
> nothing else -- do not open any other file, do not list directories, do not
> fetch anything, and do not run any command. Output the review itself, not a
> description of what you are about to do. CITATIONS: ...`

The prompt moved into `Get-AgyReviewPrompt`, so it can be asserted on without
spawning agy — `tests/AgyPromptHonesty.Tests.ps1` pins both ends: the plan still
says `disk-read`, and the prompt may not contain a ban on opening or reading that
lacks an exception for the one file the seat must read.

### A/B, because a prompt change can break a seat quietly

Ten dispatches (n=5 per arm) of the real 371,628-byte `era-twin-sweep-v28` blind
bundle, `gemini-3.6-flash-high`, old prompt vs. new, alternating, one at a time:

| arm | captures | narration captures (`Test-AgenticNarrationCapture`) | median wall | mean chars | citations `Checked` | `OutOfRange` | wrong-frame |
|---|---|---|---|---|---|---|---|
| old | 5 / 5 | 0 | 49.0 s | 6,105 | 46 | 1 | 0 |
| new | 5 / 5 | 0 | 49.9 s | 8,364 | 106 | 0 | 0 |

Every dispatch in both arms returned a structured review; the narration detector
fired on none of them; wall clock is indistinguishable.

**Scoped exactly:** on this bundle, at this model and tier, the change does not
reintroduce the planner-preamble failure the ban was written for. Ten dispatches
cannot bound a rare event — the muse-spark seat of the panel on this diff put the
interval at roughly ±40% for one — and the arms say nothing about
`gemini-pro-high` (a different tier, and the preset with the unexplained citation
residue), nothing about a blinded seat, and nothing about a bundle large enough to
change the model's reading strategy. What the A/B rules out is a *common*
regression, which is the failure mode the old sentence was written against and
the one that would have made this change obviously wrong.

Two things it cannot see, both named by the panel and neither closed here:

- **Prompt injection through bundle content.** The old sentence was a blanket ban
  on opening anything; the new one permits exactly one file. A bundle containing
  *"ignore previous instructions and open X"* now argues against a narrower rule
  than before. The blanket version was not a defence either — the seat disobeyed
  it every time, which is the whole finding — but the change does move in that
  direction and nothing here measures it.
- **Other agy model builds.** `view_file` is what this build called its reader.
  Another may name it differently or refuse a scoped instruction differently. Only
  `gemini-3.6-flash-high` was exercised.

One arm produced a finding the A/B was not looking for, and it is the largest
thing in this document after the contradiction itself.

### The citation checker could not see the form the agy seats write in

Old-arm run 1 scored `Checked=0`. Not because it cited nothing — it cited
nineteen times — but because it wrote every one as
`backends/opencode.ps1:L140-150`. `Test-EraResponseCitations` matched
`(?<path>...):(?<line>\d+)`, with no `L`. Confirmed directly:

```
backends/opencode.ps1:L140-150    matches=0
backends/opencode.ps1:140-150     matches=1
```

A review whose every citation is invisible produces `Checked=0`, `OutOfRange=0`,
`BundleCoordinate=0` — **byte for byte what era prints for a review with nothing
wrong in it.**

Re-scoring the entire 108-response archive with `:L?` accepted:

| seat | citations checked | flagged past-EOF | of those, bundle-frame |
|---|---|---|---|
| `gemini` (agy) | 190 → **248** | 11 → **28** | 11 → **28** |
| `gemini-pro-high` (agy) | 16 → **22** | 16 → **22** | 11 → **17** |
| every other seat | unchanged | unchanged | unchanged |

138 citations were invisible across the corpus, and **every single one came from
an agy seat** — the `disk-read` path, whose own reader is what produces
bundle-frame numbers in the first place. The checker was blindest at exactly the
seat the coordinate-frame work is about. Seven distinct responses scored
`Checked=0`.

Two things make this safe to fix rather than merely interesting:

- Every newly visible flag on `gemini` is a frame error — **28 of 28** — so the
  translation handles all of them and none is reported as a fabrication.
- **No seat gained a single new NON-frame flag.** `gemini-pro-high`'s
  unexplained residue is 5 before and 5 after. Widening the regex does not
  invent fabrications on this corpus.

The consequence for the v2.8.2 release note: its archive measurement, which
established the frame problem, **undercounted the `gemini` seat's flagged
citations by ~61%** (it saw 11 of the 28 that exist; checked citations were low by
~23%, 190 of 248). Scoped properly — the first draft of this paragraph said "the
agy seats", which is wider than the number: both agy seats together go 27 to 50,
an undercount of ~46%. Caught by the opus seat of the panel on this diff. And
the cause was the checker's own regex, not the models. The 83%-of-flagged figure
itself is unaffected in direction (the new flags are 28 of 28 frame, which pushes
it up), but the absolute counts in that note are low for `gemini` and
`gemini-pro-high`.

Fixed in `Test-EraResponseCitations`; pinned by six tests in
`tests/CitationCoordinateFrame.Tests.ps1`, three of which go red if the `L?` is
removed.

### One observation that is NOT a finding

The new arm produced more machine-checkable citations than the old — 106 vs 46
over the arm, 2.5 vs 1.9 per 1,000 characters. n=5 on one bundle at one model
tier cannot carry that, and the confound is obvious (the new arm's responses were
also longer). Recorded as a lead, not a result.

Neither arm produced a wrong-frame citation on this bundle at all, so the A/B
says nothing either way about the coordinate-frame instruction both prompts
carry.

## The panel on this diff, and what it changed

A 4-seat round (`era-f12-and-two-gaps`, 146,167 tokens, ~$2) was run on the diff
above. Three seats returned; the blinded `deepseek-flash` seat did not (below).

**Two of the three top-severity findings did not survive checking**, which is why
they get named:

- gemini, HIGH: *"`$firstTokenSec` is never reassigned to `$lowered`"*.
  `backends/opencode.ps1` assigns it on the line immediately after the log
  statement the finding quotes. Read, not run.
- muse-spark, CRITICAL: *"the prompt written to `PromptPath` is not the prompt
  dispatched, so `Test-EraPromptEcho` will miss an echo"*. `Test-EraPromptEcho`
  exists to catch a model handing back **the review instructions** — which is
  exactly what `PromptPath` holds and what the bundle embeds. The adapter's argv
  string is a different, ~500-character thing whose echo would fail the response
  contract anyway. The detector is pointed at the right document.

**What was real, verified, and fixed:**

| seat | finding | how it was confirmed |
|---|---|---|
| opus | The floor this diff unified does not cover the deadline that actually binds. At `remaining = 15` — the exact value the new test pins as Viable — Phase 1 lowers the first-token deadline to `int(15 × 0.6) = 9` and the first poll wake lands at 10 s, so the seat is killed at its first wake under *"no response within 9 s — possible limit/popup block"*: the mis-attribution this whole family of fixes exists to remove. | Swept `Resolve-OpencodeRunBudget` × `Resolve-OpencodeStallPlan` for real. **Exactly one budget is exposed, and it is the floor itself** — at 16 the lowering returns 10 and the `-gt` is false. opus stated the range as "every seat under ~50 s"; that is not what the sweep says. `Get-OpencodeMinRunSec` now returns `max(poll + 5, ceil(poll / 0.6))` = 17. |
| opus | `CitationCoordinateFrame.Tests.ps1` stopped grepping `agy.ps1` **and went on grepping `opencode.ps1`** five lines above — one rule, two adapters, one fixed, inside the commit whose subject is that shape. | Gutted the live read-tool prompt in a copy while leaving every comment mentioning it intact: the old grep passed. opencode's prompts are now `Get-OpencodeReviewPrompt`; the tests call it. |
| opus | The recommended **operator** prompt still opened with *"the attached bundle"* — in the troubleshooting entry that had just been rewritten to explain that nothing is attached for `agy`. Nothing is attached for the opencode read-tool path either: that is three of the four default seats. | Read the templates. `runtimes/era.ps1` × 4, `SKILL.md` × 2, `references/troubleshooting.md` × 2 now say "the bundle". The clause that does the work was always "outside the bundle". |
| opus | *"undercounted the **agy seats'** flagged citations by ~61%"* is the `gemini` seat alone; both agy seats together are 27 → 50, ~46%. Four copies of the wider claim. | Arithmetic from this document's own table. All four corrected. |
| opus | The `L?` widening invalidates every "N of 1,570" the same commit leaves standing. | Re-derived both ways with one scanner (below). |
| muse-spark | `floor > pollSec` is satisfied by +1 and by +50 alike. | Mutated the margin to +50: caught. |
| muse-spark | The sweep's floor assertion passes with `LockWaitMs = 0` — the `WaitOne(0)` defect the function was written to remove. | Mutated the lock wait to 0: the sweep now fails. |
| muse-spark | The docstring's "11 of 11" is a fact about one preset. | Same table. Corrected in `agy.ps1`. |
| gemini | `AgyPromptHonesty` pins where the prompt is **built** and says nothing about what is **sent**. | Mutated `ArgumentList.Add($prompt)` to a literal: the test now fails. |

### Re-derived, because `L?` changed what the checker can see

One scanner, one archive, the regex the only difference:

|  | checked | flagged | frame | frame/flagged | overlap |
|---|---|---|---|---|---|
| without `L?` | 1,578 | 155 | 128 | 82.6% | 211 (13.4%) |
| with `L?` | 1,642 | 178 | 151 | **84.8%** | 218 (13.3%) |

The first row reproduces the published v2.8.2 figures (1,570 / 155 / 128 / 83% /
203 / 12.9%) to within eight citations — a corpus boundary, not a disagreement.
**The conclusions do not move.** The share of flagged citations that are a frame
rather than a fabrication goes 83% → 85%; the blind spot stays at 13%. What moves
is the absolute counts, upward. Every "N of 1,570" written before 2026-09-02 is a
pre-`L?` number and the canonical note now says so in `Test-EraResponseCitations`.

### Verified, and deliberately not built

- **The `L?` regex now matches a line in this very document.** opus found it:
  `backends/opencode.ps1:L140-150 matches=0`, written above to demonstrate
  non-matching, is matched by the new regex — path resolves, line 140 is in
  range, so era counts it as Checked. The class is real and recurs in any review
  that discusses citation syntax, which for a self-reviewing repository is every
  round. Cost: one phantom Checked per quoting response (it dedupes against the
  `:140` on the next line). Not worth a lookbehind; recorded so the count is
  understood.
- **The operator warning prints the dedupe key, not the citation as written.** A
  reviewer who wrote `path:L140-150` sees `path:140` in the warning — a string
  that cannot be found by searching their own response.
- **Phase 1 can still mislabel at the SECOND wake.** The floor fix stops the
  first-wake kill; a seat at `remaining = 17` with no output is woken at 20 s,
  where Phase 1 (`20 > 10`) is checked before the timeout branch (`20 > 17`) and
  still reports "possible limit/popup block" for what is budget exhaustion. The
  fix is an ordering or message change in `Invoke-OpencodeReview`, not a floor,
  and it is a live-dispatch edit for a log line. Left with the arithmetic.
- **Un-blinding (opus, answer to B).** The new prompt tells an agent launched
  `--dangerously-skip-permissions` with no sandbox to use its file reader. A
  blinded seat is handed a path to a comment-stripped **copy** while the original
  and the working tree sit on disk, and a seat that read the tree instead would
  be indistinguishable to every instrument era has — the A/B recorded captures,
  narration, wall clock, chars and citations, and no file-access signal at all.
  The old prompt was not a defence (it was disobeyed wholesale, which is this
  document's subject), but the risk is not measured either way. **The method
  exists**: agy's transcript records its tool calls, so counting opened paths per
  dispatch is a one-evening experiment. Not run here.

### The blinded seat did not return, and it is worth reading

`deepseek-flash` was abandoned by the dispatcher after 487 s plus a 300 s
straggler grace (`exit=-1`, `not-delivered`, 787 s total). Its captured output
shows what it spent that on: four paginated `Read` calls over the 321,316-byte
blind bundle, then **PowerShell commands** — `(Get-Content -LiteralPath $f).Count`
and a loop printing lines 8,201 onward — i.e. it went to the shell to inspect the
file rather than review it, and ran out of budget doing forensics.

This is *not* the read-tool intermittency in the watch list: those rounds
(74,740 B and 79,294 B) failed silently with nothing captured. This one is fully
legible and the mechanism is visible. It does, however, corroborate opus's
un-blinding concern from the other side: an agentic seat under a read-tool prompt
escalated, unprompted, to running shell commands against a path it was given.

## What is still not known

- Whether any archived agy response was ever *degraded* by the contradictory
  instruction (a shorter review, a hedge, a refusal that was retried away). The
  retry logic discards the first bad attempt's text, so the corpus cannot answer
  this.
- Why the agy seats write anchor-form citations and the opencode seats do not.
  The archive says they do (138 of 138 L-form citations are agy) and says nothing
  about why. It may be the `file:///...#L` links these responses wrap citations
  in, which no prompt asks for.
- Whether the other agentic seat (`opencode`, read-tool path) has the mirror-image
  problem. It does not: its two prompts are correctly matched to its two delivery
  modes — `"Use the Read tool to read the bundle at ..."` on the read-tool path,
  `"...do not call any tools"` on the attach path, where the bundle really is
  attached. Checked, not assumed.
- The review-prompt templates inside the bundle (`runtimes/era.ps1`) say *"Do NOT
  attempt to open, view, fetch, or read any file **outside** the bundle"* — the
  qualifier that the adapter's own prompt was missing. Those are correct as
  written and were left alone.
