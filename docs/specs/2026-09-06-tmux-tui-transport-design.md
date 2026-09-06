# tmux TUI transport as an era backend

**Date:** 2026-09-06
**Status:** design, unbuilt. Nothing in this document has been implemented.
**Scope:** one new backend, `backends/tmux.ps1`, carrying the `opus` and
`deepseek-flash` seats. `agy` and `cmdc` are explicitly out of scope for the
first build; §13 says what they would take.
**The decision this spec asks for:** build the spike in §10, or don't.

---

## 1. The question

era dispatches its panel by spawning each vendor CLI as a one-shot child
process. Three adapters, 2,808 lines, one per vendor, each re-solving the same
four problems: get the bundle to the model, know whether it is alive, know when
it is done, get the text back.

Could one transport do all four for every vendor at once? Concretely: run each
seat's **interactive TUI** in a detached tmux window pointed at the repo, and
have the model **write its review to a file** rather than to a pipe.

**The extraction problem does not arise, because nothing is extracted.** Every
one of these TUIs has file-write tools. The prompt ends with "write your review
to `<path>`". era then reads a file. No ANSI, no spinners, no turn-boundary
parsing, no truncation guessing.

This distinction is load-bearing. A previous session rejected "run the panel in
tmux" on the grounds that capturing a review out of TUI scrollback is an
unsolved problem. That objection is correct and it is aimed at a different
design. **This spec never reads pane text.** The three signals it takes from
tmux are all structured window metadata (§6); if any part of this design finds
itself calling `capture-pane`, that part is wrong.

---

## 2. What is measured

Every claim below was run on this box on 2026-09-05/06. Anything not in this
table is `INFERRED` and is flagged as such at the point of use.

| # | Claim | Command | Result |
|---|---|---|---|
| M1 | Adapter cost is 2,808 lines | `wc -l backends/{opencode,agy,claude}.ps1` | 1492 + 971 + 345 |
| M2 | era sets no working directory; seats inherit the repo | `grep -n '\.WorkingDirectory' backends/*.ps1 workflow.ps1 runtimes/era.ps1` | one hit, and it is a comment recording this same grep |
| M3 | `.external-reviews/` is gitignored **and** filtered out of containment | `git check-ignore -v .external-reviews/.../round-6-opus-response.md` → `.gitignore:2`; `workflow.ps1:1058` | seats writing responses cannot trip `seat_containment` |
| M4 | Round 6 lost the deepseek-flash seat to transport | `.external-reviews/model-drift/round-6-metadata.json` | `exit_code -1`, `response_chars 0`, `wall_clock_sec 621.1`, `delivery_mode read-tool` |
| M5 | tmux exposes a per-window output heartbeat | `tmux list-windows -F '#{window_activity}'` on tmux 3.7c | distinct epochs per window; the one busy window reads exactly `date +%s` |
| M6 | tmux exposes the pane's foreground command | same, `#{pane_current_command}` | `bash` for shells, `claude` for the two agent windows |
| M7 | `claude` takes its prompt as an argv positional | `claude --help` | `Usage: claude [options] [command] [prompt]` |
| M8 | The `opencode` **TUI** takes `--prompt`, `-m`, `--auto` | `opencode --help` | all three present on the default (TUI) command |
| M9 | The `opencode` TUI does **not** take `--variant` | `opencode --help` vs `opencode run --help` | present on `run`, absent on the TUI |
| M10 | `claude`'s two permission flags differ | `claude --help` | `--allow-dangerously-skip-permissions` *enables the option*; `--dangerously-skip-permissions` *bypasses* |
| M11 | A Windows exe launched from WSL keeps its cwd only from a DrvFs directory | `cmd.exe /c cd` from the repo vs from `/tmp` | `C:\Users\...\external-review-auto` vs `UNC paths are not supported. Defaulting to Windows directory.` |
| M12 | `agy` is not on the WSL PATH but is reachable by absolute path | `command -v agy` → miss; `.../agy/bin/agy.exe --version` → `1.1.27` | `/etc/wsl.conf` sets `interop.appendWindowsPath=false` |
| M13 | `tui-workspace`'s completion signal is an external per-agent hook | source read: `@agent_busy_at`/`@agent_session` "are written ONLY by agent-signal"; `@agent_done` is reset to 0 by `after-select-window` | era would be depending on a hook it does not own |
| M14 | The operator's live tmux session is `main`, 12 windows | `tmux list-sessions`; `tmux list-windows -t main` | era must not create windows in it (§5.4) |
| M15 | era's env scrub does not include `TMUX_PANE` | `tests/EnvScrub.Tests.ps1:10-19` | 8 vars listed, `TMUX_PANE` absent (§8.3) |

