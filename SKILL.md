<!-- 2026-05-28: SKILL.md split. Hardening/troubleshooting/internals
     relocated to references/. If you reach for "edge case #7" by section
     name, check references/troubleshooting.md. -->
---
name: external-review-auto
description: Automatically send a curated repomix bundle to an external reviewer (agy/Claude CLI/opencode) for a second opinion. No manual paste step — the backend reads the bundle from disk and the response is captured automatically.
trigger: /external-review-auto
---

# /external-review-auto

## Prerequisites

| Dependency | Required | Install |
|---|---|---|
| **PowerShell 7+** (`pwsh`) | ✅ Required | `winget install Microsoft.PowerShell` or `brew install powershell` |
| **ThreadJob module** | ✅ Required | `Install-Module -Name ThreadJob -Force -Scope CurrentUser` |
| **repomix** | ✅ Required | `npm install -g repomix` |
| **At least one backend CLI** | ✅ Required | See below |

### Supported backends (pick at least one)

**CLI-based (no API key required — uses your existing subscriptions):**

| Backend | Install command | Reviewer presets |
|---|---|---|
| **agy** (antigravity CLI) | Platform-specific (see agy docs) | `gemini-pro-low` (**default**), `gemini-pro-high`, `gemini` |
| **Claude Code CLI** | `npm install -g @anthropic-ai/claude-code` | `opus`, `sonnet`, `haiku` |
| **opencode** | opencode install | `minimax`, `deepseek` |

**Direct REST (no API key required — pure HTTPS):**

