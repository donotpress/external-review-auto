# tmux TUI transport as an era backend

**Date:** 2026-09-06 · **Revision:** 4 (after rounds 1-3; dispositions in §15)
**Status:** design, unbuilt. Nothing here has been implemented.
**Scope:** one new backend, `backends/tmux.ps1`, carrying an `opus` seat and a
`deepseek-flash` seat. `agy` and `cmdc` are out of scope for the first build.
**The decision this asks for:** build the spike in §10, or don't.

> **Revision 3 retired this design's line-count argument** (§9): the case now
> rests entirely on capability against a day-one cost that is roughly a wash.

---

## 1. The question

era dispatches its panel by spawning each vendor CLI as a one-shot child
process. Three adapters, 2,808 lines, each re-solving the same four problems:
get the bundle to the model, know whether it is alive, know when it is done, get
the text back.

Could one transport do all four for every vendor? Run each seat's **interactive
TUI** in a detached tmux window, and have the model **write its review to a
file** rather than to a pipe.

**The extraction problem does not arise, because nothing is extracted.** Every
one of these TUIs has file-write tools. The prompt ends with "write your review
to `<path>`". era then reads a file. No ANSI, no spinners, no turn-boundary
parsing, no truncation guessing.

An earlier session rejected "run the panel in tmux" because capturing a review
out of TUI scrollback is unsolved. That objection is correct and aimed at a
different design. **This spec never reads pane text.** Everything it takes from
tmux is structured window metadata (§6); if any part of this design calls
`capture-pane`, that part is wrong.

---

## 2. What is measured

All run on this box, 2026-09-05/06. Anything absent is `INFERRED` and flagged
where used.

### 2.1 era and the environment

| # | Claim | Command | Result |
|---|---|---|---|
| M1 | Adapter cost is 2,808 lines | `wc -l backends/{opencode,agy,claude}.ps1` | 1492 + 971 + 345 |
| M2 | era sets no working directory; seats inherit the repo | `grep -n '\.WorkingDirectory' backends/*.ps1 workflow.ps1 runtimes/era.ps1` | one hit, itself a comment recording this grep |
| M3 | `.external-reviews/` is gitignored **and** exempt from `NewDirty` | `git check-ignore -v` → `.gitignore:2`; `workflow.ps1:1058` | still load-bearing — see §8.1 |
| M4 | Round 6 lost the deepseek-flash seat to transport | `round-6-metadata.json` | `exit_code -1`, `0` chars, `621.1s`, `delivery_mode read-tool` |
| M15 | era's env scrub omits `TMUX_PANE` | `tests/EnvScrub.Tests.ps1:10-19` | 8 vars, `TMUX_PANE` absent |
| M16 | Cost uses era's **own** bundle token count, never the adapter's `InputTokens` | `workflow.ps1:2957,3007`; `claude.ps1` returns `InputTokens = $null` | only `OutputTokens` must be supplied (§7.2) |
| M17 | `{{PREVIOUS_ROUND}}` admits up to **80,000 chars** | `workflow.ps1:711` | decides prompt delivery — see M22 |
| M28 | era's measured stall policy is a **per-turn** silence budget | `docs/assessments/2026-09-04-stall-threshold-measured.md` | productive silences to **570.2 s**; 3.97 % over 300 s |

### 2.2 The CLIs

| # | Claim | Command | Result |
|---|---|---|---|
| M7 | `claude` takes its prompt as an argv positional | `claude --help` | `Usage: claude [options] [command] [prompt]` |
| M8 | The `opencode` **TUI** takes `--prompt`, `-m`, `--auto` | `opencode --help` | all three on the default command |
| M9 | The `opencode` TUI does **not** take `--variant` | `opencode --help` vs `opencode run --help` | present on `run`, absent on the TUI |
| M10 | `claude`'s two permission flags differ | `claude --help` | `--allow-dangerously-skip-permissions` *enables the option*; `--dangerously-skip-permissions` *bypasses* |
| M11 | A Windows exe launched from WSL keeps its cwd only from a DrvFs dir | `cmd.exe /c cd` from the repo vs `/tmp` | `C:\Users\...` vs `UNC paths are not supported` |
| M12 | `agy` is off the WSL PATH but reachable by absolute path | `command -v agy` → miss; `agy.exe --version` → `1.1.27` | `interop.appendWindowsPath=false` |
| M13 | `tui-workspace`'s completion signal is an external per-agent hook | source: `@agent_busy_at` "written ONLY by agent-signal" | era would depend on a hook it does not own |

`claude` and `opencode` are both WSL-native, so M7-M9 were run in the
environment the seats will run in. `agy` is not, which is why it is out of scope.

### 2.3 The tmux instrument — ten probes on a private socket, tmux 3.7c