**Two of these correct the brief this spec was written from.**

- **M9 is a capability regression.** era's opencode seats pass `--variant xhigh`
  / `--variant high`. The TUI has no such flag. A tmux-transported opencode seat
  runs at opencode's own default reasoning effort. The registry's own notes
  spent two days establishing that a silently-ignored variant is the worst
  failure shape era has (`_opencode_model_map.muse-spark-1.2-contributor`), and
  this transport reintroduces it *by construction* rather than by mistake. §9
  prices it; §11 makes it a kill criterion if effort cannot be set another way.
- **M10 makes the claude seat's exposure genuinely new.** The brief asserts that
  yolo agents in the repo are "not a new exposure — it is the current one, made
  concurrent". That is true for opencode and agy. It is **false for claude**:
  era passes `--allow-dangerously-skip-permissions`, which only makes bypass
  *available*. An interactive seat with nobody present to answer a permission
  prompt needs `--dangerously-skip-permissions`, which actually bypasses. The
  claude seat's privilege therefore *increases* under this transport. §8 treats
  it as such.

---

## 3. What must not change

Transport is not protocol. None of the following is about transport, and none of
it may be touched: round numbering; per-claim disposition; the 0-criticals
terminal condition; archived artifacts under `.external-reviews/`; the citation
checker; `seat_containment`; the `round-N-*-response.md` glob that builds
`{{PREVIOUS_ROUND}}`.

The transport is therefore built **behind** era's existing backend interface,
which is already the right shape for it:

```
backends/<backend>.ps1  →  function Invoke-<Backend>Review
  in:  -BundlePath -PromptPath -ResponsePath -ModelInfo -TimeoutSec
       -ModelOverride -OpencodeProvider -AgyModelHint [-PidFile]
  out: @{ Response ExitCode Error ContentOk CaptureMethod
          InputTokens OutputTokens WallClockSec TruncationWarning
          Stderr Warnings }
```
(`workflow.ps1:2082-2135`.) A new backend is a new file plus a registry key.
`Invoke-ReviewerDispatch` needs no change at all.

---

## 4. Approaches considered

**A. Pane scraping.** Run the TUIs, read the reviews out of scrollback.
*Rejected*, and it is the design the earlier rejection was aimed at. Scrollback
is a rendering, not a record: it is ANSI-laden, reflowed on resize, bounded by
`history-limit`, and offers no way to tell "the model stopped" from "the model
is between tokens". Every problem this creates is self-inflicted.

**B. File-write TUI transport.** *Recommended.* The model's file-write tool is
the return channel. Detailed in §5-§8.

**C. Do nothing; keep three process-spawn adapters.** The honest baseline. It
works today at 1140 green tests, and §9 shows the saving is smaller than the
2,808-line headline. C is the right answer if the spike in §10 misses any kill
criterion in §11.

Recommendation is **B, as an opt-in second transport, with the process-spawn
backends remaining the default** until a tmux seat has beaten a process seat on
the same bundle. This spec does not propose deleting any adapter. Deletion is a
later decision that needs evidence this design cannot yet supply.

---

## 5. Architecture

Four units. Only the first is new code of any size.

### 5.1 `backends/tmux.ps1` — the adapter

