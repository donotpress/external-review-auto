# tmux TUI transport as an era backend

**Date:** 2026-09-06 · **Revision:** 5, final (rounds 1-4, the protocol cap; dispositions in §15)
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
| M32 | Does `opencode` emit a **turn-end event**? | **Yes.** `session.idle`, consumable by a plugin; `~/.config/opencode/plugin/tmux-bell.js` is a working example on this box |
| M33 | Can `claude` be given a **scoped hook at launch**? | **Yes.** `--settings <file-or-json>` takes a settings file *or an inline JSON string*, so a `Stop` hook can be scoped to one seat |
| M31 | `read-tool` delivery **succeeded** at 52,042 bytes | round 4 of this very review: `delivery_mode read-tool`, deepseek-flash returned 7,664 chars in 273.7 s, muse-spark 10,636 in 464.3 s | M4 failed at 59,034 bytes in the same mode — so read-tool is not uniformly fatal (§9.1) |
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
| M29 | Can a **watchdog window** destroy the whole server on a deadline? | **Yes.** A window running `sh -c 'sleep N; tmux -L <sock> kill-server'` removed the server and every sibling seat; `rc=1` thereafter |
| M30 | Does `kill-server` reap the seat **process**, or only its window? | **The process.** Measured with a heartbeat file rather than `pgrep`: the seat appended once a second, and wrote **nothing** after the server died |
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
State, as the first line of review.md, the LAST file path listed in bundle.xml,
copied exactly as it appears there:
ERA-BUNDLE-TAIL: <path>
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
- **`ERA-BUNDLE-TAIL` is a cheap read-truncation probe, and it asks for the tail
  on purpose.** Revision 5 asked for `bundle.xml`'s **line count**, which was
  **vacuous**: a TUI agent has a shell, so it runs `wc -l` and reports the true
  count *however little it actually read*. The probe would have agreed every time
  and detected nothing — a control that cannot fail, the same defect gemini found
  in the "written more than once" check (§15 finding 16). Asking for the last
  path **in the content** cannot be answered by a truncated read. Still a
  **warning, never a gate**: agreement is weak evidence, disagreement strong.

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

- **era's own tmux server, on a per-run socket: `tmux -L era-<hostpid>`** (§2.3),
  invisible to `tui-workspace`, which addresses its own `$SESSION` on the default
  socket. A socket per era process means two concurrent runs cannot see, share,
  or destroy each other's server — which is what let the window-naming scheme
  below lose its `<hostpid>` component.
- **One window does both jobs: `era-watchdog`.** It runs
  `sh -c 'sleep <TimeoutSec + 120>; tmux -L <sock> kill-server'`.
  - *As a sentinel*, it keeps the server alive for the whole dispatch, so a
    seat's window vanishing is distinguishable from the server being gone
    (M25/M26) — the distinction §6 rule 2 rests on.
  - *As a watchdog*, it destroys the server and every seat at a fixed deadline
    (M29), and M30 shows that kills the seat **processes**, not merely their
    windows.

  It is matched by exact name and excluded from every seat-presence test.
- **era does not use `tui-workspace`** — 123 KB era does not own, untested by
  era, and M13 shows its completion signal comes from a hook installed outside
  era. era's calls are `new-session -A -d` (`-A` so an existing session attaches
  rather than erroring), `new-window`, `list-windows -F`, `kill-window`.
- **One fresh window per seat per attempt**, named
  `era-<slug>-r<N>-<seat>-<attempt-nonce>`, killed when the attempt ends, with
  the kill **verified** by re-listing. The **attempt nonce** is required because
  a retry of the same seat and round would otherwise reuse the name and a
  leftover row would falsely satisfy §6's ever-alive latch. No pid appears in the
  name: the socket already scopes ownership.