| # | Question | Result |
|---|---|---|
| M18 | Does a window's **row vanish** when its command exits? | **Yes.** Listed at t+1s, gone at t+5s, siblings unaffected |
| M19 | Does `#{pane_current_command}` follow a **foreground child**? | **Yes.** A window running `bash -c "sleep 30"` reports `sleep` |
| M20 | Does `#{window_activity}` **freeze** in silence? | **Yes.** delta **0** across 8 s |
| M21 | Does `#{window_activity}` **advance** on output? | **Yes.** delta **8** across 8 s |
| M22 | How large an argv survives `tmux new-window`? | 4,096 ✓ · 8,192 ✓ · 12,288 ✓ · **16,384 ✗** · 32,768 ✗ |
| M23 | Does a hostile prompt survive as **separate argv elements**? | **Byte-identical** (newlines, `"`, `'`, `$( )`, backticks, `;`, `&&`, `\|`) and **no injection artifact** |
| M24 | How does an **absent server** read? | `no server running on …`, `rc=1` |
| M25 | Does the **server exit when its last window's command exits**? | **Yes** — and it then reads *identically to M24* |
| M26 | Does a **sentinel window** preserve the distinction? | **Yes.** Seat row gone, server alive, `rc=0` |
| M27 | Does `new-window` report a bad launch **synchronously**? | **No.** `rc=0` for a nonexistent binary; `rc=0` for an over-ceiling argv (stderr says `command too long`), and **no window is created** |

**Four of these deleted or changed a mechanism this spec had adopted.**

- **M19** killed revision 1's death signal. `#{pane_current_command} != fg_command`
  reads a seat running any `bash` tool as dead. Replaced by window absence (M18).
- **M22 + M17** killed revision 1's prompt delivery. Round 1's prompt is 1,269
  bytes and would have passed; `{{PREVIOUS_ROUND}}` admits 80,000. The ceiling is
  under 16,384, so argv delivery would have **passed its own first test and
  failed from round 2 onward**. Prompts go in a file (§5.3).
- **M25** killed revision 2's failure classifier. Without a sentinel, a seat's
  death empties the server, and "the seat died" becomes byte-identical to "tmux
  is unreachable" — the fail-open shape era has three recorded instances of.
  M26 is the fix: era's session keeps a sentinel window for its lifetime.
- **M27** killed the idea that launch success is a return code. A bad binary path
  exits 0. Launch is confirmed by **the window row appearing** (§6).

**One environment fact, found by a guard rather than a probe.** A bare `tmux`
addresses the socket in `$TMUX` — here, the operator's live 12-window server. A
local `tmux-guard` hook blocks it, recording that this assumption "already
destroyed this workspace once". **era runs its own server, `tmux -L era`.**

### 2.4 Two measurements correct the brief this was commissioned from

- **M9 is a capability regression.** era's opencode seats pass `--variant
  xhigh`/`high`; the TUI has no such flag, so the seat runs at default reasoning
  effort — the silently-ignored-variant shape the registry notes spent two days
  on, reintroduced *by construction*. §10 C6 searches for a workaround; §11.4
  scopes the failure.
- **M10 makes the claude seat's flag change real.** The brief asserts yolo agents
  in the repo are "not a new exposure". True for opencode and agy; false for
  claude, which today gets only the `--allow-` form (§8.2).

---

## 3. What must not change

Transport is not protocol. Untouchable: round numbering; per-claim disposition;
the 0-criticals terminal condition; archived artifacts under
`.external-reviews/`; the citation checker; `seat_containment`; the
`round-N-*-response.md` glob that builds `{{PREVIOUS_ROUND}}`.

The transport sits **behind** era's existing backend interface:

```
backends/<backend>.ps1  →  function Invoke-<Backend>Review
  in:  -BundlePath -PromptPath -ResponsePath -ModelInfo -TimeoutSec
       -ModelOverride -OpencodeProvider -AgyModelHint [-PidFile]
  out: @{ Response ExitCode Error ContentOk CaptureMethod
          InputTokens OutputTokens WallClockSec TruncationWarning
          Stderr Warnings }