Runs in Windows pwsh, like every other adapter. Owns:

1. **Prompt assembly** — the seat prompt (§5.3), written to a per-seat file.
2. **Launch** — one `wsl.exe` call that creates the window (§5.2).
3. **The wait loop** — file polling on the Windows side, tmux polling only when
   the file is quiet (§6).
4. **Promotion** — validate the staged file, then promote it to `$ResponsePath`
   (§5.5).
5. **Teardown** — kill the window, always, including on every failure path.
6. **Result** — era's existing hashtable.

It spawns `wsl.exe` through `ProcessStartInfo` with `CreateNoWindow=$true` and
the same environment scrub as the other three adapters, plus `TMUX_PANE` and
`TMUX` (§8.3). `tests/EnvScrub.Tests.ps1` gains `tmux` to its `-ForEach` list.

### 5.2 The launch table — registry data, not code

The *only* per-model knowledge is a command template. It belongs in
`backends/_registry.json` next to the model id, not in a `switch` in the
adapter:

```jsonc
"opus": {
  "backend": "claude",              // unchanged; process-spawn stays the default
  "tmux_launch": {
    "argv": ["claude", "--model", "{model_id}",
             "--dangerously-skip-permissions",   // M10: not the --allow- form
             "{prompt}"],
    "fg_command": "claude"                       // expected #{pane_current_command}
  }
},
"deepseek-flash": {
  "backend": "opencode",
  "tmux_launch": {
    "argv": ["opencode", "-m", "{model_id}", "--auto", "--prompt", "{prompt}"],
    "fg_command": "opencode"
  }
}
```

A seat is transportable over tmux iff it has a `tmux_launch` block. Adding
`cmdc`'s 68 models later is a data change (§13).

**There is no key-sending anywhere in this design.** M7 and M8 establish that
both CLIs accept the initial prompt as an argv value at launch, so the prompt is
submitted by the process's own startup. The brief lists "whether send-keys races
TUI readiness" as an unmeasured risk; this design **removes the risk rather than
measuring it** — there are no keys to send and no readiness to race. Combined
with the fresh-window-per-round rule (§5.4), no seat is ever sent a second turn,
so the race cannot reappear in a later round either.

The prompt is passed as a distinct `argv` element, never interpolated into a
shell string, so no quoting or injection question arises from prompt content.

### 5.3 The seat prompt contract

era's existing round prompt, plus a fixed envelope:

```
Read the review bundle at .external-reviews/<slug>/round-<N>-bundle.xml
(relative to your working directory, which is the repository root).

<... era's existing round prompt, verbatim ...>

Write your complete review to .external-reviews/<slug>/round-<N>-<seat>-raw.md
Do not modify any other file. Do not run git commands that write.
The final line of that file must be exactly:
ERA-CANARY-<nonce>
```

Three properties are deliberate:

- **Every path is repo-relative.** The window's cwd is the repo root, so the
  model never sees a WSL or a Windows path and no path translation reaches the
  model at all. era performs exactly one translation, once, at launch:
  repo-root Windows path → WSL path. M11 makes that translation mandatory in one
  direction — a Windows-exe seat launched from a non-DrvFs cwd loses its
  working directory silently — and irrelevant here, because the repo already
  lives under `/mnt/c`.
- **The canary is a per-round nonce**, not a constant. A constant could be
  satisfied by a stale file from a previous round; a nonce cannot. It is also
  what makes truncation *detected* rather than assumed: a file without its
  canary is incomplete, full stop.
- **The output path ends in `-raw.md`, not `-response.md`.** See §5.5.

### 5.4 Session and window lifecycle

- **A dedicated detached session, `era-panel`.** Not the operator's `main`
  (M14). `tui-workspace`'s daemon addresses `$SESSION` (default `main`) on every
  call, so a separate session is invisible to it and will not be snapshotted,
  restored, refreshed, or nudged.
