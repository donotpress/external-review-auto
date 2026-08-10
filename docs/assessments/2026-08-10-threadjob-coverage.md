# The ThreadJob dispatcher was testable all along

**Date:** 2026-08-10
**Origin:** `tests/README.md` — *"`workflow.ps1::Invoke-ReviewerDispatch` ThreadJob behavior — ThreadJobs are hard to mock and the integration is exercised by every smoke test."*
**Verdict:** the premise was wrong. No mocking is needed and no seam had to be added. **22 tests added; two production defects found in the process.**

## Why it did not need mocking

`Invoke-ReviewerDispatch` already accepts `-SkillRootOverride`, and it resolves
every adapter by convention:

```powershell
$skillRoot   = if ($SkillRootOverride) { $SkillRootOverride } else { $PSScriptRoot }
$adapterPath = Join-Path $skillRoot "backends/$($modelInfo.backend).ps1"
$fnName      = "Invoke-$((Get-Culture).TextInfo.ToTitleCase($modelInfo.backend))Review"
```

So a temp directory containing `backends/fake.ps1` with `Invoke-FakeReview` is a
complete skill root. Point `-SkillRootOverride` at it and the **real** dispatcher
runs: real `Start-ThreadJob`, real poll loop, real straggler logic, real
`Receive-Job` collection. No network, no API key, no production change.

The fake adapter writes every argument it received to a JSON file, so the tests
assert what the dispatcher *actually sent* rather than what the call site looks
like it sends. Naming a fake backend `agy` also exercises the agy-only branches
(`-ResolvedAgyModel`, per-reviewer `--model` resolution) without touching the
real agy adapter.

## Defect 1 — `Preset` stamping threw on any extra output

```powershell
$h = & $fnName @commonArgs
$h.Preset = $mi.preset      # throws when $h is an array
```

An adapter — or any module it dot-sources — writing to the **success** stream
makes `$h` an array. Assigning a property to an array throws:

```
The property 'Preset' cannot be found on this object.
```

The surrounding `catch` then recorded the reviewer as an *"Adapter exception"*.
Consequence: the collection path's documented defence —

```powershell
# ...Filter to the last hashtable/PSCustomObject to be defensive.
```

— **could never run**, because the job never returned the array it was meant to
filter. `Error='no-structured-output'` was unreachable for the same reason.

## Defect 2 — the filter predicate filtered nothing

```powershell
Where-Object { $_ -is [hashtable] -or $_ -is [pscustomobject] }
```

`-is [pscustomobject]` is **True for every pipeline item**, because
`Where-Object` binds `$_` as a PSObject-wrapped value. It behaves differently
from the same test on a scalar, which is what makes it so easy to get wrong:

```
scalar    'x' -is [pscustomobject]                    -> False
pipeline  @('x') | Where { $_ -is [pscustomobject] }  -> KEPT
```

| predicate | keeps |
|---|---|
| `-is [hashtable] -or -is [pscustomobject]` | string, int, hashtable, pscustom |
| `-is [hashtable] -or -is [System.Management.Automation.PSCustomObject]` | hashtable, pscustom |
| `GetType().FullName` whitelist | hashtable, pscustom |

So "filter to the last hashtable" kept everything, and `Select-Object -Last 1`
returned whatever the adapter emitted **last** — trailing chatter beat the real
result.

**My first patch to Defect 1 used the same accelerator and was therefore inert.**
The test stayed red, which is the only reason I looked closer instead of
believing the fix. Reasoning produced the bug twice; measurement caught it.

Both sites now use the fully-qualified type, and the in-job selection runs
*before* `Preset` is stamped, with a `$null` guard so "nothing structured"
reaches the collection path and gets its honest label.

**Reachability:** latent today — no shipped adapter writes to the success
stream. The finding is that a defence the code claimed to have did not exist, in
two places, and one stray `Write-Output` anywhere in an adapter's load path was
enough to convert a good review into a failure.

## Non-vacuity: mutation sweep

These are coverage tests over existing behaviour, so most passed on first run.
Three (`stray output before`, `stray output after`, `no-structured-output`) were
genuinely red and drove the fix above. For the rest, each production behaviour
was deliberately broken and the corresponding test re-run. `workflow.ps1` was
committed first, then restored with `git checkout HEAD -- workflow.ps1` after
each mutation.

| mutation | test | outcome |
|---|---|---|
| drop `$h.Preset = $mi.preset` | stamps Preset onto each adapter result | caught |
| suffix applied even for a solo run | a solo reviewer writes the unsuffixed file | caught |
| drop `$TimeoutSec = $effectiveTimeoutSec` | scales TimeoutSec by bundle size | caught |
| every reviewer gets the first one's override | sends each reviewer its OWN model override | caught |
| skip `Remove-Job` | ran them as jobs and cleaned every one up | caught |
| splat `-PidFile` unconditionally | does NOT pass -PidFile when undeclared | caught |
| revert to `[pscustomobject]` | keeps the real result when chatter follows it | caught |

7 of 7 caught; `workflow.ps1` verified byte-identical to HEAD afterwards.

## Timing

The straggler tree-kill test runs in **~2s** — it spawns a real child, lets the
dispatcher kill it, and asserts the round returns instead of burning the 630s
budget.

The global-timeout test is tagged `Slow` and takes **~30s**, because
`$budgetSec` is hardcoded `$TimeoutSec + 30` and cannot be driven faster. It is
the path that produced case (a) of the 2026-08-09 void round, so it earns the
wall clock. Everything else in the file is sub-second.

## Two mistakes worth recording

- **`ERA_STRAGGLER_GRACE_SEC=0` does not mean "fire immediately."**
  `Test-EraStragglerExpired` treats `$GraceSec -le 0` as *explicitly disabled —
  wait for the full budget*. The first run therefore hung for the entire 630s
  budget and **leaked a 900s sleeper child** onto the machine. The test now uses
  `1`, and kills any stray recorded PID in its `finally` so a failure can never
  leak a process again.
- I shadowed the automatic `$args` in a test helper.

Both were caught by running the thing, not by reading it.
