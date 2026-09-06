# tmux TUI transport as an era backend

**Date:** 2026-09-06 · **Revision:** 2 (after round 1; disposition table in §15)
**Status:** design, unbuilt. Nothing here has been implemented.
**Scope:** one new backend, `backends/tmux.ps1`, carrying an `opus` seat and a
`deepseek-flash` seat. `agy` and `cmdc` are out of scope for the first build.
**The decision this asks for:** build the spike in §10, or don't.

---

## 1. The question

era dispatches its panel by spawning each vendor CLI as a one-shot child
process. Three adapters, 2,808 lines, one per vendor, each re-solving the same
four problems: get the bundle to the model, know whether it is alive, know when
it is done, get the text back.

Could one transport do all four for every vendor at once? Run each seat's
**interactive TUI** in a detached tmux window, and have the model **write its
review to a file** rather than to a pipe.

**The extraction problem does not arise, because nothing is extracted.** Every
one of these TUIs has file-write tools. The prompt ends with "write your review
to `<path>`". era then reads a file. No ANSI, no spinners, no turn-boundary
parsing, no truncation guessing.

This distinction is load-bearing. An earlier session rejected "run the panel in
tmux" because capturing a review out of TUI scrollback is unsolved. That
objection is correct and aimed at a different design. **This spec never reads
pane text.** Everything it takes from tmux is structured window metadata (§6);
if any part of this design calls `capture-pane`, that part is wrong.

---

## 2. What is measured

All run on this box, 2026-09-05/06. Anything absent from this table is
`INFERRED` and flagged as such where used.

### 2.1 era and the environment

| # | Claim | Command | Result |
|---|---|---|---|
| M1 | Adapter cost is 2,808 lines | `wc -l backends/{opencode,agy,claude}.ps1` | 1492 + 971 + 345 |
| M2 | era sets no working directory; seats inherit the repo | `grep -n '\.WorkingDirectory' backends/*.ps1 workflow.ps1 runtimes/era.ps1` | one hit, itself a comment recording this grep |
| M3 | `.external-reviews/` is gitignored **and** filtered out of containment | `git check-ignore -v` → `.gitignore:2`; `workflow.ps1:1058` | see §8.1 — §5.4 makes this moot |
| M4 | Round 6 lost the deepseek-flash seat to transport | `round-6-metadata.json` | `exit_code -1`, `0` chars, `621.1s`, `delivery_mode read-tool` |
| M15 | era's env scrub omits `TMUX_PANE` | `tests/EnvScrub.Tests.ps1:10-19` | 8 vars listed, `TMUX_PANE` absent |
| M16 | Cost uses era's **own** bundle token count, never the adapter's `InputTokens` | `workflow.ps1:2957,3007` (`$estIn` from `$BundleTokens`); `claude.ps1` returns `InputTokens = $null` | only `OutputTokens` must be supplied (§7.2) |
| M17 | `{{PREVIOUS_ROUND}}` substitution admits up to **80,000 chars** | `workflow.ps1:711` `$maxChars = 80000` | decides prompt delivery — see M22 |

### 2.2 The CLIs

| # | Claim | Command | Result |
|---|---|---|---|
| M7 | `claude` takes its prompt as an argv positional | `claude --help` | `Usage: claude [options] [command] [prompt]` |
| M8 | The `opencode` **TUI** takes `--prompt`, `-m`, `--auto` | `opencode --help` | all three on the default (TUI) command |
| M9 | The `opencode` TUI does **not** take `--variant` | `opencode --help` vs `opencode run --help` | present on `run`, absent on the TUI |
| M10 | `claude`'s two permission flags differ | `claude --help` | `--allow-dangerously-skip-permissions` *enables the option*; `--dangerously-skip-permissions` *bypasses* |
| M11 | A Windows exe launched from WSL keeps its cwd only from a DrvFs dir | `cmd.exe /c cd` from the repo vs `/tmp` | `C:\Users\...` vs `UNC paths are not supported` |
| M12 | `agy` is off the WSL PATH but reachable by absolute path | `command -v agy` → miss; `agy.exe --version` → `1.1.27` | `/etc/wsl.conf` sets `interop.appendWindowsPath=false` |
| M13 | `tui-workspace`'s completion signal is an external per-agent hook | source: `@agent_busy_at`/`@agent_session` "written ONLY by agent-signal"; `@agent_done` reset by `after-select-window` | era would depend on a hook it does not own |

`claude` and `opencode` are both WSL-native (`command -v` resolves each), so
M7-M9 were run in the same environment the seats will run in. `agy` is the only
one that is not, which is why it is out of scope.

### 2.3 The tmux instrument — measured this round, on a private socket

Seven probes, `tmux -L eraprobe`, tmux 3.7c. **P4 and P5 are a matched
negative/positive pair**: an instrument that only ever showed a "one" would
prove nothing.