```
(`workflow.ps1:2082-2135`.)

**Routing.** `Invoke-ReviewerDispatch` selects an adapter by
`$Registry[$r].backend`, so the selector is **a distinct registry preset**:

```jsonc
"opus-tmux":           { "backend": "tmux", "transport_of": "opus",           ... },
"deepseek-flash-tmux": { "backend": "tmux", "transport_of": "deepseek-flash", ... }
```

`-Reviewer opus-tmux` routes to `backends/tmux.ps1`; `-Reviewer opus` keeps
`claude.ps1`. The dispatcher needs no change, the default panel is untouched, the
two transports are A/B-comparable in one round, and no existing preset moves.

---

## 4. Approaches considered

**A. Pane scraping** — *rejected*, and what the earlier rejection was aimed at:
scrollback is a rendering, not a record. **B. File-write TUI transport** —
*recommended, on capability grounds only* (§5-§8). **C. Do nothing** — three
adapters, 1140 green tests, and after §9 a day-one line-count case that is
roughly a wash; **C is the answer if the spike misses any kill criterion in
§11.** B is proposed as an opt-in second transport with process-spawn remaining
the default. No adapter is deleted by this spec.

---

## 5. Architecture

### 5.1 `backends/tmux.ps1`

Runs in Windows pwsh like every other adapter. Owns: scratch-dir setup (§5.4),
staging (§5.3), launch and launch confirmation (§6), the wait loop, promotion
(§5.6), teardown on every path it controls, reaping of the paths it does not
(§5.5), and era's result hashtable.

It launches `wsl.exe` through `ProcessStartInfo` with `CreateNoWindow=$true`,
`UseShellExecute=$false`, and the existing 8-var scrub **plus `TMUX` and
`TMUX_PANE`** (M15). `tests/EnvScrub.Tests.ps1` gains `tmux` to its `-ForEach`.

### 5.2 The launch table — registry data, not code

```jsonc
"opus-tmux": {
  "backend": "tmux", "transport_of": "opus", "model_id": "claude-opus-5",
  "tmux_launch": ["claude", "--model", "{model_id}",
                  "--dangerously-skip-permissions",     // M10, not the --allow- form
                  "Read {instructions} and follow it exactly."]
},
"deepseek-flash-tmux": {
  "backend": "tmux", "transport_of": "deepseek-flash",
  "model_id": "opencode-go/deepseek-v4-flash",
  "tmux_launch": ["opencode", "-m", "{model_id}", "--auto",
                  "--prompt", "Read {instructions} and follow it exactly."]
}
```

A seat is tmux-transportable iff it has a `tmux_launch` array. Adding `cmdc` is
a data change (§13).

**No key-sending anywhere.** M7/M8: both CLIs accept an initial prompt at launch,
so the first turn is submitted by the process's own startup. "Does send-keys race
TUI readiness" is **removed as a question**, not answered. §5.5's fresh window
per attempt means no seat is ever sent a second turn.

**The exec vector is fixed end-to-end and contains no shell.** Windows pwsh →
`ProcessStartInfo` → `wsl.exe -d Ubuntu -- tmux -L era new-window -d -t era:
-n <win> -c <scratch> -- <argv...>`, each element a distinct argument. M23
measured a hostile prompt arriving byte-identical with no injection artifact. **A
shell string anywhere in this chain reintroduces the hazard M23 shows is
otherwise absent**, so a test asserts the argv form.

### 5.3 Prompt and bundle staging

Per M22 the argv ceiling is under 16,384 and per M17 a round prompt may reach
80,000, so **the argv carries only a fixed ~60-byte pointer** and everything real
is staged on disk:

```
<scratch>/instructions.md   era's round prompt + the envelope below
<scratch>/bundle.xml        a copy of round-N-bundle.xml
<scratch>/review.md         where the model writes  (absent at launch)
```

Envelope appended to era's existing round prompt:

```
The review bundle is the file bundle.xml in your current directory.
Write your complete review to the file review.md in your current directory.
Do not read, write, or create any other file.
State, as the first line of review.md, how many lines bundle.xml contains:
ERA-BUNDLE-LINES: <count>
Write the last line ONLY when the review is final, and do not edit the file
afterwards. That last line must be exactly, alone on the line:
ERA-CANARY-<nonce>
```

- **Every path is a bare filename in the cwd.** era does exactly one
  translation, once: scratch Windows path → WSL path via `wslpath -u`, quoted for
  spaces. The scratch dir sits under Windows `%TEMP%` (hence DrvFs), so a future
  Windows-exe seat inherits a valid cwd (M11).
- **Nonce and scratch dir are per dispatch attempt**, not per round, so a retry
  cannot promote the previous attempt's leftover file.
- **The canary is a completion contract, not a race to win.** Round 2 noted that
  stability across two polls is necessary but not sufficient — a model could
  write a canary-valid file and then revise it. Rather than add a quiescence
  mechanism, the prompt makes the canary mean "final". §10 records whether
  `review.md` is written more than once, which measures compliance; if models
  routinely revise after the canary, this contract is wrong and the design needs
  a turn-end signal it does not currently have.
- **Canonical matching.** era compares the last non-empty line, trailing
  whitespace and CR stripped. Both marker lines are removed before validation.
- **`ERA-BUNDLE-LINES` is a cheap read-truncation probe.** era knows
  `bundle.xml`'s true line count, so a mismatch is evidence the model saw less
  than the whole bundle — the silent failure §9.1 concedes the canary cannot
  catch. It is a **warning, never a gate**: a model can report a count it did not
  derive, so agreement is weak evidence and disagreement is strong evidence. This
  is the only new detection added after round 3, and it is two lines of prompt
  plus one comparison.

### 5.4 Isolation: the seat does not run in the repo

Each seat's cwd is a fresh per-attempt scratch directory outside any git work
tree, holding exactly the three files above.

**What this is and is not.** Round 2 found revision 2 overclaiming here, and it
was right. The seat runs `--dangerously-skip-permissions` with a full filesystem;
absolute paths still resolve. **This is not a sandbox.** What changes is that the
repo is no longer the seat's working directory and no repo path is handed to it,
so reaching the repo requires the model to go looking for a path it was never
given, against an instruction not to.

| Hazard | Revision 1 (cwd = repo) | Now | Enforced? |
|---|---|---|---|
| Seat **writes** into the repo | plausible, path in hand | no path, no reason | detected by `seat_containment` |
| Peers' in-flight files **written** | shared directory | separate directories | structural |
| Git index contention | live hazard | no work tree in cwd | structural |
| Seat's own state files tripping containment | likely | land in scratch | structural |
| Prior rounds / peers **read** | one `ls` away | requires seeking an unGiven path | **not enforced, not detectable** |

That last row is the honest residual. `seat_containment` diffs `git status`, so
it sees **writes only**; a seat that read every prior round would still return
`contained`. Round 1's finding is therefore **mitigated, not eliminated**, and
§11.2 cannot fire on it. Real confinement would need a mount namespace or a
bind-mounted root — deliberately **not** proposed here, because it is a new
subsystem to close a gap the spike has not yet shown to be exercised. §12 records
it as unmeasured, and §14.1 asks whether that is acceptable.

era's round prompt already says *"Review ONLY what is in the bundle."* The
scratch directory makes that instruction **easy to follow**, which is a weaker
claim than revision 2 made and the one the evidence supports.

### 5.5 Server, session, window lifecycle, and reaping

- **era's own tmux server: `tmux -L era`** (§2.3), invisible to `tui-workspace`,
  which addresses its own `$SESSION` on the default socket.
- **A sentinel window, named exactly `era-sentinel`, is created with the session
  and outlives every seat.** Without it, M25: the last seat's death kills the
  server and reads exactly like M24's transport failure. It runs `sleep
  infinity` — a finite command would reintroduce M25 the moment it returned —
  and it is matched by exact name, so it is excluded from both the sweep below
  and every seat-presence test. Because `new-session -A` attaches to an existing
  session **without recreating an initial window**, era checks for `era-sentinel`
  after every `new-session -A -d` and recreates it if absent. Round 3 found the
  sweep killing the sentinel and nothing restoring it, which silently reinstated
  M25; the exact-name exclusion plus check-and-recreate is the fix.
- **era does not use `tui-workspace`** — 123 KB era does not own, untested by
  era, and M13 shows its completion signal comes from a hook installed outside
  era. era's calls are `new-session -A -d` (`-A` so an existing session attaches
  rather than erroring), `new-window`, `list-windows -F`, `kill-window`.
- **One fresh window per seat per attempt**, named
  `era-<hostpid>-<slug>-r<N>-<seat>-<attempt-nonce>`, killed when the attempt
  ends — and the kill is **verified** by re-listing, because an unverified
  `kill-window` leaves an unattended agent behind. `<hostpid>` is era's own
  process id, so any process can test the owner's liveness with `Get-Process
  -Id`. The **attempt nonce** is required because a retry of the same seat and
  round would otherwise reuse the name, and a leftover row from the previous
  attempt would falsely satisfy §6's ever-alive latch.
- **Reaping, because era's own death is not a path era controls.** Windows are
  detached on a persistent server, so a crashed or interrupted era leaves
  unattended `--dangerously-skip-permissions` agents with no budget. On **every**
  launch, before creating anything, era sweeps windows matching
  `era-<pid>-*` whose `<pid>` is not a live process (`Get-Process -Id`), skipping
  `era-sentinel`. Encoding the pid **in the window name** is what makes the sweep
  decidable: revision 3 said "sweep windows whose runid is not live" while
  providing nothing that mapped a runid to a process, so the sweep had no
  implementable test — three reviewers found it independently.
- **`-PidFile` keeps its existing contract and is honestly partial.**
  `Stop-EraAdapterChild` (`workflow.ps1:894-897`) `[int]::TryParse`s the file, so
  a non-numeric runid would not throw — it would return `$false` and make the
  straggler kill a **silent no-op**. The adapter writes the real `wsl.exe` pid.
  **That kill tears down the launcher and does *not* remove the tmux window**,
  which belongs to the tmux server in another process tree. So the
  dispatcher-level straggler kill cannot reach a tmux seat: the adapter must
  terminate within its own `$TimeoutSec`, and the sweep above is the backstop.

### 5.6 Staging and promotion

The model writes `<scratch>/review.md`; era promotes it to `$ResponsePath` only
after it passes. `claude.ps1:324` records the rule this protects: *"A non-review
is not written to disk … so it cannot be picked up by the
`round-N-*-response.md` glob that builds the next round's `{{PREVIOUS_ROUND}}`
context."* Under this transport the model holds the pen, so writing straight to
`$ResponsePath` would let a refusal enter the next round's context as a review.
The scratch path cannot match that glob.

1. **Stability** — size and mtime identical across two consecutive fast polls,
   so a streaming write is not caught mid-flush. Required **only while the writer
   is alive (rule 1)**. Under rules 2-3 the writer is gone or killed and nothing
   can change, so a canary there is accepted **without** a stability sample —
   which is what makes §6's success branches reachable.
2. **Canary** — last non-empty line matches (§5.3); then stripped.
3. **`Test-EraCaptureAcceptable`** (`_capture-validation.ps1:309`, unchanged,
   shared with five backends).
4. Write `$ResponsePath`.

On failure the scratch `review.md` is copied to
`.external-reviews/<slug>/round-N-<seat>-raw.md` as the forensic record, and the
scratch dir is removed.

---

## 6. Completion and liveness

Two signals, plus a launch confirmation. All are structured tmux metadata or a
local file stat; none is pane text.

| Signal | Source | Answers |
|---|---|---|
| **Launched** | the window row **appears** after `new-window` | the seat actually started |
| **Completion** | `review.md`, stable, last line == canary | done, and write-complete |
| **Death** | the window's row is **absent** while the sentinel still answers | the seat's process exited |

**Launch is confirmed by observation, not by a return code.** M27: `new-window`
exits 0 for a nonexistent binary and for an over-ceiling argv. era therefore
polls for the window row to appear within 10 s; if it never does, that is
`tmux-transport-unavailable` — a launch fault, **not** a seat verdict, and not
eligible for the bounded re-dispatch. This is also the **ever-alive latch**:
absence only means death *after* presence has been observed once.

**Death is window absence, not `#{pane_current_command}`.** M19: the pane command
follows any foreground child, so a seat running a `bash` tool would have read as
dead. M18: a window is destroyed when its command exits — and the window's
command *is* the agent, so absence is exactly agent exit. M25/M26: the sentinel
is what keeps this distinguishable from an unreachable server, which is M24's
`rc=1`.