- **era does not use `tui-workspace`.** It is 123 KB era does not own, it is not
  covered by era's tests, its `new` verb refuses to run without a pre-existing
  session, and — decisively — M13 shows its completion signal comes from an
  `agent-signal` hook installed per agent, outside era. era's four tmux calls
  are `new-session -d`, `new-window -c <dir>`, `list-windows -F`, `kill-window`.
  That is the whole dependency.
- **One fresh window per seat per round**, killed at the end of the round.

  This settles the brief's open question about persistent context directly.
  era's rounds are independent by construction; a seat that carried its own
  round-N-1 review and the disposition table into round N would be reviewing its
  own past answers, and "the panel converged" would stop meaning what era's
  0-criticals terminal condition takes it to mean. **Round independence is
  protocol (§3), so it wins.** The cost is one TUI cold start per seat per
  round, paid against a 700 s seat floor.
- Window name: `era-<slug>-r<N>-<seat>`, which is also the kill key. A window of
  that name surviving from an earlier crashed round is killed before launch.

### 5.5 Staging and promotion

The model writes `round-N-<seat>-raw.md`. era promotes it to
`round-N-<seat>-response.md` only after it passes validation.

This is not ceremony. `claude.ps1:324` records the rule it protects: *"A
non-review is not written to disk … so it cannot be picked up by the
`round-N-*-response.md` glob that builds the next round's `{{PREVIOUS_ROUND}}`
context."* Under this transport the model holds the pen, so if it wrote straight
to `$ResponsePath` a refusal or a narration would enter the next round's context
as though it were a review — silently defeating a guard era already has. The
staging name is chosen so that it cannot match the glob
(`workflow.ps1:679`).

Promotion sequence: canary present as the final non-empty line → strip it →
`Test-EraCaptureAcceptable` (`backends/_capture-validation.ps1:309`, unchanged,
shared with five other backends) → write `$ResponsePath`. Any failure leaves
`-raw.md` on disk as the forensic record, exactly as the round-6 error log was.

---

## 6. Completion and liveness

Three signals. All three are structured tmux metadata or a local file stat. None
of them is pane text.

| Signal | Source | Answers |
|---|---|---|
| **Completion** | the staged file's last line == the canary | done, and complete |
| **Death** | `#{pane_current_command}` != the seat's `fg_command` (M6) | the TUI exited or crashed |
| **Progress** | `#{window_activity}`, an epoch (M5) | when the pane last emitted anything |

The wait loop runs on the Windows side and polls the **staged file** — a local
filesystem stat, effectively free. It calls into WSL for the two tmux signals
only on a slower cadence (every 15 s), because each call crosses the interop
boundary.

Terminal conditions, in precedence order:

1. **Canary present** → success.
2. **`pane_current_command` no longer the agent** → `ExitCode = -1`,
   `Error = 'tmux-seat-exited'`. This is immediate, and it is the failure mode
   era currently cannot see at all: today a dead CLI is indistinguishable from a
   thinking one until the budget runs out.
3. **`window_activity` has not advanced for `StallSec`** → stall; kill; record
   `Error = 'tmux-seat-stalled'` with the silence duration.
4. **`$TimeoutSec` reached** → kill; `Error = 'tmux-seat-timeout'`.

`StallSec` is **not a new number**. It is read from era's existing measured
stall policy (`docs/assessments/2026-09-04-stall-threshold-measured.md`, which
established that 3.97 % of productive deepseek-flash turns go silent for over
300 s, up to 570.2 s). Inventing a fresh threshold here would repeat the mistake
that document was written to end.

**What this replaces.** `#{window_activity}` is a direct observation of "has
this process emitted anything recently". `backends/opencode.ps1` spends 454
lines inferring the same fact from a child's stdout
(`Resolve-OpencodeStallPlan` 173, `Resolve-OpencodeRunBudget` 122, plus
`Get-OpencodeMinRunSec` 68, `Get-OpencodeKillRiskSec` 48,
`Get-OpencodePollIntervalMs` 43). That is the single largest concrete saving in
this design and the one this spec is most confident about.