| # | Question | Result |
|---|---|---|
| M18 | Does the window **row vanish** when its command exits? | **Yes.** A window running `sh -c "echo hi; sleep 2"` is listed at t+1s and gone at t+5s, while its siblings remain and `list-windows` still exits 0 |
| M19 | Does `#{pane_current_command}` follow a **foreground child**? | **Yes.** A window running `bash -c "sleep 30"` reports `cmd=sleep`, not `bash` |
| M20 | Does `#{window_activity}` **freeze** during genuine silence? | **Yes.** `sh -c "echo start; sleep 60"`: epoch identical at t+2s and t+10s, delta **0** |
| M21 | Does `#{window_activity}` **advance** on output? | **Yes.** A 1 Hz `echo` loop: delta **8** across an 8 s interval |
| M22 | How large an argv survives `tmux new-window`? | 4,096 ✓ · 8,192 ✓ · 12,288 ✓ · **16,384 ✗** · 32,768 ✗ (window fails to run) |
| M23 | Does a hostile prompt survive as **separate argv elements**? | **Byte-identical**, 166 bytes containing newlines, `"`, `'`, `$( )`, backticks, `;`, `&&`, `\|` — and **no injection artifact was created** |
| M24 | How does an **absent tmux server** read? | `no server running on /tmp/tmux-1000/eraprobe`, `rc=1` — distinguishable from any seat verdict |

**M19 killed a signal this spec previously relied on.** Revision 1 made
`#{pane_current_command} != fg_command` the highest-precedence death signal. All
four reviewers flagged it as false-firing whenever the agent runs a tool; M19
confirms it by measurement. It is gone (§6).

**M22 killed the prompt-delivery mechanism.** Revision 1 passed the round prompt
as an argv value. Round 1's prompt is 1,269 bytes and would have worked; M17
allows a round-2 prompt of 80,000. The ceiling is under 16,384. The failure
would have appeared **only from round 2 onward** — a mechanism that passes its
own first test and then fails in production. Prompts now go in a file (§5.3).

**One environment fact, discovered by a guard rather than a probe.** A bare
`tmux` command without `-L`/`-S` addresses the socket named in `$TMUX` — on this
box, the operator's live 12-window server. A local `tmux-guard` hook blocks it,
recording that the assumption "already destroyed this workspace once". **era
therefore runs its own tmux server, `tmux -L era`** (§5.4), which is stronger
isolation than the dedicated *session* revision 1 proposed.

### 2.4 Two measurements correct the brief this was commissioned from

- **M9 is a capability regression.** era's opencode seats pass `--variant
  xhigh` / `--variant high`. The TUI has no such flag, so a tmux-transported
  opencode seat runs at opencode's default reasoning effort. That is the
  silently-ignored-variant shape the registry notes spent two days on
  (`_opencode_model_map.muse-spark-1.2-contributor`), reintroduced *by
  construction*. §10 step C6 pre-registers the search for a workaround; §11.4
  makes its absence fatal to this seat.
- **M10 makes the claude seat's exposure genuinely new.** The brief asserts yolo
  agents in the repo are "not a new exposure — it is the current one, made
  concurrent". True for opencode and agy; **false for claude**, which today gets
  only the `--allow-` form. An unattended interactive seat needs the real
  bypass. §5.4's scratch-directory isolation is the answer, and it leaves the
  claude seat with *less* reach than it has today, not more.

---

## 3. What must not change

Transport is not protocol. Untouchable: round numbering; per-claim disposition;
the 0-criticals terminal condition; archived artifacts under
`.external-reviews/`; the citation checker; `seat_containment`; the
`round-N-*-response.md` glob that builds `{{PREVIOUS_ROUND}}`.

The transport is built **behind** era's existing backend interface, which is
already the right shape:

```
backends/<backend>.ps1  →  function Invoke-<Backend>Review
  in:  -BundlePath -PromptPath -ResponsePath -ModelInfo -TimeoutSec
       -ModelOverride -OpencodeProvider -AgyModelHint [-PidFile]
  out: @{ Response ExitCode Error ContentOk CaptureMethod
          InputTokens OutputTokens WallClockSec TruncationWarning
          Stderr Warnings }