The wait loop polls `review.md` on the Windows side (a local stat, effectively
free) and calls into WSL every 15 s, so death is detected **within 15 s**, not
immediately.

Terminal conditions, in precedence order. **Each first stats `review.md`,** so a
partial file is labelled truncation rather than by whatever ended the attempt:

1. Canary present and stable → **success**.
2. Window absent (after launch confirmed), then branch **three ways** on the
   file: canary present → **success** (no stability needed — the writer is gone);
   file without canary → `tmux-seat-truncated`; no file → `tmux-seat-exited`.
3. `$TimeoutSec` reached → kill, verify the window is gone, then branch three
   ways: canary present → **success**; file without canary →
   `tmux-seat-timeout-partial`; no file → `tmux-seat-timeout`.

Round 3 found revision 3's version of rules 2-3 had **no success branch**: a
model that wrote a complete, canary-valid `review.md` and exited was caught by
rule 2's `else` and recorded as `tmux-seat-exited`, `ExitCode -1`. The same
inversion made near-success non-retryable while garbage was retried. Both are
fixed by branching on the canary first.

**Neither timeout code is recoverable.** Revision 3 routed a timed-out seat that
had written a partial file into `tmux-seat-truncated`, which §7.1 marks
recoverable — so a seat that burned its whole budget became re-dispatchable for
another whole budget, indefinitely. `tmux-seat-timeout-partial` exists to keep
the partial-file diagnosis without inheriting truncation's recoverability.