| Backend | API key env var | Reviewer presets |
|---|---|---|
| **geminiapi** | `GEMINI_API_KEY` (free at https://aistudio.google.com/apikey) | `gemini-api`, `gemini-api-pro` |
| **anthropic** | `ANTHROPIC_API_KEY` (https://console.anthropic.com/) | `opus-api`, `sonnet-api`, `haiku-api` |
| **openaicompat** | per-preset (`DEEPSEEK_API_KEY`, `MINIMAX_API_KEY`, …) | `deepseek-api`, `deepseek-reasoner-api`, `minimax-api`; extensible via `_registry.json` to Groq/Together/OpenRouter/any OpenAI-compatible endpoint |

REST adapters bypass the CLI entirely — no subprocess, no TTY exposure, no console pollution, no transcript-file polling. Use them if you want the strongest hermetic guarantees and/or you have direct API keys. Otherwise CLI adapters are fine and free.

The skill fails fast with a clear error if any dependency is missing. CLI presets check for the binary on PATH; REST presets check for the API key env var.

### First run / missing prereqs (guidance for the driving LLM)

- **Preflight:** before the first dispatch on a new machine, run `pwsh runtimes/era.ps1 -Doctor`. It prints one consolidated report — pwsh, ThreadJob, repomix, and every backend CLI/API key — each marked `[ OK ]` / `[MISS]` / `[ -- ]` with the exact fix command, plus a `READY` / `NOT READY` verdict. It only reports; it never installs.
- **On any prereq error** (from `-Doctor` or a failed dispatch), surface the exact missing item and the fix command from the message, then **offer to run it for the user** — e.g. *"repomix isn't installed. Want me to run `npm install -g repomix`?"* — and only run it with their approval. **Never auto-install without asking.** The fix commands are: `Install-Module -Name ThreadJob -Force -Scope CurrentUser`, `npm install -g repomix`, the relevant backend CLI install, or `setx`/`$env:` for an API key (CLI presets reuse the user's existing login — no key needed).
- If **no backend is available**, tell the user they need at least one (cheapest reliable: Claude **Haiku** via the `claude` CLI, or **DeepSeek V4 Flash** via opencode) before a review can run.

> **Default reviewer (adaptive):** a bare `/era` with no `-Reviewer` prefers
> **`gemini-pro-low` (Gemini 3.1 Pro (Low) via agy)** — far more reliable than the old
> Flash default (94% class vs 67%). **But the default adapts to what's installed:** if
> agy isn't available, `/era` auto-selects the first usable backend by preference
> (`gemini-pro-low` → `sonnet` → `deepseek` → `gemini-api`) instead of erroring, and
> prints which it chose. Override the order with `$env:ERA_DEFAULT_REVIEWER` (e.g.
> `ERA_DEFAULT_REVIEWER=haiku`), or pass `-Reviewer` explicitly (an explicit choice is
> respected as-is and still errors if its backend is missing). If NO backend is
> available, `/era` errors with install guidance and points to `-Doctor`.
> **Cost note:** Pro (Low) is **$1.5 in / $5.0 out per M**; the cost-cap prompt still
> fires (unless `-Force`).

## How it works

This skill follows a **single-entry-point** architecture. When the slash command fires, the LLM:

1. **Curates** a file list from conversation context (or lets era.ps1 auto-detect)
2. **Optionally writes** a custom review prompt with background/decisions/context
3. **Delegates** all deterministic work to `era.ps1` — a PowerShell script that handles repomix bundling, cost estimation, backend dispatch, response capture, and metadata

**Do not follow manual workflow steps.** Always delegate to `era.ps1`.

## Parsing natural-language input — call `resolve.ps1` (portable, deterministic)

When the user gives free-form input (e.g. `/era gemini 3.1 pro low`, `/era console-bugs use opus`) rather than typed flags, **do not interpret the rules ad hoc.** Shell out to the deterministic resolver so the resolution is **identical regardless of which model is driving** (Claude, Gemini, an opencode model, etc.):

```pwsh
# positional arg
pwsh "<skill-root>/runtimes/resolve.ps1" "<user input>"
# or via stdin
"<user input>" | pwsh "<skill-root>/runtimes/resolve.ps1"
```

`resolve.ps1` prints **only** a JSON object of typed `era.ps1` flags to stdout, e.g.:

| User input | resolve.ps1 stdout |
|---|---|
| `gemini 3.1 pro low` | `{"Reviewer":"gemini-pro-low"}` |
| `deepseek v4 flash` | `{"Reviewer":"deepseek","Model":"opencode-go/deepseek-v4-flash"}` |
| `console-bugs use opus` | `{"Reviewer":"opus","TopicSlug":"console-bugs"}` |
| (bare / empty) | `{"Reviewer":"gemini-pro-low"}` |
| unmatched/ambiguous | `{"error":"unresolved","input":"<raw>"}` |

Parse the JSON, then forward the keys as `era.ps1` flags (`-Reviewer`, `-Model`, `-TopicSlug`).
If the JSON is `{"error":"unresolved",...}`, **ask the user one clarifying question — never guess.**
If the user already passed typed flags (`--reviewer X --model Y`), forward them verbatim; the
resolver is a friendly fallback, not a replacement. The full human-readable patterns table lives
in `era/SKILL.md`; `resolve.ps1` is the executable, single-source-of-truth version of it.

## Handling the response — triage before incorporating

A review response is a list of *claims*. Some claims are facts (the code does X, this method exists, this error is raised). Some are reasoning (this would cause Y under Z conditions, A is preferred over B). **Auto-incorporating every claim without verification is the failure mode this skill is designed to AVOID.** A reviewer can be wrong, out of date, or hallucinating an API that doesn't exist.

**Before incorporating any finding, classify it:**

| Claim type | Examples | Action before incorporating |
|---|---|---|
| **Empirical — specific code/API behavior** | "pandas raises ValueError on duplicate-index reindex", "sqlite3 connections aren't thread-safe", "this SDK method returns shape X", "HTTP status 404 indicates Y" | **Validate via probe.** Run the code path, read the live SDK output, check the actual exception. Cite the validation in the spec amendment. |
| **Code-reading — claims about the spec or repo** | "view.py:114 hardcodes `_accounts[0]`", "the dataclass has no `headline` field", "the spec says X but Y" | **Read the cited file.** Confirm the claim against actual source. |
| **Known platform behavior** | Python defaults, well-documented library quirks, OS conventions | **Trust + cite the doc** (or quickly check if in doubt). |
| **Design reasoning / consistency** | "this would scale-mismatch", "this design contradicts an earlier decision", "this is the standard GIPS approach" | **Reason about it yourself.** If the logic holds, incorporate; if not, push back. |

When auto-incorporating across multiple review rounds, this triage decays unless deliberately maintained. Watch for the "auto-pilot" failure mode where after 2-3 rounds the conductor stops thinking and just folds whatever the reviewer says. **Validate at least one empirical claim per round to keep the muscle warm.**

Skip incorporation entirely when:
- The claim contradicts something already validated (the reviewer may not have the full context)
- The "fix" introduces complexity beyond the original scope without clear necessity
- The "important issue" is a stylistic preference, not a defect

Be willing to push back in your next round's prompt: "Round N-1 raised X, but after probing I found Y — please re-evaluate."

## Usage

```
/external-review-auto                           # auto-detect topic, full review
/external-review-auto <topic-slug>              # explicit topic
/external-review-auto --mode assessment         # review code (no spec required)
/external-review-auto --reviewer opus           # use Claude Sonnet backend
/external-review-auto --model "gemini 3.1 pro"  # specific model
```

### All flags

| Flag | era.ps1 flag | Purpose |
|------|-------------|---------|
| `<topic-slug>` (positional) | `-TopicSlug <slug>` | Explicit topic (auto-detected from newest spec if omitted) |
| `--doctor` | `-Doctor` | Preflight only: report prereq + backend status (with fix commands) and exit. No dispatch, no install. |
| `--mode assessment` | `-Mode assessment` | No spec file required; reviews arbitrary code |
| `--reviewer <name>` | `-Reviewer <name>` | Comma-separated for multi-reviewer: `gemini,opus`. Default (omitted) = `gemini-pro-low` (Gemini 3.1 Pro (Low)) |
| `--model <hint>` | `-Model <hint>` | Override model: `"gemini 3.1 pro"`, `"deepseek v4 pro"` |
| `--provider <name>` | `-Provider <name>` | Force a specific opencode provider |
| `--include <path1,path2>` | `-IncludeFiles path1,path2` | Specific files to bundle (curated by LLM) |
| `--prompt-override <path>` | `-PromptOverrideFile path` | LLM pre-wrote a custom prompt at this path |
| `--force` | `-Force` | Skip cost confirmation prompt |
| `--diff` | `-Diff` | Round 2+: only bundle changed files (opt-in) |
| `--auto-detect` | `-AutoDetect` | Derive include list from `git status` + `HEAD~1` (human use) |
| `--spec-review <path>` | `-SpecReview <path>` | One-flag spec review: auto-fills template + bundles spec |

### LLM-driven file selection

Pass specific files via `-IncludeFiles` to avoid bundling the whole repo. Curate the list from conversation context:

```pwsh
pwsh ~/.claude/skills/external-review-auto/runtimes/era.ps1 -IncludeFiles src/file1.py,src/file2.py,docs/spec.md
```

Without `-IncludeFiles`, era.ps1 uses broad globs (`*.md`, `*.py`, etc.) — okay for quick reviews but produces larger bundles.

### LLM-driven prompt

Write a rich prompt (with background, decisions, conversation context) to a temp path, then pass it:

```pwsh
# Step 1: write prompt
Set-Content -Path .external-reviews/my-topic/pending-prompt.md -Value "..."

# Step 2: invoke era.ps1 with the prompt and curated files
pwsh ~/.claude/skills/external-review-auto/runtimes/era.ps1 -TopicSlug my-topic -PromptOverrideFile .external-reviews/my-topic/pending-prompt.md -IncludeFiles src/file1.py,src/file2.py
```

era.ps1 copies your prompt to the correct `round-N-prompt.md` after resolving N internally. Without `-PromptOverrideFile`, era.ps1 writes a generic fallback.

For round N > 1, include `{{PREVIOUS_ROUND}}` anywhere in your prompt to auto-substitute round-(N-1)'s response.

### Quick examples

```pwsh
# Preflight: check prerequisites + backend availability (no dispatch)
pwsh ~/.claude/skills/external-review-auto/runtimes/era.ps1 -Command doctor

# Auto-detect context and dispatch (newest spec or recent git changes)
pwsh ~/.claude/skills/external-review-auto/runtimes/era.ps1 -Command review-this

# Scan for review targets (specs, commits, existing topics — no dispatch)
pwsh ~/.claude/skills/external-review-auto/runtimes/era.ps1 -Command suggest

# Update model registry from connected opencode providers
pwsh ~/.claude/skills/external-review-auto/runtimes/era.ps1 -Command update-models

# Default: auto-detect topic, gemini-pro-low = Gemini 3.1 Pro (Low) via agy backend
pwsh ~/.claude/skills/external-review-auto/runtimes/era.ps1

# Explicit topic, Claude Sonnet
pwsh ~/.claude/skills/external-review-auto/runtimes/era.ps1 -TopicSlug purchase-cooldown -Reviewer opus

# Multi-reviewer (agy + Claude + opencode)
pwsh ~/.claude/skills/external-review-auto/runtimes/era.ps1 -Reviewer gemini,opus,minimax

# One-flag spec review
pwsh ~/.claude/skills/external-review-auto/runtimes/era.ps1 -SpecReview docs/superpowers/specs/2026-05-28-project-b-design.md -Reviewer gemini -Model 'gemini 3.1 pro'
```

### CI/CD / non-interactive mode

Set `$env:ERA_FORCE=1` to skip the cost confirmation prompt.

## Prompt templates

Use these when writing custom prompts via `-PromptOverrideFile`.

> ### ⚠️ Agentic-backend rule: never tell the model to "read/open/view files"
>
> The `agy` backend (Gemini via Antigravity) is an **agentic planner**, not a single-shot completion model. Its response is captured from agy's transcript (`PLANNER_RESPONSE` entries). If your override prompt instructs the model to *"read the bundled source files,"* *"cite the file/function you read,"* or otherwise invites file access, agy will try to **use its own tools to open files** — emitting a planner preamble like `"I will view <file> from line X to Y…"` (often a file **not even in the bundle**). The capture grabs only that ~120-char preamble and you get a truncated non-review. Wall-clock looks normal (~300s); `response_chars` is ~110–130.
>
> **The bundle is already self-contained — say so.** Open every override with: *"The spec and all source files are fully included in the attached bundle. Review ONLY what is in the bundle. Do NOT attempt to open, view, fetch, or read any file outside the bundle."* You may still ask the reviewer to **reference** `file:line` *in its findings* (the spec-review template does) — that's about citing, not opening. The distinction is "cite what's attached" (safe) vs. "go read the source" (triggers tool-use).
>
> This only bites the `-PromptOverrideFile` path; the default `-SpecReview` template is already worded safely. Non-agentic backends (Claude CLI `opus`/`sonnet`, `geminiapi`, `opencode`/`deepseek`/`minimax`) are immune — they return a single completion regardless — so a truncating agy run can be re-dispatched to one of those as a fallback. See `references/troubleshooting.md`.

### Spec review template

```markdown
# External Review Prompt — {{TOPIC_TITLE}}

You are reviewing a design spec for {{ONE_SENTENCE_PROJECT_DESCRIPTION}}.

The spec is `{{SPEC_PATH}}` (included in the attached bundle). Every other file in the bundle is **existing code** the implementation will touch or that provides necessary context for the design decisions.

## Background

{{BACKGROUND_FROM_SPEC}}

## Decisions already made (don't re-litigate; review for *correctness within these constraints*)

{{DECISIONS_FROM_SPEC}}

## What to review

Please assess the spec for the following, in priority order. **Be specific** — point to file paths, line numbers, exact functions.

### 1. Correctness — does the design actually solve the problem?
### 2. Race conditions / concurrency
### 3. Compatibility with existing code paths and conventions
### 4. Persistence / migration plumbing (only if applicable; skip if not)
### 5. Edge cases the spec missed
### 6. Testability — are the proposed tests sufficient?
### 7. Anything else wrong, missing, or under-specified.

## Output format

` `` `
## Critical issues (must fix before implementation)
1. <file:line> — <issue> — <suggested fix>

## Important issues (should fix)
1. ...

## Minor / nits
1. ...

## Things the spec got right (briefly, so I know what's solid)
1. ...

## Open questions for the author
1. ...
` `` `

Be terse. Don't pad. If a section is empty, write "(none)".
```

### Assessment (code review) template

```markdown
# External Review — {{TOPIC_TITLE}}

You are reviewing {{SUBJECT_DESCRIPTION}}.

The following files are attached for your review:
{{FILE_LIST}}

## Context from conversation

{{CONVERSATION_CONTEXT}}

## What to review

Please assess:
1. **Correctness** — are the claims / implementation accurate?
2. **Completeness** — what's missing?
3. **Edge cases** — what could break?
4. **Actionability** — are the suggestions well-targeted?

## Output format

` `` `
## Critical issues
1. ... — ...

## What is correct
1. ...

## What's missing or under-weighted
1. ...

## Suggestions
1. ...

## Final verdict
<one sentence>
` `` `

Be terse. Don't pad. If a section is empty, write "(none)".
```

## Constraints

- **`ignore.useGitignore: false` + `ignore.useDefaultPatterns: false`** in every repomix config (prevents the project's existing repomix config from ballooning the bundle).
- **Round numbers stay monotonic** across both auto and manual reviews (shared counter per topic slug).
- **Never pass bundle content through argv** — always use a file path on disk.
- **Prompt file must be written BEFORE repomix** — `instructionFilePath` is read at bundle time.

## If invocation fails

- For edge cases and known errors: see `references/troubleshooting.md`
- For hardening details, opencode variant resolution, parallel-dispatch mechanics, and maintainer notes: see `references/internals.md`

## See also

- `references/internals.md` — hardening details, opencode variant resolution, parallel-dispatch mechanics, maintainer notes
- `references/troubleshooting.md` — edge cases and known errors with fixes