---

## 7. Failure taxonomy

Every failure maps onto era's existing result contract; no new field is added to
`round-N-metadata.json`.

| Failure | Detected by | `ExitCode` | `Error` | Recoverable? |
|---|---|---|---|---|
| Review written and complete | canary | 0 | — | — |
| Written but truncated | canary absent, turn over | -1 | `tmux-seat-truncated` | yes, re-dispatch |
| Never written, agent gone | `pane_current_command` | -1 | `tmux-seat-exited` | yes |
| Never written, agent silent | `window_activity` | -1 | `tmux-seat-stalled` | yes |
| Budget exhausted | `$TimeoutSec` | -1 | `tmux-seat-timeout` | no |
| Wrote a refusal / narration | `Test-EraCaptureAcceptable` | -1 | `agentic-narration-capture` | as today |
| tmux/WSL unavailable | launch call | -1 | `tmux-transport-unavailable` | no |

The last row is the one that must fail loudly. era's own history has three
recorded fail-open catches where a read failure became indistinguishable from a
real measurement, and `Compare-EraSeatContainment` has a standing comment about
exactly this shape. If tmux is missing, the seat is `unmeasured`, never
`contained` and never "the model declined".

`Get-EraRecoverableFailures` keys on `Error` codes, so the four recoverable
codes above must be added to it or the bounded re-dispatch will not fire for
tmux seats. This is a real integration point, not a detail.

---

## 8. Containment, concurrency, exposure

### 8.1 Containment is already instrumented and already correct

`seat_containment` (`workflow.ps1:1016`) diffs `git status` around the dispatch,
and M3 shows `.external-reviews/` is both gitignored and explicitly filtered out
of `NewDirty`. So a seat writing its own review cannot trip containment, and a
seat that edits source code or moves HEAD **will**. The instrument is exactly
right for this experiment and needs no change. It is the day-one safety readout.

### 8.2 Four interactive agents in one working tree

The brief flags collisions as unmeasured. Reasoned, not measured:

- **Response writes cannot collide.** Four distinct paths in a gitignored
  directory.
- **The git index lock is the real hazard.** A read (`git status`, `git log`,
  `git diff`) takes no lock. `git add`/`commit`/`checkout` do. The prompt
  forbids writing git commands (§5.3), and `seat_containment` detects it if a
  model ignores that. Prompt text is not a control, so this is *detected*, not
  *prevented* — which is the honest description and the reason §11 makes a
  `breached` verdict a kill criterion.
- **Not addressed by this design:** two seats reading the same file while a
  third edits it. Under the prompt contract no seat edits anything, so this
  cannot arise unless containment is already breached.

### 8.3 `TMUX_PANE` cuts both ways

M15: era scrubs 8 agent env vars and not `TMUX_PANE`. A nested `claude` spawned
by era inherits the driving session's `TMUX_PANE` and its hooks then write to
the *operator's* window — incrementing `@agent_done`, overwriting
`@agent_busy_at`, and running the repo's verdict gate on a window whose agent
did nothing. This is a **pre-existing defect in the process-spawn backends**,
independent of this spec, and it is one more reason era must not build on
`@agent_*` state (M13).

For the tmux backend it is in scope: `wsl.exe` is launched with `TMUX` and
`TMUX_PANE` scrubbed, so the seat window's own tmux identity is the one tmux
assigns it.

### 8.4 The claude seat's privilege increases

Per M10, an interactive claude seat requires `--dangerously-skip-permissions`
where the process seat uses `--allow-dangerously-skip-permissions`. This is a
real escalation and it is stated here rather than buried: under this transport
the `opus` seat gains bypass it does not have today. It does not exceed what the
opencode and agy seats already have, and `seat_containment` measures the
consequence, but the brief's claim that nothing new is exposed is wrong for this
one seat.

---

## 9. Honest cost accounting

The headline "2,808 lines replaced by one mechanism" does not survive contact
with the files. Function-level `wc`:

