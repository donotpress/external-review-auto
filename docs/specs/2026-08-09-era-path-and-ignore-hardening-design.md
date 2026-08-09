# era: path-boundary and ignore-pattern hardening (P2 / P4 / P7)

**Date:** 2026-08-09
**Status:** approved
**Origin:** 3-model panel design review (`gemini`, `opus`, `deepseek-flash`) —
`.external-reviews/era-proposals/round-1-*`. All three ranked P2, P4 and P7 in
their top four and called them cheap, safe and correct.

## Problem

Three independent defects, each confirmed by measurement against this tree on
2026-08-09.

**P2 — vendored trees are uploaded.** era's repomix config sets
`useDefaultPatterns=false` and ships `node_modules/**` among its
`customPatterns`. A bare `<dir>/**` pattern is **root-anchored** in repomix:

```
repomix --include "**/*.md" --ignore "node_modules/**" \
        --no-gitignore --no-default-patterns
  → bundles packages/p/node_modules/d/a.md
```

So in any monorepo, every vendored `.md`/`.json`/`.ts`/`.js` under a nested
`node_modules` is bundled and sent to three third-party APIs. repomix's own
default list spells these `**/node_modules/**`; the `**/` prefix would be pure
redundancy if bare patterns matched at depth.

**P4 — sibling directories are misclassified as in-repo.**
`$full.StartsWith($repoRoot, OrdinalIgnoreCase)` has no directory-separator
boundary. With repo root `C:\a\era-p6`, the sibling
`C:\a\era-p6-ext\outside.md` tests as *inside* the repo and is relativized to
`-ext/outside.md`, which then fails `Test-Path` with a confusing "paths not
found". Observed directly while probing P6. Seven sites share the idiom; the
`$HOME` mirror at `era.ps1:1231` has the same shape (`C:\Users\Joshua2` vs
`C:\Users\Joshua`).

The guard **fails closed** — a false "inside" classification produces a path
that does not exist under the root, so repomix bundles nothing and the file is
silently dropped. The harm is silent loss of an explicitly requested file, not
exfiltration.

**P7 — a failed run leaves nothing to diagnose.** `era.ps1`'s `finally` deletes
`round-N-config.json` on success and failure alike (PowerShell unwinds `exit`
through `finally`), and the manifest that would replace it is written only
*after* repomix succeeds. A failed run therefore leaves no bundle, no manifest
and no config. The claim-file deletion two lines above is correct — that one is
per-process state. The config is a receipt, not a tombstone.

## Design

### Unit 1 — `Test-EraPathInsideRoot` (new, `workflow.ps1`)

A pure predicate. `Test-EraPathInsideRoot -Path <p> -Root <r>` returns `$true`
when `p` is `r` itself or lies beneath it, comparing on a
directory-separator boundary.

- Normalises both sides through `[System.IO.Path]::GetFullPath` and strips
  trailing separators before comparing.
- Case-insensitive (`OrdinalIgnoreCase`), matching the idiom it replaces.
- Null or empty on either side returns `$false`.
- No filesystem access — it is a string-boundary predicate, so it works for
  paths that do not exist yet.

Replaces all seven sites:

| Site | Role |
|---|---|
| `era.ps1:502` | `-SpecReview` path relativize |
| `era.ps1:1143` | staging predicate (`$stagingInPlay`) |
| `era.ps1:1215` | staging relativize (absolute in-repo) |
| `era.ps1:1231` | `$HOME` mirror for staged copies |
| `era.ps1:1302` | path-traversal guard |
| `workflow.ps1:41` | diff guard |
| `workflow.ps1:203` | manifest guard |

`workflow.ps1:1241` is **not** a site — it is a glob-prefix test
(`$n.StartsWith('**/')`), not a path-containment test.

### Unit 2 — ignore patterns and the parser that consumes them

The shipped list in `era.ps1` becomes:

```powershell
@('**/node_modules/**', '**/.git/**', '**/__pycache__/**',
  '*.pyc', '*.duckdb', 'validation_results/**/*.db') + $artifactIgnore
```