- **Reaping is the watchdog, and there is no sweep.** era's own death is not a
  path era controls, so orphan cleanup must not depend on era being alive to do
  it. The watchdog does not: it is a deadline already running inside the server
  it will destroy. If era crashes, is interrupted, or is killed, every seat dies
  at `TimeoutSec + 120` with **no liveness test, no process identity, and no
  sweep**. Orphan lifetime is bounded by construction.

  **This replaces the pid-keyed sweep of revisions 3-4, which rounds 3 and 4
  between them produced six criticals against and which was still unsound**: it
  needed a liveness test for a `runid` nothing mapped to a process, then a
  `<hostpid>` that pid reuse can resurrect into "live", a name-parse the spec
  never pinned against slugs containing dashes, and an ownership question with
  two incompatible answers. None of those questions exists now, because nothing
  has to decide *whose* a window is.
- **`-PidFile` is not declared by this adapter.** `workflow.ps1:2128` passes it
  only to adapters whose param block declares it, so omitting it is supported and
  is the honest option. Revision 4 proposed writing the `wsl.exe` pid; round 4
  measured that `new-window -d` returns immediately, so that pid is dead within
  milliseconds and `Stop-EraAdapterChild` would either no-op or, after pid reuse,
  kill an unrelated process. Cleanup is the watchdog's job, not the dispatcher's.

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
polls for the window row **every 250 ms for 10 s**; if it never appears, that is
`tmux-transport-unavailable` — a launch fault, **not** a seat verdict, and not
eligible for the bounded re-dispatch. This is also the **ever-alive latch**:
absence only means death *after* presence has been observed once. The tight
cadence matters because a seat that starts and dies in seconds (bad model id,
auth failure) could otherwise vanish between two slow samples and be filed as an
unrecoverable transport fault; **where the two readings are ambiguous the
classifier prefers `tmux-seat-exited`**, the recoverable label, because a wasted
retry is cheaper than a real seat fault reported as broken infrastructure.

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
   ways: canary present → **success, with a `Warnings` entry recording that
   stability never held**; file without canary → `tmux-seat-timeout-partial`; no
   file → `tmux-seat-timeout`.

   The warning is not cosmetic. A model that writes the canary and keeps
   appending never satisfies rule 1's stability check, so it burns the full
   budget and arrives here — and without the warning, the one contract violation
   §5.3 admits it cannot enforce would be recorded as a clean success.

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

**A turn-end signal does exist, and era can own it.** An interactive TUI does not
exit when its turn ends — it sits at a prompt — so a seat that finishes *without*
writing the canary (answered in chat, refused, stopped after a partial write)
would burn the **full `$TimeoutSec`**. Revisions 3-5 accepted that cost, reasoning
that no signal was available without pane text (§11.5) or the `agent-signal` hook
era does not own (M13).

**That reasoning conflated two claims and revision 6 corrects it.** M13's finding
is "do not depend on a hook era does not own" — not "no hook is available". Both
CLIs expose a first-class turn-end event, and era can install its own, scoped to
the seat:

- **opencode** emits `session.idle` (M32), consumable by a plugin era writes into
  the seat's scratch config.
- **claude** takes `--settings` as an inline JSON string (M33), so a `Stop` hook
  can be passed at launch with no file to manage and no effect on the operator's
  own `~/.claude/settings.json`.

Each hook does one thing: `touch <scratch>/turn-ended`. That is **rule 4**:

4. `turn-ended` present and no canary → the model finished without producing a
   review → kill → `tmux-seat-no-review` (recoverable).

**Why a hook and not a model-written marker.** Asking the model to "always write
`done.txt` whatever happens" fails on exactly the case that matters: a model that
refuses or derails is the one least likely to follow an extra instruction. A
CLI-level hook fires on the *runtime's* turn boundary regardless of what the
model did, which is the property the classifier needs.

**Residual:** a hook is one more thing that can silently not fire. Rule 4 is
therefore an *accelerator*, never a gate — `$TimeoutSec` remains the backstop, so
a hook that never fires costs the old full-budget wait rather than a wrong
verdict. C5 asserts the hook fires at all.

---

## 7. Failure taxonomy and the result contract

### 7.1 Failures