**Plausibly deleted (transport-shaped):**

| | lines |
|---|---|
| `opencode`: stall/budget inference (5 functions) | 454 |
| `opencode`: delivery-mode split — attach cap, bundle sizing | 72 |
| `agy`: `Get-AgyTranscriptResponse` (transcript-store parsing) | 207 |
| `agy`: `_SpawnAndCaptureOnce` | 210 |
| `claude`: `Get-ClaudeRemainingMs` + the stdin-pipe machinery | ~90 |
| shares of the three `Invoke-*Review` bodies | ~250 (INFERRED) |
| **total** | **~1,280** |

**Survives regardless (policy, not transport):** variant resolution, model-map
lookups, per-reviewer cost caps, prompt assembly, pricing, the detectors. Also
`agy.ps1` in full until §13 is done.

**Added:** `backends/tmux.ps1` (~400-600, INFERRED), registry launch blocks,
session/window lifecycle, staging and promotion, canary handling, new `Error`
codes in `Get-EraRecoverableFailures`, and tests for all of it.

So the realistic first-cut figure is **~1,280 deleted against ~500 added, and
only if both process-spawn adapters are eventually retired** — which this spec
does not propose. On day one it is purely additive. Anyone approving this on the
2,808 number is approving something that is not on offer.

**Against that, three things the process transport cannot do at any price:**

1. A seat that reads the bundle off disk has no attach cap and no delivery-mode
   split, so M4's failure — a 59,034-byte bundle over opencode's 51,200-byte
   cap, 621 s, zero characters — cannot occur in this shape.
2. A dead seat is detected in seconds (§6 rule 2) instead of at budget
   exhaustion.
3. A new model becomes a data change (§13).

**And one thing it demonstrably does worse: M9.** The opencode TUI cannot be
told a reasoning effort. That is a real loss on the exact seat this design is
meant to rescue.

---

## 10. The spike

Two seats, not four. Same prompt, same bundle, known-good archived comparanda —
`.external-reviews/model-drift/round-6-{prompt.md,bundle.xml}` and the three
responses that round produced.

**Seats:** `opus` via `claude`, and `deepseek-flash` via `opencode`.
deepseek-flash is the sharp case: it *failed* that round for transport reasons
(M4), so a real review from it is a measured capability win rather than a
re-implementation of something that already worked.

**Positive controls first, before any negative result is believable.** The last
session recorded five window-probe results that were all wrong and all looked
clean; the pattern was a fact about the instrument reported as a fact about the
subject. So, in order, and each must produce a **one** before any **zero** is
reported:

- **C1** — create the `era-panel` session and a window running `sleep 60`.
  Assert `#{pane_current_command}` reads `sleep` and `#{window_activity}` is
  within a few seconds of `date +%s`. *Proves the instrument can see a live
  window at all.*
- **C2** — let it exit. Assert `pane_current_command` changes. *Proves the death
  signal fires.* Without C2, "the seat died" and "my probe cannot tell" are the
  same reading.
- **C3** — a window that writes a file with the canary and one that writes the
  same file without it. Assert accept and reject respectively. *Proves the
  completion signal discriminates,* rather than accepting anything on disk.
- **C4** — feed the archived `round-6-opus-response.md` through the promotion
  path. It must pass `Test-EraCaptureAcceptable`. *Proves the validator accepts
  a known-good review,* so a later rejection means something.

**Then the two seats,** dispatched concurrently, and recorded per seat:
wall-clock; canary present; file bytes; `Test-EraCaptureAcceptable` verdict;
citation-checker result; and `seat_containment` for the round.

**Comparison, and its limit.** Against round 6: opus produced 7,248 chars,
deepseek-flash produced nothing. The honest read of a tmux opus review is
therefore *"a review of comparable substance"*, judged by the detectors and the
citation checker — **not** "better", which two samples cannot support. For
deepseek-flash the bar is unambiguous and binary: 0 characters, or a review.

