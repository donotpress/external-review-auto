# tmux TUI transport: what was built, what was measured, and what I inferred

**Date:** 2026-09-06 · **Status:** built, opt-in, working. Not in the default panel.
**Purpose of this document:** to be attacked. §7 lists the claims I am least
able to check myself.

The design is `docs/specs/2026-09-06-tmux-tui-transport-design.md` (6 revisions,
4 review rounds). This records what happened when it was actually built, which is
not what the design predicted.

---

## 1. What exists now

`backends/tmux.ps1` (~530 lines) runs a seat's **interactive CLI** in a detached
tmux window and collects the review as a **file the model writes itself**.
Nothing is scraped from the pane. Three opt-in registry presets, none in
`config/defaults.json`, so a bare `/era` can never select them:

| preset | CLI | model | verified |
|---|---|---|---|
| `muse-spark-tmux` | opencode | muse-spark-1.3-contributor | yes |
| `opus-tmux` | claude | claude-opus-5 | yes |
| `longcat-tmux` | **cmdc** | meituan/longcat-2.0:free | yes |

No API keys anywhere: all three run on subscriptions.

## 2. Reliability, measured

**Every attempt that reached a launched seat produced a valid review.**

- 7 raw spike runs (muse-spark, 59,034-byte bundle): 7/7 canary-valid, 7/7
  correct `ERA-BUNDLE-TAIL`.
- 6 dispatches through era across the three presets: 6/6 `exit=0`,
  `content_ok=true`, `capture_method=tmux`, `seat_containment=contained`.
- Latest concurrent three-seat round: longcat 3,697 chars / 77.8 s, muse-spark
  4,393 / 134.9 s, opus 9,771 / 162.4 s.

era's process-spawn arm, over the same period: **15/16** seat dispatches across
four rounds of a real review.

## 3. The three arguments this design was commissioned on

**Two are dead. I killed both.**

1. **Line count — dead.** `backends/tmux.ps1` is ~530 lines against ~412
   theoretically deletable, and nothing is deleted while process-spawn remains
   the default. It is a net add.
2. **M4 (the motivating failure) — weakened.** Round 4 of the design review
   accidentally overshot the 51,200-byte attach cap at 52,042, so both opencode
   seats fell to `read-tool` — M4's exact delivery mode — and **both returned
   full reviews**. read-tool failed once at 59,034 bytes and worked once at
   52,042. The failure is real; the diagnosis is not established.
3. **`cmdc` — stands, and is now demonstrated.** 68 models with **no era backend
   at all**. Reaching them is a registry entry.

**`cmdc` also answers M9**, which was the strongest con. The opencode TUI has no
`--variant`, and opencode *silently ignores* an undeclared one. cmdc is loud in
both directions: `--effort high` → "Reasoning effort set to high for DeepSeek V4
Flash"; on a model without it → "LongCat 2.0 has no adjustable reasoning effort".

## 4. What building it cost, that reviewing it did not predict

Six bugs. Five were invisible to the design review because they live at a
boundary no document describes.

**`wsl.exe -d X -- cmd args` does not exec directly — it hands everything to
`bash -c`.** That single fact produced four separate-looking failures:

| symptom | cause |
|---|---|
| `wslpath -u C:\Users\Joshua` → `C:UsersJoshua` | bash ate backslashes as escapes |
| `list-windows -F #{window_name}` → "-F expects an argument" | bash read `#` as a comment |
| watchdog died instantly, taking the server | tmux JOINS command args and re-runs them through `sh`, so `-- /bin/sh -c 'sleep N'` became `sh -c sleep` |
| an argument with `"$@"` arrived empty | .NET adds its own Windows quoting on top of the single-quoting I added to fix the first two |

Fixing each layer with more escaping made the next one worse. The transport now
writes a **script file** and only its path crosses the boundary.

**Fifth: the non-login PATH.** `wsl.exe` gives a bash whose PATH is system
defaults. `cmdc` is `#!/usr/bin/env node` and **node is not on it**, so the
window died instantly while `new-window` still returned 0 — at the tmux level,
indistinguishable from a model crashing on startup. opencode never showed it
because its launcher is a compiled ELF binary. Seats now run under a login shell.

