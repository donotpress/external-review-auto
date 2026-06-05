# /era (external-review-auto) Skill — Improvements Design

**Status:** Draft for external review
**Date:** 2026-05-28
**Surface:** `~/.claude/skills/external-review-auto/` (SKILL.md, runtimes/era.ps1, workflow.ps1, backends/*.ps1)
**Author context:** Spec written by Claude after using /era twice in one session (project-a, project-b). Both reviews caught real bugs that would have shipped — outcome quality is high. Ergonomics has identifiable, fixable friction.

---

## 1. Motivation

The /era skill has high-value outcomes (real bug catches by external reviewer models) and identifiable friction. This session: 6 dispatches, 3 failures, ~3 minutes of pure debugging overhead, ~6,000-token SKILL.md loaded into LLM context as a system-reminder.

**Constraint:** the skill is cross-platform by design — Claude Code, Copilot CLI, Codex, Gemini CLI — and supports 6 backends (agy, Claude CLI, opencode, geminiapi REST, anthropic REST, openaicompat REST). Much of SKILL.md's size is genuine engineering for that surface (TTY isolation, env scrubbing, opencode `model.json` state-mutation race-fix, stall detection). **Improvements must preserve this hardening, not strip it.**

Goal: streamline SKILL.md and fix bugs **without losing the cross-platform robustness** that makes the skill broadly useful.

## 2. Goals / Non-goals

**Goals:**

- Cut SKILL.md token footprint from ~6,000 to ~1,500-2,000 by relocating maintainer/troubleshooting content to `references/` (loaded on-demand)
- Fix concrete bugs: `-Diff` flag parameter binding error, bundle-empty check ordering, comma-string `-IncludeFiles` silent failure
- Reduce manual ceremony for common workflows: spec review, round-N follow-ups, file curation
- Keep platform-agnostic invocation: any change must work whether invoked via Claude Code Skill tool, Copilot `skill`, Gemini `activate_skill`, or direct `pwsh era.ps1`

**Non-goals:**

- Rewriting the multi-backend dispatch layer (it works)
- Replacing PowerShell with cross-shell (era.ps1 is PS-specific by intentional choice — see `runtimes/shell.md`)
- Adding new backends
- Changing the round-numbering / claim-file concurrency model (it's clean)

## 3. Concrete data from session

| Dispatch | Outcome | Cause |
|---|---|---|
| `project-a` round 1 | ✅ Worked, caught lazy-render guard bug | — |
| `project-b` round 1 attempt #1 | ❌ Empty bundle (0 files in XML) | `-IncludeFiles "a,b,c"` parsed as one string in PS, not split |
| `project-b` round 1 attempt #2 | ❌ "Term '/c/Users/...' not recognized" | Bash `$HOME` expansion produced `/c/Users/...` path that PS couldn't parse |
| `project-b` round 1 attempt #3 | ✅ Worked, caught timing bug | PS array syntax `'a','b','c'` |
| `project-b` round 2 attempt #1 | ❌ "Cannot convert 'System.Collections.Hashtable' to 'SwitchParameter'" | `-Diff` flag parameter binding bug |
| `project-b` round 2 attempt #2 | ✅ Worked, found 2 new edge cases | Dropped `-Diff` |
| `project-b` round 3 | ✅ Worked, found 3 more new edge cases | — |
| `project-b` round 4 | (in flight) | — |

SKILL.md token weight: empirically ~6,000 tokens loaded as `<system-reminder>` block on first use. Of that, ~70% is troubleshooting / maintainer notes / hardening rationale that the calling LLM doesn't need to invoke the skill.

## 4. Proposed changes (with cross-platform impact analysis)

### A. SKILL.md split: keep entry-point content, relocate everything else to `references/`

**Current SKILL.md structure:**

| Section | Approx tokens | Necessary for invocation? |
|---|---|---|
| Prerequisites table | 150 | Yes (informs install) |
| Supported backends table | 200 | Yes (informs `--reviewer` choice) |
| Hardening guarantees (CLI adapters) | 600 | No (maintainer-internal) |
| Variant resolution (opencode) | 250 | No (auto-applied by adapter) |
| Safe opencode invocation for subagents | 300 | No (specific edge case) |
| Stall detector (opencode adapter) | 100 | No (auto-applied) |
| Resolver gotcha (era.ps1 maintainer) | 250 | No (maintainer-only) |
| How it works (5 lines) | 50 | Yes |
| Usage examples | 200 | Yes |
| All flags table | 400 | Yes |
| LLM-driven file selection | 250 | Yes |
| LLM-driven prompt | 350 | Yes |
| Quick examples | 200 | Yes |
| CI/CD note | 30 | Yes |
| Prompt templates | 1,400 | Yes (heavily used) |
| Module layout (ASCII tree) | 250 | No (maintainer-internal) |
| Parallel dispatches | 600 | No (rare, edge case) |
| Edge cases 1-9 | 700 | Conditional (load on failure) |
| Constraints | 150 | Yes |

**Proposed split:**

`SKILL.md` (target ~2,000 tokens) — keeps:
- Prerequisites, backends, brief "How it works"
- Usage + flags table
- LLM-driven file selection + prompt (the two patterns 90% of calls use)
- Quick examples
- Prompt templates (the high-value content)
- Critical constraints
- Pointers: `references/troubleshooting.md`, `references/internals.md`

`references/internals.md` (loaded only by maintainers or when debugging) — moves:
- Hardening guarantees
- Variant resolution details
- Safe opencode invocation for subagents
- Stall detector internals
- Resolver gotcha
- Module layout
- Parallel dispatches mechanics

`references/troubleshooting.md` (referenced from SKILL.md "If invocation fails, see…") — moves:
- All 9 edge cases
- Common error → fix mappings (incl. the 3 new bugs from this session, post-fix)

**Cross-platform impact:** ✅ POSITIVE. All four invocation platforms benefit because the per-invocation context cost drops. References load on-demand via standard file Read, which every platform supports.

Round-1 reviewer caveat: callers (or future debug scripts) that parse SKILL.md by specific section names or line numbers will break the first time after the split. Mitigation: SKILL.md's "If invocation fails, see…" pointer must be **explicit** (e.g., `For hardening details, see references/internals.md §1. For known errors, see references/troubleshooting.md.`). Add a one-line top-of-file comment to SKILL.md announcing the relocation for the first session after deploy.

### B. Fix `-Diff` flag parameter binding (era.ps1)

**Bug:** `-Diff` passed as a switch parameter returns:
```
Cannot convert value "System.Collections.Hashtable" to type "System.Management.Automation.SwitchParameter".
Boolean parameters accept only Boolean values and numbers
```

**Root cause hypothesis (without era.ps1 source in hand):** likely a `[switch]` parameter that's being passed a hashtable somewhere upstream — perhaps splatting `@PSBoundParameters` from a wrapper without filtering, OR a missing `$` on the param declaration causing PowerShell to interpret `Diff` as a hashtable key.

**Fix:** find the `[switch]$Diff` declaration in era.ps1; check if there's a splat assignment that includes `Diff` as a hashtable key without a value. The typical idiom that breaks this is `$params = @{ ...; Diff }` (intending shorthand for `Diff = $true`) — PowerShell parses the bare `Diff` as a hashtable key with no value, producing a `[System.Collections.Hashtable]` entry.

**Cross-platform impact:** zero (PS-internal bug fix).

### C. Bundle-empty check ordering

**Current behavior:** repomix runs (~3 seconds + bundle file write), then the script checks `<file>` tag count in the XML, then errors out if zero. Wastes the repomix call.

**Fix:** validate every path in `-IncludeFiles` against `Test-Path` BEFORE invoking repomix. Print a precise error naming each missing path. Exit 1 without writing a bundle.

Round-1 reviewer note: `Test-Path` must be evaluated relative to the **repository root** (or wherever era.ps1 decides repomix will run from), not the current working directory of the caller. Mismatch causes false "missing file" errors for legitimate relative paths. Implementation: `Push-Location $repoRoot; Test-Path $f; Pop-Location` (or pass `-LiteralPath` with explicit joins).

**Cross-platform impact:** zero (PS-internal).

### D. PowerShell `-IncludeFiles` comma-string detection

**Current behavior:** `-IncludeFiles "a,b,c"` (quoted) passes a single-element array with one string `"a,b,c"`. repomix treats this as one literal path, finds no match, returns an empty bundle. Error surface is far from the cause.

**Fix:** in era.ps1's `-IncludeFiles` validation step (post-Test-Path, pre-repomix), detect if any element contains a comma. **Fail fast** with the error:

```
ERROR: -IncludeFiles element 'a,b,c' contains a comma. Did you mean to pass
PS-array syntax 'a','b','c' (separate quoted elements) instead of a single
comma-string? If you genuinely need a literal comma in a filename, escape it
with `,` (PS-grave-comma escape).
```

Round-1 reviewer note: auto-splitting risks masking a real typo where the user intended a single literal-comma path. Fail-fast preserves intent.

**Cross-platform impact:** zero (PS-internal).

### E. Auto-include round-(N-1) response in round-N prompt

**Current behavior:** for round N>1, the author must manually summarize the previous response (e.g. "## Round-1 → Round-2 changes summary") in the prompt or trust the model to find it in the bundle. The reviewer model is given the spec but not the previous review's output unless it's manually attached.

**Fix:** introduce a `{{PREVIOUS_ROUND}}` template token. Callers writing round-N prompts include the token where they want the previous review inserted:

```markdown
# Round 3 review

Round 2 found these issues:

{{PREVIOUS_ROUND}}

Confirm fixes or flag remaining gaps.
```

`workflow.ps1` substitutes the token with the contents of `round-(N-1)-response.md` at dispatch time. If the token is absent from the prompt, no auto-include happens — caller is presumed to have intentionally omitted it (e.g., they already manually summarized).

Round-1 reviewer note: this is more robust than a fenced-section auto-detection heuristic. Explicit placement, no false-positives, easy to opt-out.

Edge case (parallel dispatch — round N-1 in flight when round N's prompt is built): if `round-(N-1)-response.md` doesn't exist yet but `round-(N-1)-claim.json` does, substitute the token with the literal string `[Round N-1 is in flight; not yet available]`. No JSON manifest dump — low value, adds noise.

**Cross-platform impact:** zero (filesystem-only operation; works the same regardless of invoker).

### F. `--auto-detect` for IncludeFiles (optional, scoped)

**Current behavior:** caller enumerates every file path. For LLM agents this is fine because we already know what files were touched. For human callers it's tedious.

**Fix:** add an OPTIONAL `-AutoDetect` flag that runs `git status --porcelain` (uncommitted) + `git diff --name-only HEAD~1..HEAD` (most-recent commit only) to derive candidate files. Print the candidate list and prompt for confirmation (or `-Force` to skip). Doesn't replace `-IncludeFiles`; complements it for the human-driven case.

Round-1 reviewer notes incorporated: (a) narrowed window from `HEAD~5..HEAD` to `HEAD~1..HEAD` — five commits is too wide and pulls in unrelated work; the typical use case is "review what I just touched." (b) explicit error if `git` isn't on PATH or current directory isn't a git work tree: `"AutoDetect requires git; pass -IncludeFiles explicitly."` Off by default; opt-in.

**Cross-platform impact:** ✅ NEUTRAL. Git is the cross-platform inference primitive — works the same everywhere. **Does not require the calling LLM to have introspection on "files I touched this session"** (which would not be portable across Claude Code / Copilot / Codex). LLM agents continue to use `-IncludeFiles` explicitly; humans get `-AutoDetect`.

### G. Spec-review preset

**Current behavior:** the spec-review prompt template lives in SKILL.md and the author copies/edits it manually. For the project-b review I wrote ~1,000 tokens of prompt from scratch even though the template is right there.

**Fix:** add `-SpecReview <spec_path>` flag that:
- Auto-fills the spec-review template
- Adds `-IncludeFiles` to include the spec automatically
- Optionally extracts `Related:` / `Source spec:` lines from the spec's frontmatter to auto-include related files

```pwsh
# This single command should do what 14 explicit -IncludeFiles entries did:
pwsh era.ps1 -SpecReview docs/superpowers/specs/2026-05-28-project-b-design.md -Reviewer gemini -Model 'gemini 3.1 pro'
```

Edge cases (round-1 reviewer):
- **No frontmatter-related-files found:** include the spec file ONLY. Don't error; many specs are self-contained.
- **`-SpecReview` + `-PromptOverrideFile` both passed:** mutually exclusive. Throw a clear error: `"-SpecReview and -PromptOverrideFile are mutually exclusive (SpecReview generates the prompt from a template; PromptOverrideFile uses your prompt verbatim). Pick one."` Don't silently override either.
- **`-SpecReview` + `-IncludeFiles` both passed:** additive (spec + auto-detected related + your extras). Useful for "spec plus this one extra reference file" cases.

**Cross-platform impact:** zero (PS-internal feature).

## 5. Implementation plan

**PR layout (each independently shippable):**

| PR | Scope | Risk | Value |
|---|---|---|---|
| PR 1 | Doc split (A) | Low — content-only move | High — every future invocation saves ~4k tokens |
| PR 2 | Bug fixes (B + C + D) | Low — isolated to era.ps1 input validation | High — unblocks `-Diff` and prevents silent comma-string failures |
| PR 3 | Round-(N-1) auto-include (E) | Medium — touches workflow.ps1 reservation | High — eliminates the "summarize previous round" boilerplate |
| PR 4 | `-AutoDetect` flag (F) | Low — additive, opt-in | Medium — human callers benefit; LLM callers unaffected |
| PR 5 | `-SpecReview` preset (G) | Low — additive | High — most common workflow becomes one command |

**Suggested order:** PR 1 first (largest user-facing impact, lowest risk). PR 2 immediately after (unblocks real bugs). PR 3-5 in any order.

## 6. Backwards compatibility

- PR 1 doc split: existing references in conversations / tests to "the SKILL.md prerequisites section" remain valid because the section stays in SKILL.md. References to "edge case #7" become "see references/troubleshooting.md edge case #7" — needs one-time update to any callers that cite line numbers.
- PR 2 bug fixes: `-Diff` flag worked before? No, it was already broken. Fix is pure improvement. The comma-string detection is additive (warn + auto-split, never break a previously-working invocation).
- PR 3 auto-include: opt-in by design (the `{{PREVIOUS_ROUND}}` token must be explicitly placed in the prompt — see §4.E). Legacy prompts written before this PR contain no token, so auto-include never fires — zero duplication risk. No fence-detection heuristic needed.
- PR 4 `-AutoDetect`: opt-in, no behavior change unless flag passed.
- PR 5 `-SpecReview`: opt-in.

## 7. Cross-platform guarantee restatement

Every proposal above either (a) operates inside era.ps1 itself (PS-only, no platform implications), (b) operates on the filesystem (`references/` files, `round-N-*` artifacts — all platforms read files the same way), or (c) uses git as inference (universal across the four supported invocation platforms).

**No proposal requires the calling LLM or its host platform to expose specific introspection capabilities** beyond what's already required to write a prompt and invoke a subprocess. The skill remains agnostic to caller.

## 8. Acceptance criteria

- [ ] SKILL.md is ≤2,000 tokens (current ~6,000)
- [ ] All 9 edge cases from current SKILL.md remain findable (in `references/troubleshooting.md`) and the SKILL.md entry-point text points there explicitly
- [ ] `-Diff` flag invocation succeeds for at least one round-2 dispatch test case (no SwitchParameter error)
- [ ] `-IncludeFiles "a,b,c"` (quoted string) either auto-splits or errors with a helpful message naming the issue — never silently produces an empty bundle
- [ ] Round-2+ dispatches automatically include round-(N-1) response in the prompt, demonstrated by a smoke test
- [ ] `-SpecReview docs/spec.md -Reviewer gemini` works end-to-end without requiring `-IncludeFiles` or `-PromptOverrideFile`
- [ ] Both /era reviews in the next session (any topic) complete first-try without dispatch retries

## 9. Open questions

1. **Should we move the prompt templates into `references/templates/spec-review.md` and `references/templates/assessment.md`** and have the `-SpecReview` flag read them? This decouples template-editing from SKILL.md edits. Probably yes, but adds one PR.

2. **For PR 3 (auto-include round-(N-1)),** should the previous round's response be in the prompt text or as a separate bundle file? Prompt-text is simpler; separate file is more visible to the reviewer model. Author's lean: prompt-text with fence.

3. **PR 1 doc split** — should `references/internals.md` be loaded automatically when era.ps1 itself errors? E.g., on a non-zero exit, print the error AND emit "See ~/.claude/skills/external-review-auto/references/troubleshooting.md for diagnosis steps." This makes the troubleshooting reference self-pointing.

4. **Adoption path for existing invocations.** This skill lives at `~/.claude/skills/`, outside the trading repo. Changes don't affect the repo itself. But the skill is presumably used across multiple projects. Should we version the skill (`v2` directory, opt-in migration), or just edit in place? Author's lean: in-place edit; the changes are all backwards-compatible per §6.
