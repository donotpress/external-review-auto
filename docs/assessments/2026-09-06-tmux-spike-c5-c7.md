# tmux transport spike: C5 and C7 pass; the pre-registered size bar does not

**Date:** 2026-09-06
**Seat:** `muse-spark` (`opencode-go/muse-spark-1.3-contributor`) over a raw tmux
window — **not** through `backends/tmux.ps1`, which is still unwritten.
**Bundle:** `.external-reviews/model-drift/round-6-bundle.xml`, **59,034 bytes** —
the exact bundle that produced M4, the failure this design exists to beat.
**Verdict:** the central bet holds. One pre-registered threshold is missed and is
reported as missed.

---

## 1. Why this ran before `backends/tmux.ps1`

The spec's §12 says the central bet — *whether a TUI agent reliably writes the
file and finishes its turn* — is unmeasured, and §11 makes C5 and C7 kill
criteria. Both are answerable with a scratch directory and two `tmux` calls. Five
hundred lines of adapter written before that question is settled would be five
hundred lines written on a guess.

## 2. What was run

A per-attempt scratch directory under `%TEMP%` holding exactly `bundle.xml` and
`instructions.md` (era's archived round-6 prompt plus the §5.3 envelope), with a
watchdog window and the seat launched as separate argv elements, no shell:

```
tmux -L eraspike new-session -d -s era -n era-watchdog "sh -c 'sleep 1000; tmux -L eraspike kill-server'"
tmux -L eraspike new-window  -d -t era: -n era-seat-muse -c "$SCRATCH" -- \
    opencode -m opencode-go/muse-spark-1.3-contributor --auto \
    --prompt "Read instructions.md and follow it exactly."
```

## 3. Results

| Check | Result |
|---|---|
| **Launch latch** (window row appears, §6) | **pass** — `era-seat-muse`, `cmd=opencode`, within 3 s |
| **Writes the file** | **pass** — `review.md` at **t+150 s** |
| **Canary** | **pass** — last non-empty line is `ERA-CANARY-e36c7e99f3940342`, the nonce issued for this attempt |
| **Read-truncation probe** (`ERA-BUNDLE-TAIL`) | **pass** — reported `docs/specs/2026-09-06-model-drift-detection-design.md`, byte-identical to the bundle's actual last `path="…"`. The 59,034-byte bundle was read **to its end** |
| **`Test-EraCaptureAcceptable`** | **`Ok = True`** on the stripped body (3,666 chars) |
| **Structure** | 5 sections, matching the requested format |
| **C7 — process reaping** | **pass** — 2 processes with `cwd = scratch` before `kill-server`, **0** after, still 0 at +10 s |
| **Pre-registered size ≥ 4,000 chars (§10)** | **FAIL — 3,666** |

**The detector result is meaningful because the detector can say no.** A control
in the same call rejected a narration string with `agentic-narration-capture`. A
verdict from an instrument that has not just proved it can return the other
answer is not evidence.

## 4. The threshold that failed, reported as failed

§10 pre-registered: canary, detector `Ok`, no citation warning, **and ≥ 4,000
characters** — the floor set by the smallest real review in the round-6 archive
(muse-spark, 4,226). This run produced **3,666 characters of body**, 13 % under.
Round 6's process-spawn muse-spark on the same bundle produced 4,294 bytes.

The bar was pre-registered precisely so it could not be renegotiated afterwards,
so: **this run does not clear it.** What that means is limited — one sample of a
model whose output on this repo has ranged widely, and the spec assigns
muse-spark the iteration role for exactly this reason. It is not evidence that
the transport degrades quality; it is one run below a line drawn from one prior
run. Repeats are the answer, not a lower line.

## 5. Two design questions settled

**A thinking TUI is never quiet.** `#{window_activity}` was sampled every 5 s for
the whole attempt: **the longest silence was 0 s.** The epoch advanced on every
single sample. This confirms what gemini and muse-spark predicted in rounds 2-3
and settles §14.2: a stall rule keyed on `window_activity` **would never have
fired**. Deleting it in revision 3 was correct, and for a second reason beyond
the arithmetic — the signal is not merely low-value here, it is inert.

**A TUI does not exit when its turn ends.** After `review.md` was complete and
canary-terminated, the window was still present with `cmd=opencode`. This is the
measured justification for §6 rule 4 (the `turn-ended` hook): without it, this
seat would have sat idle until `$TimeoutSec`, having finished its work at t+150 s.

## 6. What this does *not* show

- **`backends/tmux.ps1` still does not exist.** Nothing here exercises era's
  result contract, promotion, `seat_containment`, or the recoverable-failure
  codes. This is the bet, not the build.
- **One seat, one run, one model.** No opus run, and — per the operator's usage
  constraint — no deepseek run, which is the seat M4 actually failed on. Reading
  the 59,034-byte bundle successfully is strong evidence about the *bundle size*
  half of M4 and none about the *model* half.
- **No A/B.** Wall clock (150 s) is not comparable to round 6's 73-464 s
  process-spawn range without matched, interleaved repeats.
- The citation checker was not run; only `Test-EraCaptureAcceptable`.

## 7. Incidental finding: the detector accepts an empty string

`Test-EraCaptureAcceptable -Response ''` returns **`Ok = True`**. Found because a
path-translation slip fed it an empty read, and the pass looked clean. era's
adapters gate emptiness upstream (exit code and content checks), so this is
latent rather than live — but it is a fail-open in a function five backends share,
and a sixth backend written against it could inherit the hole. Not fixed here;
recorded.
