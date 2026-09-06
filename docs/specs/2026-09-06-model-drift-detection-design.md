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
parsing (§4.2), the writer's acceptance gate (§4.3) and the comparator (§4.4) are
all pure or injectable, and only §4.1 touches the outside world. The earlier
draft drew four units and claimed the comparator was "the only real logic" — it
was not, because parsing three dissimilar CLI formats was buried inside the
network-only probe.

### 4.1 Fetch (one per backend) — I/O only, no parsing

Runs the vendor CLI and returns **raw stdout plus process facts**. Nothing else.
Network. Never invoked from the test suite.

```
Get-EraModelRaw-<Backend>  ->  @{ command; exitCode; stdout; stderr; capturedUtc }
```

### 4.2 Parse (one per backend) — **pure, unit-tested on golden stdout**

Raw stdout → normalised model map. **No I/O, so it is testable on committed
golden literals with no network.**

```
ConvertFrom-EraModelListing-<Backend> -Stdout <string>  ->  @{
    models = @{ '<vendor model id>' = @{ display; variants; cost; status } }
    fields = @{ ids='compared'; display='collected'; variants='n/a'; pricing='unmeasured' }
}
```

**Splitting fetch from parse is not tidiness.** §7 shows three genuinely
different formats — an ANSI preamble plus TAB pairs, a JSON stream, and
whitespace-column text with section headers. That is real logic, and leaving it
inside a network-only function makes it untestable without a network — the
`BroadScopeGate` failure this spec cites at §8 as a thing to avoid, reproduced.
The earlier draft's claim that the comparator was "the only real logic" was
false and is retracted.

### 4.3 Snapshot writer — **has an acceptance gate; it is not pure serialisation**

Parse result → `tests/fixtures/models-<backend>.json`.

**A writer that always writes reproduces §3 inside the detector.** If a probe
runs unauthenticated, times out, hits a truncated list, or the CLI is missing,
a naive writer stamps a fresh `_captured` — clearing `snapshot-stale`, turning
the build green — and emits a snapshot missing most models, which the comparator
then reports as `model-withdrawn` **errors** against the registry. That is a
failure of the instrument published as a fact about the subject: exactly what §3
says this design exists to prevent, arriving through the writer instead of
through the clock.

So the writer **refuses to write** when:

- the probe exited non-zero, or wrote to stderr in a way the parser does not
  recognise;
- the parse yields zero models;
- the model count fell by more than `MaxModelCountDropFraction` versus the
  existing snapshot for that backend.

The snapshot records `exitCode`, `stderrExcerpt` and `rawLineCount` so a reader
can tell a real vendor change from a broken capture. **`MaxModelCountDropFraction`
is a POLICY, not a measurement**, and carries the same labelling obligation as
`MaxSnapshotAgeDays` (§3). Proposed initial value **0.25**.

### 4.4 Comparator — pure function

```
Compare-EraModelRegistry
    -Registry            <obj>
    -Snapshots           <map: backend -> snapshot>
    -DefaultPanelSources <map: source-name -> string[]>
    -Now                 <datetime>
  -> findings[]
```

No file reads, no CLI calls, **no clock of its own** — `Now` is injected so the
staleness finding is testable on literals.

`-DefaultPanelSources` is a **map, not a merged array**. The earlier draft passed
`-DefaultPanel <string[]>`, which made `default-panel-mismatch` (§6) impossible
to emit: merging the two sources destroys the disagreement the finding exists to
report. That row was added during a self-review pass and not propagated to the
signature — a drift between two parts of this document, which is the failure
class the document is about.

### 4.5 Test / reporter

Consumes findings, prints the report, asserts. Offline and deterministic.

### 4.4 Test / reporter

Consumes findings, prints the report, asserts. Offline and deterministic.

## 5. Per-field capability, not per-backend status

Coverage genuinely differs per backend, so a single per-backend "ok" would lie.
Measured 2026-09-06:

**`collected` is not `compared`, and the earlier draft conflated them.** A field
the probe can see but which no finding in §6 consumes is not being checked —
calling it "checked" in the report is the §3 trap committed by this design
itself: a claim of verification with no verification behind it. So the states are:

- `compared` — the probe sees it **and** a §6 finding branches on it;
- `collected` — the probe sees it, nothing compares it yet (recorded for later);
- `unmeasured` — this probe cannot see it;
- `n/a` — this backend has no such concept.

| Backend | Command | ids | display | variants | pricing |
|---|---|---|---|---|---|
| `opencode` | `opencode models --verbose` | **compared** | collected | **compared** | **compared** (JSON `cost`) |
| `agy` | `agy models` | **compared** | collected | n/a (tier is in the id) | **unmeasured** |
| `cmdc` | `cmdc --list-models` | collected | n/a (prints a capability description, not a display name) | n/a | **unmeasured** |
| `claude` | *(none exists)* | **unmeasured** | unmeasured | unmeasured | unmeasured |