```
(`workflow.ps1:2082-2135`.)

**How a seat is routed to it (§5.2 in revision 1 left this undefined, and the
dispatcher cannot infer it).** `Invoke-ReviewerDispatch` selects an adapter by
`$Registry[$r].backend`. So the selector is **a distinct registry preset**:

```jsonc
"opus-tmux":           { "backend": "tmux", "transport_of": "opus",           ... },
"deepseek-flash-tmux": { "backend": "tmux", "transport_of": "deepseek-flash", ... }
```

`-Reviewer opus-tmux` routes to `backends/tmux.ps1`; `-Reviewer opus` keeps
`claude.ps1`. The dispatcher needs no change, the default panel is untouched,
the two transports are A/B-comparable in one round, and no existing preset's
behaviour moves. **This is the whole opt-in mechanism.**

---

## 4. Approaches considered

**A. Pane scraping.** *Rejected*, and it is what the earlier rejection was aimed
at. Scrollback is a rendering, not a record: ANSI-laden, reflowed on resize,
bounded by `history-limit`, and unable to distinguish "stopped" from "between
tokens".

**B. File-write TUI transport.** *Recommended.* §5-§8.

**C. Do nothing.** The honest baseline: three adapters, 1140 green tests, and a
saving (§9) well below the 2,808 headline. **C is the answer if the spike misses
any kill criterion in §11.**

Recommendation is **B as an opt-in second transport**, process-spawn remaining
the default. No adapter is deleted by this spec; deletion is a later decision
needing evidence this design cannot yet supply.

---

## 5. Architecture

### 5.1 `backends/tmux.ps1`

Runs in Windows pwsh like every other adapter, and owns: scratch-dir setup
(§5.4), prompt and bundle staging (§5.3), launch, the wait loop (§6), promotion
(§5.5), teardown on every path, and era's result hashtable.

It launches `wsl.exe` through `ProcessStartInfo` with `CreateNoWindow=$true`,
`UseShellExecute=$false`, and the existing 8-var environment scrub **plus `TMUX`
and `TMUX_PANE`** (M15 — otherwise the seat inherits the driving session's pane
identity). `tests/EnvScrub.Tests.ps1` gains `tmux` to its `-ForEach` list.

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

A seat is tmux-transportable iff it has a `tmux_launch` array. Adding `cmdc`
later is a data change (§13).

**There is no key-sending anywhere in this design.** M7/M8: both CLIs accept an
initial prompt at launch, so the first turn is submitted by the process's own
startup. "Does send-keys race TUI readiness" is **removed as a question**, not
answered — there are no keys and no readiness to race. §5.4's fresh window per
round means no seat is ever sent a second turn, so it cannot reappear later.

**The exec vector is fixed end-to-end and contains no shell.** Windows pwsh →
`ProcessStartInfo` → `wsl.exe -d Ubuntu -- tmux -L era new-window -d -t era:
-n <win> -c <scratch> -- <argv...>`, each element a distinct argument. M23
measured a prompt containing newlines, both quote kinds, `$( )`, backticks, `;`,
`&&` and `|` arriving byte-identical with no injection artifact. **A shell
string anywhere in this chain reintroduces the hazard M23 shows is otherwise
absent**, so a test asserts the argv form.

### 5.3 Prompt and bundle staging

Per M22 the argv ceiling is under 16,384 bytes and per M17 a round prompt may
reach 80,000. **The argv therefore carries only a fixed ~60-byte pointer**, and
everything real is staged on disk:

```
<scratch>/instructions.md   era's round prompt + the envelope below
<scratch>/bundle.xml        a copy of round-N-bundle.xml
<scratch>/review.md         where the model writes  (does not exist at launch)
```

The envelope appended to era's existing round prompt:

```
The review bundle is the file bundle.xml in your current directory.
Write your complete review to the file review.md in your current directory.
Do not read, write, or create any other file.
The last line of review.md must be exactly this, alone on the line:
ERA-CANARY-<nonce>
```

- **Every path is a bare filename in the cwd.** The model sees no WSL path, no
  Windows path, and no repo path. era does exactly one translation, once:
  scratch-dir Windows path → WSL path via `wslpath -u`, quoted for spaces. M11
  makes the direction matter, and the scratch dir is created under the Windows
  `%TEMP%` (hence DrvFs) so a future Windows-exe seat inherits a valid cwd.
- **The nonce is per dispatch attempt, not per round.** A round may re-dispatch
  a recoverable failure (§7); a per-round nonce would let attempt 2 promote
  attempt 1's leftover file on its first poll. The scratch dir is also new per
  attempt, so `review.md` cannot pre-exist.
- **Canonical canary matching.** era compares the last non-empty line, with
  trailing whitespace and CR stripped, to `ERA-CANARY-<nonce>` — and the prompt
  says "the last line", so prompt and validator agree on the same rule. The
  canary line is removed before validation so it cannot affect the detectors.

### 5.4 Isolation: the seat does not run in the repo

**This replaces revision 1's "cwd is the repo root", and it is the largest
change in this revision.** Each seat's cwd is a fresh per-attempt scratch
directory outside any git work tree, containing exactly the three files above.

Round 1 established the reason. Revision 1 paid a cold start per round for round
independence and did not get it: the seat's cwd was the repo, so
`.external-reviews/<slug>/` — every prior round's response, the disposition
table, and every *peer's in-flight* `-raw.md` — was one `ls` away. A model told
to read a bundle in that directory is not confined by being given a fresh
context. Worse, M3 exempts all of `.external-reviews/` from `NewDirty`, so a
seat corrupting a peer's file or the bundle itself would not have tripped
`breached` either.

The scratch directory settles all of it at once, and by **removing** mechanism:

| Hazard | Under revision 1 | Now |
|---|---|---|
| Prior rounds readable | present | not on disk in the seat's world |
| Peers' in-flight files readable | present | each seat has its own directory |
| Git index contention between seats | detected, not prevented | no git work tree in cwd |
| A seat's own session/state files tripping containment | possible | written in the scratch dir |
| `.external-reviews/` as a containment blind spot | present | seat cannot reach it |

era's existing round prompt already says *"Review ONLY what is in the bundle. Do
NOT attempt to open, view, fetch, or read any file outside the bundle."* The
scratch directory makes that instruction structurally true instead of
aspirational. **Revision 1's whole "four concurrent yolo agents in one tree"
section is deleted rather than mitigated**, and with it the worktree-per-seat
proposals round 1 offered — a worktree is a second copy of the repo, where this
is no repo at all.

The cost is real and stated: the seat cannot run `git log` or open a repo file
for context beyond the bundle. That is what era's prompt already forbids.

### 5.5 Session and window lifecycle

- **era's own tmux server: `tmux -L era`.** Not the operator's (§2.3). A
  separate server is invisible to `tui-workspace`, whose every call addresses
  its own `$SESSION` on the default socket.
- **era does not use `tui-workspace`.** 123 KB era does not own, untested by
  era, and M13 shows its completion signal comes from an `agent-signal` hook
  installed outside era. era's four calls are `new-session -A -d` (`-A` so an
  existing session is attached to rather than erroring), `new-window`,
  `list-windows -F`, `kill-window`.
- **One fresh window per seat per attempt**, killed when the attempt ends.
  Round independence is protocol (§3), so a seat never carries context between
  rounds. With §5.4 this is now enforced by the filesystem as well as by the
  context.
- **Window name `era-<runid>-<slug>-r<N>-<seat>`**, where `runid` is unique per
  era process. Revision 1 omitted `runid`, so two concurrent era runs on one
  repo would have killed each other's windows by name.

### 5.6 Staging and promotion

The model writes `<scratch>/review.md`; era promotes it to `$ResponsePath` only
after it passes. This is not ceremony — `claude.ps1:324` records the rule it
protects: *"A non-review is not written to disk … so it cannot be picked up by
the `round-N-*-response.md` glob that builds the next round's
`{{PREVIOUS_ROUND}}` context."* Under this transport the model holds the pen, so
writing straight to `$ResponsePath` would let a refusal enter the next round's
context as though it were a review, silently defeating a guard era already has.
The scratch path cannot match that glob.

Promotion sequence:

1. **Stability** — size and mtime identical across two consecutive fast polls.
   A file-write tool that streams could otherwise be caught mid-write with the
   canary already flushed.
2. **Canary** — last non-empty line matches (§5.3); then stripped.
3. **`Test-EraCaptureAcceptable`** (`backends/_capture-validation.ps1:309`,
   unchanged, shared with five other backends).
4. Write `$ResponsePath`.

On any failure the scratch `review.md` is copied to
`.external-reviews/<slug>/round-N-<seat>-raw.md` as the forensic record — the
role round 6's error log played — and the scratch dir is removed.

---

## 6. Completion and liveness

Three signals. All are structured tmux metadata or a local file stat; none is
pane text.

| Signal | Source | Answers |
|---|---|---|
| **Completion** | `review.md`, stable, last line == canary | done, and write-complete |
| **Death** | the window's row is **absent** from `list-windows` while the server still answers (M18, M24) | the seat's process exited |
| **Progress** | `review.md` mtime/size; secondarily `#{window_activity}` (M20, M21) | is anything happening |

