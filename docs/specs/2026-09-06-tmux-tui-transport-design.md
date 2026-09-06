# tmux TUI transport as an era backend

**Date:** 2026-09-06 · **Revision:** 3 (after rounds 1-2; dispositions in §15)
**Status:** design, unbuilt. Nothing here has been implemented.
**Scope:** one new backend, `backends/tmux.ps1`, carrying an `opus` seat and a
`deepseek-flash` seat. `agy` and `cmdc` are out of scope for the first build.
**The decision this asks for:** build the spike in §10, or don't.

> **Revision 3 retires this design's line-count argument.** Round 2 showed the
> stall-detection saving was illusory (§9), so the case now rests entirely on
> capability — removing M4's failure class and unlocking `cmdc` — against a
> day-one cost that is roughly a wash. Read §9 before §1.

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

- **M9 is a capability regression.** era's opencode seats pass `--variant xhigh`
  / `--variant high`; the TUI has no such flag, so a tmux-transported opencode
  seat runs at default reasoning effort. That is the silently-ignored-variant
  shape the registry notes spent two days on, reintroduced *by construction*.
  §10 C6 pre-registers the search for a workaround; §11.4 scopes the failure.
- **M10 makes the claude seat's flag change real.** The brief asserts yolo
  agents in the repo are "not a new exposure". True for opencode and agy; false
  for claude, which today gets only the `--allow-` form (§8.2).

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

**A. Pane scraping.** *Rejected*, and it is what the earlier rejection was aimed
at: scrollback is a rendering, not a record.

**B. File-write TUI transport.** *Recommended, on capability grounds only.* §5-§8.

**C. Do nothing.** Three adapters, 1140 green tests, and — after §9 — a
day-one line-count case that is roughly a wash. **C is the answer if the spike
misses any kill criterion in §11.**

Recommendation is **B as an opt-in second transport**, process-spawn remaining
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
  whitespace and CR stripped. The canary is removed before validation.

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
- **A sentinel window is created with the session and outlives every seat.**
  Without it, M25: the last seat's death kills the server and reads exactly like
  M24's transport failure. The sentinel is what makes §6 rule 2 sound.
- **era does not use `tui-workspace`** — 123 KB era does not own, untested by
  era, and M13 shows its completion signal comes from a hook installed outside
  era. era's calls are `new-session -A -d` (`-A` so an existing session attaches
  rather than erroring), `new-window`, `list-windows -F`, `kill-window`.
- **One fresh window per seat per attempt**, named
  `era-<runid>-<slug>-r<N>-<seat>`, killed when the attempt ends. `runid` is
  unique per era process so two concurrent era runs cannot kill each other's
  windows.
- **Reaping, because era's own death is not a path era controls.** Windows are
  detached on a persistent server, so a crashed or interrupted era leaves
  unattended `--dangerously-skip-permissions` agents running with no budget.
  On **every** launch, before creating anything, era sweeps `era-*` windows whose
  `runid` is not a live era process and kills them. `-PidFile` receives the
  **runid**, not a process id: the `wsl.exe` pid is a grandparent in another
  namespace and killing it does not kill the window, so a pid there would be a
  reaping mechanism that cannot reap. This sweep is the only defence against
  orphans and it must run even when the current dispatch is a single seat.

### 5.6 Staging and promotion

The model writes `<scratch>/review.md`; era promotes it to `$ResponsePath` only
after it passes. `claude.ps1:324` records the rule this protects: *"A non-review
is not written to disk … so it cannot be picked up by the
`round-N-*-response.md` glob that builds the next round's `{{PREVIOUS_ROUND}}`
context."* Under this transport the model holds the pen, so writing straight to
`$ResponsePath` would let a refusal enter the next round's context as a review.
The scratch path cannot match that glob.

1. **Stability** — size and mtime identical across two consecutive fast polls,
   so a streaming write is not caught mid-flush. Required **only on the success
   path (rule 1)**; rules 2-3 stat a file whose writer is already gone or killed,
   where nothing can change.
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
2. Window absent (after launch confirmed) → file with no canary →
   `tmux-seat-truncated`; else `tmux-seat-exited`.
