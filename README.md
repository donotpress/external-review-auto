# /external-review-auto

**/era** — Automated external code review via agy, Claude CLI, or opencode.

Bundles a curated file set via repomix and dispatches it to a reviewer backend. No manual paste step — the backend reads the bundle from disk and the response is captured automatically.

## Prerequisites

Works on **Windows, macOS, and Linux** (PowerShell 7 is cross-platform).

**At least one of:**

| Backend | What you need |
|---------|--------------|
| **agy** (Gemini) | [Antigravity CLI](https://antigravity.google/download#antigravity-cli) installed and signed in |
| **Claude CLI** | [Claude Code](https://code.claude.com/docs) installed and signed in |
| **opencode** | [opencode](https://github.com/anomalyco/opencode) installed with at least one provider configured |
| **REST** (Gemini / Anthropic / DeepSeek / MiniMax) | An API key from the provider's console |

`/era doctor` checks everything — PowerShell 7, repomix, ThreadJob, backends — and reports exactly what's missing with install commands. If something needs installing, your TUI can do it for you.

## Install

Tell your TUI:

```
Clone https://github.com/donotpress/external-review-auto and set it up as a skill, then run /era doctor
```

The TUI will clone it to the right location for your platform and run the preflight check. Then follow the `/era doctor` output to install prerequisites and pick a backend.

### Platform-specific clone paths

If you prefer to clone manually:

| Platform | Clone to |
|----------|----------|
| **Claude Code** | `~/.claude/skills/external-review-auto/` |
| **opencode** | `~/.config/opencode/skills/external-review-auto/` |
| **agy** | `~/.claude/skills/external-review-auto/` + symlink `~/.gemini/skills/era` |
| **Standalone** | `~/external-review-auto` |

### Claude Code

```bash
git clone https://github.com/donotpress/external-review-auto ~/.claude/skills/external-review-auto
```

Then add to `~/.claude/CLAUDE.md`:

```
- **era** (`~/.claude/skills/external-review-auto/SKILL.md`) - external code review. Trigger: `/era`
```

### opencode

```bash
git clone https://github.com/donotpress/external-review-auto ~/.config/opencode/skills/external-review-auto
```

See [`runtimes/opencode.md`](runtimes/opencode.md) for the `command.era` entry to add to `opencode.json`.

### Antigravity (agy)

```bash
git clone https://github.com/donotpress/external-review-auto ~/.claude/skills/external-review-auto
ln -s ~/.claude/skills/external-review-auto ~/.gemini/skills/era
```

### Standalone shell

```bash
git clone https://github.com/donotpress/external-review-auto ~/external-review-auto
```

See [`runtimes/shell.md`](runtimes/shell.md) for PATH/shim setup.

## Quick start

In a TUI (Claude Code, opencode, etc.), just type:

```
/era                          # review current work with default reviewer
/era Gemini 3.1 Pro           # use Gemini 3.1 Pro (High)
/era Opus 4.8                 # use Claude Opus
/era deepseek v4 flash        # use DeepSeek V4 Flash
/era deepseek                 # bare family name -> DeepSeek V4 Flash (New), the family default (v1.13)
/era deepseek pro             # ...name the tier to get V4 Pro instead
/era my-feature with sonnet   # review topic "my-feature" with Claude Sonnet
/era my-feature use sonnet    # same — 'use', 'with', and 'via' all split topic from reviewer
/era multi gemini,opus        # dispatch to multiple reviewers in parallel
/era review this              # auto-detect context and review (spec or git changes)
/era review this with opus    # same, with an explicit reviewer
/era what should I review     # scan repo for review targets (specs, commits, topics)
/era doctor                   # check prerequisites + backend status
/era set default to opus      # change your default reviewer (persists)
/era update models            # refresh model registry from connected providers
```

Everything — setup, configuration, reviews — works as natural language. No manual env vars, no shell config files.

### First time on a new machine?

In a TUI, just type:

```
/era doctor
```

(or `/era setup`, `/era check`, `/era init` — all do the same thing)

This runs a full preflight: checks PowerShell 7, ThreadJob, repomix, git, and every backend CLI/API key. Shows `[OK]` / `[MISS]` status with the exact install command for each missing piece. No guessing.

**You do NOT need to restart your TUI after installing prerequisites.** `/era doctor` checks live state each time — if you just installed repomix or signed into a CLI, run `/era doctor` again to confirm, then start reviewing.

**Minimum to get running:**

```bash
# 1. PowerShell 7+ (skip if already installed)
winget install Microsoft.PowerShell      # Windows
brew install powershell                   # macOS

# 2. repomix
npm install -g repomix

# 3. ThreadJob module
Install-Module -Name ThreadJob -Force -Scope CurrentUser

# 4. At least one backend — the easiest options:
#    - Install the agy CLI and sign in (reuses your Google login), OR
#    - Install the claude CLI and sign in, OR
#    - Set an API key: $env:GEMINI_API_KEY / $env:ANTHROPIC_API_KEY / $env:DEEPSEEK_API_KEY
```

On first run with no `-Reviewer`, `/era` auto-detects what you have installed and picks the first usable backend. You don't need to configure anything — just have one CLI signed in or one API key set.

### Standalone (no TUI)

```bash
pwsh runtimes/era.ps1                                                  # default
pwsh runtimes/era.ps1 -TopicSlug my-design -Reviewer gemini-pro-high   # explicit
pwsh runtimes/era.ps1 -TopicSlug my-topic -IncludeFiles src/main.py,tests/test_main.py -PromptOverrideFile prompt.md
```

**Session context (`-ConversationFile`):** agent callers should distill the
conversation (goal, findings, claims to scrutinize, open questions) into a
file and pass it — it is injected into the prompt (never bundled), so any
absolute path works:

```bash
pwsh runtimes/era.ps1 -TopicSlug my-design -ConversationFile /tmp/session-context.md -IncludeFiles src/main.py
```

**Out-of-repo files:** absolute `-IncludeFiles` paths outside the repo are
staged into the round's artifact dir and bundled, with home-rooted paths
mirrored under `HOME/` so the bundle never embeds your username. Relative
`../` traversal is still blocked.
```bash
pwsh runtimes/era.ps1 -TopicSlug skill-review -IncludeFiles ~/.claude/skills/era/SKILL.md
```

## Set your default reviewer

**Since v1.12 a bare `/era` dispatches a three-model PANEL simultaneously** —
Gemini 3.6 Flash (agy), Claude Opus 5 (claude CLI) and DeepSeek V4 Flash (New)
(opencode-go). Cross-vendor on purpose: a single reviewer is a single point of
failure, and in practice each model catches defects the others miss.

To **pin a personal default**, just say so in your TUI — one preset or a panel:

```
/era set default to gemini pro high
/era default opus
/era set default gemini,opus,deepseek-flash,muse-spark
```

This writes `config/defaults.json` inside the skill (v1.12 — previously an
environment variable). A file is read identically from Claude Code, PowerShell,
WSL, opencode and agy, because it is located from the script's own path rather
than from the environment. Takes effect immediately, everywhere, with no restart.

> **Why not an env var?** It is per-process and inherited, so it drifts: a value
> set at Windows User scope is invisible to already-running shells, which keep
> handing their *startup* copy to every child. Measured on one box: a variable
> cleared from User scope, Machine scope and `HKCU\Environment` still arrived in
> every new shell for days, because the owning terminal window predated the
> change — silently collapsing a 3-reviewer panel to one. `config/defaults.json`
> therefore takes precedence over `ERA_DEFAULT_REVIEWER`, and a losing env
> override is reported on stderr instead of being applied silently.

Any valid preset works (`haiku`, `sonnet`, `gemini-pro-high`, `deepseek`, `gemini-api`, …). A per-run `-Reviewer` always overrides it.

To check your current setup:

```
/era doctor
```

### Manual override

If you prefer to set the env var directly:

```powershell
# Windows (persistent, per-user):
[Environment]::SetEnvironmentVariable('ERA_DEFAULT_REVIEWER', 'gemini-pro-high', 'User')
$env:ERA_DEFAULT_REVIEWER = 'gemini-pro-high'  # current session
```
```bash
# macOS / Linux — add to ~/.bashrc or ~/.zshrc:
export ERA_DEFAULT_REVIEWER='gemini-pro-high'
```

## Supported backends

### CLI-based (uses your existing CLI auth — no API key needed)

| Backend | Presets | How it works |
|---------|---------|-------------|
| **agy** | `gemini-pro-low` (**default**), `gemini-pro-high`, `gemini` | Bundle read on-disk; response captured from the agy session transcript, correlated by a per-dispatch **Run-ID GUID** (concurrent-safe). Model selected per-process via `--model`. |
| **Claude CLI** | `opus`, `sonnet`, `haiku` | Bundle piped via stdin → `claude --print`. Direct stdout capture — the most robust path. The bundle *is* the prompt, so it must fit the CLI's window (**measured ~600k tokens**, appreciably less than the model's 1M API window). |
| **opencode** | `deepseek`, `minimax` | Bundle **attached via `opencode run -f <file>` at or under 51,200 bytes; above that the model reads it from disk** (attaching truncates silently at exactly 50 KiB). Model + variant via `-m`/`--variant` — **stateless** (no `state.json` swap / mutex). |

All CLI adapters launch their binary in a **private hidden console** (`ProcessStartInfo.CreateNoWindow=$true`), scrub agent-context env vars (`CLAUDECODE`, `AI_AGENT`, etc.) from the child's env block to avoid recursion-guard fast-exits, **tree-kill** (`Kill($true)`) on stall/timeout so no child process is orphaned, and route through a try/catch wrapper in the dispatcher so a failing adapter can't silently zero out metadata.

### Robustness

- **Two findings the audit round made and nobody acted on (v2.7.1)** — both real. First: the v2.4.1 fix that made model-hint resolution deterministic touched `resolve-model.ps1` and *only* there, while `era.ps1` carries a **second, independent implementation** of the same rule (the `-AgyModel` path) which kept the exact defect that release claimed to fix — a bare `.Keys` loop with no defined enumeration order, and a `Sort-Object` tie silently inheriting it. That is the same *one rule, two implementations, one of them fixed* shape the panel kept flagging, committed while fixing the previous instance of it. Second: `max_bundle_tokens` is honoured by the plan and read by **no adapter**, so raising it makes the plan say "fits" and the `claude` CLI answer `Prompt is too long` after the round is already paid for on every other seat — the asymmetry the opencode attach cap had, one backend over. Lowering a ceiling stays quiet; raising a **measured** one now warns, because the measurement is the thing that knows.

- **The first panel ever pointed at these releases found a critical (v2.7)** — six of eight releases had gone out on their author's review alone. One 4-seat round on that diff returned, all confirmed: `-PremiseCheck` was **discarded on every `-Diff` round** while its own log line said it had been appended (the section was written before `Merge-EraDiffPrompt`, whose `if (-not $ExistingCarriesCallerContent) { return $DiffPrompt }` threw it away); `-BlindSeat` still deleted code at the block-comment **closer** — the exact mirror of the opener bug fixed one release earlier, and the same shape found the same way; `-BundleOverrides` was never passed to the fallback re-dispatch, so a blinded seat's fallback silently got the sighted bundle; citation warnings were written **after** the metadata that was supposed to carry them; and a `bundle-access-refusal` — where the model never saw the bundle and *nothing was reviewed* — was categorised `answered-badly`, throwing away the branch the detector had just computed. Python triple-quote handling was **removed** rather than fixed: a line scanner cannot tell an opening docstring delimiter from a closing one, and its failure mode deletes code. Also closed: `Get-EraBundleLineCounts` failed **open and silently** on any read error (`Test-Path` is PowerShell-aware, `[System.IO.File]` resolves against the process CWD), and four tests that would have passed against a gutted implementation — including one asserting `-BeLike '**/*'`, which matches every non-empty string.

- **One seat can review the code without the narrative (v2.6)** — `-BlindSeat <preset>` hands a single reviewer the bundle with comments blanked while the rest review the normal one, keeping the round an A/B. The argument, from a reviewer that raised it and no other: this codebase's comments are unusually strong, which is exactly why a wrong one is persuasive — the ceiling that turned out 4x too tight came with a confident account of its own derivation, and every reviewer that read it inherited that premise before forming its own. A bare number invites *"where did this come from?"*; an explained number suppresses the question. Measured on a real 445 KB bundle of this repo, **43% of it was commentary**. Line numbers are preserved deliberately: deleting comment lines would shift everything after them and era validates `file:line` citations against the bundle, so a stripped seat would have all of its citations flagged as fabricated. repomix's own `--remove-comments` cannot do this job here — checked against 1.12.0, it covers 33 extensions and `.ps1` is not one of them. **Measured 2026-09-01 (v2.6.1):** in two within-model A/B pairs on a real server, the blinded arm produced more premise findings than the same model sighted (1 vs 0, and 3 vs 1) — a consistent direction on thin margins at n=1 per cell, not a settled effect. The same run showed the cost: a sighted seat found a defect discoverable *only* because a comment stated the intent the code violated, which is why exactly one seat is blinded. Method and full scoring in `docs/assessments/2026-09-01-blind-seat-ab.md`.

- **A locked directory no longer kills the round silently-wrongly (v2.4)** — repomix aborts the *entire* run on one unreadable directory, and the usual culprit is a live browser profile (`PermissionError: Permission denied while scanning directory`). A `.repomixignore` in the reviewed repo **cannot** prevent it: repomix hands that file to globby as an `ignoreFile`, so globby walks the locked directory while globbing for the file that would have excluded it — only the ignore-pattern list prunes traversal, and narrowing `-IncludeFiles` does not help because the full-tree walk happens regardless. Browser-profile directories are now pruned by default (also a privacy control — a live profile holds session cookies, and era uploads the bundle to a third party), and the abort now explains the cause, the fix, and explicitly what is *not* the fix.
- **Fabricated `file:line` citations are flagged (v2.4)** — one model was measured citing lines 5891, 5360 and 3612 of a 2,834-line file across two separate rounds. era reads each bundled file's line count and checks every citation against it, reporting any that point past the end of the file. Advisory by design: the prose findings were often correct and twice genuinely novel, so it is the line numbers that are untrustworthy, not the reasoning. Basenames that appear at more than one path are skipped rather than guessed — an over-eager checker that cries wolf on a correct citation is worse than none.
- **A non-review says which kind it was (v2.4)** — `agentic-narration-capture` covered three faults needing three different responses and named only one of them. The summary now reports `bundle-access-refusal` (the model could not see the bundle — look at delivery, not the prompt), `sub-floor-non-answer` (it answered, briefly and without structure — **often not narration at all**; a correct 280-character answer was rejected while 301- and 324-character ones passed), or `tool-intent-narration`. The error *code* is unchanged so the bounded fallback re-dispatch still triggers.

- **Every reviewer's delivery channel is checked before dispatch (v2.3)** — each backend gets the bundle a different way, and each way has a different ceiling: `opencode` **attaches** (silent truncation at 51,200 bytes) or **reads from disk** (verified to 668,389); `claude` **inlines via stdin** (measured ~600k tokens); `agy` **reads from disk** (unbounded); the REST adapters put it in a request body. Nothing checked any of that. Three consecutive 4-seat panels delivered 2 seats — a 2,396,233-byte bundle came back `Prompt is too long` from `opus`, and both opencode seats timed out at 600 s having returned nothing. The only pre-existing scale gate measured *pre-bundle source* bytes against a 10 MB ceiling — ~200x looser than the tightest channel era dispatches to — and armed only when no `-IncludeFiles` was passed, so all three curated rounds sailed through it. era now measures the bundle it actually built against every selected seat and **refuses with exit 1** (nothing dispatched, nothing spent, free to re-run) when a seat cannot possibly succeed; `-ForceBundleSize` / `ERA_BUNDLE_FORCE=1` dispatches anyway with a per-seat warning. The round summary names each seat's **delivery mode** (`via=attach`, `via=read-tool`, `via=stdin`, `via=disk-read`) and its **failure category** — `not-delivered` (nothing was reviewed; the seat's silence carries no information) as against `answered-badly` (the bundle *was* reviewed and the answer was rejected). `round-N-metadata.json` records `delivery_mode` per reviewer and `bundle_bytes`. Limits live in `backends/_registry.json` as `max_bundle_bytes` / `max_bundle_tokens`, so a newly measured ceiling is data, not a code change (this wiring was dead in v2.3 while being documented as working — fixed in v2.3.1 with an end-to-end test). Full method and numbers in `docs/assessments/2026-08-31-bundle-delivery-limits.md`.
- **The stall forensics were empty for the wrong reason (v2.3)** — every artifact under `%TEMP%\opencode-stall-debug` was 0 bytes while the error line beside it reported a non-zero `total bytes`. That contradiction read as "the process produced nothing" and sent a diagnosis after a startup failure that was never happening. `FileStream.Length` counts bytes still sitting in the write buffer, and the snapshot copied the file **without flushing**. Reproduced exactly: 218 bytes in → `Length` 218, on-disk 0, after `Flush()` → 218 — the same 218 as the log. Every artifact recorded before this fix is empty or cut at a 4,096-byte boundary for that reason, not because the backend was silent. ⚠️ A broken measuring instrument is worse than no instrument: it was briefly used to justify retiring a delivery path that works (below).
- **Bundles over 50 KiB reach opencode (v2.3)** — above the attach cap the model is told to read the bundle itself. That path was retired and un-retired the same day; the case for retiring it rested entirely on the empty artifacts above. Measured properly with **canaries** — marker lines planted at widely separated depths and asked back verbatim *before* the review, because a review coming back does not prove coverage — both default opencode seats returned markers from 25/50/75% depth on **109,066 B (57 s), 314,720 B (85 s) and 668,389 B (256 s)** bundles — 13x the attach cap. ⚠️ A returned marker proves **retrievability**, not that the model read the content in between; what supports the stronger claim is the conjunction of markers, grounded `file:line` citations across a 10,773-line bundle, and wall-clock scaling with size. It remains **intermittent in a way that is not explained** (the same seat lost rounds at 74,740 and 79,294 bytes, sizes these probes clear comfortably — neither size nor model). Concurrency was the leading hypothesis and **has since been tested and ruled out (v2.3.2)**: 10 trials with an `opencode serve` holding the database plus 22 external `opencode run` contenders produced **0 stalls**, identically to 10 trials with no other opencode process, and `database is locked` never appeared. The cause is genuinely unknown, with concurrency now the least-supported explanation. Caveat: those trials finish in ~13 s while the historical failures burned 600 s, so the failing regime was not reproduced.

- **The cost estimate is always reported (v1.17)** — the `$2`/`$10` per-reviewer and `$15` aggregate caps are enforced *through the cost prompt*, and `Invoke-CostPrompt` returns early whenever `Get-ForceMode` is true — which covers `-Force` (which SKILL.md tells the driving LLM to always pass) and any non-interactive host. So in agent usage the caps never fired. Measured across 43 recorded rounds nothing ever came close — worst round $1.76 against the $15 cap, worst single reviewer $1.71 against its $10 cap, zero breaches — so era now **reports and warns rather than blocks**: every round prints its per-reviewer estimate and total, a cap breach prints a `WARNING`, and both land in `cost_warnings` in the round metadata. Caps remain advisory under `-Force` by design.
- **Honest metadata** — every run records `content_ok`, `capture_strategy`, `retry_count`, and per-attempt cost. A non-review (an agentic tool-narration or "I can't read the bundle" refusal that still exits 0) is detected and recorded as a failure, never a silent success.
- **`content_ok` means "there is a review on disk" (v1.17)** — it used to be read off the adapter's own flag, which only agy and opencode ever set, so for REST backends it meant "the HTTP call worked". Worse, agy's clean-capture return sets it `$true` while passing the agy *process* exit code straight through, so a capture that read fine but whose process was killed at the deadline reported `content_ok=true, error=null` with its answer already demoted to `*.rejected.md`. It is now true only when that reviewer's response file is actually present under a readable name; a downgrade is named in `warnings`.
- **The non-review detector runs on every backend (v1.17)** — it used to be dot-sourced by only the two agentic adapters (`agy`, `opencode`), so `claude`, `anthropic`, `geminiapi` and `openaicompat` accepted any non-empty string as a review. A two-character answer from `opus` — a shipped default panel member — was recorded `content_ok=true`, promoted to canonical, and fed into round N+1. All six adapters now route their capture through the shared detector before returning success, and a hit is an honest `ExitCode=-1` / `ContentOk=$false` that writes no artifact. The detector runs on the model's own text, *before* any truncation banner is prepended, so the banner cannot push a short non-answer over the length floor.
- **A prompt echoed back is not a review (v1.17)** — measured 2026-08-09: gemini-pro-high hit its output cap and what landed on disk was the prompt, handed back. Nothing caught it — the narration detector's branches are all gated on the response having no markdown heading (an era prompt is full of them), and a response contract cannot help because the prompt necessarily contains the tokens it requires (measured: an echoed prompt passes with `missing=[]`). All six adapters now run `Test-EraPromptEcho`. Threshold picked by measurement, not taste: across 69 real prompt→response pairs in the local corpus the overlap metric reads **0.000** — including 85 KB round-2 prompts that embed prior reviews — while a quarter-echo reads 0.225. Full table in `docs/assessments/2026-08-10-prompt-echo-threshold.md`.
- **A void round exits 2 (v1.17)** — a round where every reviewer failed to produce a readable review no longer exits 0. Measured 2026-08-09: all three panel members went void in one run (opus over budget, deepseek-flash failed post-bundle, gemini-pro-high truncated and rejected) and era reported success. Exit **2** is distinct from the preflight **exit 1** on purpose — exit 1 spent nothing and re-running is free, exit 2 already cost real money, so **never silently re-dispatch on 2**. era prints a per-reviewer breakdown and keeps every artifact for diagnosis.
- **Self-healing (agy)** — a stall/timeout, an empty capture, or a narration capture triggers one in-adapter retry within the same budget.
- **agy auto-fallback (v1.10)** — if agy still fails after that retry, era re-dispatches to a non-agy reviewer (`$env:ERA_AGY_FALLBACK`, default auto / `off` to disable) so the round still produces a review instead of an empty result.
- **Cross-shell paths (v1.10)** — `-IncludeFiles /c/Users/…` (Git-Bash/MSYS) is normalized to `C:/Users/…` on Windows; running outside a git repo without git no longer raw-errors; known `-IncludeFiles`/empty-bundle mistakes print a clean `[era] ERROR:` line (exit 1) instead of a PowerShell stack.
- **claude WSL credential fallback (v1.15)** — Windows `claude.exe` and a `claude` running inside WSL read **separate** credential stores that expire independently. When the Windows one fails for a reason a different store would fix (auth / workspace-trust), the adapter retries once via `wsl.exe -e <linux claude>` and records the switch in `warnings`. Other failures (bad model id, network, rate limit, context overflow) are **not** retried. ⚠️ **A working interactive agent is no evidence that this backend works** — it authenticates against a different store. Measured 2026-08-04: `opus` went 115/119 lifetime → 0/4 in one day on an expired Windows token while the agent kept working.
- **The WSL retry fits inside the GLOBAL budget (v1.16)** — the v1.15 fallback runs a *second* full attempt, but the dispatcher waits only `TimeoutSec + 30` for the whole adapter, so two attempts each budgeted `TimeoutSec` could overrun it and the ThreadJob was killed mid-retry, recorded as a bare "Timed out after N seconds (global)" with no cause. The retry now receives the REMAINING budget (floored at 60 s). ⚠️ Observed only on a loaded box with three concurrent dispatches — **a single unloaded verification run cannot surface this class of defect**.
- **The claude adapter reports the CLI's real error (v1.15)** — it threw with `$stderr` while the CLI prints fatal reasons to **stdout**, so failures recorded a *blank* cause; four sessions read the empty string and concluded the model was unreliable. It now carries whichever stream actually spoke.
- **Concurrency-safe** — agy uses per-process `--model` + Run-ID capture; opencode is stateless; multiple dispatches against one topic reserve distinct round numbers atomically.
- **Adaptive default** — a bare `/era` (no `-Reviewer`) live-detects which backends you have (CLI on PATH / API key set) and picks the first usable one by preference instead of erroring; override with `$env:ERA_DEFAULT_REVIEWER`. `era.ps1 -Doctor` prints the full status.
- **Line-numbered bundles** — repomix emits true per-file line numbers and every prompt template instructs `file:line` citation from them, sharply reducing fabricated line citations (verify per the SKILL.md conductor protocol regardless).
- **pwsh 7+** is required (enforced via `#Requires`).

### Direct REST (uses an API key — pure HTTPS, no subprocess, no TTY)

| Backend | Presets | Auth env var |
|---------|---------|-------------|
| **geminiapi** | `gemini-api`, `gemini-api-pro` | `GEMINI_API_KEY` |
| **anthropic** | `opus-api`, `sonnet-api`, `haiku-api` | `ANTHROPIC_API_KEY` |
| **openaicompat** | `deepseek-api`, `deepseek-reasoner-api`, `minimax-api` (extensible to Groq / Together / OpenRouter via registry edit) | per-preset (`DEEPSEEK_API_KEY`, `MINIMAX_API_KEY`, …) |

REST adapters are simpler (~150 LOC each vs ~300 for CLI adapters), have no console/TTY exposure, and return real token counts + costs in the metadata. They coexist with CLI adapters — use whichever fits your auth setup.

### opencode over HTTP + NVIDIA NIM (v1.8)

The opencode-go models are plain HTTP APIs, so they can be reached **directly** through the `openaicompat` adapter — no opencode **TUI**, and none of the headless-driver watchdog / console-pollution / narration-capture failure class. Same opencode-go subscription, same cost.

| Preset | Model | Endpoint | Key |
|---|---|---|---|
| `deepseek-http` | deepseek-v4-pro | `opencode.ai/zen/go/v1` | `OPENCODE_API_KEY` |
| `glm-http` | glm-5.1 | `opencode.ai/zen/go/v1` | `OPENCODE_API_KEY` |
| `minimax-http` | minimax-m2.7 | `opencode.ai/zen/go/v1` | `OPENCODE_API_KEY` |
| `kimi-http` | kimi-k2.7-code | `opencode.ai/zen/go/v1` | `OPENCODE_API_KEY` |
| `nvidia` | llama-3.1-70b-instruct (free NIM tier) | NVIDIA NIM | `NVIDIA_API_KEY` |

- **Keys auto-resolve from opencode's `auth.json`.** If `OPENCODE_API_KEY` / `MINIMAX_API_KEY` / `NVIDIA_API_KEY` isn't in your environment, era sources it from `~/.local/share/opencode/auth.json` (subscription `type:api` entries) at dispatch — no manual key setup if you already use opencode.
- **Opt-in flag:** set `ERA_USE_HTTP_OPENCODE=1` to transparently route the `deepseek` / `minimax` reviewer aliases over HTTP instead of the TUI. Default off — existing behavior unchanged.
- **Reasoning models** (deepseek) are handled: the adapter falls back to `reasoning_content` and honors a per-preset `max_tokens`, so reviews are never silently blank.
- Not reachable this way: **Gemini 3.1 Pro** (Antigravity-only → keep `agy`) and **Claude** (no HTTP route without an Anthropic key / Zen balance → keep the `claude` CLI).

## Architecture

```
LLM reads SKILL.md → parses natural-language input → delegates to era.ps1
                                                          ↓
                                              workflow.ps1 core (lock, dispatch, ThreadJobs)
                                                          ↓
                                              backend adapter (CLI or REST)
```

Single entry point. All deterministic work (repomix, dispatch, cost calculation) is handled by PowerShell. The SKILL.md provides structured workflow guidance (9-step checklist, decision trees, convergence loop) so any driving model follows the same invocation flow without inferring steps.

## Natural-language input

LLMs invoking `/era` should parse free-form input (e.g. `/era use gemini 3.1 pro`, `/era deepseek v4 flash`) into typed flags before dispatching. The resolver rules are in [SKILL.md](SKILL.md) — filler-word stripping, pattern matching against the registry, highest-tier-wins defaults, topic-slug vs reviewer-spec disambiguation.

## Documentation

See **[SKILL.md](SKILL.md)** for full usage — includes a quick-reference card, invocation workflow (9-step checklist + dot-graph), mode selection and file curation decision trees, round 2+ convergence protocol, pitfalls table, flags, prompt templates, resolver rules, and the normative **conductor protocol** (claim triage + validation duty, per-claim dispositions, iteration stop rules including confabulation detection) with the **conversation-context hand-off** template for `-ConversationFile`.

## Troubleshooting

If invocation fails, see **[references/troubleshooting.md](references/troubleshooting.md)** for edge cases and known errors with fixes.

## Tests

Pester 5 unit tests live in `tests/`. Run before merging changes to `backends/`, `workflow.ps1`, or `runtimes/era.ps1`:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck   # one-time
Invoke-Pester -Path tests/                                              # ~100s, no network
```

Coverage (325 tests): `Get-AgyTranscriptResponse` (the highest-risk function), the agy retry loop + non-review detector, the cross-adapter process-tree-kill and shareable-sink invariants, the natural-language resolver (incl. the with/via clause acceptance table), empty-bundle/ANSI regexes, registry integrity, env-scrub blocks, and out-of-repo staging (incl. the username-absence privacy assertion). See `tests/README.md` for the full list and when to add tests.

## License

MIT — see [LICENSE](LICENSE).