| Failure | Detected by | `ExitCode` | `Error` | Recoverable |
|---|---|---|---|---|
| Complete review | canary + stability | 0 | — | — |
| Partial write, writer crashed | file present, canary absent (**rule 2 only**) | -1 | `tmux-seat-truncated` | yes |
| Gone, nothing written | window absent after launch (M18, M26) | -1 | `tmux-seat-exited` | yes |
| Turn ended, no review | `turn-ended` hook, no canary (M32/M33) | -1 | `tmux-seat-no-review` | yes |
| Budget exhausted, partial file | `$TimeoutSec`, canary absent | -1 | `tmux-seat-timeout-partial` | **no** |
| Budget exhausted, nothing written | `$TimeoutSec`, no file | -1 | `tmux-seat-timeout` | no |
| Refusal / narration | `Test-EraCaptureAcceptable` | -1 | `agentic-narration-capture` | **only if the attempt did not time out** |
| Never launched | window never appeared (M27) | -1 | `tmux-transport-unavailable` | **no** |
| tmux/WSL unreachable | sentinel gone, `rc=1` (M24, M26) | -1 | `tmux-transport-unavailable` | **no** |

The last two rows must fail loudly and must **not** be recoverable. era has three
recorded fail-open catches where a read failure became indistinguishable from a
real measurement. A deterministic config fault — a bad model id, an argv over the
ceiling — would otherwise burn the bounded re-dispatch budget pretending to be a
flaky seat.

Only `tmux-seat-truncated` and `tmux-seat-exited` are recoverable, and neither
can be produced by a timeout (§6). **`agentic-narration-capture` inherits the
same condition**: it is reachable from rule 3's success branch, i.e. after a full
budget has already been spent, and a seat that burned ~800 s must not be
re-dispatched for another ~800 s merely because its output failed validation.
Recoverability is therefore conditioned on how the attempt *terminated*, not
inherited wholesale from the process-spawn backends.

**`tmux-seat-truncated` is rare by construction, not unreachable.** Because an
interactive TUI does not exit at turn end (§6), a partial write reaches rule 2
only if the agent actually crashed; every non-crashing partial waits out the
budget and lands on `tmux-seat-timeout-partial`. That is the intended behaviour —
a budget-exhausted seat is not retried — but it means truncation-with-retry
covers crashes only, and the table above says so. The two `yes` rows are added to
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
   characters — cannot occur in this shape.

   **This is weaker than revisions 1-4 claimed, and the evidence arrived by
   accident.** Round 4 of this review overshot the attach cap at 52,042 bytes,
   so both opencode seats fell to `read-tool` — M4's exact delivery mode — and
   **both succeeded** (M31). So the honest statement of the motivating case is:
   read-tool failed once at 59,034 bytes and worked once at 52,042. It is a real
   failure with an unknown trigger, not a mode that is broken outright, and n=1
   either way. A design justified mainly by removing it is justified by less than
   it looked.

   **Also qualified:** the model still *reads* through a tool with its own
   limits, and a read-side truncation yields a coherent review **with a valid
   canary**. The canary certifies the write reached its last line and **nothing
   about the bundle reaching the model**. `ERA-BUNDLE-LINES` (§5.3) is a partial
   probe, not a fix.
2. A dead seat is detected within 15 s rather than at budget exhaustion.
3. A new model becomes a data change — `cmdc`'s 68 models have no era backend at
   all (§13.1). This is the largest single win and it is not a line-count win.

**And one thing it does worse: M9**, on the exact seat this design exists to
rescue.

---

## 10. The spike

Three seats, but not equally used, because **`deepseek-flash` costs materially
more opencode usage than `muse-spark` and the operator has asked for it to be
used sparingly**:

- **`opus-tmux`** and **`muse-spark-tmux`** carry *all* iteration and every
  control. `muse-spark` is an opencode seat, so it exercises the identical TUI
  path — `--prompt`, `--auto`, and the missing `--variant` (M9) — while costing
  roughly a fifth per Mtok. Nothing about the opencode transport is learned only
  from deepseek.
- **`deepseek-flash-tmux` runs exactly once**, last, after both other seats have
  passed, as the single confirmation against M4. It is the seat that failed round
  6, so one clean review from it is the measurement; repeating it buys nothing
  and costs the most.

All three run on the archived
`.external-reviews/model-drift/round-6-{prompt.md,bundle.xml}` and that round's
responses. If the transport cannot get `muse-spark` to a canary-valid review,
the deepseek run is not attempted at all.