`cmdc` is `collected`, not `compared`: nothing consumes it, because no era
backend dispatches to it (§7).

**Pricing is now `compared` where it can be, because it is the highest-consequence
drift in the design.** §2's first argument against auto-updating is that pricing
feeds the spend guard — so a design that collects opencode's `cost` and compares
nothing is blind to the drift it says matters most. §6 gains `pricing-changed`.
Where pricing is `unmeasured` (agy, cmdc) the report must say so on every run;
that gap is real and is named in §11.

**`claude` is permanently `unmeasured` by this mechanism.** The CLI has no
enumeration subcommand — verified against its full `--help`. Four of era's 25
presets are claude-backed. The report must say so on every run; a reader must
never infer that claude's model ids were verified.

## 6. Findings and severity

The comparator emits findings, each with a severity:

| Finding | Meaning | Severity |
|---|---|---|
| `model-withdrawn` | registry preset names an id absent from the snapshot | **error** if the preset is in the default panel, else **warning** |
| `variant-undeclared` | registry asks for a variant the model does not declare | **error, always** — see below |
| `pricing-changed` | snapshot `cost` differs from registry `pricing` where pricing is `compared` | **warning** (never auto-applied, §2) |
| `snapshot-stale` | `_captured` older than `MaxSnapshotAgeDays` | **error** |
| `snapshot-missing` | no snapshot for a backend **that has a probe** | **error** |
| `snapshot-rejected` | writer refused a capture (§4.3) and the old snapshot stands | **error** |
| `backend-unmeasurable` | backend has no enumeration (claude) | **info**, always emitted |
| `model-unconsumed` | snapshot lists models no preset uses | **info** (this is normal) |
| `default-panel-mismatch` | `config/defaults.json` and `$EraShippedPanel` disagree | **error** |

### Severity is keyed on runtime loudness, not on the default panel alone

The earlier draft keyed every severity on default-panel membership, with the
rationale that a stale non-default preset *"fails loudly at the vendor when
someone names it"*. **That is true for withdrawal and false for variants**, and
the difference is measured in this repo:

> `tests/OpencodeVariantDeclared.Tests.ps1:3-19` — *"opencode DOES NOT VALIDATE
> VARIANT NAMES... an undeclared variant is SILENTLY IGNORED, not rejected...
> There is no runtime signal to check, which is why the guard has to be a test."*

A withdrawn model produces `Model not found` and a non-zero exit — loud. An
undeclared variant produces exit 0 and a normal-looking review at the wrong
reasoning effort — **silent in the default case and silent when named**. So the
correct discriminator is *"does this failure announce itself at runtime?"*, not
*"is this preset in the default panel?"*.

Keying variants on the panel would also have been a **strictness regression
against a test already shipping**: that file's sweep (`:164-189`) iterates the
whole `_opencode_model_map` — every provider, every entry, not the panel — and
asserts `$problems | Should -BeNullOrEmpty`, on the stated grounds that *"an
inert undeclared name is one preference-loop edit away from being a live one"*.
The 2026-09-04 sweep found four such entries, all inert and all non-default, and
corrected all four. A comparator that downgraded those to warnings would
contradict the test it is meant to generalise.

`model-withdrawn` keeps panel-keyed severity, because there the "loud at the
vendor" argument does hold, and because failing the build on every deprecated
non-default model would be the `0c6be1d` "warning nobody reads" failure in build
form. `tests/RegistryCapabilities.Tests.ps1` already carries that convention in
its *"the default panel contains no RETIRED preset"* test.

### Unmeasurable backends are exempt from absence findings

`claude` has four presets, one of them the default-panel `opus`, and can never
have a snapshot (§5). Under the earlier draft that made `snapshot-missing` fire
as an error on day one, and a stub empty snapshot would have made every claude
preset a `model-withdrawn` error instead. Both were unconditional red builds for
a backend behaving exactly as designed.

So: a backend whose `fields.ids` is `unmeasured` emits `backend-unmeasurable`
**instead of** — never alongside — `snapshot-missing`, `snapshot-stale` and
`model-withdrawn`. The same exemption covers REST backends (deferred, §10) and
`cmdc` (no era backend consumes it, §7). `snapshot-missing` applies only to a
backend that **has a probe**.

The default panel is read from **both** `config/defaults.json` and
`$EraShippedPanel` in `runtimes/_era-defaults.ps1`, which are required to stay in
lockstep; both are passed to the comparator separately (§4.4) so a mismatch
between them is itself a finding.

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

