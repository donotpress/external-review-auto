# The review archive was not destroyed. It was moved, by another session.

**Date:** 2026-09-01
**Status:** false alarm, fully retracted. No data was lost. No guard was added.
**Cost:** one wrong causal story published in a commit message, a git tag and a
GitHub release, and about an hour building a safety mechanism for an event that
did not happen.

## What I claimed

While benchmarking a change to `tests/BundleDeliveryWiring.Tests.ps1`, I found
`.external-reviews/` missing from this repository and reported — in a commit, in
the `v2.8.1` tag, and in the published release notes — that a test I had just
written had destroyed it: about 35 topic directories, every round this skill had
ever run against itself. I named a mechanism:

```powershell
Remove-Item -LiteralPath (Join-Path $box.Repo '.external-reviews') -Recurse -Force
```

with `$box` null, so `Join-Path $null 'x'` returns a relative path that
`Remove-Item` resolves against the repository.

I wrote that from reading the code. I did not run it.

## What is actually true

**The archive was MOVED by a different session**, at 19:13 the same day, and it
left a note in the repository root saying so:

```
.external-reviews-MOVED.txt
    era's own self-review archive was moved out of this skill directory on
    2026-09-01, to %USERPROFILE%\.claude\era-archive\external-review-auto-selfreviews
```

with a measured reason: Claude Code walks `~/.claude/skills` at session start,
that tree is on a 9p mount, and of 555 paths opened at start-up ~206 were this
archive's `round-N-*.md` files, which nothing reads at start-up. All 35 topic
directories are intact at that path, including both rounds I reported as lost,
with every response, bundle and manifest.

The brief for that session's work said, in its own words, *"Another session may
share this tree."* It did.

## How the story was disproved

Three measurements, in the order they were taken:

1. **`Join-Path $null 'x'` throws.** On pwsh 7.6.5 it raises `Cannot bind
   argument to parameter 'Path' because it is null`. It cannot return a relative
   path, so the named line could not have produced one — and had `$box` been
   null, the test would have failed rather than deleted anything. Those runs
   passed 7/7.
2. **The suspect variant was re-run against a decoy.** A decoy
   `.external-reviews/` with canary files was planted and the exact benchmarked
   file re-run. The decoy survived.
3. **The whole suite was re-run against decoys**, with no tag exclusions, exactly
   as when the "loss" was noticed. Six decoy topic directories, all intact
   afterwards.

Only then did I look at the repository root and find the note that had been
sitting there the whole time.

## What was built, and then removed

On the false premise I added a guarded delete (`Remove-EraTestTree`), converted
all 142 recursive deletes in the suite to it, added an enforcement test, and
added a backup tool. **All of it has been reverted**, because the justification
was fiction and because this repository has a standing rule about mechanisms that
measurement does not support (see `2026-08-14-quote-grounding-declined.md`, which
declined two detectors on exactly that basis).

The measurement that decides it, taken while the mechanism was still in place:

- **142** recursive deletes in `tests/`. Every target resolves to a path under
  the system temp directory. Zero point at the repository.
- **0** recursive deletes anywhere in runtime code (`workflow.ps1`, `runtimes/`,
  `backends/`, `tools/`). There never have been any.
- The full suite, run with decoy topic directories in place, deletes none of
  them.

So the class the guard would have closed has never occurred here, and nothing in
the suite is currently capable of it. A seatbelt is cheap and the argument for
one is not silly — but "it could happen" is the justification this project
rejects from its reviewers, and it does not get a pass because the author is the
one making it.

**The strongest argument against this decision, and it is not answered.** Both
the gemini and deepseek-flash seats of the v2.8.2 panel attacked it, and
deepseek-flash put it best: *the measurement bounds the CURRENT suite, not future
code.* Every one of the 142 targets is temp-rooted today; nothing makes the 143rd
so. A guard is the only thing that converts "we checked" into "it cannot happen",
and the cost of being wrong is asymmetric — an unnecessary guard wastes a few
lines, a missing one loses artifacts that cannot be regenerated.

gemini's specific route (`Join-Path ""` yielding a relative path) is **measured
false** — that call throws too. But the general point stands on its own without
that route, and it is recorded here rather than argued away. The decision to
decline rests on: no occurrence, no current capability, and a project rule about
unmeasured mechanisms. If a future session prefers the seatbelt, this paragraph
is the argument for it and nothing here contradicts it.

## What genuinely changed

Nothing in the code. Two things worth knowing:

1. **`.external-reviews/` is expected to be ABSENT from this repository now.**
   The archive lives at
   `%USERPROFILE%\.claude\era-archive\external-review-auto-selfreviews`. Rounds
   cited by `README.md` and by other assessments are there, not here. Running
   `/era` against this repo will create a fresh `.external-reviews/`, which will
   re-introduce the start-up cost the move was made to remove.
2. **The published `v2.8.1` notes contain the false story** and have been
   corrected in place; the commit message that carries it cannot be, so this file
   is what a reader following it lands on.

## The lesson, which is the one this repository already had

A confident causal story, written from reading rather than running, published
before it was checked. The v2.8.1 release it went into was itself a write-up of
three cases where exactly that had happened — a fabrication claim that was a
coordinate-frame bug, an instrument asserted to work that had never been tested,
and a refusal that had never been exercised. I found the fourth case the same
afternoon and it was mine.

The panel's measured failure mode is "a correct mechanism wrapped in a fabricated
example, stated with identical confidence to the true parts." This was that,
without the panel.