**There is no stall rule, and `#{window_activity}` is not used.** Revisions 1-2
had one, borrowing era's measured threshold. Round 2 showed the borrowing
invalid on two counts, and the arithmetic finished it:

- **Semantics.** M28's policy is a **per-turn** silence budget; an adapter that
  sees turn boundaries resets the clock each turn. `#{window_activity}` is one
  clock over the whole attempt, so the same number means a different thing.
- **Arithmetic.** M28 records productive silences to **570.2 s**. A threshold
  safely above that, against a bundle-scaled budget of ~800 s, leaves a stall
  rule roughly **100-130 s** before `$TimeoutSec` claims the attempt anyway.

M20/M21 established the *instrument* is sound — the epoch freezes in silence and
tracks output. It is not the instrument that fails; it is that the rule it would
drive is worth ~2 minutes on a 13-minute budget, at the cost of a third liveness
mechanism and a threshold whose validity does not transfer. **So it is deleted.**

**The cost of that deletion, stated plainly.** An interactive TUI does not exit
when its turn ends — it sits at a prompt. So a seat that finishes its turn
*without* writing the canary (it answered in chat, refused, or stopped after a
partial write) never triggers rule 2, and burns the **full `$TimeoutSec`** before
rule 3 classifies it. Round 3 raised this as the direct consequence of deleting
the stall rule, and it is accepted rather than patched: for a two-seat spike the
worst case is one ~800 s wait, and era's dispatcher already bounds a lone
straggler. **No turn-end rule is added now**, because none is available without
pane text (§11.5) or an `agent-signal`-style hook era does not own (M13). What
changes is that **C5 now records whether a turn-ended TUI goes quiet** — if it
does, a cheap turn-end rule becomes available in a later revision; if it does
not, this cost is permanent and should be weighed in §14.2.

---

## 7. Failure taxonomy and the result contract

### 7.1 Failures

| Failure | Detected by | `ExitCode` | `Error` | Recoverable |
|---|---|---|---|---|
| Complete review | canary + stability | 0 | — | — |
| Partial write | file present, canary absent (rules 2-3) | -1 | `tmux-seat-truncated` | yes |
| Gone, nothing written | window absent after launch (M18, M26) | -1 | `tmux-seat-exited` | yes |
| Budget exhausted, partial file | `$TimeoutSec`, canary absent | -1 | `tmux-seat-timeout-partial` | **no** |
| Budget exhausted, nothing written | `$TimeoutSec`, no file | -1 | `tmux-seat-timeout` | no |
| Refusal / narration | `Test-EraCaptureAcceptable` | -1 | `agentic-narration-capture` | as today |
| Never launched | window never appeared (M27) | -1 | `tmux-transport-unavailable` | **no** |
| tmux/WSL unreachable | sentinel gone, `rc=1` (M24, M26) | -1 | `tmux-transport-unavailable` | **no** |

The last two rows must fail loudly and must **not** be recoverable. era has three
recorded fail-open catches where a read failure became indistinguishable from a
real measurement. A deterministic config fault — a bad model id, an argv over the
ceiling — would otherwise burn the bounded re-dispatch budget pretending to be a
flaky seat.

Only `tmux-seat-truncated` and `tmux-seat-exited` are recoverable, and neither
can be produced by a timeout (§6). The two `yes` rows are added to
`Get-EraRecoverableFailures`
(`workflow.ps1:2604`), which keys the re-dispatch on `Error`; any `Error`-string
allowlist in the metadata schema or its tests must accept the new codes.

### 7.2 Token telemetry

M16: era computes input cost from **its own** `$BundleTokens`, and `claude.ps1`
already returns `InputTokens = $null`, so the tmux backend returns `$null` too.
Only `OutputTokens` is consumed (output cost, per-reviewer cap), using the
estimator `claude.ps1` already uses: `ceil(chars/4)` over the promoted response.
Recorded because revision 1 never said where these came from; **no new mechanism
is introduced.**

---

## 8. Containment and exposure

### 8.1 Containment stays, and M3 stays load-bearing

