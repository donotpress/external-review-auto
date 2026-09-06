# Model drift detection across era's backends

**Status:** design, not implemented
**Date:** 2026-09-06
**Scope:** CLI backends now (`agy`, `opencode`, `claude`), REST backends as a later phase, `cmdc` snapshotted but unconsumed

---

## 1. The problem, in the repo's own defect log

era's registry names models, variants and prices. Vendors withdraw, rename and
re-tier those without telling anyone. Nothing in era compares the two, so the
registry rots silently and the rot is found by a round going wrong.

Every incident below is recorded in this repo or was measured on 2026-09-05/06:

| Drift | Consequence | Silent for | Found by |
|---|---|---|---|
| `ox-alpha` withdrawn from `opencode models` | a **default-panel** seat dispatching a model that cannot run | ~4 days (added 08-22, withdrawn 08-26) | a round returning nothing |
| `opencode-go/ox-alpha-free` renamed to `omen-alpha` | explicit `-Reviewer ox-alpha` spawned a process and failed at the vendor | ~10 days | dispatching it on 2026-09-05 |
| muse-spark asked for `--variant max`, which it does not declare | the seat ran at **default** reasoning effort while era believed maximum | **9 days** (08-26 → 09-04) | a panel seat reading the registry |
| `gemini-3.5-flash` gone from `agy models` | `gemini-flash-35` preset names a model that no longer exists | unknown | measured 2026-09-06, **still true** |
| gemini default two minors behind (3.6 while 3.8 shipped) | panel quality, silently | unknown | the operator asking |

A sixth, one layer down and the same shape: on 2026-09-06 PowerShell renamed
`ThreadJob` to `Microsoft.PowerShell.ThreadJob`, and era's guard — which asked
for the module *name* rather than the *capability* — took era down completely on
a host that was fully capable.

**The common shape.** Something outside era changes its name or goes away; era
holds a stale literal; era reports the mismatch as a fact about the subject
rather than about its own instrument. `~/.claude/CLAUDE.md` was written about
exactly this, and `backends/opencode.ps1` records three fail-open catches of the
same family.

## 2. What this is, and what it deliberately is not

**Is:** a drift *detector*. It compares what the registry claims against what
each vendor CLI declares, and reports.

**Is not:** an auto-updater. Three reasons, each concrete:

1. **Pricing feeds the spend guard.** `pricing.input_per_m` / `output_per_m`
   drive the cost estimate and the per-reviewer cap. A vendor-sourced write
   could change spend behaviour with no human in the loop. This is not
   hypothetical: the `gemini` 3.6 → 3.8 bump on 2026-09-05 had to carry 3.6's
   pricing over **unverified**, because `agy models` prints no rates at all.
2. **Auto-swapping the default panel changes what reviews your code**, without
   the operator deciding.
3. **The registry's notes are its most valuable content** — dense, dated,
   measured history. A generator would flatten them.

Detection is automated; application stays human. Same division era already uses
for citation warnings, cost warnings and seat containment.

## 3. The trap this design exists to avoid

A test that compares the registry against a checked-in snapshot proves the
registry agrees with **a file**, not with the vendor. Shipped naively, that is a
machine for reporting *stale agreement* as health — the precise
instrument-for-subject substitution that caused every incident in §1.

So:

- Every snapshot carries `_captured` (ISO date) and `_command`.
- The offline test **fails** when any snapshot is older than `MaxSnapshotAgeDays`.
  "Nobody has refreshed this in months" becomes a red build, not a silent green.
- The report never prints a bare "no drift". It prints
  `no drift vs a snapshot captured <date> (<n> days old)`.