`.external-reviews/**` (supplied by `$artifactIgnore`) stays **deliberately
root-anchored**: era's own artifact directory is always at the repo root, and
the staging carve-out enumerates root-relative siblings. Prefixing it would
leave a nested tree ignored with no staging exception.

Only `node_modules` changes real output. `__pycache__` holds `.pyc`, `.git`
holds nothing the include globs match, and `validation_results/**/*.db` targets
an extension that is not included — those three are changed for consistency, so
sibling patterns that look alike behave alike.

**This forces a matching parser change.** `Measure-EraBroadScope` parses ignore
patterns with `^([^*]+)/\*\*$`, which matches `node_modules/**` but **not**
`**/node_modules/**`. Left alone, the measurer would stop pruning
`node_modules` entirely and over-count. The parser learns both shapes:

| Pattern | repomix semantics | measurer behaviour |
|---|---|---|
| `<dir>/**` | root-anchored | prune that root-relative path |
| `**/<dir>/**` | any depth | prune any directory with that leaf name |

This coupling — a producer in `era.ps1` and a narrow regex consumer in
`workflow.ps1`, with nothing asserting the second understands the first — is
what allowed the original under-counting bug. A contract test closes it.

### Unit 3 — config retention on failure

`era.ps1` sets `$runSucceeded = $true` as the last statement of the `try`. The
`finally` deletes `round-N-config.json` only when that flag is set. The
claim-file deletion stays unconditional.

The failure path names the retained config so the receipt is discoverable
rather than merely present.

## Testing

Every test below must fail against the current tree before its production
change lands.

**P4 — `tests/PathInsideRoot.Tests.ps1`**
- root itself is inside root
- a true child is inside
- a sibling sharing a prefix (`C:\repo-ext` vs `C:\repo`) is **outside** —
  the measured defect
- trailing separators on either side do not change the verdict
- case differences do not change the verdict
- `$null` / empty on either side returns `$false`
- integration: the `era-p6-ext` repro — an out-of-repo file in a
  prefix-sharing sibling directory is **staged**, not relativized to
  `-ext/outside.md`

**P2 — `tests/IgnorePatternDepth.Tests.ps1`**
- real repomix measurement: with the new patterns, a nested
  `packages/p/node_modules/d/a.md` is **not** bundled, while `root.md` is
- `Measure-EraBroadScope` prunes a nested `node_modules` for `**/<dir>/**`
- `Measure-EraBroadScope` still prunes root-only for `<dir>/**`
- contract test: every pattern in the live shipped list parses into a shape the
  measurer recognises — zero unrecognised patterns

**P7 — `tests/ConfigRetention.Tests.ps1`**
- a run that fails at the existing "Bundle is empty" guard (repo with an empty
  subdirectory, `-IncludeFiles 'emptydir'`) leaves `round-1-config.json` on disk
- the round-claim file is still removed on that same failure
- source check: the config deletion is conditional on the success flag

## Risks

- **P2 changes what is bundled.** Intent is strictly subtractive (fewer files
  uploaded), so it cannot expand the payload. A caller who genuinely wanted a
  vendored nested tree reviewed must now name it with `-IncludeFiles`, which is
  the explicit path anyway.
- **P4 touches seven sites across two files in shared tooling.** Mitigated by
  the helper being a pure predicate with an exhaustive unit test, and by the
  replaced expression being textually identical at every site.
- **P7 leaves a small file behind on failure.** Bounded: one config per failed
  round, overwritten by the next run of the same round number.

## Out of scope

P1 (response contract), P3 (repomix tree-kill), P5 (porcelain `-z` parse),
P8 (registry capabilities). P6 (`-RequestFile`) was dropped unanimously by the
panel. The convergence-detector dead code (`ContentOk` / `ResponseChars`) is
recorded but not fixed here.

## Execution

All three changes touch `era.ps1` and two touch `workflow.ps1`, so
feature-parallel agents would collide. Work is split by file ownership instead:

1. **Parallel** — three agents, one new independent test file each. No shared
   files.
2. **Sequential** — one agent applies the production edits across `era.ps1` and
   `workflow.ps1`.
3. **Verify** — one full Pester run, review at the end.

Tests land before production code, which is also the TDD order.
