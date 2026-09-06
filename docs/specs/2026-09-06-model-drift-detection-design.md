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

## 4. Architecture — four units

Every unit holding logic is reachable without a network: parsing (§4.2) and the
comparator (§4.3) are pure, and only §4.1 touches the outside world.

**This revision SUBTRACTS.** Three review rounds added machinery, and the third
round showed each addition creating the next round's defect: a writer gate whose
refusal was invisible, an attempt-header to make it visible, and then a finding
that committing probe failures into a git fixture makes an offline build fail on
transient network weather. The rule applied below is that **an operational
failure is reported by the operation, not serialised into a checked-in file.**

### 4.1 Fetch (one per backend) — I/O only

```
Get-EraModelRaw-<Backend>  ->  @{ command; exitCode; stdout; stderr; capturedUtc }
```

Network. Never invoked from the test suite.

### 4.2 Parse (one per backend) — pure, unit-tested on golden stdout

```
ConvertFrom-EraModelListing-<Backend> -Stdout <string>
    ->  @{ models = @{ '<vendor id>' = @{ display; variants } } }
```

**Collect only what §6 consumes, plus `display` for human-readable reports.**
`status`, `limit` and `cost` are dropped from the shape: nothing compares them in
v1, and "collected but unbudgeted" is the very thing §5 forbids. When pricing
comparison is designed (§11), `cost` returns with a finding that reads it.

The parser does **not** report coverage — that is a static property of a
backend's CLI, not something a parser discovers, and a parser that reports its
own trustworthiness can be wrong in the direction that matters. Coverage is §5.

### 4.3 Comparator — pure function

```
Compare-EraModelRegistry
    -Registry             <obj>
    -Snapshots            <map: backend -> snapshot>
    -BackendCapabilities  <map: backend -> the STATIC row of §5>
    -DefaultPanelSources  <map: source-name -> string[]>
    -Now                  <datetime>
  -> findings[]
```

No file reads, no CLI calls, no clock of its own.

`-BackendCapabilities` is separate from `-Snapshots` because **`claude` has no
snapshot by construction**, so a comparator iterating snapshots could never
enumerate it. `-DefaultPanelSources` is a map, not a merged array: merging
destroys the disagreement `default-panel-mismatch` exists to report. `-Now` is
injected so staleness is testable on literals.

### 4.4 Refresh command — writes snapshots, reports its own failures

Runs fetch → parse → write, then **runs the comparator and prints the report**.
A refresh that only writes a file is not a detection event.

It **refuses to replace a model list** when the probe exited non-zero or the
parse yielded zero models, and **exits non-zero telling the operator so**. It
does *not* record the failure inside the snapshot. An earlier draft did, to make
the refusal visible to the offline comparator; the round-4 panel showed that
turns a transient network drop into a red offline build and dirties a committed
fixture with network weather. A failed refresh is an operational failure of the
refresh command, and the refresh command is what reports it.

A model-count drop beyond `MaxModelCountDropFraction` is a **warning printed to
the operator running the refresh**, not a refusal. The earlier hard refusal
deadlocked on a legitimate vendor cull; a human is already standing in front of
this command, and a 20-model withdrawal list is self-evidently suspicious to
them. `MaxModelCountDropFraction` remains a **POLICY, not a measurement** (§3),
proposed 0.25.

**`notObserved` is CUT.** It was added so absence could be recorded positively.
It did not work: it is computed at capture time against that day's registry and
compared later against the current one, so a preset added after the last capture
is absent from `models` *and* from `notObserved`, and would be reported as a
withdrawal of a model that exists. Nothing in §6 ever read it — the
`collected`-is-not-`compared` trap of §5, committed by the fix that added it.
Absence is key-absence under `models`, and the `model-withdrawn` message names
the snapshot's `_captured` date so a reader can see whether the preset predates
it.

### 4.5 Reporter

