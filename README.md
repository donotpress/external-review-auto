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
/era my-feature use sonnet    # review topic "my-feature" with Claude Sonnet
/era multi gemini,opus        # dispatch to multiple reviewers in parallel
/era review this              # auto-detect context and review (spec or git changes)
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

## Set your default reviewer

A bare `/era` adapts to what you have installed (see [Robustness](#robustness)). To **pin a personal default**, just say so in your TUI:

```
/era set default to gemini pro high
/era default opus
/era set default sonnet
```

This persists `ERA_DEFAULT_REVIEWER` per-user (writes to your shell profile on macOS/Linux, or the Windows user environment). Takes effect immediately and in new shells. No restart needed.

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
| **Claude CLI** | `opus`, `sonnet`, `haiku` | Bundle piped via stdin → `claude --print`. Direct stdout capture — the most robust path. |
| **opencode** | `deepseek`, `minimax` | Bundle **attached via `opencode run -f <file>`** (no Read-tool call). Model + variant via `-m`/`--variant` — **stateless** (no `state.json` swap / mutex). |

All CLI adapters launch their binary in a **private hidden console** (`ProcessStartInfo.CreateNoWindow=$true`), scrub agent-context env vars (`CLAUDECODE`, `AI_AGENT`, etc.) from the child's env block to avoid recursion-guard fast-exits, **tree-kill** (`Kill($true)`) on stall/timeout so no child process is orphaned, and route through a try/catch wrapper in the dispatcher so a failing adapter can't silently zero out metadata.

### Robustness

- **Honest metadata** — every run records `content_ok`, `capture_strategy`, `retry_count`, and per-attempt cost. A non-review (an agentic tool-narration or "I can't read the bundle" refusal that still exits 0) is detected and recorded as a failure, never a silent success.
- **Self-healing (agy)** — a stall/timeout, an empty capture, or a narration capture triggers one in-adapter retry within the same budget.
- **Concurrency-safe** — agy uses per-process `--model` + Run-ID capture; opencode is stateless; multiple dispatches against one topic reserve distinct round numbers atomically.
- **Adaptive default** — a bare `/era` (no `-Reviewer`) live-detects which backends you have (CLI on PATH / API key set) and picks the first usable one by preference instead of erroring; override with `$env:ERA_DEFAULT_REVIEWER`. `era.ps1 -Doctor` prints the full status.
- **pwsh 7+** is required (enforced via `#Requires`).

### Direct REST (uses an API key — pure HTTPS, no subprocess, no TTY)

| Backend | Presets | Auth env var |
|---------|---------|-------------|
| **geminiapi** | `gemini-api`, `gemini-api-pro` | `GEMINI_API_KEY` |
| **anthropic** | `opus-api`, `sonnet-api`, `haiku-api` | `ANTHROPIC_API_KEY` |
| **openaicompat** | `deepseek-api`, `deepseek-reasoner-api`, `minimax-api` (extensible to Groq / Together / OpenRouter via registry edit) | per-preset (`DEEPSEEK_API_KEY`, `MINIMAX_API_KEY`, …) |

REST adapters are simpler (~150 LOC each vs ~300 for CLI adapters), have no console/TTY exposure, and return real token counts + costs in the metadata. They coexist with CLI adapters — use whichever fits your auth setup.

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

See **[SKILL.md](SKILL.md)** for full usage — includes a quick-reference card, invocation workflow (9-step checklist + dot-graph), mode selection and file curation decision trees, round 2+ convergence protocol, pitfalls table, flags, prompt templates, resolver rules, and triage guidance.

## Tests

Pester 5 unit tests live in `tests/`. Run before merging changes to `backends/`, `workflow.ps1`, or `runtimes/era.ps1`:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck   # one-time
Invoke-Pester -Path tests/                                              # ~100s, no network
```

Coverage (260+ tests): `Get-AgyTranscriptResponse` (the highest-risk function), the agy retry loop + non-review detector, the cross-adapter process-tree-kill and shareable-sink invariants, the natural-language resolver, empty-bundle/ANSI regexes, registry integrity, and env-scrub blocks. See `tests/README.md` for the full list and when to add tests.

## License

MIT — see [LICENSE](LICENSE).
