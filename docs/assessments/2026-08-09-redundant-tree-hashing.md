# Redundant tree hashing — measured, not fixed

**Date:** 2026-08-09
**Origin:** graded panel item #5, "tree walked/hashed 2-3x per round" (3/3 reviewers, filed under efficiency)
**Verdict:** claim is structurally correct; the efficiency framing does not survive measurement. **No change made.**

## The claim

All three reviewers observed that a single round walks and hashes the include
set more than once. That is true, and the call sites are:

| # | Call site | When | What it does |
|---|---|---|---|
| 1 | `Measure-EraBroadScope` (`era.ps1:1193`) | broad path only | walks the tree for the scale gate's count/bytes |
| 2 | `Get-ReviewDiff` (`era.ps1:1032`) | follow-up rounds only | expands the include list, SHA256s every file |
| 3 | `Write-ReviewManifest` (`era.ps1:1407`) | every round | expands the include list again, SHA256s every file again |

A broad follow-up round therefore does all three. 2 and 3 hash the identical
file set, so that overlap is genuinely redundant work.

## The measurement

Synthetic tree built at the scale gate's documented ceiling — 1000 files,
9.77 MB — and each function timed independently:

```
Write-ReviewManifest  : 1047 ms
Get-ReviewDiff        :  654 ms
Measure-EraBroadScope :  142 ms
```

Redundant portion (the 2/3 overlap): **~654 ms**.

## Why nothing was changed

A three-model panel round measures 400–900 s wall-clock. 654 ms of duplicated
hashing is **0.07 %–0.16 % of a round**, at the largest bundle era will send
without `-ForceBroadScope`. It is not detectable by a user.

Against that, a shared hash cache would have to be correct across a genuinely
awkward gap: `Get-ReviewDiff` runs at `era.ps1:1032`, `Write-ReviewManifest` at
`era.ps1:1407`, and **the include list is rewritten in between** — P6
out-of-repo staging reassigns `$IncludeFiles` at `era.ps1:1223` and
`$effectiveInclude` is rebuilt at `era.ps1:1272`. The two calls are not
guaranteed to see the same input, which is exactly the condition under which a
naive memoisation returns a stale hash and the round-over-round delta silently
lies. That is the same class of defect as the bugs closed in `556fa7a` and
`2ef72b2`, traded for a saving of one part in a thousand.

Cheaper correctness, no cache: the two calls hashing independently means a file
edited mid-run is caught as a real difference rather than papered over.

## What would change this verdict

Re-measure if any of these becomes true:

- the scale ceiling (`ERA_BROAD_MAX_FILES` / `ERA_BROAD_MAX_BYTES`, currently
  1000 files / 10 MB) is raised by more than ~50x;
- rounds stop being dominated by reviewer latency (e.g. a local-model panel
  turning a 400 s round into a 5 s one);
- a third hashing consumer is added, making the overlap 3x rather than 2x.

Reproduce with the timing probe shape above: build N files, call the three
functions, compare the overlap against measured round wall-clock in
`round-N-metadata.json` (`wall_clock_sec`).