Consumes findings, prints, asserts. Offline and deterministic. Must carry §3's
age-qualified verdict — never a bare "no drift", always `no drift vs a snapshot
captured <date> (<n> days old)` — and must name every backend whose coverage is
`unmeasured` and every backend skipped as unconsumed.

## 5. Coverage is a static table, and `collected` is not `compared`

A field the probe can see but which no §6 finding consumes is **not** checked.

- `compared` — a §6 finding branches on it;
- `collected` — recorded for human reading, nothing compares it;
- `unmeasured` — this backend's CLI cannot express it;
- `n/a` — no such concept for this backend.

| Backend | Command | probe? | consumed? | ids | display | variants |
|---|---|---|---|---|---|---|
| `opencode` | `opencode models --verbose` | yes | yes | **compared** | collected | **compared** |
| `agy` | `agy models` | yes | yes | **compared** | collected | n/a (tier is in the id) |
| `cmdc` | `cmdc --list-models` | yes | **no** | collected | n/a | n/a |
| `claude` | *(none exists)* | **no** | yes | **unmeasured** | unmeasured | unmeasured |

`probe?` and `consumed?` are columns, not prose. An earlier draft stated the
exemption rule in §6 as "unmeasured OR unconsumed" while the table carried no
consumption column, so a literal implementer had nothing to branch on.

This table is the `-BackendCapabilities` input, **static and hand-maintained**.
§8 pins its completeness: a backend the registry references with no row here
would otherwise produce *zero* findings — a clean bill of health for a backend
nobody looked at, which is §1's shape inside the detector.

**Pricing is absent from this table in v1.** Round 2 correctly said calling it
"checked" while nothing compared it was a false claim; round 3's fix promoted it
to `compared` with no field mapping, units, cache handling or tolerance, which
committed the same offence at one remove. It is now not collected at all (§4.2),
and the mapping is named as future work (§11). This costs nothing in evidence
terms: pricing is `unmeasured` for agy and cmdc anyway, and the one figure this
repo *knows* is wrong — gemini 3.8's, inherited unverified from 3.6 — is on an
agy preset and invisible to an opencode `cost` comparison either way.

## 6. Findings and severity

| Finding | Meaning | Severity |
|---|---|---|
| `model-withdrawn` | a **consumed** backend's registry preset names an id absent from `models` | **error** if in the default panel, else **warning** |
| `variant-undeclared` | the registry's variant map lists a variant the model does not declare | **error, always** |
| `retired-withdrawn` | a `retired` preset's model is gone | **warning** (see below) |
| `snapshot-stale` | a **consumed** backend's `_captured` is older than `MaxSnapshotAgeDays` | **error** |
| `snapshot-missing` | no snapshot for a backend with `probe? = yes` and `consumed? = yes` | **error** |
| `backend-unmeasurable` | `probe? = no` (only `claude`) | **info**, always emitted |
| `backend-unconsumed` | `consumed? = no` (only `cmdc`) | **info**, always emitted |
| `default-panel-mismatch` | the default-panel sources disagree | **error** |

`snapshot-rejected` and `model-unconsumed` are **CUT**. The first belonged to the
refresh command, which now reports its own failures (§4.4). The second would have
emitted ~68 info rows per run from cmdc's unconsumed snapshot alone.

### Two exemptions, keyed on two different columns

An earlier draft collapsed these into one rule keyed on `unmeasured`, which was
then claimed to cover `cmdc` — whose ids are `collected`, not `unmeasured`.
Calling collected data "unmeasurable" is itself the instrument-for-subject
substitution this design exists to prevent, so they are now separate:

- **`probe? = no`** (`claude`) → `backend-unmeasurable`, and no absence or
  staleness findings. Four of era's 25 presets are claude-backed and permanently
  unverifiable this way; the report says so on every run.
- **`consumed? = no`** (`cmdc`) → `backend-unconsumed`, and no absence or
  staleness findings. Its snapshot is captured so the data exists when a backend
  is written; nothing compares it, and it must not red-build the suite by ageing
  past the staleness threshold.