**Sixth, and the one I am least comfortable about: I caused a cross-session
incident and could not see it.** Seats inherit tmux's `TMUX`/`TMUX_PANE`. My
first fix cleared `TMUX` only — tmux re-sets `TMUX_PANE` regardless — so seats
ran with an empty socket and a live pane id. Pane ids are **per-server**, so
`set-option -p -t %1` resolved the *default* socket and stamped the **operator's**
windows, painting them "working" for 900 s each with era seats' conversation ids.
A peer session measured this and told me; nothing about it was visible from
inside this session. Reverted — seats now carry era's own socket.

**Residual, not fixed:** three `set-failed … no such window: %1` lines per
three-seat round, in a shared log that gates pushes for every repo on this box.
They are timestamped at *launch*, not teardown, and are against era's own socket.
Raising the teardown pause 2 s → 6 s changed nothing, which is how I know the
pause was not the mechanism.

## 5. A finding independent of this design

`tools/token-truth.py` reads vendor records — `opencode.db`, claude transcripts —
because era's own numbers cannot compare two transports: input cost comes from
era's own repomix count and output from `ceil(chars/4)`, the same estimator on
both arms.

Validating it found that **era understates real spend ~3.2x** ($0.5651 estimated
vs $1.8107 vendor-recorded across 12 seats). Two causes: 126,912
reasoning/thinking tokens era counts none of, and agentic tool-call turns that
never reach the response file. Worst is deepseek-flash at 5.5–11.2x, best
muse-spark at 2.5–4.5x. `Get-PerReviewerCap` and the $15 aggregate cap both gate
on the estimate.

Three instrument artifacts were caught during that validation, each of which had
produced a clean-looking number first: two opencode databases (era spawns the
Windows one); aliased project directories double-counting every claude
transcript; and duplicate turn records that doubled every claude figure and
produced "opus understated 10x" — believable, and wrong.

## 6. My recommendation

**Keep it, opt-in. Do not promote it to the default panel.** era's process-spawn
backends work, run anywhere `pwsh` runs, and have no cross-session blast radius.
Replacing a working thing with an equally-working thing that has more failure
surface is a bad trade. The transport earns its place through `cmdc` and nothing
else.

## 7. The claims I want attacked

These are inferences, not measurements. Each is where I am most likely wrong.

1. **"13/13 reviews means reliable."** Every run was benign: one bundle, no
   failure injection, no adversarial model behaviour, and — except for one
   three-seat round — no concurrency. Two of the six era dispatches used a
   2,696-token bundle, far smaller than a real round. Does this evidence support
   "reliable", or only "works in the easy case"?
2. **"~3.2x cost understatement."** The opencode rows use the vendor's own `cost`
   field. The **claude rows are computed** from era's own pricing table and
   inherit any error in it. `agy` is absent entirely — no vendor record store is
   known — so a third of the default panel is unmeasured. Should the headline
   number be quoted at all, or only the opencode subset?
3. **"`cmdc` justifies the transport."** One model, one review, one bundle, and
   it is the *free* model. Its review was 2,968 chars — below the 4,000-char bar
   the design pre-registered. Does one free-tier review demonstrate that 68
   models are reachable, or only that one is?
4. **"M4's diagnosis is not established."** I inferred this from a single
   accidental success at 52,042 bytes. One success against one failure. Is
   "unknown trigger" the right reading, or am I over-correcting against my own
   earlier claim?
5. **"The residual log noise is acceptable because it is on era's own socket."**
   It still counts against a shared health gate that refuses pushes for every
   repo on this box. Is "nothing goes stale" a sufficient defence, or is any
   entry in a shared gated log a defect that must be fixed at the seat?
6. **"The boundary bugs are behind us."** Six found, all at the WSL boundary,
   five of them one root cause. Is the script-file transport actually the fix, or
   is it the fourth escaping layer that has not failed *yet*?
7. **Scope.** Is a second transport worth permanent maintenance for one
   capability gain, when the capability could instead be had by writing
   `backends/cmdc.ps1` in the existing process-spawn style — which would run
   anywhere `pwsh` runs and cross no boundary at all?

Question 7 is the one I would most like a straight answer to. I have not costed
`backends/cmdc.ps1`, and if it is cheap, it may be the better answer to the only
argument this design has left.