3. `$TimeoutSec` reached → kill → file with no canary → `tmux-seat-truncated`;
   else `tmux-seat-timeout`.

Revision 1 made `tmux-seat-truncated` unreachable — three reviewers found it
independently — because these rules labelled by cause without looking at the
file. Stat-first fixes it.

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
A wedged seat costs its full budget, which is what era's dispatcher-level
straggler grace already exists to bound.

---

## 7. Failure taxonomy and the result contract

### 7.1 Failures

| Failure | Detected by | `ExitCode` | `Error` | Recoverable |
|---|---|---|---|---|
| Complete review | canary + stability | 0 | — | — |
| Partial write | file present, canary absent (rules 2-3) | -1 | `tmux-seat-truncated` | yes |
| Gone, nothing written | window absent after launch (M18, M26) | -1 | `tmux-seat-exited` | yes |
| Budget exhausted | `$TimeoutSec` | -1 | `tmux-seat-timeout` | no |
| Refusal / narration | `Test-EraCaptureAcceptable` | -1 | `agentic-narration-capture` | as today |
| Never launched | window never appeared (M27) | -1 | `tmux-transport-unavailable` | **no** |
| tmux/WSL unreachable | sentinel gone, `rc=1` (M24, M26) | -1 | `tmux-transport-unavailable` | **no** |

The last two rows must fail loudly and must **not** be recoverable. era has three
recorded fail-open catches where a read failure became indistinguishable from a
real measurement. A deterministic config fault — a bad model id, an argv over the
ceiling — would otherwise burn the bounded re-dispatch budget pretending to be a
flaky seat.

The two `yes` rows are added to `Get-EraRecoverableFailures`
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

### 8.3 `TMUX_PANE` cuts both ways