§3's staleness rule is therefore scoped to **consumed** backends.

### Severity keys on runtime loudness, not the default panel alone

An earlier draft keyed everything on panel membership, reasoning a stale
non-default preset *"fails loudly at the vendor when named"*. **True for
withdrawal, false for variants**, and the counter-evidence ships here:

> `tests/OpencodeVariantDeclared.Tests.ps1:3-19` — *"opencode DOES NOT VALIDATE
> VARIANT NAMES... SILENTLY IGNORED, not rejected... There is no runtime signal
> to check, which is why the guard has to be a test."*

A withdrawn model exits non-zero with `Model not found`. An undeclared variant
exits 0 and returns a normal-looking review at the wrong reasoning effort.

**`variant-undeclared` checks the variant MAP, not era's chosen variant.** The
map sweep is strictly stronger — it covers every listed variant, including inert
entries one preference-loop edit away from live, which is why
`tests/OpencodeVariantDeclared.Tests.ps1:164-189` sweeps the whole map. Checking
the *chosen* variant would additionally require the comparator to know era's
preference order, which lives in `backends/opencode.ps1` and is already
reimplemented once in that test — reproducing inside the detector the
two-copies-of-one-rule hazard the test itself warns about.

### Panel membership when the sources disagree

Membership is the **UNION** of the sources. It is undefined exactly during the
incident `default-panel-mismatch` reports, so it fails toward error.

### Retired presets

`retired` is read by tests and by **nothing at runtime** — which is why the
`ox-alpha` preset was deleted rather than left flagged. So a silent exemption
would mark green a preset that still dispatches and still fails at the vendor,
which is the `ox-alpha` incident exactly. A retired preset whose model is gone
therefore emits `retired-withdrawn` (warning), not silence.
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

- **Comparator tests** — pure, on literals, TDD, red first. One per finding in
  §6, including both exemptions, the union rule for a disagreeing panel, and
  `retired-withdrawn`.
- **Parser tests** — pure, on committed golden stdout per backend, including the
  ANSI preamble `agy` emits and whichever stream it arrives on (§11).
- **Capabilities-completeness test** — the §5 table's backend set equals the set
  of backends the registry references. Without it, a new backend with no row
  produces zero findings and reads as healthy.
- **Fixture-shape test** — every snapshot parses and carries `_captured` and
  `_command`. Shape rules are **per-backend**: `variants` must be an array and
  never `null` only for backends whose §5 row says `variants` is `compared`
  (opencode). Applying it universally would force `agy` and `cmdc` — whose
  variants are `n/a` — to fake `[]`, which then feeds false variant checks.
  **No minimum entry count**: a count floor here is a second hard gate with no
  override, and would red-build a legitimate cull that the refresh command
  already warned a human about.
- **No network in the suite.** The repo has already had to fix a stated "no
  network or live backend spawning" property that was false.

**What the staleness threshold does and does not buy.** It bounds *neglect*, not
drift. Effective detection latency is the time to the next refresh, so a
default-panel seat withdrawn the day after a capture stays green for up to
`MaxSnapshotAgeDays` — the `ox-alpha` harm at a larger multiplier. It is kept,
but cadence protects the default panel, not the threshold. Shipping the
threshold *as if* it were the protection would be the over-claim §3 prevents.

## 9. Migration: fold in the existing opencode fixture

`tests/fixtures/opencode-declared-variants.json` (captured 2026-09-04, 43
entries) holds `opencode models --verbose` data. Two files holding the same
vendor data can disagree — the drift problem inside the drift detector — so
`models-opencode.json` supersedes it.

**Migrate by re-probing.** The old fixture holds variants only; a conversion
cannot invent `display`. Stamping converted old data with a fresh `_captured`
would be §3's trap; carrying the old date forward ships a snapshot already older
than the 30-day policy on day one.