**`MaxSnapshotAgeDays` is a POLICY, not a measurement, and must be labelled as
one in the code.** The incident data does not derive it: ox-alpha was dead ~4
days before discovery and the muse-spark variant 9 days, so no threshold in a
sane range "would have caught" those — refresh *cadence* is the control, and the
threshold only bounds indefinite rot. Proposed initial value **30 days**, with a
comment stating plainly that it is a declared choice and what would change it.
This repo has been bitten by guessed constants presented as measurements
(`11e83ef`: "the 600s seat-budget floor was a guess, and it was overriding the
measurement"); the fix is to label the guess, not to dress it up.

## 4. Architecture — five units

Separated so that **every unit holding logic is reachable without a network**:
parsing (§4.2), the writer's gate (§4.3) and the comparator (§4.4) are all pure
or injectable, and only §4.1 touches the outside world.

### 4.1 Fetch (one per backend) — I/O only, no parsing

```
Get-EraModelRaw-<Backend>  ->  @{ command; exitCode; stdout; stderr; capturedUtc }
```

Network. Never invoked from the test suite.

### 4.2 Parse (one per backend) — pure, unit-tested on golden stdout

```
ConvertFrom-EraModelListing-<Backend> -Stdout <string>
    ->  @{ models = @{ '<vendor id>' = @{ display; variants; cost; status } } }
```

**The parser does NOT report coverage.** An earlier draft had it return its own
`fields` map. That is the wrong layer: coverage is a static property of what a
backend's CLI can express, not something a parser discovers, and a parser that
reports its own trustworthiness can be wrong about it in the direction that
matters. Coverage lives in the static table at §5 and is passed to the
comparator (§4.4).

Splitting fetch from parse is not tidiness — §7 shows three genuinely different
formats, and leaving that logic inside a network-only function makes it
untestable without a network, which is the `BroadScopeGate` failure §8 cites.

### 4.3 Snapshot writer — refuses to write THE MODEL LIST, never writes nothing

Parse result → `tests/fixtures/models-<backend>.json`.

**A writer that always writes reproduces §3 inside the detector**: a probe that
fails or truncates would stamp a fresh `_captured`, turn the build green, and
emit missing models the comparator reports as `model-withdrawn` errors.

**But a writer that writes *nothing* on failure reproduces it too**, in the
opposite direction: the capture pipeline dies, no file changes, and the offline
test happily reports `no drift vs a snapshot captured <date>` until the staleness
threshold trips — up to `MaxSnapshotAgeDays` of a dead probe reading as health.
An earlier draft had exactly this hole, and made it worse by recording
`exitCode` / `stderrExcerpt` / `rawLineCount` **only on accepted writes** — that
is, only when `exitCode` is 0 by construction and nobody needs them.

So the writer **always updates an attempt header, and separately decides whether
to replace the model list**:

```jsonc
{
  "_captured":    "2026-09-04",   // moves ONLY on an accepted capture
  "_command":     "...",
  "_lastAttempt": {               // ALWAYS updated, accepted or refused
    "utc": "...", "exitCode": 1, "rejectedReason": "parse yielded 0 models",
    "stderrExcerpt": "...", "rawLineCount": 0
  },
  "models":   { ... },            // replaced ONLY on an accepted capture
  "notObserved": [ ... ]          // registry ids the probe looked for and did not find
}
```

It **refuses to replace the model list** when the probe exited non-zero, or the
parse yielded zero models. Those two are cheap, certain, and are most of the
value — an earlier draft added a third, a `MaxModelCountDropFraction` hard
refusal, and the round-4 panel was right that it overshot: a legitimate vendor
cull larger than the fraction would be refused on *every* subsequent run, the old
snapshot would stand, staleness would eventually trip, and there was no way
forward. The drop check is kept as a **refusal that names its override** —
`-AcceptDrop` — so a real cull is one acknowledged flag, not a deadlock.
`MaxModelCountDropFraction` remains a **POLICY, not a measurement** (§3),
proposed 0.25.

**`notObserved` exists because key-absence is not a measurement.** The writer is
given the registry's expected id set for that backend, so "the probe looked for
this id and did not see it" is recorded positively. Without it, a model missing
because the vendor withdrew it is byte-identical to one missing because the
listing was truncated or a namespace was never covered — a never-asked question
recorded as a negative answer, which is §1's whole subject.

### 4.4 Comparator — pure function

```
Compare-EraModelRegistry
    -Registry             <obj>
    -Snapshots            <map: backend -> snapshot>
    -BackendCapabilities  <map: backend -> field coverage, the STATIC table of §5>
    -DefaultPanelSources  <map: source-name -> string[]>
    -Now                  <datetime>
  -> findings[]
```

No file reads, no CLI calls, no clock of its own.

`-BackendCapabilities` is separate from `-Snapshots` because **`claude` has no
snapshot by construction**, so a comparator iterating snapshots can never
enumerate it and could never emit `backend-unmeasurable` for the one backend that
needs it. Coverage must come from a source that lists every backend, including
those with no probe.

`-DefaultPanelSources` is a **map, not a merged array**: merging destroys the
disagreement `default-panel-mismatch` exists to report.

`-Now` is injected so the staleness finding is testable on literals.

### 4.5 Test / reporter

Consumes findings, prints the report, asserts. Offline and deterministic. The
report **must** carry the age-qualified verdict from §3 — never a bare "no
drift", always `no drift vs a snapshot captured <date> (<n> days old)` — and must
name every backend whose coverage is `unmeasured`.

## 5. Coverage is a static table, and `collected` is not `compared`

A field the probe can see but which no §6 finding consumes is **not** being
checked. Calling it "checked" is §3's trap committed by this design itself.

- `compared` — a §6 finding branches on it;
- `collected` — recorded, nothing compares it yet;
- `unmeasured` — this backend's CLI cannot express it;
- `n/a` — no such concept for this backend.

| Backend | Command | ids | display | variants | pricing |
|---|---|---|---|---|---|
| `opencode` | `opencode models --verbose` | **compared** | collected | **compared** | **collected** |
| `agy` | `agy models` | **compared** | collected | n/a (tier is in the id) | **unmeasured** |
| `cmdc` | `cmdc --list-models` | collected (unconsumed) | n/a | n/a | **unmeasured** |
| `claude` | *(none exists)* | **unmeasured** | unmeasured | unmeasured | unmeasured |

This table is the `-BackendCapabilities` input (§4.4). It is **static and
hand-maintained**, not probe output.

**Pricing is `collected`, not `compared`, and there is no `pricing-changed`
finding in v1.** An earlier draft promoted it and the round-4 panel showed the
promotion was unimplementable as written: opencode's `cost` is
`{input, output, cache}` while the registry's `pricing` is
`{input_per_m, output_per_m}`, and nothing specified the field mapping, the
units, cache handling, or what "differs" means. A literal implementer would
either emit a standing warning every run — the "warning nobody reads" failure
this document cites — or silently compare a guessed subset. That is a claim of
verification with undefined semantics, which is precisely the offence the
round-2 finding was raised against, reinstated by its own fix.

The honest v1 state is `collected`, with the mapping named as future work (§11).
Note what this costs: nothing, in evidence terms. Pricing is `unmeasured` for
agy and cmdc anyway, and the one pricing figure this repo *knows* is wrong —
gemini 3.8's, inherited unverified from 3.6 — is on an agy preset and invisible
to a comparison of opencode `cost` regardless.

## 6. Findings and severity

| Finding | Meaning | Severity |
|---|---|---|
| `model-withdrawn` | registry preset names an id absent from the snapshot | **error** if in the default panel, else **warning** |
| `variant-undeclared` | registry asks for a variant the model does not declare | **error, always** |
| `snapshot-stale` | `_captured` older than `MaxSnapshotAgeDays` | **error** |
| `snapshot-rejected` | `_lastAttempt` records a refused capture | **error** |
| `snapshot-missing` | no snapshot for a backend that **has a probe and is consumed** | **error** |
| `backend-unmeasurable` | backend coverage says `ids = unmeasured` | **info**, always emitted |
| `model-unconsumed` | snapshot lists models no preset uses | **info** (normal) |
| `default-panel-mismatch` | the default-panel sources disagree | **error** |

### Severity keys on runtime loudness, not on the default panel alone

An earlier draft keyed everything on default-panel membership, reasoning that a
stale non-default preset *"fails loudly at the vendor when someone named it"*.
**True for withdrawal, false for variants**, and the counter-evidence ships in
this repo:

> `tests/OpencodeVariantDeclared.Tests.ps1:3-19` — *"opencode DOES NOT VALIDATE
> VARIANT NAMES... an undeclared variant is SILENTLY IGNORED, not rejected...
> There is no runtime signal to check, which is why the guard has to be a test."*

A withdrawn model exits non-zero with `Model not found`. An undeclared variant
exits 0 and returns a normal-looking review at the wrong reasoning effort —
silent by default *and* when named. Keying it on the panel would also have been
a **strictness regression** against that file's sweep (`:164-189`), which
iterates the whole `_opencode_model_map` and asserts `Should -BeNullOrEmpty`.

**`variant-undeclared` checks both contracts**, because the bundle contains
both: the variant era's preference loop actually *chooses* (`:74-103`) and every
variant *listed* in the map (`:164-189`). Checking only the chosen one would
miss an inert entry that is one preference-loop edit away from live, which is
the stated reason the sweep exists.

### Panel membership when the sources disagree

`model-withdrawn` severity keys on panel membership, and
`default-panel-mismatch` exists precisely because the two sources can disagree —
so membership is undefined exactly during the incident it matters in. **Rule:
membership is the UNION of the sources.** Fail toward error.

### Exemption: unmeasurable OR unconsumed

A backend emits `backend-unmeasurable` **instead of** — never alongside —
`snapshot-missing`, `snapshot-stale`, `snapshot-rejected` and `model-withdrawn`
when its coverage is `ids = unmeasured` (`claude`) **or** when no era backend
consumes it (`cmdc`, whose ids are `collected` but which no preset dispatches
to — the earlier draft's exemption was keyed on `unmeasured` alone and therefore
did not actually cover `cmdc`, which it claimed to). REST backends (§10) are
exempt on the same "no probe" grounds until their phase lands.

### Retired presets

A preset marked `retired` in the registry is **exempt from `model-withdrawn`**
(its absence is expected and recorded) but **not** from `variant-undeclared`,
matching `tests/OpencodeVariantDeclared.Tests.ps1`, which excuses a retired
preset's absence (`:79-93`) while its sweep still checks retired map entries
(`:164-189`). Note the live caveat: `retired` is read by tests only and by
nothing at runtime, which is why the `ox-alpha` preset was deleted rather than
left flagged.
## 7. Probe details, as measured 2026-09-06

**agy** — `agy models`. First line is an ANSI-coloured `Fetching available
models...`; every subsequent line is `id<TAB>display name`. Confirmed with
`cat -A`. No pricing, no variants (the tier is encoded in the id, e.g.
`gemini-3.8-flash-high`).

**opencode** — `opencode models --verbose`. Emits `provider/id` followed by a
JSON object per model carrying `status`, `cost` (input/output/cache), `limit`
(context/input/output) and variants. Richest source; the only one that can check
pricing and variants.

**cmdc** — `cmdc --list-models`. 68 models. Plain text with a header line and
section headers (`Open Source`), entries as `id<2+ spaces>description`; ids
contain `/`. No JSON option (`--output-format` applies to `-p` only, verified).
**Snapshotted but unconsumed:** cmdc is not an era backend — there is no
`backends/cmdc.ps1` and zero registry references. The snapshot exists so the
data is there if a backend is written. The report must label it
`tracked, no era backend consumes this` and must not count it toward coverage.

**claude** — no enumeration. `claude --help` lists `agents`, `auth`, `doctor`,
`gateway`, `import`, `install` and others; there is no `models` subcommand and
no listing flag. `--model` accepts a value but cannot enumerate.

## 8. Test strategy
## 8. Test strategy

- **Comparator tests** — pure, on literals, TDD, red first. One per finding in
  §6, explicitly including `pricing-changed`'s absence, `snapshot-rejected`,
  `model-unconsumed`, the union rule for a disagreeing panel, retired-preset
  handling, and both `variant-undeclared` contracts (chosen and swept). An
  earlier draft's plan omitted three of its own finding types.
- **Parser tests** — pure, on committed golden stdout captures per backend,
  including the ANSI preamble `agy` emits and whatever stream it arrives on.
- **Fixture-shape test** — every snapshot parses and carries `_captured`,
  `_command`, `_lastAttempt`. **And enforces §9's binding rules**: every entry
  under `models` has a `variants` key whose value is an array, never `null`; a
  minimum entry count is pinned. Without this, a writer bug that emits
  `variants: null` for a present model makes
  `tests/OpencodeVariantDeclared.Tests.ps1:105-114` read it as absent and skip
  it — silently disabling the guard, by the same mechanism as the 2026-08-26 →
  09-04 variant incident.
- **No network in the suite.** The repo has already had to fix a stated
  "no network or live backend spawning" property that was false.
- **Refresh is a separate, explicit command** that **runs the comparator and
  prints the report**. A refresh that only writes a file is not a detection
  event, and the moment a human is actually looking is the moment a verdict is
  worth most.

**What the staleness threshold does and does not buy.** It bounds *neglect*, not
drift. Effective detection latency is the time to the next refresh, so a
default-panel seat withdrawn the day after a capture stays green for up to
`MaxSnapshotAgeDays` — the `ox-alpha` harm at a larger multiplier. The threshold
is kept, but it is **not** the mechanism protecting the default panel; cadence
is, and default-panel backends need one materially tighter than the threshold.
Shipping the threshold *as if* it were the protection would be the over-claim §3
exists to prevent.

## 9. Migration: fold in the existing opencode fixture

`tests/fixtures/opencode-declared-variants.json` (captured 2026-09-04, 43
entries) already holds `opencode models --verbose` data. Two files holding the
same vendor data can disagree — the drift problem reproduced inside the drift
detector — so the new `models-opencode.json` supersedes it.

**Migrate by RE-PROBING, not by converting.** The old fixture holds variants
only; the §4.2 shape also carries `display`, `cost` and `status`, which a
conversion cannot invent. And stamping converted old data with a fresh
`_captured` would be §3's trap exactly; carrying the old date forward means
shipping a snapshot already older than the proposed 30-day policy on day one. A
fresh probe avoids both.

**The earlier draft claimed "its assertions do not change — only where it reads
from". That was false**, and the error was load-bearing. The old contract is
three-valued and its `_README` says so: `[...]` = declares these, `[]` = declares
none, `null` = absent from `opencode models`. Three assertions branch on it
(`:79-93`, `:105-114`, `:176-178`), and the sweep states why — *"absent is not
the same fact as 'declares nothing'"*. The accessor also changes
(`$Snap.declared.$mid` → `$Snap.models.$mid.variants`), so the assertions change.

Binding rules:

1. **Absence is key-absence under `models`**, and is additionally recorded
   positively in `notObserved` (§4.3) so "looked for and not found" is
   distinguishable from "never covered".
2. **Present-with-no-variants is `[]`**, never `null`. Enforced by the
   fixture-shape test (§8), not by convention.
3. The `_README` convention text is carried into the new file.
4. The test's accessors are rewritten and its absent-branch becomes a
   key-existence check. This is an assertion change and is described as one.

**Acceptance check:** a conversion-equivalence script that rebuilds the old
three-valued `declared` map from the new file and asserts key-set and per-model
array equality, run before the old fixture is deleted. An earlier draft said to
run "the old test against a converted fixture", which is impossible — the old
test reads `.declared` and would fail for reasons unrelated to correctness. That
sentence was a survivor of the retracted "assertions do not change" draft: the
same section-to-section drift this document has now produced twice, which is why
this revision was written as a whole rather than patched section by section.

This lands as its own commit so a regression is attributable.

## 10. Not in scope

- REST backends (`openaicompat` ×8, `anthropic` ×3, `geminiapi` ×2 — 13 of 25
  presets). Most expose an OpenAI-style `/v1/models`, but that needs API keys
  present, which makes coverage machine-dependent. §4.1/§4.2 is the extension
  point.
- Any automatic edit to `backends/_registry.json`.
- Any change to which models the default panel uses.

## 11. Known-unresolved

1. **`gemini-flash-35` is dead right now.** `agy models` lists 3.8/3.7/3.6/3.1-pro
   and no 3.5. `tests/SpecReview.Tests.ps1` still asserts it deliberately — that
   test pins what the registry *says*, and the registry is wrong in a way no
   existing test can see. This design closes that gap.
2. **Pricing comparison is deferred**, and with it the only field whose drift
   §2 calls highest-consequence. Closing it needs a defined mapping from
   opencode `cost{input,output,cache}` to registry
   `pricing{input_per_m,output_per_m}`, a unit convention, cache handling and an
   equality tolerance — none of which exist yet. **agy pricing cannot be closed
   this way at all**: `agy models` prints no rates, so `gemini` 3.8's inherited,
   unverified figure stays unverifiable by this mechanism and needs a different
   one.
3. **`MaxSnapshotAgeDays = 30` and `MaxModelCountDropFraction = 0.25` are
   declared policies**, not derived. See §3.
4. **The writer's stderr rule is under-specified.** "wrote to stderr in a way the
   parser does not recognise" is not implementable as prose; the allowed stderr
   patterns per backend need enumerating in the golden tests, and it is unstated
   whether `agy`'s ANSI `Fetching available models...` preamble arrives on stdout
   or stderr.
## External review — round 2 (4-seat panel, 2026-09-06)

`gemini` (Gemini 3.8 Flash High) · `opus` (Claude Opus 5) · `deepseek-flash`
(DeepSeek V4 Flash) · `muse-spark` (Muse Spark 1.3). All four returned; 0
citation warnings; `seat_containment: contained`.

Disposition per claim. Cross-seat agreement is recorded because three of the
eight were found independently by three seats.

| # | Claim | Seats | Disposition |
|---|---|---|---|
| 1 | `variant-undeclared` must be **error regardless of panel** — opencode does not validate variant names, so it is silent both by default and when named; downgrading it was a strictness regression against the shipping sweep | opus, deepseek-flash, muse-spark | **CONFIRMED** — verified verbatim at `tests/OpencodeVariantDeclared.Tests.ps1:3-19` ("SILENTLY IGNORED, not rejected... no runtime signal to check") and `:164-189` (sweeps the whole `_opencode_model_map`, `Should -BeNullOrEmpty`). §6 rewritten to key severity on **runtime loudness**, not panel membership. |
| 2 | `snapshot-missing` fails the build on day one: `claude` has presets (incl. default-panel `opus`) and can never have a snapshot | opus, gemini, muse-spark | **CONFIRMED** — §6 now exempts `fields.ids='unmeasured'` backends, which emit `backend-unmeasurable` *instead of* absence findings; `snapshot-missing` scoped to backends with a probe. |
| 3 | Comparator signature cannot produce two of its own findings: `Now` was not a parameter, and a merged `-DefaultPanel` array destroys the `default-panel-mismatch` it must detect | opus, gemini, muse-spark | **CONFIRMED** — §4.4 takes `-Now` and `-DefaultPanelSources <map>`. Root cause worth recording: the mismatch row was added during the spec self-review and not propagated to the signature — this document drifting against itself. |
| 4 | The snapshot writer had no acceptance gate, so a failed/partial probe stamps a fresh `_captured` (green) and emits missing models reported as `model-withdrawn` errors — §3's trap reached through the writer | opus | **CONFIRMED** — §4.3 is no longer "pure serialisation": refuses on non-zero exit, empty parse, or a model-count drop over `MaxModelCountDropFraction` (labelled a policy, like `MaxSnapshotAgeDays`), and records `exitCode`/`stderrExcerpt`/`rawLineCount`. New `snapshot-rejected` finding. |
| 5 | Migration claim "assertions do not change" is false, and it drops the fixture's three-valued contract (`[]` = declares none vs `null` = absent) | opus, gemini | **CONFIRMED** — §9 retracts the claim and adds four binding rules; absence is key-absence only, present-with-no-variants is `[]`. |
| 6 | Parsing is real logic trapped inside a network-only probe, making it untestable without a network — the `BroadScopeGate` failure this spec itself cites | muse-spark | **CONFIRMED** — split into §4.1 fetch (I/O) and §4.2 parse (pure, golden-stdout tests). The "comparator is the only real logic" claim is retracted. |
| 7 | `cost`/`status`/`display` are collected but no finding consumes them, while §5 called opencode pricing "checked" — a claim of verification with nothing behind it, and pricing is §2's own highest-consequence drift | deepseek-flash, muse-spark | **CONFIRMED** — §5 now distinguishes `compared` / `collected` / `unmeasured` / `n/a`; §6 gains `pricing-changed` (warning, human-applied). |
| 8 | The staleness threshold bounds neglect, not drift; and a refresh that only writes a file is not a detection event | deepseek-flash | **CONFIRMED** — §8 now requires refresh to run the comparator and print, and states plainly that cadence, not the threshold, protects the default panel. |

**Zero claims rejected this round.** That is unusual and is itself worth
flagging: it more likely means the spec had real slack than that the panel was
uncritical. Three of the eight were caught by three independent seats, which is
the cross-vendor redundancy the panel exists for.

---

## External review — round 3 (4-seat panel, 2026-09-06, era round 4)

Same panel. All four returned; 0 citation warnings; `seat_containment: contained`.
This round was asked specifically whether the round-2 fixes introduced new
defects or overshot. **Both happened, and the panel found both.**

| # | Claim | Seats | Disposition |
|---|---|---|---|
| 1 | `snapshot-rejected` is unemittable: a refused capture writes nothing, so the pure comparator has no input carrying it — and the diagnostic fields were recorded only on *accepted* writes, i.e. only when `exitCode` is 0 by construction | opus, gemini, muse-spark | **CONFIRMED** — the round-2 fix for claim 4 reintroduced the exact defect claim 3 removed. §4.3 now always writes a `_lastAttempt` header and refuses only the *model list*; the comparator reads the rejection from that block. |
| 2 | `backend-unmeasurable` cannot be emitted for `claude` from a `Snapshots` map — `claude` has no snapshot by construction, so iterating snapshots never enumerates it | gemini, muse-spark | **CONFIRMED** — §4.4 takes `-BackendCapabilities`, a static table listing every backend including those with no probe. |
| 3 | `pricing-changed` is unimplementable: opencode `cost{input,output,cache}` vs registry `pricing{input_per_m,output_per_m}` with no mapping, units, cache handling or tolerance | deepseek-flash, muse-spark | **CONFIRMED, and the round-2 fix is REVERTED.** Pricing returns to `collected`; `pricing-changed` is removed from v1 and the mapping is named in §11. As deepseek put it, shipping a `compared` claim with undefined semantics "is the exact offence Claim 7 was raised against" — the fix committed the offence it was fixing. |
| 4 | The writer's `MaxModelCountDropFraction` had no override: a legitimate vendor cull >25% is refused on every run, the old snapshot stands, staleness trips, no way forward | gemini, muse-spark | **CONFIRMED** — kept as a refusal that names its override, `-AcceptDrop`. |
| 5 | Panel membership is undefined exactly when the two sources disagree, yet `model-withdrawn` severity keys on it | opus | **CONFIRMED** — §6 states the union rule, failing toward error. |
| 6 | §9's acceptance check ("run the old test against a converted fixture") is impossible — the old test reads `.declared` and would fail for unrelated reasons; a survivor of the retracted draft | opus | **CONFIRMED** — replaced with a conversion-equivalence script. This is the second instance of section-to-section drift in this document, and the reason this revision was written whole rather than patched. |
| 7 | §9's binding rules had no test; a writer emitting `variants: null` for a present model would silently disable a shipping guard by the same mechanism as the 2026-08-26 variant incident | opus | **CONFIRMED** — §8's fixture-shape test now enforces rules 1 and 2 and pins a minimum entry count. |
| 8 | Rule 1 collapses "observed absent" into "never observed"; key-absence cannot distinguish a withdrawal from a truncated listing. Root cause: the writer receives only a parse result, so it *cannot* record absence positively — forced by the architecture, not chosen | opus | **CONFIRMED** — the writer is now given the registry's expected id set and records `notObserved` explicitly. |
| 9 | The `unmeasured`-keyed exemption did not actually cover `cmdc`, which is `collected`, so a literal implementation red-builds a backend nothing consumes | muse-spark | **CONFIRMED** — exemption is now `unmeasured OR unconsumed`. |

Folded in from Important: retired-preset handling per finding; `variant-undeclared`
must check **both** the chosen variant and the swept map; the reporter must carry
the age-qualified verdict; migrate-by-reprobe rather than convert; the parser no
longer reports its own coverage; the test plan covers every finding it defines;
the stderr rule is named as under-specified in §11.

**Round-2 stress-test, as requested.** Three of four seats independently judged a
round-2 fix to have overshot — opus and deepseek-flash on claim 7 (pricing),
gemini on claim 4 (the writer gate). Both judgements are accepted and both fixes
are now cut back. Nobody argued any round-2 finding should have been *rejected*;
the criticism was uniformly of the fixes, not the findings. That is a more useful
result than a rejection would have been, and it is what the round-2 note about an
8-for-8 confirmation rate was worried about.