`seat_containment` (`workflow.ps1:1016`) diffs `git status` around the dispatch.
Revision 2 claimed the expectation was now "`NewDirty` empty for every path";
that is **false**, because era itself writes `$ResponsePath` inside the repo
during the round. M3's `.external-reviews/` exemption is exactly what covers
that write and remains necessary. The expectation is unchanged from today:
`contained`, with `NewDirty` empty **outside** `.external-reviews/`.

What §5.4 changes is the meaning of a breach: with no repo in the seat's cwd, a
repo write is now unambiguous evidence a seat went looking. It remains a
**write**-only instrument (§5.4's last row).

### 8.2 The claude seat's flag changes; its reach shrinks

Per M10 an unattended interactive claude seat needs
`--dangerously-skip-permissions` where the process seat uses the `--allow-` form.
Stated plainly because it is an escalation of the flag. But under §5.4 the seat's
cwd holds three files and no repository, where today's process seat runs **in the
repo** (M2). Net reach is lower than today's, though — per §5.4 — not confined.

### 8.3 `TMUX_PANE`

M15: era scrubs 8 vars, not `TMUX_PANE`, so a nested `claude` inherits the
driving session's pane identity and its hooks write to the *operator's* window. A
**pre-existing defect in the process-spawn backends**, out of scope, and one more
reason not to build on `@agent_*` state (M13). The tmux backend scrubs both.

---

## 9. Honest cost accounting

**Revision 3 withdraws the line-count argument.** Revisions 1-2 led with a
~1,280-line saving whose largest single row was `opencode`'s 454 lines of stall
inference. §6 has deleted the stall rule, so that row does not pay — the
transport does not replace stall detection, it does without it.

| Plausibly deleted | lines | day-one? |
|---|---|---|
| `opencode`: delivery-mode split — attach cap, bundle sizing | 72 | yes |
| `claude`: `Get-ClaudeRemainingMs` + stdin-pipe machinery | ~90 | yes |
| shares of the `claude`/`opencode` `Invoke-*Review` bodies | ~250 (INFERRED) | yes |
| `agy`: `Get-AgyTranscriptResponse` + `_SpawnAndCaptureOnce` | 417 | **no** — §13.2 |
| `opencode`: stall/budget inference | ~~454~~ **0** | **withdrawn** |
| **day-one relevant** | **~412** | |

**Added:** `backends/tmux.ps1` (400-600, INFERRED), registry blocks, scratch-dir
and window lifecycle, the reaping sweep, staging, promotion, canary handling, new
error codes, and tests.

**So day one is a wash at best, and quite possibly a net loss of a hundred lines
or so.** Nothing is deleted until a process-spawn adapter is retired, which this
spec does not propose. **Any argument for this design that rests on line count
should be rejected**, including the one revisions 1-2 made.

**What survives is capability:**

1. A seat that reads the bundle from disk has no attach cap and no delivery-mode
   split, so M4's failure — 59,034 bytes over a 51,200-byte cap, 621 s, zero
   characters — cannot occur in this shape. **Qualified:** the model still
   *reads* through a tool with its own limits, and a read-side truncation yields
   a coherent review **with a valid canary**. The canary certifies the write
   reached its last line and **nothing about the bundle reaching the model**.
   Not closed by this design.
2. A dead seat is detected within 15 s rather than at budget exhaustion.
3. A new model becomes a data change — `cmdc`'s 68 models have no era backend at
   all (§13.1). This is the largest single win and it is not a line-count win.

**And one thing it does worse: M9**, on the exact seat this design exists to
rescue.

---

## 10. The spike

Two seats: `opus-tmux` and `deepseek-flash-tmux`, on the archived
`.external-reviews/model-drift/round-6-{prompt.md,bundle.xml}` and that round's
three responses. deepseek-flash is the sharp case — it *failed* round 6 for
transport reasons (M4), so a real review from it is a measured capability win.

**Controls first; no negative result is believable until they pass.** The prior
session recorded five window probes that were all wrong and all looked clean —
each a fact about the instrument reported as a fact about the subject.

- **C1-C4 are already done.** M18-M27 (§2.3) are those controls, run and
  recorded, including the matched pair M20/M21 and the M25/M26 sentinel result.
- **C5 — does a seat launch, reach a file write, and go quiet when its turn
  ends?** Assert the window row appears (M27's latch), then that `review.md`
  appears. Sample `#{window_activity}` every 5 s for the whole attempt **and for
  120 s after the canary lands**, reporting the longest interval with no epoch
  change. This is an *observation, not a rule* (§6 adds none), and it decides
  whether a cheap turn-end rule is available later. **Observation is limited to
  window existence, the activity epoch, and file stats**; revision 2's "assert
  the model's first tool use occurs" is withdrawn, because the only way to see
  that is pane text, which §11.5 forbids.
- **C6 — can opencode's reasoning effort be set without `--variant`?** §11.4
  turns on this. Pre-registered search set, in order: a `variant`/`effort`/
  `reasoning` key under `model` or per-provider in `opencode.json` (measured this
  round: **no such key is present today**); an `OPENCODE_*` environment variable;
  an agent definition (`opencode agent`); a config path named by `opencode models
  --verbose`. Record which were tried and what each returned — a negative is only
  a negative once the set was enumerated in advance.
- **C7 — reaping.** Launch a seat, kill era mid-dispatch, and assert the next
  launch's sweep removes the orphaned window. §5.5's sweep is the only thing
  standing between a crash and an unattended yolo agent.

**Then both seats concurrently**, recording per seat: wall-clock; canary; bytes;
`Test-EraCaptureAcceptable`; citation-checker result; `seat_containment`;
`ERA-BUNDLE-LINES` against the true count; and **whether `review.md` is written
again after the canary**.

That last one needs the harness to hold off: under §5.6 era promotes and tears
down the moment the canary is stable, so the model's process is destroyed before
it could revise and **the observation cannot fail** — a control that records a
never-asked question as a negative answer. The spike therefore **waits 120 s
after the canary before teardown**, watching `review.md`'s mtime. This delay is a
spike instrument only; it is not part of §5.6.

**Pre-registered thresholds.** A seat **passes** iff: canary present;
`Test-EraCaptureAcceptable` returns `Ok`; the citation checker adds no warning;
and the response is ≥ 4,000 characters — the smallest real review in the round-6
archive was muse-spark at 4,226. Against round 6 (opus 7,248; deepseek-flash 0),
the honest claim for opus is *"a review clearing the same bar"*, **not** "better",
which two samples cannot support. For deepseek-flash the bar is binary.

The spike is throwaway: it touches no existing backend, `workflow.ps1`, or
`runtimes/era.ps1`, and adds nothing to the default panel. The full suite (1140
passed / 0 failed, ~17 min) runs before and after and must be unchanged.

---

## 11. Kill criteria

1. **C5, C6 or C7 cannot be run, or C5 or C7 fails.** The seats never worked, or
   a crash leaks unattended agents; nothing downstream means anything.
2. **`seat_containment` returns `breached`.** Under §5.4 that is a seat writing
   into a repo it was given no path to. **`unmeasured` is not this criterion** —
   it means the instrument failed and the spike is *invalid*, to be re-run.
3. **The deepseek-flash seat returns nothing** *for a transport reason*. The one
   concrete failure this design exists to beat. **Resolving the overlap with 4:**
   if C6 finds no effort control but the seat still returns a review that clears
   §10's thresholds at default effort, criterion 3 is **satisfied** and criterion
   4 fires alone. The two are only in conflict if read as the same test; they are
   not — 3 is about transport, 4 is about fidelity.
4. **C6 finds no way to set opencode's reasoning effort.** The transport then
   trades a *visible* failure for a *silent* degradation, which is worse. This
   kills the **opencode seat**, not the transport: §13.1's `cmdc` case and the
   claude seat survive it. The open decision is then whether a transport that
   cannot faithfully carry opencode is worth having — §14.3.
5. **Either seat needs pane text to work.** That is design A, rejected in §4, and
   it does not become correct by being arrived at gradually.

Missing 1, 2, 3 or 5 means the answer is §4's option C.

---

## 12. What remains unmeasured

- Whether a TUI agent reliably writes the file and finishes its turn. **The
  central bet.** The design's answer is not confidence but detectability.
- Whether models revise a file after writing the canary (§5.3's contract), and
  whether a turn-ended TUI goes quiet — both now measured by C5.
- The cost of having no turn-end signal (§6): a seat that finishes without a
  canary burns its full budget. Accepted for the spike, unquantified in
  production.
- Whether opencode's reasoning effort is settable at all (C6, M9).
- **Read confinement (§5.4).** A seat *can* read the repo by absolute path, and
  `seat_containment` cannot see reads. Mitigated by not handing over a path; not
  enforced, not detectable.
- **Read-side truncation** (§9.1): a bundle truncated on read yields a
  canary-valid review of less than the bundle. The citation checker is only a
  partial mitigation — citations to the part the model *did* see are correct.
- The `agy` seat: reachable from WSL (M12), but a Windows console application in
  a Linux pty is unmeasured. The reason it is out of scope.
- TUI cold-start latency per attempt against the 700 s floor; interop polling
  cost at 15 s; the 400-600 line estimate for `backends/tmux.ps1`.

---

## 13. If it works

1. **`cmdc`** — 68 models (kimi-k3, glm-5.3, minimax-m3) with **no era backend at
   all**. One `tmux_launch` array. After §9 this is the primary argument for the
   design, not a follow-on.
2. **`agy`**, if the Windows-TUI-in-a-Linux-pty question resolves. Only then do
   `agy.ps1`'s 417 transport lines enter §9's arithmetic.
3. **Retiring a process-spawn adapter** — only after real rounds without a
   containment breach.

**A four-seat tmux panel is not a goal.** Two seats settle the question.

---

## 14. Open questions for review

1. §5.4 now concedes the scratch directory is mitigation, not confinement: a
   seat can read the repo by absolute path and `seat_containment` cannot see it.
   Is that acceptable for a spike, given today's process seats run **in** the
   repo with the same tools — or does read confinement have to exist before any
   seat runs unattended?
2. §6 deletes the stall rule because it is worth ~100-130 s on an ~800 s budget.
   Is that arithmetic right, and is there a case where a wedged seat burning its
   full budget costs more than the third mechanism would?
3. §9 withdraws the line-count argument entirely, leaving `cmdc` as the main
   case. Is unlocking 68 models with no adapter worth a new subsystem, when the
   two seats it is being tested on both already work over process-spawn?
4. §11.3/§11.4 now resolve their overlap by saying criterion 3 is about transport
   and 4 about fidelity, so a default-effort deepseek review satisfies 3. Is that
   the right reading, or does an unfaithful seat fail the motivating case anyway?
5. Rounds 1-3 found 16, 11 and 14 criticals — roughly flat per seat, and round
   3's were almost all defects introduced by round 2's own fixes (the missing
   success branch, the undecidable sweep, the sentinel the sweep kills). That is
   the signature of a design being patched rather than converging. **Is the
   remaining risk in the design, or is it now in the fact that no line of this
   has ever run?** If the latter, the next round should be the spike, not a
   fifth revision.

---

## 15. Dispositions

Rounds 1-3, four seats each (gemini lost in round 2 to a `stall-or-timeout` in
era's *existing* agy adapter — not evidence about this design). Criticals 16 /
11 / 14; `contained` every round; no citation warnings.

**Rounds 1-2 are embodied in the text above and summarised, not tabulated.**
Round 1: seat moved out of the repo (§5.4); a registry preset became the routing
selector (§3); `tmux-seat-truncated` made reachable by stat-first labelling;
`#{pane_current_command}` deleted as a death signal after M19; prompt moved from
argv to a file after M22/M17; nonce and scratch made per-attempt; exec vector
fixed (M23); `tmux -L era` replaced a bare `tmux`. Round 2: the stall rule and
`#{window_activity}` deleted on a semantics-plus-arithmetic argument, forcing §9
to withdraw the line-count case; sentinel (M25/M26) and launch latch (M27) added;
and two of my overclaims corrected — the scratch dir is mitigation not
confinement, and `NewDirty` is not empty for every path because era writes
`$ResponsePath` itself. Rejected across both: a `/proc` CPU-time stall signal, a
semantic check on the review, and worktree-per-seat.

### Round 3 — 3/6/2/3 criticals

Notable because **almost every finding is a defect introduced by round 2's own
fixes**, which is the signature §14.5 now asks about.

| # | Finding | Raised by | Disposition |
|---|---|---|---|
| 1 | Rules 2-3 had **no success branch**: a model that wrote a complete canary'd file and exited fell through `else` to `tmux-seat-exited`. Near-success got the non-retryable label while garbage got retried | opus, deepseek | **CONFIRMED — §6** rules 2-3 branch three ways, canary first, no stability needed once the writer is gone. Directly caused by round 1's stat-first fix; the fix labelled by cause and only *then* looked at the file |
| 2 | A timed-out seat with a partial file was labelled `tmux-seat-truncated`, which is **recoverable** — so a budget-exhausted seat could be re-dispatched for another full budget, indefinitely | deepseek | **CONFIRMED — §6, §7.1.** New `tmux-seat-timeout-partial` keeps the diagnosis without inheriting recoverability. Neither timeout code is recoverable |
| 3 | The reaping sweep had **no implementable liveness test**: it keyed on a `runid` that nothing mapped to a process | opus, gemini, muse-spark | **CONFIRMED — §5.5.** era's own pid is encoded in the window name, so any process can test it with `Get-Process -Id` |
| 4 | Putting a runid in `-PidFile` breaks the existing consumer | gemini, muse-spark | **CONFIRMED; mechanism corrected. Measured:** `Stop-EraAdapterChild` (`workflow.ps1:894-897`) uses `[int]::TryParse`, so a runid would **not** throw as predicted — it returns `$false`, making the straggler kill a **silent no-op**, the worse failure. The adapter writes the real `wsl.exe` pid; §5.5 states that killing it does not remove the window |
| 5 | The sweep kills the sentinel, and `new-session -A` never recreates it — silently reinstating M25 | opus, muse-spark | **CONFIRMED — §5.5.** `era-sentinel` is exact-named, runs `sleep infinity`, is excluded from the sweep and from presence tests, and is checked-and-recreated after every `new-session -A` |
| 6 | The "written more than once" control **cannot fail**, because era tears down the moment the canary is stable | gemini | **CONFIRMED — §10.** The spike waits 120 s after the canary before teardown. A vacuous control is a never-asked question recorded as a negative answer |
| 7 | Interactive TUIs never exit, so a turn ending without a canary burns the full `$TimeoutSec` — the direct cost of round 2 deleting the stall rule | gemini, muse-spark | **CONFIRMED, ACCEPTED, NOT PATCHED (§6).** No turn-end signal exists without pane text (§11.5) or a hook era does not own (M13). C5 now measures whether a turn-ended TUI goes quiet. Adding a mechanism now would re-add what round 2 removed, on no evidence |
| 8 | Window names lacked a per-attempt nonce, so a leftover row from attempt 1 falsely satisfies the ever-alive latch | muse-spark | **CONFIRMED — §5.5** |
| 9 | `kill-window` is unverified; a failed kill leaves an unattended agent until the next sweep | muse-spark | **CONFIRMED — §5.5**, the kill is verified by re-listing |
| 10 | Read-side truncation is silent where M4 was loud; no detection proposed | muse-spark | **CONFIRMED — partially closed.** §5.3 adds `ERA-BUNDLE-LINES`, a two-line prompt probe against the true count, as a **warning, never a gate**: agreement is weak evidence, disagreement strong. The only new detection this round |
| 11 | Canary-as-contract is unenforced; a canary-valid intermediate can promote | muse-spark | **ACKNOWLEDGED, unchanged.** §5.3 and §12 already record it as unverified; finding 6's fix is what lets the spike measure it. Enforcing before measuring is the accretion §14.5 warns about |