**The acceptance check does not compare the new capture to the old fixture.**
Two earlier drafts tried and both were wrong — the first ran the old test against
a converted file it cannot read, the second asserted key-set equality between a
fresh probe and a snapshot taken days earlier, which asserts vendor stability:
the precise thing this design exists to disprove, and a failure that fires
exactly when the tool is working. Instead, split it:

1. **Parser correctness** is verified in a golden test against the *committed
   2026-09-04 stdout capture* — a fixed input with a fixed expected output, which
   is the only comparison that is legitimately an equality.
2. **The fresh capture** is accepted on schema validity plus every currently
   active preset resolving.
3. **Any difference** between the old fixture's `declared` map and the new
   capture is printed as a drift report for a human to sign off — it is
   information, not an assertion.

The old contract was three-valued and its `_README` says so: `[...]` = declares
these, `[]` = declares none, `null` = absent. Three assertions branch on it
(`:79-93`, `:105-114`, `:176-178`), and the accessor changes
(`$Snap.declared.$mid` → `$Snap.models.$mid.variants`), so the assertions change.
An earlier draft claimed they did not; that is retracted. Carry the `_README`
convention text into the new file, and keep absence as key-absence.

This lands as its own commit so a regression is attributable.

## 10. Not in scope

- REST backends (`openaicompat` ×8, `anthropic` ×3, `geminiapi` ×2 — 13 of 25
  presets). Most expose an OpenAI-style `/v1/models`, but that needs API keys,
  making coverage machine-dependent. §4.1/§4.2 is the extension point.
- Any automatic edit to `backends/_registry.json`.
- Any change to which models the default panel uses.

## 11. Known-unresolved

1. **`gemini-flash-35` is dead right now.** `agy models` lists 3.8/3.7/3.6/3.1-pro
   and no 3.5. `tests/SpecReview.Tests.ps1` still asserts it deliberately — it
   pins what the registry *says*, and the registry is wrong in a way no existing
   test can see. This design closes that gap.
2. **Pricing comparison is deferred, and pricing is not even collected in v1.**
   Closing it needs a defined mapping from opencode `cost{input,output,cache}` to
   registry `pricing{input_per_m,output_per_m}`, a unit convention, cache
   handling and an equality tolerance. **agy pricing cannot be closed this way at
   all** — `agy models` prints no rates — so gemini 3.8's inherited, unverified
   figure needs a different mechanism entirely. This is the largest known gap:
   §2 calls pricing the highest-consequence drift and v1 does not check it.
3. **`MaxSnapshotAgeDays = 30` and `MaxModelCountDropFraction = 0.25` are
   declared policies**, not derived. See §3.
4. **`agy`'s ANSI `Fetching available models...` preamble** — it is unstated
   whether it arrives on stdout or stderr, and the golden parser test must pin
   whichever it is.
5. **`retired` is enforced by nothing at runtime.** `retired-withdrawn` reports
   the symptom; the underlying gap is that era will still dispatch a retired
   preset. Fixing that is a separate change to era, not to this detector.
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

---

## External review — round 4 (4-seat panel, 2026-09-06, era round 5)

All four returned; `seat_containment: contained`; 1 citation warning, translated
by era's own checker (both opencode seats were on the read-tool path this round,
the bundle having grown past the 51,200-byte attach cap).

This round was asked whether round 3's fixes overshot **and what should be cut**.
Three of four seats answered the cut question substantively. The verdict was that
the design had accreted: each round's fix was creating the next round's defect.
**This revision subtracts.**