**Death is window absence, not `#{pane_current_command}`.** M19 measured that
the pane command follows any foreground child, so a seat running a `bash` tool
would have read as dead. M18 measured that a window is destroyed when its
command exits — and since the window's command *is* the agent, absence is
exactly agent exit, whatever the agent was running at the time. M24 separates
this from instrument failure: a live server missing one window is death; `rc=1`
with `no server running` is `tmux-transport-unavailable` and is never a seat
verdict.

The wait loop polls the **staged file** on the Windows side (a local stat,
effectively free) and calls into WSL for tmux state every 15 s, because each
call crosses the interop boundary. Detection latency for death and stall is
therefore **up to 15 s**, not "immediate".

Terminal conditions, in precedence order. **Each first stats `review.md`,** so a
partial file is labelled truncation rather than by whatever ended the attempt:

1. Canary present and stable → **success**.
2. Window absent → `review.md` exists but no canary → `tmux-seat-truncated`;
   otherwise `tmux-seat-exited`.
3. No file growth **and** `window_activity` static for `StallSec` → kill →
   partial file → `tmux-seat-truncated`, else `tmux-seat-stalled`.
4. `$TimeoutSec` reached → kill → partial file → `tmux-seat-truncated`, else
   `tmux-seat-timeout`.

Revision 1 made `tmux-seat-truncated` structurally unreachable — three reviewers
found it independently — because rules 2-4 each labelled by cause without ever
looking at the file. Stat-first fixes it.