- **Comparator tests** — pure, on literals. TDD, red first. Cover: withdrawn
  model in default panel (error) vs outside it (warning); undeclared variant;
  stale snapshot; missing snapshot; unmeasurable backend always reported;
  default-panel sources disagreeing.
- **Fixture-shape test** — every snapshot parses and carries `_captured`,
  `_command`, `fields`.
- **No network in the suite.** The repo has already had to fix a stated
  "no network or live backend spawning" property that was false
  (`BroadScopeGate` was spawning real `opencode`). Probes are invoked only by
  the refresh command.
- **Refresh is a separate, explicit command**, run by a human when a seat
  misbehaves or the staleness test goes red. **Refresh RUNS THE COMPARATOR and
  prints the report** — it does not merely write a file. A refresh that only
  writes is not a detection event, so the one moment a human is actually looking
  would otherwise produce no verdict, and drift found at capture time would wait
  for a later test run to be reported.

**What the staleness threshold does and does not buy.** It bounds *neglect*, not
drift. Effective detection latency is the time to the next refresh, so a
default-panel seat withdrawn the day after a capture stays green for up to
`MaxSnapshotAgeDays` — the ox-alpha harm (§1) at a larger multiplier, and that is
the error-grade case. The threshold is necessary and is kept, but it is **not**
the mechanism protecting the default panel; refresh cadence is. Default-panel
backends therefore need a cadence materially tighter than the threshold, by a
scheduled probe or by refreshing on a schedule the operator sets. Naming that
cadence is left to implementation, but shipping the threshold *as if* it were the
protection would be the same over-claim §3 exists to prevent.

## 9. Migration: fold in the existing opencode fixture

`tests/fixtures/opencode-declared-variants.json` (captured 2026-09-04, 43
entries) already holds data from `opencode models --verbose` — the same command
this design runs. Keeping both means two files hold the same vendor data and can
disagree, which is the drift problem reproduced inside the drift detector.

So: the new `models-opencode.json` supersedes it, and
`tests/OpencodeVariantDeclared.Tests.ps1` is repointed at the new file.

**The earlier draft claimed "its assertions do not change — only where it reads
from". That was wrong, and the error was load-bearing.** The old fixture's
contract is *three-valued*, and its `_README` says so explicitly: `[...]` =
declares these, `[]` = declares none, `null` = **absent from `opencode models`**.
Three assertions branch on that distinction (`:79-93`, `:105-114`, `:176-178`),
and the sweep comment states the reason — *"absent is not the same fact as
'declares nothing', and the snapshot records the difference (null vs [])"*.

The §4.2 shape (`models = @{ id = @{ ... } }`) has no representation for "absent"
except a missing key, and nothing in the earlier draft stopped the writer
emitting `variants: null` for a **present** model that declares none — which
would collapse "present, declares nothing" into "absent" and silently disable the
`:105-114` guard. The accessor changes shape too
(`$Snap.declared.$mid` → `$Snap.models.$mid.variants`), so the assertions
demonstrably change.

Binding rules for the migration:

1. **Absence is key-absence only.** A model absent from `opencode models` has no
   key under `models`. The writer must never emit a present model with
   `variants: null`.
2. **Present-with-no-variants is `[]`**, never `null`.
3. The `_README` convention text is carried into the new file, not dropped.
4. The test's accessors are rewritten to `.models.<id>.variants`, and the
   "absent" branch becomes a key-existence check. This is an assertion change and
   is described as one.

This is the one step that touches a currently-passing test, and it lands as its
own commit so a regression is attributable. A pre-migration run of the old test
against a converted fixture is the acceptance check.

## 10. Not in scope

- REST backends (`openaicompat` ×8, `anthropic` ×3, `geminiapi` ×2 — 13 of 25
  presets). Most expose an OpenAI-style `/v1/models`, but that needs API keys
  present, which makes coverage machine-dependent. Deferred to a later phase; the
  probe contract in §4.1 is the extension point.
- Any automatic edit to `backends/_registry.json`.
- Any change to which models the default panel uses.

## 11. Known-unresolved

1. **`gemini-flash-35` is dead right now.** `agy models` lists 3.8/3.7/3.6/3.1-pro
   and no 3.5. `tests/SpecReview.Tests.ps1` still asserts it, deliberately — that
   test pins what the registry *says*, and the registry is wrong in a way no
   existing test can see. This design closes that gap; the assertion should be
   revisited when it lands.
2. **Pricing for `gemini` 3.8 is inherited from 3.6 and unverified**, and no
   probe in this design can verify it, because `agy models` prints no rates.
   Whatever mechanism does verify agy pricing is out of scope here and should be
   named as a separate problem rather than assumed solved by this work.
3. **`MaxSnapshotAgeDays = 30` is a declared policy**, not derived. See §3.

---

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
