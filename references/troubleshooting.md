# /era Skill — Troubleshooting Reference

> **Usage:** This file is the authoritative guide for diagnosing /era dispatch failures. `SKILL.md` points here whenever an invocation fails.

---

## Edge cases

1. **`/era` alias not working in Claude Code:** Install the wrapper at `~/.claude/skills/era/SKILL.md`. Type `/era` instead of `/external-review-auto`.
2. **No spec exists, no slug passed:** The LLM should ask the user for a slug and which files to bundle, then invoke era.ps1 with `-TopicSlug` and `-IncludeFiles`.
3. **Repomix not installed:** `npm install -g repomix`. era.ps1 fails with a clear message.
4. **Backend CLI not installed:** era.ps1 checks PATH and fails fast: "Backend CLI 'X' is not on PATH."
5. **ThreadJob module missing:** era.ps1 detects and tells the user: `Install-Module -Name ThreadJob -Force -Scope CurrentUser`.
6. **Estimated cost exceeds caps:** era.ps1 prompts for confirmation when the estimated dispatch cost exceeds the individual reviewer cap or the aggregate run cap (dollar-based, not token-based). Use `-Force` to skip.
7. **Orphaned claim file:** If a process was killed mid-run, `round-N-claim.json` is left behind and causes the next dispatch to skip that round number. Manual cleanup: `Remove-Item .external-reviews/<topic>/round-*-claim.json`.
8. **`.external-reviews/` first time in repo:** Suggest adding to `.gitignore`.
9. **Empty bundle (zero files matched):** era.ps1 aborts before dispatch with a clear message naming the `-IncludeFiles` paths that didn't match. repomix only includes files inside the repo root — absolute paths outside the repo, unexpanded tilde paths, or typo'd globs all silently produce a bundle with no `<file>` content, which the model would then "review" as "no files to review". The check counts `<file ... >` tags in the bundle XML; if zero, dispatch is skipped.
10. **Auto-detected spec path is wrong for your repo:** The default spec glob `docs/superpowers/specs/*-design.md` only matches the superpowers project layout. Set `$env:ERA_SPEC_GLOB` to your repo's convention (e.g. `'docs/**/*-design.md'` or `'specs/**/*.md'`).
11. **Default bundle globs don't include your language:** The out-of-box default covers ~40 extensions (`.py`, `.ts`, `.go`, `.rs`, `.java`, `.c`, `.cpp`, etc.) but may still miss niche ones. Set `$env:ERA_DEFAULT_GLOBS` to a comma-separated list (e.g. `'**/*.nim,**/*.zig,**/*.md'`). Pass `-IncludeFiles` explicitly for one-off reviews.
12. **agy returns a planner preamble instead of a review:** The default prompt templates now include a guard phrase instructing the model not to open files. If you're writing a custom override prompt, open with: *"All source files are fully included in the attached bundle. Review ONLY what is in the bundle. Do NOT attempt to open, view, fetch, or read any file outside the bundle."* See section "agy returns a ~120-char planner preamble" below.

---

## Known errors (post-fix reference)

### `-Diff` SwitchParameter binding error

**Pre-fix symptom:** Running era.ps1 with `-Diff` produced:
```
Cannot convert value "System.Collections.Hashtable" to type "System.Management.Automation.SwitchParameter".
Boolean parameters accept only Boolean values and numbers
```

**Root cause:** A splat `@params` that included `Diff` as a bare hashtable key without `= $true`, causing PowerShell to interpret it as a `[System.Collections.Hashtable]` value.

**Post-fix expectation:** `-Diff` works as a normal switch; no type-conversion error. The round-2 follow-up diff workflow runs cleanly.

---

### agy returns a ~120-char planner preamble instead of a review (override prompts)

**Symptom:** An `agy` (Gemini) dispatch runs the full ~300s wall-clock, exits 0, but `round-N-response.md` contains a single line like `"I will view <file> from line X to Y to check…"` — often naming a file **not in the bundle**. `round-N-metadata.json` shows `response_chars` ≈ 110–130, `est_output_tokens` ≈ 30. Reproducible across retries; killing stray agy processes does **not** fix it.

**Root cause:** `agy` is an **agentic planner**, and the response is captured from its transcript's first `PLANNER_RESPONSE`. When a `-PromptOverrideFile` prompt instructs the model to *"read the bundled source files," "cite the file/function you read,"* or *"view"* anything, agy plans a tool call to open files instead of reviewing the attached bundle — and the capture grabs that planner preamble. The default `-SpecReview` template avoids this; only hand-written override prompts trigger it. **Not** concurrency, **not** the capture loop.

**Fix:** Reword the override so the bundle is explicitly self-contained — *"The spec and all source files are fully included in the attached bundle. Review ONLY what is in the bundle. Do NOT attempt to open, view, fetch, or read any file outside the bundle."* Asking the model to **reference** `file:line` *in its findings* is fine (citing ≠ opening). See SKILL.md → "Prompt templates → ⚠️ Agentic-backend rule."

**Fallback:** Non-agentic backends are immune (they return one completion regardless). Re-dispatch the same bundle + prompt to `-Reviewer opus` / `sonnet` (Claude CLI), `gemini-api` / `gemini-api-pro` (REST), or `deepseek` / `minimax` (opencode). Note: only `agy` reaches Gemini **3.1 Pro**; the REST path tops out at Gemini 2.5 Pro.

---

### Missing `-IncludeFiles` paths not caught before repomix

**Pre-fix symptom:** Passing a path that doesn't exist (typo, absolute path outside repo root, unexpanded `~`) caused repomix to produce an empty bundle. The error surfaced only after repomix ran (~3s), reading: "Bundle is empty — repomix matched 0 files."

**Post-fix expectation:** era.ps1 validates all `-IncludeFiles` paths using `Test-Path` (relative to `$repoRoot`) BEFORE invoking repomix. Missing paths produce an explicit error naming each missing path. era.ps1 exits without writing a bundle.

---

### Comma-string `-IncludeFiles` produces silent empty bundle

**Pre-fix symptom:** Passing `-IncludeFiles "a,b,c"` (a single quoted string with commas) parsed as a single-element array containing `"a,b,c"`. repomix found no matching path, produced an empty bundle, and the model received "no files to review."

**Post-fix expectation:** era.ps1 detects any `-IncludeFiles` element that contains a comma and fails fast with a clear error:
```
ERROR: -IncludeFiles element(s) contain a comma: a,b,c
Did you mean PS-array syntax 'a','b','c' (separate quoted elements) instead
of a single comma-string 'a,b,c'? If you genuinely need a literal comma in a
filename, escape with `, (PS grave-comma escape).
```

---

### agy settings.json `.era-backup` (deprecated crash-recovery)

**Background:** Earlier versions selected the agy/Gemini model by **swapping** `~/.gemini/antigravity-cli/settings.json` before each dispatch and restoring it after, writing a crash-safe `settings.json.era-backup` first. A SIGKILL/Ctrl-C between swap and restore could leave the user pinned to the wrong interactive model; era.ps1 restored the orphaned backup on its next launch.

**Now:** agy model selection is per-process via the `--model "<settings_value>"` flag (concurrent-safe). `settings.json` is never mutated, no `.era-backup` is ever written, and concurrent `/era` Gemini runs (including Gemini 3.1 Pro) no longer serialize on a global mutex.

**Migration:** The `.era-backup` recovery block in era.ps1 is retained for **one release** purely to restore any backup orphaned by a crash that happened *before* upgrading. It self-deprecates (nothing creates new backups). If you ever find a stale `~/.gemini/antigravity-cli/settings.json.era-backup` after upgrading, you may delete it manually; the next `/era` run will also clean it up.

---

### opencode `model.json` swap + mutex (removed) / `.era-backup`

**Background:** Earlier versions selected the opencode model/variant by **swapping** `~/.local/state/opencode/model.json` (prepend `recent[0]`, set the `variant` map) under a `Global\era-opencode-state-mutex`, writing a `model.json.era-backup` for crash recovery. That serialized concurrent opencode startups and risked restore races.

**Now:** opencode is **stateless** by default. The model is selected with `-m`, the variant with `--variant`, and the bundle is attached with `-f` — probe-verified that `opencode run -m` does not mutate `model.json`. No swap, no mutex, no `.era-backup`; concurrent opencode dispatches run in parallel. The optional `ERA_OPENCODE_VARIANT_STATE=1` insurance writes the variant entry and restores it **byte-identical** under a brief `era-opencode-variant-mutex`.

**Migration:** the `model.json.era-backup` recovery block in era.ps1 is retained for one release to restore a pre-upgrade orphaned backup; delete a stale one manually if you find it.

---

### opencode returned a non-review (tool-intent narration / refusal) — `content_ok=false`

**Symptom:** an opencode dispatch exits 0 but `round-N-metadata.json` shows `content_ok=false`, `error=agentic-narration-capture`, and no `round-N-response.md` is written.

**Cause:** the model emitted a tool-intent narration or a "I can't read the bundle" refusal instead of a review. The shared `Test-AgenticNarrationCapture` detector flags it so it fails honestly rather than being recorded as a successful review.

**Fix:** re-dispatch (the failure is usually transient). The default `-f` attach mode makes this rare; if it persists, check `opencode` auth/provider for the model.