`StallSec` is **not a new number**: it is era's measured stall policy
(`docs/assessments/2026-09-04-stall-threshold-measured.md`, which found 3.97 %
of productive deepseek-flash turns silent over 300 s, up to 570.2 s). Inventing
a fresh threshold would repeat the mistake that document ended.

**How much of `opencode.ps1`'s stall machinery this actually replaces is
conditional, and §9 no longer claims otherwise.** M20/M21 prove the *instrument*
is sound in both directions — the epoch freezes in silence and tracks output. It
does **not** follow that a thinking TUI is silent: if either CLI animates a
spinner while waiting on inference, `window_activity` never ages, rule 3 never
fires, and `$TimeoutSec` is the only backstop — which is what era already has.
Spike step **C5** measures this on the real TUIs and is what §9's largest claim
is conditioned on. The file-mtime signal is primary precisely because it does
not depend on the answer.

---

## 7. Failure taxonomy and the result contract

### 7.1 Failures

| Failure | Detected by | `ExitCode` | `Error` | Recoverable |
|---|---|---|---|---|
| Complete review | canary + stability | 0 | — | — |
| Partial write | file present, canary absent (rules 2-4) | -1 | `tmux-seat-truncated` | yes |
| Gone, nothing written | window absent (M18) | -1 | `tmux-seat-exited` | yes |
| Silent, nothing written | no growth + static activity | -1 | `tmux-seat-stalled` | yes |
| Budget exhausted | `$TimeoutSec` | -1 | `tmux-seat-timeout` | no |
| Refusal / narration | `Test-EraCaptureAcceptable` | -1 | `agentic-narration-capture` | as today |
| tmux/WSL unreachable | `rc=1`, `no server running` (M24) | -1 | `tmux-transport-unavailable` | no |

The last row must fail loudly. era has three recorded fail-open catches where a
read failure became indistinguishable from a real measurement, and
`Compare-EraSeatContainment` carries a standing comment about that exact shape.
A missing tmux is `unmeasured`, never `contained` and never a model verdict.

The three `yes` rows must be added to `Get-EraRecoverableFailures`
(`workflow.ps1:2604`), which keys the bounded re-dispatch on `Error`; and any
`Error`-string allowlist in the metadata schema or its tests must accept the new
codes, or the spike writes labels its own validator rejects.

### 7.2 Token telemetry (round 1 raised this four times; it is smaller than it looked)

M16: era computes input cost from **its own** `$BundleTokens`, and `claude.ps1`
already returns `InputTokens = $null`. So the tmux backend returns `$null` too —
no gap, no new mechanism. Only `OutputTokens` is consumed (output cost and the
per-reviewer cap), and it uses the estimator `claude.ps1` already uses:
`ceil(chars/4)` over the promoted response. Recorded here because revision 1
never said where these came from, which is a real omission; **no new estimator
is introduced**, which is the part round 1 over-read.

---

## 8. Containment and exposure

### 8.1 Containment stays, and asserts something stronger

`seat_containment` (`workflow.ps1:1016`) diffs `git status` around the dispatch.
Under §5.4 the seats do not run in the repo at all, so the expected verdict is
`contained` with `NewDirty` empty **for every path, not merely every path
outside `.external-reviews/`**. M3's exemption is no longer load-bearing, and a
breach now means something unambiguous: a seat reached outside its scratch
directory and into the repo. The instrument is unchanged and is the day-one
safety readout.

### 8.2 The claude seat's flag changes; its reach shrinks

Per M10 an unattended interactive claude seat needs `--dangerously-skip-
permissions` where the process seat uses the `--allow-` form. Stated plainly
because it is an escalation of the *flag*. But under §5.4 the seat's cwd holds
three files and no repository, where today's process seat runs **in the repo**
(M2). Net reach is lower than today's, and `seat_containment` measures it.

### 8.3 `TMUX_PANE` cuts both ways

M15: era scrubs 8 vars, not `TMUX_PANE`. A nested `claude` spawned by era
inherits the driving session's pane identity and its hooks then write to the
*operator's* window. That is a **pre-existing defect in the process-spawn
backends**, out of scope here, and one more reason not to build on `@agent_*`
state (M13). The tmux backend scrubs both `TMUX` and `TMUX_PANE`.

---

## 9. Honest cost accounting

"2,808 lines replaced by one mechanism" does not survive contact with the files.

**Plausibly deleted (transport-shaped):**

| | lines |
|---|---|
| `opencode`: stall/budget inference (5 functions) | 454 |
| `opencode`: delivery-mode split — attach cap, bundle sizing | 72 |
| `agy`: `Get-AgyTranscriptResponse` (transcript parsing) | 207 |
| `agy`: `_SpawnAndCaptureOnce` | 210 |
| `claude`: `Get-ClaudeRemainingMs` + stdin-pipe machinery | ~90 |
| shares of the three `Invoke-*Review` bodies | ~250 (INFERRED) |
| **total** | **~1,280** |

