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

Deliberately separated so the only unit with real logic has no I/O.

### 4.1 Probe (one per backend)

Runs the vendor CLI, returns a normalised object. **Network. Never invoked from
the test suite.**

```
Get-EraModelSnapshot-<Backend>  ->  @{
    backend    = 'agy'
    command    = 'agy models'
    capturedUtc= '2026-09-06'
    models     = @{ '<vendor model id>' = @{ display; variants; cost; status } }
    fields     = @{ ids='checked'; display='checked'; variants='n/a'; pricing='unmeasured' }
}
```

`fields` is the honesty mechanism (§5). A probe that cannot see a field says so
rather than omitting it.

### 4.2 Snapshot writer

Probe result → `tests/fixtures/models-<backend>.json`. Pure serialisation.

### 4.3 Comparator — **pure function, the only real logic**

```
Compare-EraModelRegistry -Registry <obj> -Snapshots <map> -DefaultPanel <string[]>
    -> findings[]
```

No file reads, no CLI calls, no clock — the age check is a separate finding
produced by passing `Now` in. Fully unit-testable on literals, the same way
`Compare-EraSeatContainment` is.

### 4.4 Test / reporter

Consumes findings, prints the report, asserts. Offline and deterministic.

## 5. Per-field capability, not per-backend status

Coverage genuinely differs per backend, so a single per-backend "ok" would lie.
Measured 2026-09-06:

| Backend | Command | ids | display | variants | pricing |
|---|---|---|---|---|---|
| `opencode` | `opencode models --verbose` | checked | checked | **checked** | **checked** (JSON `cost`) |
| `agy` | `agy models` | checked | checked | n/a (tier is in the id) | **unmeasured** |
| `cmdc` | `cmdc --list-models` | checked | **n/a** (prints a capability description, not a display name) | n/a | **unmeasured** |
| `claude` | *(none exists)* | **unmeasured** | unmeasured | unmeasured | unmeasured |

Three states, never two: `checked` / `unmeasured` / `n/a`. `unmeasured` means
"this probe cannot see this field"; `n/a` means "this backend has no such
concept". Collapsing either into "ok" reintroduces §3.

**`claude` is permanently `unmeasured` by this mechanism.** The CLI has no
enumeration subcommand — verified against its full `--help`. Four of era's 25
presets are claude-backed. The report must say so on every run; a reader must
never infer that claude's model ids were verified.

## 6. Findings and severity

The comparator emits findings, each with a severity:

| Finding | Meaning | Severity |
|---|---|---|
| `model-withdrawn` | registry preset names an id absent from the snapshot | **error** if the preset is in the default panel, else **warning** |
| `variant-undeclared` | registry asks for a variant the model does not declare | **error** if default panel, else **warning** |
| `snapshot-stale` | `_captured` older than `MaxSnapshotAgeDays` | **error** |
| `snapshot-missing` | no snapshot file for a backend that has presets | **error** |
| `backend-unmeasurable` | backend has no enumeration (claude) | **info**, always emitted |
| `model-unconsumed` | snapshot lists models no preset uses | **info** (this is normal) |
| `default-panel-mismatch` | `config/defaults.json` and `$EraShippedPanel` disagree | **error** |

**Why severity is keyed on the default panel.** The measured harm was a dead
seat in the default panel — every bare `/era` dispatching a model that could not
run, for days. A stale *non-default* preset only bites someone who names it
explicitly, and it fails loudly at the vendor when they do. Failing the build on
any drift would turn an unrelated commit red because a vendor deprecated
something overnight — the `0c6be1d` "a warning that fires on every healthy round
is a warning nobody reads" failure, in build form.

This is not a new convention: `tests/RegistryCapabilities.Tests.ps1` already has
a test whose entire job is *"the default panel contains no RETIRED preset"*.
Graduated severity keyed on the default panel is the existing pattern here.

The default panel is read from **both** `config/defaults.json` and
`$EraShippedPanel` in `runtimes/_era-defaults.ps1`, which are required to stay in
lockstep; a mismatch between them is itself a finding.

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
  misbehaves or the staleness test goes red.

## 9. Migration: fold in the existing opencode fixture

`tests/fixtures/opencode-declared-variants.json` (captured 2026-09-04, 43
entries) already holds data from `opencode models --verbose` — the same command
this design runs. Keeping both means two files hold the same vendor data and can
disagree, which is the drift problem reproduced inside the drift detector.

So: the new `models-opencode.json` supersedes it, and
`tests/OpencodeVariantDeclared.Tests.ps1` is repointed at the new file. Its
assertions do not change — only where it reads from. This is the one step that
touches a currently-passing test, and it should land as its own commit so a
regression is attributable.

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