| # | Claim | Seats | Disposition |
|---|---|---|---|
| 1 | Committing `_lastAttempt` probe failures into a git fixture turns a transient network drop into a red offline build and dirties a checked-in file with network weather — round 3's fix overshot from "unemittable" to "fail-closed" | gemini, muse-spark | **CONFIRMED — `_lastAttempt` and `snapshot-rejected` CUT.** A failed refresh is an operational failure of the refresh command, which now exits non-zero and says so (§4.4). |
| 2 | `notObserved` is never read by any finding, and creates a new bug: a preset added after the last capture is absent from `models` AND from `notObserved`, so it reports as a withdrawal of a model that exists | opus, gemini, muse-spark (deepseek dissented, wanting it kept with real semantics) | **CONFIRMED — CUT.** It was added to make absence positive and nothing consumed it: §5's own `collected`-is-not-`compared` trap, committed by the fix that added it. Absence is key-absence; the finding message names the `_captured` date so a reader can see whether the preset predates it. |
| 3 | The `unmeasured OR unconsumed` exemption is incoherent: `cmdc`'s ids are `collected`, so labelling it `backend-unmeasurable` is factually false, and §5's table had no consumption column for an implementer to branch on | opus, gemini, deepseek-flash, muse-spark | **CONFIRMED, all four seats.** Split into two exemptions on two new table columns (`probe?`, `consumed?`) with two findings: `backend-unmeasurable` and `backend-unconsumed`. `model-unconsumed` CUT — it would have emitted ~68 info rows per run from cmdc alone. |
| 4 | §9's acceptance check asserts key-set equality between a fresh probe and a 2026-09-04 snapshot — i.e. asserts vendor stability, the thing this design exists to disprove, failing exactly when the tool is working | opus, gemini | **CONFIRMED.** opus notes this is the third generation of a defect in the same paragraph. Split into golden-test parser equality (fixed input, legitimately an equality), schema+resolution acceptance for the live capture, and a printed drift report for a human. |
| 5 | The fixture-shape test's pinned minimum entry count is a second hard gate with no override, re-creating the deadlock `-AcceptDrop` was added to remove | opus | **CONFIRMED — count floor CUT.** The drop check also demoted from refusal to a warning printed to the human already standing in front of the refresh. |
| 6 | The universal "`variants` is an array, never null" shape rule contradicts the coverage table, where `agy`/`cmdc` variants are `n/a` — an implementer must fake `[]` or red-build them | muse-spark | **CONFIRMED** — shape rules are per-backend, applying only where `variants` is `compared`. |
| 7 | The static capabilities table is hand-maintained with nothing asserting completeness: a backend with no row produces zero findings and reads as healthy | opus, muse-spark | **CONFIRMED** — §8 adds a completeness test. This was machinery added in round 3 to fix that exact shape of bug, carrying the bug. |
| 8 | The comparator cannot compute the chosen-variant contract without era's preference order, which lives in `backends/opencode.ps1` and is already reimplemented once in the test | gemini, muse-spark | **CONFIRMED** — chosen-variant check CUT; the map sweep is strictly stronger and avoids a second copy of the preference rule. |
| 9 | The retired exemption marks green a preset that still dispatches, since `retired` is enforced by nothing at runtime — the `ox-alpha` shape exactly | muse-spark | **CONFIRMED** — `retired-withdrawn` (warning) replaces silent exemption; the underlying runtime gap is named in §11. |
| 10 | `status`/`limit`/`cost` are collected while nothing consumes them | deepseek-flash, muse-spark | **CONFIRMED** — dropped from the parse shape; `cost` returns when a finding reads it. |

**Net effect: seven things removed, two added.** Removed — `_lastAttempt`,
`snapshot-rejected`, `notObserved`, `model-unconsumed`, the shape test's count
floor, the chosen-variant check, and `status`/`limit`/`cost` from the parse
shape. Added — two table columns, and a completeness test for the table.

**On the oscillation.** Rounds 2→3→4 each fixed the previous round's fix on the
same sub-problem (the writer's failure path). That is the signature of a
convergence loop chasing its own tail, and it is why this revision was framed as
subtraction with an explicit "what should be cut" question rather than another
pass of the same kind. The question earned its place: three seats used it, and
seven of the ten dispositions above are deletions.