**Survives regardless (policy, not transport):** variant resolution, model maps,
per-reviewer caps, prompt assembly, pricing, the detectors — and `agy.ps1`
entirely until §13.

**Added:** `backends/tmux.ps1` (400-600, INFERRED), registry blocks, scratch-dir
and window lifecycle, staging, promotion, canary handling, new recoverable
codes, and tests. **Day one is a strictly positive net**: nothing is deleted
until a process-spawn adapter is retired, which this spec does not propose.
Anyone approving this on the 2,808 figure is approving something not on offer.

**The 454-line line is conditional on C5.** If a thinking TUI is never quiet,
`window_activity` cannot replace stall inference and that row does not pay.

**Three things process-spawn cannot do at any price:**

1. A seat that reads the bundle from disk has no attach cap and no delivery-mode
   split, so M4's failure — 59,034 bytes over a 51,200-byte cap, 621 s, zero
   characters — cannot occur in this shape. **Qualified:** the model still
   *reads* through a tool with its own limits, and a read-side truncation yields
   a coherent review **with a valid canary**. The canary certifies that the
   write reached its last line and **nothing about the bundle reaching the
   model**. §5.3's "a file without its canary is incomplete" is a claim about
   write-completeness only. This residual risk is not closed by this design.
2. A dead seat is detected within 15 s (§6 rule 2) rather than at budget
   exhaustion.
3. A new model becomes a data change (§13).

**And one thing it does worse: M9.** The opencode TUI cannot be told a reasoning
effort — on the exact seat this design exists to rescue.

---

## 10. The spike

Two seats. Same prompt and bundle as the archived comparanda,
`.external-reviews/model-drift/round-6-{prompt.md,bundle.xml}` and that round's
three responses. Seats: `opus-tmux` and `deepseek-flash-tmux`. deepseek-flash is
the sharp case — it *failed* round 6 for transport reasons (M4), so a real
review from it is a measured capability win, not a re-implementation.

**Controls first, and no negative result is believable until they pass.** The
prior session recorded five window probes that were all wrong and all looked
clean; the pattern was a fact about the instrument reported as a fact about the
subject.

- **C1-C4 are already done.** M18-M24 (§2.3) are exactly those controls, run and
  recorded: a live window reads as live, a dead one as absent, a foreground
  child does *not* read as death, the activity epoch freezes in silence **and**
  advances on output, an absent server is distinguishable, and a hostile argv
  round-trips without injecting. Revision 1's C1 was a bare `sleep 60`, which
  would have proved only that the epoch exists — round 1 caught that, and M20/M21
  are the fix.
- **C5 — is a thinking TUI quiet?** Launch one seat on the real bundle and
  sample `#{window_activity}` and `review.md` size every 5 s for the whole turn.
  Report the longest interval with no epoch change. **This decides whether §6
  rule 3 exists at all**, and §9's largest claim with it.
- **C6 — can opencode's reasoning effort be set without `--variant`?** §11.4
  turns on this, and revision 1 gave the spike no way to evaluate its own kill
  criterion. Pre-registered search set, in order: a `variant`/`effort`/
  `reasoning` key under `model` or per-provider in `opencode.json` (measured
  this round: **no such key is present today**); an `OPENCODE_*` environment
  variable; an agent definition (`opencode agent`); `opencode models --verbose`
  output naming a config path. Record which were tried and what each returned —
  a negative is only a negative once the set is enumerated in advance.
- **C7 — does a seat launch and run at all?** Assert the window exists after
  launch, the model's first tool use occurs, and `review.md` appears. Revision 1
  jumped from instrument controls straight to a scored run; if the launch argv
  does not resolve, no earlier control would have caught it.

**Then both seats concurrently**, recording per seat: wall-clock; canary; bytes;
`Test-EraCaptureAcceptable`; citation-checker result; `seat_containment` for the
round; and whether `review.md` was written more than once (a model that revises
after writing could be killed mid-revision by a promotion that fires too early).

**Pre-registered comparison thresholds**, so the result is not negotiated
afterwards. A seat **passes** iff: canary present; `Test-EraCaptureAcceptable`
returns `Ok`; the citation checker adds no warning; and the response is ≥ 4,000
characters — the smallest real review in the round-6 archive was muse-spark at
4,226. Against round 6 (opus 7,248 chars; deepseek-flash 0), the honest claim
for opus is *"a review that clears the same bar"*; **not** "better", which two
samples cannot support. For deepseek-flash the bar is binary: 0 characters, or a
review.

The spike is throwaway. It touches no existing backend, `workflow.ps1`, or
`runtimes/era.ps1`, and adds nothing to the default panel. The full suite (1140
passed / 0 failed, ~17 min) runs before and after and must be unchanged, since
nothing on its paths is edited.

