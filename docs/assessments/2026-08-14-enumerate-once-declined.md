# "Enumerate once" — measured, declined

**Date:** 2026-08-14
**Origin:** round-6 (opus), blocker 1's suggested fix — *"build the include set **once**: have `Measure-EraBroadScope` return the concrete paths it already enumerated and feed that list to both `Write-ReviewManifest -SourceFiles` and `Get-ReviewDiff`. One change removes two tree walks and closes this."*
**Verdict:** the correctness half was closed separately; the performance half does not survive measurement. **No change made.**

## The proposal was two things, and they have separated

Opus bundled a correctness fix and a performance fix into one refactor:

1. **Correctness** — the three walks disagreed about what to ignore, so the
   manifest baselined `node_modules/**/*.md` and the next round's diff called
   them changed.
2. **Performance** — the same tree is enumerated up to three times per round.

**(1) is closed** by `70093f3`, which extracted `Get-EraVendorIgnorePatterns` /
`Get-EraIgnoreSets` / `Test-EraPathIgnored` and gave all three walks one rule,
and by `5b22901`, which taught the parser the last shipped pattern shape it was
silently dropping. The walks now agree. What is left is doing identical, correct
work twice.

## The measurement

One expansion pass over the shipped default globs, on this repo:

```
333 paths, 208 ms
```

So the redundant second pass costs **~208 ms**. The earlier assessment
(`2026-08-09-redundant-tree-hashing.md`) measured **~654 ms** for the equivalent
overlap on a synthetic tree at the scale gate's documented ceiling — 1,000 files
and 9.77 MB.

Against real round wall clock:

| round | wall clock | 208 ms is | 654 ms is |
|---|---:|---:|---:|
| round 5 | 574 s | 0.04% | 0.11% |
| round 6 | 496 s | 0.04% | 0.13% |

A round is dominated by model latency — opus alone took 458 s in round 6. The
redundant walk is invisible next to it, at the ceiling as well as at this repo's
size.

## Why not do it anyway

The refactor is not free:

- `Measure-EraBroadScope` runs **only on the broad path**, so both consumers
  still need their existing enumeration as a fallback. The change adds a second
  code path rather than replacing one.
- It changes what the manifest records — concrete paths instead of the glob list
  — which is the round's provenance record and is read by `Get-ReviewDiff` on
  every follow-up round.
- It touches the default bundling path. `70093f3` already produced two of my own
  defects in this area within one sitting (an absolute-vs-relative path
  comparison, and a parameter used ~150 lines before it was defined), both
  caught by tests rather than by reading.

Trading a measured 0.04% for a refactor of the default bundling path is a bad
trade, and it stays a bad trade until something else makes those walks matter.

## What would change this verdict

- A repo where enumeration is a meaningful share of round time — a monorepo an
  order of magnitude past the scale gate's 1,000-file ceiling, where the walk
  runs into seconds rather than hundreds of milliseconds.
- A future consumer that needs the *concrete* enumerated set rather than the
  globs, at which point the return value earns itself and the dedup comes free.

Neither is true today. Re-measure before revisiting; do not re-argue it.