**Controls first; no negative result is believable until they pass.** The prior
session recorded five window probes that were all wrong and all looked clean —
each a fact about the instrument reported as a fact about the subject.

- **C1-C4 are already done.** M18-M27 (§2.3) are those controls, run and
  recorded, including the matched pair M20/M21 and the M25/M26 sentinel result.
- **C5 — does a seat launch, reach a file write, and go quiet when its turn
  ends?** Assert the window row appears (M27's latch), then that `review.md`
  appears. Assert the seat's **`turn-ended` hook fires** (M32/M33) — §6 rule 4 rests on it,
  and a hook that silently never fires is the one failure that would restore the
  full-budget wait. Sample `#{window_activity}` every 5 s for the whole attempt
  **and for 120 s after the canary lands**, reporting the longest interval with
  no epoch change. This is an *observation, not a rule* (§6 adds none), and it decides
  whether a cheap turn-end rule is available later. **Observation is limited to
  window existence, the activity epoch, and file stats**; revision 2's "assert
  the model's first tool use occurs" is withdrawn, because the only way to see
  that is pane text, which §11.5 forbids.
- **C6 — can opencode's reasoning effort be set without `--variant`?** §11.4
  turns on this. Pre-registered search set, in order: a `variant`/`effort`/
  `reasoning` key under `model` or per-provider in a scratch `opencode.json`
  (measured: **no such key is present in the current config**); an `OPENCODE_*`
  environment variable; an agent definition (`opencode agent`); a config path
  named by `opencode models --verbose`; a plugin (the same mechanism M32 uses);
  and finally **driving the TUI as a human would** — `tmux send-keys` to whatever
  in-TUI model/effort selector exists.

  **Whether the TUI has an interactive effort selector at all is UNMEASURED.**
  Revision 5 reasoned from "no `--variant` flag" (M9) to "effort cannot be set",
  which does not follow; a probe of the binary's strings was inconclusive, not
  negative. Note that send-keys reintroduces the launch-readiness race §5.2
  otherwise designs away, so it is the last resort, not the first.

  **Verification is out-of-band, so this stays testable without reading the
  pane.** `opencode.db` records the variant actually used per message — that is
  how the registry's deepseek 32,000-token output-ceiling diagnosis was made. So
  whatever sets the effort, C6 confirms it from the database, never from the
  screen. A method that cannot be confirmed there counts as a negative.
- **C7 — reaping, asserted on processes rather than windows.** Launch a seat,
  kill era mid-dispatch, and assert the watchdog destroys the server at its
  deadline and that **no seat process survives**. M30 already showed
  `kill-server` reaps a foreground seat; what remains untested is a seat that
  **backgrounded a tool child outside the pane's foreground process group**,
  which would not receive the pty's SIGHUP. Assert with a **heartbeat file**, not
  `pgrep`: measured this round, a `pgrep -f` pattern matches the two shells
  running the probe, so a naive check reports a live process that is its own
  instrument. Bracket the pattern (`[c]laude`) if `pgrep` is used at all.

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
archive was muse-spark at 4,226. Against round 6 (opus 7,248; muse-spark 4,226; deepseek-flash 0), the honest
claim for opus and muse-spark is *"a review clearing the same bar"*, **not**
"better", which single samples cannot support. For deepseek-flash the bar is
binary — and M31 now means even a success there is one data point against one
failure, not a demonstration that the mode was broken.

The spike is throwaway: it touches no existing backend, `workflow.ps1`, or
`runtimes/era.ps1`, and adds nothing to the default panel. The full suite (1140
passed / 0 failed, ~17 min) runs before and after and must be unchanged.

---

## 11. Kill criteria

1. **C5 or C7 fails, or C6 cannot be run.** C5 fails only if a seat does not
   launch or never writes `review.md`; **its quietness measurement has no pass/
   fail**, because §6 already accepts a never-quiet TUI as a permanent cost, so a
   noisy TUI must not kill the design. C7 fails if a killed seat leaves a live
   process.
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
- Whether a seat that **backgrounds a tool child** leaves it alive after
  `kill-server` (C7). M30 settles the foreground case only.
- What actually caused M4, now that M31 shows the same delivery mode working at
  52,042 bytes. Until that is known, the design's motivating failure has an
  unknown trigger.
- The cost of having no turn-end signal (§6): a seat that finishes without a
  canary burns its full budget. Accepted for the spike, unquantified in
  production.
- Whether opencode's reasoning effort is settable at all (C6, M9) — including
  whether its TUI has an **interactive** effort selector, which revision 5
  wrongly treated as settled by the absence of a flag.
- Whether either turn-end hook (M32/M33) fires reliably in a detached pane.
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
   seat runs unattended? A **middle path is uncosted**: give the seat read access
   to the reviewed source files but not to `.external-reviews/`, which would let
   it cite real files at real line numbers instead of bundle coordinates, while
   still keeping prior rounds and peers out of reach.
2. §6 deletes the stall rule because it is worth ~100-130 s on an ~800 s budget.
   Is that arithmetic right, and is there a case where a wedged seat burning its
   full budget costs more than the third mechanism would?
3. §9 withdraws the line-count argument entirely, leaving `cmdc` as the main
   case. Is unlocking 68 models with no adapter worth a new subsystem, when the
   two seats it is being tested on both already work over process-spawn?
4. §11.3/§11.4 now resolve their overlap by saying criterion 3 is about transport
   and 4 about fidelity, so a default-effort deepseek review satisfies 3. Is that
   the right reading, or does an unfaithful seat fail the motivating case anyway?
5. Rounds 1-4 found 16, 11, 14 and 11 criticals (4.0 → 3.7 → 3.5 → 2.75 per
   seat). Round 3's and round 4's were dominated by defects in the *reaping
   subsystem added in response to round 2* — six criticals against one mechanism
   that was still unsound when revision 5 deleted it. **The remaining risk is no
   longer in the design; it is that no line of this has ever run.** The next step
   is the spike, not a fifth review round — which is also where the protocol cap
   lands.

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

### Round 3 — 3/6/2/3 criticals, and Round 4 — 4/4/2/1

Both rounds were dominated by defects in **fixes from the previous round**, and
between them produced six criticals against one mechanism: the reaping sweep
added in response to round 2. Revision 5 deleted it rather than patching it a
third time.

| # | Finding | Round / raised by | Disposition |
|---|---|---|---|
| 1 | Rules 2-3 had **no success branch**: a model that wrote a complete canary'd file and exited fell to `else` → `tmux-seat-exited`. Near-success got the non-retryable label; garbage got retried | 3 · opus, deepseek | **CONFIRMED — §6** branches three ways, canary first, no stability once the writer is gone |
| 2 | A timed-out seat with a partial file was labelled `truncated`, which is **recoverable** — a budget-exhausted seat could be re-dispatched indefinitely | 3 · deepseek | **CONFIRMED — §6, §7.1.** New `tmux-seat-timeout-partial`; neither timeout code is recoverable |
| 3 | The reaping sweep had **no implementable liveness test** (keyed on a `runid` nothing mapped to a process) | 3 · opus, gemini, muse-spark | **CONFIRMED**, fixed in rev 4 by putting era's pid in the window name — and that fix generated findings 6-8 below |
| 4 | A runid in `-PidFile` breaks the existing consumer | 3 · gemini, muse-spark | **CONFIRMED; mechanism corrected. Measured:** `Stop-EraAdapterChild` (`workflow.ps1:894-897`) uses `[int]::TryParse`, so it would **not** throw as predicted — it returns `$false`, a **silent no-op**, the worse failure |
| 5 | The sweep kills the sentinel, and `new-session -A` never recreates it — silently reinstating M25 | 3 · opus, muse-spark | **CONFIRMED**, and now moot: §5.5's `era-watchdog` is a single window that is both sentinel and reaper, and there is no sweep to kill it |
| 6 | `-PidFile` would hold a pid that is **already dead**: `new-window -d` returns in milliseconds, so the `wsl.exe` launcher is gone for the whole attempt; pid reuse could redirect the kill at an unrelated process | 4 · opus, muse-spark | **CONFIRMED — §5.5.** The adapter no longer declares `-PidFile` at all (`workflow.ps1:2128` makes that supported). Cleanup is the watchdog's, not the dispatcher's |
| 7 | The sweep's liveness test is **pid-reuse-unsafe** and is the sole backstop, so a recycled pid makes an orphan permanently unreapable | 4 · opus | **CONFIRMED — sweep DELETED (§5.5).** Replaced by `era-watchdog`, a deadline running *inside* the server it destroys. **M29** measured it removing the server and every seat; **M30** measured, via a heartbeat file, that this reaps the seat *process*. No liveness test, no pid, no identity question survives |
| 8 | One name schema, two candidate pid owners; and the sweep's parse was never pinned against slugs containing dashes | 4 · muse-spark | **CONFIRMED — moot.** The socket (`tmux -L era-<hostpid>`) now scopes ownership, so no pid appears in a window name and nothing parses one |
| 9 | "The adapter must terminate within its own `$TimeoutSec`" was an obligation with no mechanism | 4 · muse-spark | **CONFIRMED — §5.5.** The watchdog is the mechanism, and it does not depend on the adapter, or on era, still being alive |
| 10 | Launch-vs-instant-crash is a sampling race, and it decides recoverable vs not | 4 · muse-spark | **CONFIRMED — §6.** Launch polls every 250 ms for 10 s, and ambiguity resolves to the **recoverable** label |
| 11 | `agentic-narration-capture` stays recoverable even when reached after a full budget burn — the same defect finding 2 fixed | 4 · opus | **CONFIRMED — §7.1.** Recoverability is conditioned on how the attempt terminated |
| 12 | A model that writes the canary then keeps appending never stabilises, burns the budget, and rule 3 records it as a clean success | 4 · opus | **CONFIRMED — §6.** Rule 3's success branch sets a `Warnings` entry that stability never held |
| 13 | §7.1 attributed `tmux-seat-truncated` to "rules 2-3", but rule 3 routes to `timeout-partial`; and since TUIs never exit, truncation is near-unreachable | 4 · gemini | **CONFIRMED — §7.1** attributes it to rule 2 only and states it covers crashes alone. The behaviour is intended; the table was wrong |
| 14 | Kill criterion 1 fired on C5, but C5 is defined as an observation with no failure threshold — and §6 already *accepts* a never-quiet TUI | 4 · gemini | **CONFIRMED — §11.1.** C5 fails only on no-launch or no-write; quietness has no pass/fail |
| 15 | `kill-window` verifies *window* death, never *process* death; a backgrounded tool child outside the pane's pgrp survives, and a windowless orphan is invisible | 4 · deepseek | **CONFIRMED, partially closed. M30** shows `kill-server` does reap a foreground seat. The backgrounded-child case stays open and is now C7's assertion, using a heartbeat file — because `pgrep -f` matches the shells running it (measured), which would report the instrument as the orphan |
| 16 | The "written more than once" control **cannot fail**, since era tears down the moment the canary is stable | 3 · gemini | **CONFIRMED — §10.** The spike waits 120 s after the canary. A vacuous control records a never-asked question as a negative answer |
| 17 | Interactive TUIs never exit, so a turn ending without a canary burns the full budget — the cost of round 2 deleting the stall rule | 3 · gemini, muse-spark | **CONFIRMED, ACCEPTED, NOT PATCHED (§6).** No turn-end signal exists without pane text (§11.5) or a hook era does not own (M13). C5 measures whether a quiet TUI makes a cheap rule available later |
| 18 | Read-side truncation is silent where M4 was loud | 3 · muse-spark | **CONFIRMED — partially closed.** §5.3's `ERA-BUNDLE-LINES` is a two-line probe against the true count, a **warning, never a gate** |
| 19 | Window names lacked a per-attempt nonce; `kill-window` was unverified | 3 · muse-spark | **CONFIRMED — §5.5** |

### What round 4 measured about the design's own premise

Round 4's bundle overshot the 51,200-byte attach cap at 52,042, so both opencode
seats fell to `read-tool` — **M4's exact delivery mode — and both returned full
reviews** (M31). That is evidence against this design's motivating case,
collected by accident, and §9.1 now carries it: read-tool failed once at 59,034
bytes and worked once at 52,042. The failure is real; the diagnosis "read-tool is
the problem" is not established.