---

## 11. Kill criteria

1. **C5, C6 or C7 cannot be run, or C7 fails.** The seats never worked; nothing
   downstream means anything.
2. **`seat_containment` returns `breached`.** Under §5.4 that means a seat
   reached out of its scratch directory into the repo, which is not a thing to
   iterate on. **`unmeasured` is not this criterion** — it means the instrument
   failed and the spike is *invalid*, to be re-run, not a verdict on the design.
3. **The deepseek-flash seat still returns nothing.** The one concrete failure
   this design exists to beat, unbeaten.
4. **C6 finds no way to set opencode's reasoning effort.** Then the transport
   trades a *visible* failure for a *silent* degradation — the worse of the two.
   This kills the **opencode seat**; §13.1's `cmdc` case and the claude seat
   survive it, and the decision then is whether a transport that cannot carry
   opencode is worth having.
5. **Either seat needs pane text to work.** That is design A, rejected in §4,
   and it does not become correct by being arrived at gradually.

Missing 1, 2, 3 or 5 means the answer is §4's option C and this document is the
record of why.

---

## 12. What remains unmeasured

- Whether a TUI agent reliably writes the file and finishes its turn. **The
  central bet; the spike exists to settle it.** The design's answer is not
  confidence but detectability — the canary makes failure legible.
- Whether a thinking TUI is ever quiet (C5), and so whether §6 rule 3 and §9's
  454-line row are real.
- Whether opencode's reasoning effort is settable at all (C6, M9).
- **Read-side truncation** (§9.1): a bundle truncated on read yields a
  canary-valid review of less than the bundle. Not closed. The citation checker
  is a partial mitigation only — a seat reviewing a truncated bundle produces
  *correct* citations to the part it saw.
- The `agy` seat: reachable from WSL (M12), but a Windows console application
  driven through a Linux pty is unmeasured. Out of scope for this reason.
- TUI cold-start latency per attempt, against the 700 s seat floor. INFERRED to
  be small; not timed.
- Interop-boundary polling cost at a 15 s cadence. Believed cheap; not timed.
- The 400-600 line estimate for `backends/tmux.ps1`.

---

## 13. If it works

Each its own decision; none approved here.

1. **`cmdc`** — 68 models including kimi-k3, glm-5.3, minimax-m3, and **no era
   backend at all**. Under this transport it is one `tmux_launch` array: the
   cheapest large capability gain available, and the first extension.
2. **`agy`**, if the Windows-TUI-in-a-Linux-pty question resolves. Only then do
   `agy.ps1`'s 971 lines enter the §9 arithmetic.
3. **Retiring a process-spawn adapter** — only after the transport has carried
   real rounds without a containment breach.

**A four-seat tmux panel is not a goal.** Two seats settle the question; scaling
is a later decision on the evidence they produce.

---

## 14. Open questions for review

1. §5.4 puts the seat outside the repo entirely, so it can read only the bundle.
   Does that cost anything a reviewer actually needs — given era's prompt
   already forbids reading outside the bundle — or does some finding class
   depend on repo access the bundle cannot supply?
2. §9.1 concedes read-side truncation is not closed: a bundle truncated by the
   model's own read tool yields a canary-valid, correctly-cited, *partial*
   review. Is there a cheap detector for it, or is the honest move to record it
   as a known limit shared with today's `read-tool` delivery mode?
3. §11.4 now kills only the opencode seat rather than the transport. Is that the
   right scoping, or does a transport that cannot carry opencode fail its own
   motivating case (M4 was an opencode seat)?
4. §7.2 argues the token-telemetry finding was largely an omission rather than a
   defect, because M16 shows cost uses era's own bundle count. Is that reading
   of `workflow.ps1:2957,3007` right?
5. Round 1 produced six criticals of which this revision **subtracted** (§5.4
   deletes the concurrency section and four findings with it) more than it
   added. Is anything now missing that those deleted paragraphs were carrying?

---

## 15. Round 1 disposition

Four reviewers (opus, gemini, deepseek-flash, muse-spark); 6/2/2/6 criticals.
All four seats returned; `seat_containment` = `contained`; no citation warnings.