M15: era scrubs 8 vars, not `TMUX_PANE`. A nested `claude` spawned by era
inherits the driving session's pane identity and its hooks then write to the
*operator's* window. A **pre-existing defect in the process-spawn backends**, out
of scope, and one more reason not to build on `@agent_*` state (M13). The tmux
backend scrubs both.

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
- **C5 — does a seat launch and reach a file write?** Assert the window row
  appears (M27's latch), then that `review.md` appears. **Observation is limited
  to window existence and file stats**; revision 2's "assert the model's first
  tool use occurs" is withdrawn, because the only way to see that is pane text,
  which §11.5 forbids.
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
`Test-EraCaptureAcceptable`; citation-checker result; `seat_containment`; and
**whether `review.md` was written more than once** (which tests §5.3's canary
contract).

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
- Whether models revise a file after writing the canary (§5.3's contract).
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

1. **`cmdc`** — 68 models including kimi-k3, glm-5.3, minimax-m3, and **no era
   backend at all**. One `tmux_launch` array. After §9, this is the primary
   argument for the whole design, not a follow-on.
2. **`agy`**, if the Windows-TUI-in-a-Linux-pty question resolves. Only then do
   `agy.ps1`'s 417 transport lines enter §9's arithmetic.
3. **Retiring a process-spawn adapter** — only after the transport has carried
   real rounds without a containment breach.

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
5. Round 2's response grew 118 % over round 1 and era flagged possible
   divergence. This revision **deletes** a signal, a rule, a spike step and a
   §9 row while adding only reaping and a sentinel. **What else should be cut?**

---

## 15. Dispositions

### Round 1 — 4 seats, 6/2/2/6 criticals, `contained`, no citation warnings

25 findings: 22 confirmed, 3 rejected. Embodied in revision 2 and superseded
below where round 2 revisited them. The load-bearing ones: the seat moved out of
the repo (§5.4); a distinct registry preset became the routing selector (§3);
`tmux-seat-truncated` was made reachable by stat-first labelling (§6);
`#{pane_current_command}` was deleted as a death signal after M19 measured the
false-fire all four seats predicted; the prompt moved from argv to a file after
M22/M17; nonce and scratch dir became per-attempt; the exec vector was fixed and
M23 measured it injection-free; `tmux -L era` replaced a bare `tmux`. Rejected: a
`/proc` CPU-time stall signal and a semantic check on the review (both accretion),
and worktree-per-seat (superseded by §5.4).

### Round 2 — 3 of 4 seats, 4/6/1 criticals

**The gemini seat was lost**: `exit=-1`, 0 chars, `stall-or-timeout`, no response
file, no error log. era proceeded on three reviews. This is a transport failure
in era's *existing* agy adapter and is not evidence about this design — but it is
a fourth data point for the failure class in §9.1.

era also warned: response size grew 118 % (6,146 → 13,369 chars), *"Reviewer may
be finding new issues from spec expansion rather than converging."* Revision 3 is
net-subtractive in response.

| # | Finding | Raised by | Disposition |
|---|---|---|---|
| 1 | The scratch dir is obscurity, not confinement; §5.4 overclaimed ("cannot reach", "structurally true"), and `seat_containment` sees **writes only**, so a reading seat still returns `contained` | opus, muse-spark | **CONFIRMED — §5.4 rewritten** with a per-hazard table marking which rows are structural and which are not enforced. Round 1's finding is downgraded from "deleted" to "mitigated". A mount namespace is **rejected for now** as a new subsystem closing a gap the spike has not shown exercised; recorded in §12 and asked in §14.1 |
| 2 | `StallSec` does not transfer: era's is a **per-turn** budget, `window_activity` is one clock per attempt; and a threshold above M28's 570.2 s leaves the rule ~100-130 s before the timeout | opus, muse-spark | **CONFIRMED — the stall rule and `#{window_activity}` are DELETED (§6).** The instrument was sound (M20/M21); the rule was not worth a third mechanism. Forces §9 to withdraw its largest row |
| 3 | No reaping: era's own crash leaves detached `--dangerously-skip-permissions` agents on a persistent server, and `-PidFile` was never specified | opus | **CONFIRMED — §5.5.** A sweep of `era-*` windows with a dead `runid` on every launch; `-PidFile` carries the **runid**, since the `wsl.exe` pid is a grandparent that cannot reap. New spike step C7 |
| 4 | Kill criteria 3 and 4 contradict — deepseek-flash **is** the opencode seat | opus | **CONFIRMED — §11.3** states the resolution: 3 is about transport, 4 about fidelity; a default-effort review satisfies 3 while 4 fires alone |
| 5 | Early promotion can kill a model revising after a canary-valid write | muse-spark | **CONFIRMED, answered by contract not mechanism (§5.3).** The prompt makes the canary mean "final"; §10 measures whether models comply. If they do not, the contract is wrong and a turn-end signal is needed — stated rather than assumed |
| 6 | §8.1's "`NewDirty` empty for every path" is false: era writes `$ResponsePath` into the repo, so M3's exemption is still load-bearing | muse-spark | **CONFIRMED — §8.1 corrected**, reverting revision 2's overreach |
| 7 | C7 required observing "first tool use", which needs pane text — forbidden by §11.5 | muse-spark | **CONFIRMED — §10 C5** now observes only the window row and file stats |
| 8 | Rules 2-4 never said whether their file check requires stability; canary-present-but-unstable on a dead window matched no branch | muse-spark | **CONFIRMED — §5.6** scopes stability to the success path only; a dead writer's file cannot change |
| 9 | No "was ever alive" latch and no launch check, so a never-formed window reads as a recoverable seat death; and when the dead window is the last one, the server exits and M24's signature *is* death | deepseek | **CONFIRMED BY MEASUREMENT. M25**: the server does exit, reading identically to M24. **M26**: a sentinel window preserves the distinction. **M27**: `new-window` exits 0 for a nonexistent binary, so launch is confirmed by the row appearing, within 10 s, and a launch fault is `tmux-transport-unavailable` and **not recoverable** (§7.1). The best single finding of the round: one [UNVERIFIED] hypothesis that named its own settling command, and the command settled it |