The spike is throwaway. It does not touch `workflow.ps1`, `runtimes/era.ps1`, or
any existing backend, and it adds no registry key to the default panel. The full
suite (1140 passed / 0 failed, ~17 min) runs before and after and must be
unchanged, because nothing on its paths was edited.

---

## 11. Kill criteria

Stated in advance, so the result is not negotiated afterwards.

1. **Any control C1-C4 fails or is inconclusive.** The instrument is not
   trusted; no result from the seats means anything. Stop.
2. **`seat_containment` returns `breached` or `unmeasured`.** Four yolo agents
   in one live tree with no reliable containment readout is not a thing to
   iterate on.
3. **The deepseek-flash seat still returns nothing.** The single concrete
   failure this design exists to beat, unbeaten.
4. **M9 cannot be worked around.** If reasoning effort cannot be set for a TUI
   opencode seat through config, then this transport trades a known failure for
   a silent degradation — the worse of the two, because the first is visible in
   metadata and the second is not.
5. **Either seat needs pane text to be made to work.** That is design A, which
   was rejected on its merits in §4 and does not become correct by being arrived
   at gradually.

Missing any of these means the answer is §4's option C, and this document
becomes the record of why.

---

## 12. What remains unmeasured

Listed so nothing here is mistaken for evidence.

- Whether a TUI agent reliably writes the file and completes its turn. **This is
  the central bet and the spike exists to settle it.** The design's response is
  not confidence but detectability: the canary makes a failure legible rather
  than silent.
- Whether opencode's reasoning effort can be set for a TUI session at all (M9).
- The `agy` seat entirely: reachable from WSL by absolute path (M12), but a
  Windows console application driven through a Linux pty is unmeasured and is
  the reason `agy` is out of scope.
- TUI cold-start latency per round, against the 700 s seat floor.
- Whether interop-boundary polling is cheap enough at a 15 s cadence. Believed
  yes; not timed.
- The ~500-line estimate for `backends/tmux.ps1` (§9) is INFERRED from the
  shape of the existing adapters, not from anything written.

---

## 13. If it works

In dependency order, each its own decision, none of them approved here.

1. **`cmdc`.** 68 models including kimi-k3, glm-5.3, minimax-m3, and **no era
   backend at all** — no `backends/cmdc.ps1`, zero registry references. Under
   this transport it is one `tmux_launch` block, so it is the cheapest large
   capability gain available and it should be the first extension.
2. **`agy`,** if the Windows-TUI-in-a-Linux-pty question (§12) resolves. Only
   then does `agy.ps1`'s 971 lines come into play, and only then does the
   line-count argument in §9 reach the headline figure.
3. **Retiring a process-spawn adapter.** Requires a transport that has carried
   real rounds without a containment breach. Not before.

**A four-seat panel is not a goal of this work.** Two seats settle the question;
four is a scaling decision to be taken on the evidence the two produce.

---

## 14. Open questions for review

1. §5.4 kills the seat window every round to keep rounds independent, paying a
   cold start each time. Is round independence worth that, or is there a case
   for persistence that does not contaminate the 0-criticals terminal condition?
2. §6 rule 3 borrows era's measured stall threshold, which was measured against
   *stdout silence from a one-shot child*. `#{window_activity}` measures *pty
   output from an interactive TUI*, which redraws spinners. Is the number
   transferable, or does a TUI's idle redraw make silence rarer and the
   threshold too generous to ever fire?
3. §9 concedes the real saving is ~1,280 lines, additive on day one, and §11.4
   concedes a possible silent-degradation trade. Is that still worth building,
   or does M4 alone — one seat, one round — not justify a second transport?
4. §8.2 detects rather than prevents git-index contention. Is detection
   sufficient for four concurrent yolo agents, or does this need a real control
   (a worktree per seat) before it runs on anything but a spike?
5. §5.5 has the model write a staging file that era promotes. Is there a failure
   mode where a model writes the canary to a *complete-looking but wrong* file —
   and would the citation checker catch it?