| # | Finding | Raised by | Disposition |
|---|---|---|---|
| 1 | Round independence not delivered — cwd is the repo, so prior rounds and peers' in-flight files are one `ls` away | opus, muse-spark | **CONFIRMED — §5.4 rewritten.** Seat now runs outside the repo. Deletes this, the peer-read hazard, git contention, TUI-state containment noise, and the `.external-reviews/` blind spot. Worktree-per-seat *rejected*: a worktree is a second repo where this is none |
| 2 | Nothing routes a seat to `backends/tmux.ps1` | opus | **CONFIRMED — §3.** A distinct registry preset (`opus-tmux`) with `"backend": "tmux"`; dispatcher unchanged, and the two transports become A/B-comparable |
| 3 | `tmux-seat-truncated` structurally unreachable | opus, gemini, deepseek | **CONFIRMED — §6.** Rules 2-4 now stat the file before labelling |
| 4 | `#{pane_current_command}` false-fires on any foreground tool child | all four | **CONFIRMED BY MEASUREMENT (M19)** — `bash -c "sleep 30"` reports `sleep`. Signal deleted; death is window absence (M18), which is immune to it |
| 5 | Per-round nonce + retained staged file lets a retry promote the previous attempt's output | opus, gemini, deepseek | **CONFIRMED — §5.3.** Nonce and scratch dir are per attempt |
| 6 | Token telemetry has no source | all four | **CONFIRMED as an omission, REJECTED as a defect (§7.2).** M16: cost uses era's own bundle count and `claude.ps1` already returns `InputTokens = $null`. Only `OutputTokens` is consumed, by an estimator that already exists. No new mechanism |
| 7 | `window_activity` may never go quiet on a redrawing TUI, and §9 banks its largest claim on it | gemini, opus, deepseek, muse-spark | **CONFIRMED — §6, §9.** Instrument proved sound both ways (M20/M21); whether a *thinking TUI* is quiet is now spike step C5, and the 454-line saving is explicitly conditioned on it. File mtime is the primary progress signal |
| 8 | Prompt-as-argv: §5.1/§5.2 contradict, and there is a size ceiling | opus, gemini, deepseek, muse-spark | **CONFIRMED BY MEASUREMENT (M22).** Ceiling is 12,288 ✓ / 16,384 ✗; `{{PREVIOUS_ROUND}}` allows 80,000 (M17), so this would have passed round 1 and failed from round 2. Prompt now staged in a file; argv is a fixed pointer |
| 9 | Exec vector must forbid a shell or injection returns | muse-spark | **CONFIRMED — §5.2**, vector fixed end-to-end. M23 measured a hostile prompt round-tripping byte-identical with no injection |
| 10 | Promotion can catch a half-written file | muse-spark, opus | **CONFIRMED — §5.6**, size+mtime stable across two polls |
| 11 | Canary "final line" vs "final non-empty line" mismatch | muse-spark, deepseek | **CONFIRMED — §5.3**, one canonical rule stated in both prompt and validator |
| 12 | Kill criterion 2 treated `unmeasured` as fatal | muse-spark | **CONFIRMED — §11.2.** Infra failure invalidates the spike; it is not a verdict |
| 13 | M9 kill criterion unfalsifiable — no spike step, no pre-registered search set | opus, gemini, muse-spark | **CONFIRMED — §10 C6**, search set enumerated in advance. Also **narrowed** (§11.4): it kills the opencode seat, not the transport |
| 14 | No control covers the seat-launch path | deepseek | **CONFIRMED — §10 C7** |
| 15 | C1 (`sleep 60`) proved nothing about whether activity tracks output | opus | **CONFIRMED — M20/M21** are the matched negative/positive pair, run this round |
| 16 | Canary proves write-completeness only; read-side truncation is silent | deepseek | **CONFIRMED — §9.1, §12** qualified rather than fixed. No cheap detector proposed; open question 2 |
| 17 | Window names collide across concurrent era runs | gemini, muse-spark | **CONFIRMED — §5.5**, `runid` added |
| 18 | `new-session -d` errors if the session exists | opus | **CONFIRMED — §5.5**, `-A` |
| 19 | Comparison "comparable substance" reintroduces post-hoc negotiation | muse-spark | **CONFIRMED — §10**, thresholds pre-registered (canary + detector + citations + ≥4,000 chars) |
| 20 | tmux server identity across `wsl.exe` calls is assumed | deepseek | **CONFIRMED and sharpened (§2.3).** A bare `tmux` addresses the *operator's live server*; era uses `tmux -L era` |
| 21 | New `Error` codes need `Get-EraRecoverableFailures` and any schema allowlist | muse-spark | **CONFIRMED — §7.1** |
| 22 | "immediate" vs a 15 s poll; §9's "~500 added" vs its own 400-600 list; "four agents" when the spike runs two; recoverable-count off by one | opus, deepseek | **CONFIRMED — §6, §9, §11** corrected |
| 23 | Use `/proc/<pid>/stat` CPU time as a stall signal | gemini | **REJECTED.** A third liveness mechanism to cover a case C5 has not yet shown exists. File mtime plus the timeout backstop is sufficient; adding this is the accretion this revision is trying to reverse |
| 24 | Add a semantic check for a canary-valid but wrong review | muse-spark | **REJECTED.** That is era reviewing the review. Recorded as a known limit (§12) instead |
| 25 | Worktree-per-seat before any non-spike run | muse-spark, opus | **REJECTED as superseded** by §5.4, which removes the repo from the seat's world entirely rather than giving it a second copy |
