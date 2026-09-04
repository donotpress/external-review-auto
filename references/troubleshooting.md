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
12. **agy returns a planner preamble instead of a review:** The default prompt templates include a guard phrase scoping the model to the bundle. **The guard must say "outside the bundle".** agy's delivery mode is `disk-read` — the adapter passes a PATH in argv and nothing else, so the model only ever sees the bundle by opening it. A blanket "do not open, read, fetch, list, or run anything" forbids that. The adapter's own internal prompt said exactly that until 2026-09-02; the model disobeyed it (which is the only reason the seat ever worked) — see `docs/assessments/2026-09-02-agy-disk-read-contradiction.md`. If you're writing a custom override prompt, open with: *"All source files are fully included in the bundle. Review ONLY what is in the bundle. Do NOT attempt to open, view, fetch, or read any file outside the bundle."* **And do not write "the *attached* bundle":** nothing is attached for `agy` (`disk-read`) or for opencode above 51,200 bytes (`read-tool`) — three of the four default seats. The templates said "attached" until 2026-09-02, which is the same falsehood as the adapter prompt above, one layer out; the clause that does the work is "outside the bundle", not the word "attached". Raised by the opus seat of the panel on the fix. See section "agy returns a ~120-char planner preamble" below.
13. **HTTP preset (`*-http` / `nvidia`) fails with a key error (v1.8):** these presets read `OPENCODE_API_KEY` / `NVIDIA_API_KEY` from the env, falling back to opencode's `auth.json` (`~/.local/share/opencode/auth.json`, `type:api` entries). If you get a key error, confirm that file has a `type:api` `key` for the matching provider (`opencode-go`/`nvidia`), or set the env var directly. A `401` from `opencode.ai/zen/go` usually means the opencode-go subscription has no balance for that model.
14. **A driving tool's timeout fires before `era` finishes (measured 2026-09-02):** era scales its own `TimeoutSec` to the bundle at 20 ms/token — 600 s floor, **1800 s ceiling, reached at 90,000 tokens** — plus 300 s of straggler grace for the last seat. Every driving tool waits less than that. **The fix is to dispatch in the background, not to raise the timeout** -- but it has to be the RIGHT background, and the difference is what killed `direction-paths-2026-09-04` round 1. The timeout cannot be raised far enough either way: on Claude Code the Bash foreground wait is capped at **600 s**, and `timeout: 1800000` is accepted and silently clamped.

    | launch shape | survives the tool call ending? |
    |---|---|
    | harness `run_in_background: true` | **yes** -- the harness owns it and reports completion |
    | foreground call that overruns its timeout | **yes** on Claude Code -- measured 2026-09-02, the child is moved to the background and runs to completion, not SIGTERMed |
    | `nohup ... &` inside a foreground call | **NO** -- still in the call's process group, reaped with it |
    | `setsid ...` | yes -- new session, outside the group that gets reaped |

    `nohup` guards against SIGHUP, which is not what happens here: the tool call's whole process GROUP is reaped, and `nohup` does not leave the group. That is how `direction-paths-2026-09-04` round 1 died ~60 s in, with three seats still running and nothing in the log to say so.

    **A timeout message is not evidence the round died.** Measured on Claude Code, twice, with a `pwsh` child stood in for the dispatch: at the 120 s default a 200 s child was **moved to the background and ran to completion** (`RC=0`), and under a requested `1800000` the foreground wait ended at 600 s and a 640 s child likewise **completed in the background** (`RC=0`). Neither was `SIGTERM`ed. So the round is probably still running; re-dispatching on the assumption that it died spends it twice.

    **How to tell an aborted round from a finished one:** a finished round has `round-N-metadata.json`. That file is written last, so its absence is the signature — not "`.pid` but no `.md`", which means only that one *seat* did not return while era carried on. Exit 2 means era ran and produced nothing usable; a round that was actually killed produces no exit code at all, and neither case means "no findings were available".

    **An orphaned `round-N-claim.json` does not block anything.** `Reserve-ReviewRound` scans for the highest existing round and takes N+1, so an aborted round just consumes a number. Delete that one file if you want the number back — never `round-*-claim.json` as a glob, which would delete the claim of a round running concurrently and is exactly what the claim mechanism exists to prevent.

    **What is not known.** This entry replaces one that attributed `bulk-refresh-vpn-headless` round 1 to a 120 s kill. Its own artifacts refute that: the round started 03:48:40, `round-1-muse-spark-response.md` was written at +292 s and `round-1-gemini-response.md` at +467 s — both long after a 120 s kill would have landed — and only `round-1-metadata.json` is missing. Round 3 of the same topic then succeeded at 228.5 s wall clock, also past 120 s. What actually aborted rounds 1 and 2 has **not** been established, and is deliberately left unexplained here rather than guessed at.


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

**Fix:** Reword the override so the bundle is explicitly self-contained — *"The spec and all source files are fully included in the bundle. Review ONLY what is in the bundle. Do NOT attempt to open, view, fetch, or read any file outside the bundle."* Asking the model to **reference** `file:line` *in its findings* is fine (citing ≠ opening). See SKILL.md → "Prompt templates → ⚠️ Agentic-backend rule."

**Fallback:** Non-agentic backends are immune (they return one completion regardless). Re-dispatch the same bundle + prompt to `-Reviewer opus` / `sonnet` (Claude CLI), `gemini-api` / `gemini-api-pro` (REST), or `deepseek` / `minimax` (opencode). Note: only `agy` reaches Gemini **3.1 Pro**; the REST path tops out at Gemini 2.5 Pro.

---

### Missing `-IncludeFiles` paths not caught before repomix

**Pre-fix symptom:** Passing a path that doesn't exist (typo, absolute path outside repo root, unexpanded `~`) caused repomix to produce an empty bundle. The error surfaced only after repomix ran (~3s), reading: "Bundle is empty — repomix matched 0 files."

**Post-fix expectation:** era.ps1 validates all `-IncludeFiles` paths using `Test-Path` (relative to `$repoRoot`) BEFORE invoking repomix. Missing paths produce an explicit error naming each missing path. era.ps1 exits without writing a bundle.

---

### Comma-string `-IncludeFiles` produces silent empty bundle

**Pre-fix symptom:** Passing `-IncludeFiles "a,b,c"` (a single quoted string with commas) parsed as a single-element array containing `"a,b,c"`. repomix found no matching path, produced an empty bundle, and the model received "no files to review."

**First fix (PR 2 D):** era.ps1 detected any `-IncludeFiles` element containing a comma and failed fast with an error explaining PS-array syntax. This broke calls from OpenCode's Bash tool on Windows, where `-IncludeFiles "a","b","c"` is flattened to `"a,b,c"` by Windows command-line parsing.

**Current fix:** era.ps1 **auto-splits** comma-containing elements into separate paths transparently. No error, no user-facing change — the array is expanded before repomix runs. A log line is emitted: `[era] -IncludeFiles: expanded N element(s) with embedded commas into M path(s).`

---

### repomix timeout (fixed 2026-08-09 — was a known limitation)

**Previously:** era reported `repomix timed out after 300s`, but a `node`
process kept burning CPU and disk afterwards, and the error explained nothing.

**Cause:** the guard used `Start-ThreadJob` + `Wait-Job -Timeout` + `Stop-Job`.
`Stop-Job` ends the *thread*; it cannot bound the **native child process**
repomix spawned. The backend adapters never had this problem — they hold a
`Process` handle and call `.Kill($true)`, an invariant
`tests/ProcessTreeKill.Tests.ps1` asserts across agy/claude/opencode. repomix
was the one place that did not, because npm resolves it to a `.ps1` shim that
`CreateProcess` cannot execute.

**Fix:** `Resolve-EraRepomixCommand` picks a spawnable form — it prefers the
sibling `repomix.cmd` (measured: npm installs `repomix`, `repomix.cmd` and
`repomix.ps1` side by side), falling back to `pwsh -File` for a lone `.ps1` and
running a real executable directly. `Invoke-EraTrackedProcess` then runs it with
`-PassThru`, waits with a real timeout, and on expiry calls `.Kill($true)` to
take out the whole tree. Verified by measurement: child count 1 → 0, parent
exited.

**The inert drain is fixed too.** `Receive-Job` could never return anything —
the ThreadJob body captured every byte into a local and emitted nothing until
completion, so a job that had not completed had no output to receive. Output now
goes to redirect files, so partial output is on disk and readable at kill time.
`tests/RepomixProcess.Tests.ps1` asserts this directly: a killed `ping` still
yields its partial output.

Both failure paths also run the capture through `Get-EraTruncatedText`, because
the run that started collecting 72,378 files interpolated a **16.9 MB** log into
its exception string.

**If a timeout still happens:** the tree is killed for you. Read the partial
output in the error, then re-run with `-IncludeFiles` scoped to what you
actually want reviewed. The broad-bundle gate above should stop you reaching
this state at all.

---

### agy settings.json `.era-backup` (deprecated crash-recovery)

**Background:** Earlier versions selected the agy/Gemini model by **swapping** `~/.gemini/antigravity-cli/settings.json` before each dispatch and restoring it after, writing a crash-safe `settings.json.era-backup` first. A SIGKILL/Ctrl-C between swap and restore could leave the user pinned to the wrong interactive model; era.ps1 restored the orphaned backup on its next launch.

**Now:** agy model selection is per-process via the `--model "<settings_value>"` flag (concurrent-safe). `settings.json` is never mutated, no `.era-backup` is ever written, and concurrent `/era` Gemini runs (including Gemini 3.1 Pro) no longer serialize on a global mutex.

**Migration:** The `.era-backup` recovery block in era.ps1 is retained for **one release** purely to restore any backup orphaned by a crash that happened *before* upgrading. It self-deprecates (nothing creates new backups). If you ever find a stale `~/.gemini/antigravity-cli/settings.json.era-backup` after upgrading, you may delete it manually; the next `/era` run will also clean it up.

---

### opencode `model.json` swap + mutex (removed) / `.era-backup`

**Background:** Earlier versions selected the opencode model/variant by **swapping** `~/.local/state/opencode/model.json` (prepend `recent[0]`, set the `variant` map) under a `Global\era-opencode-state-mutex`, writing a `model.json.era-backup` for crash recovery. That serialized concurrent opencode startups and risked restore races.

**Now:** opencode is **stateless** by default. The model is selected with `-m`, the variant with `--variant`, and the bundle is attached with `-f` (at or under 51,200 bytes; above that the model reads it from disk) — probe-verified that `opencode run -m` does not mutate `model.json`. No swap, no mutex, no `.era-backup`; concurrent opencode dispatches run in parallel. The optional `ERA_OPENCODE_VARIANT_STATE=1` insurance writes the variant entry and restores it **byte-identical** under a brief `era-opencode-variant-mutex`.

**Migration:** the `model.json.era-backup` recovery block in era.ps1 is retained for one release to restore a pre-upgrade orphaned backup; delete a stale one manually if you find it.

---

### opencode returned a non-review (tool-intent narration / refusal) — `content_ok=false`

**Symptom:** an opencode dispatch exits 0 but `round-N-metadata.json` shows `content_ok=false`, `error=agentic-narration-capture`, and no `round-N-response.md` is written.

**Cause:** the model emitted a tool-intent narration or a "I can't read the bundle" refusal instead of a review. The shared `Test-AgenticNarrationCapture` detector flags it so it fails honestly rather than being recorded as a successful review.

**Fix:** re-dispatch (the failure is usually transient). The `-f` attach mode used for bundles under 51,200 bytes makes this rare; if it persists, check `opencode` auth/provider for the model.

---

### opencode stalls at limit/popup — dispatch hangs for minutes instead of failing fast

**Symptom:** an opencode dispatch (e.g. `deepseek` or `minimax` reviewer) produces no output for a long time, then eventually fails with a timeout error. The stall snapshot shows zero or near-zero bytes.

**Cause:** the model hit a usage limit (weekly quota, balance exhausted) and the opencode TUI displayed a blocking popup dialog. This popup is rendered via direct console writes (invisible to stdout/stderr capture), so the dispatch waits naively until the global `TimeoutSec` (600–1800s) fires.

**Fix:** the first-token watchdog (Phase 1) now kills the process at the `ERA_OPENCODE_FIRST_TOKEN_SEC` deadline (default 120s, min 10s) if zero output has ever been captured. This catches the popup case at ~120–130s instead of waiting 10–30 minutes. If Phase 1 misses (e.g. the popup produces at least one byte), Phase 2 catches it at the variant-aware stall threshold (120–600s). Set `ERA_OPENCODE_FIRST_TOKEN_SEC` to a lower value (e.g. `60`) to fail faster at the cost of false-positive risk on very slow models.

### `opus`/`sonnet`/`haiku` return nothing, with a BLANK error string (Windows/WSL credential split)

**Symptom.** Every `claude`-backend reviewer fails at once, instantly (`wall_clock_sec = 0`), and the
metadata records `claude CLI failed (exit=1, model=…): ` with **nothing after the colon**. The
interactive Claude Code agent you are running from works fine, so the backend "should" work.

**Cause.** Two things, and the second is why the first stayed hidden for a day (measured 2026-08-04):

1. **Separate credential stores.** `/era` shells out to the **Windows** `claude.exe`, which reads
   `C:\Users\<u>\.claude\.credentials.json`. A `claude` running **inside WSL** reads the Linux home's
   store. They expire **independently**. `opus` went **115/119 lifetime → 0/4 in one day** when the
   Windows refresh token lapsed — 19 minutes after its last success — while the agent, authenticated
   against the WSL store, kept working. ⚠️ **A working agent is no evidence that this backend works.**
2. **The adapter discarded the reason.** The CLI prints fatal causes to **stdout**; the adapter threw
   with `$stderr`, which was empty. The sentence naming the cause
   (`Failed to authenticate: OAuth session expired and could not be refreshed`) sat in the discarded
   buffer. Four sessions read the blank string and concluded the *model* was unreliable.

**Fixed in v1.15.** The error now carries whichever stream spoke, and a credential-shaped failure
retries once via `wsl.exe -e <linux claude>` (recorded in `warnings`). If you see the fallback
warning, `/era` is working but the **Windows** CLI still needs `claude` run interactively and logged
in — anything else shelling out to `claude.exe` remains broken.

**Diagnosing it yourself:**
```powershell
claude.exe --print --model claude-opus-5 "Reply with: PONG"   # exit 1 + the real reason on stdout
python -c "import json;print(json.load(open(r'C:\Users\<u>\.claude\.credentials.json'))['claudeAiOauth'])"
```
An `accessToken` of **0 characters** or a past `refreshTokenExpiresAt` confirms it.

⛔ **Not the cause, though it looks like one:** `hasTrustDialogAccepted: false` in `~/.claude.json`.
One failure did print `Ignoring 1 permissions.allow entry … this workspace has not been trusted`, but
that message says it is *ignoring* an entry, not aborting — and the flag was already `false` across
all 115 successes. A dispatch later succeeded with it still `false`. It is a co-occurring warning.

---

## "Refusing this round: N of M requested reviewer(s) cannot receive a …-byte bundle" (exit 1)

**Cause:** the bundle is larger than a selected reviewer's delivery channel can carry.
Each backend receives the bundle differently and each way has a different ceiling — see
SKILL.md → *Bundle delivery limits*. The message names every doomed seat, its channel,
its limit and where that limit comes from.

**This is a preflight refusal, not a failed round.** Exit **1** means nothing was
dispatched and nothing was spent; re-running after curating is free. (Exit **2** is a
void round that already cost money — never conflate them.)

**Fix, in order of preference:**
1. **Curate** — `-IncludeFiles` down to what the review actually needs. Bundle size is
   almost always dominated by one or two large files; check `round-N-manifest.json`.
2. **Drop the seat** — `-Reviewer` without the reviewer that cannot carry it. `agy`
   (`gemini`) reads from disk and has no channel limit, so it always survives.
3. **Force it** — `-ForceBundleSize` (or `ERA_BUNDLE_FORCE=1`) dispatches anyway and
   warns per seat. Note `-Force` does **not** do this; it only skips the cost prompt.

---

## `claude` returns "Prompt is too long"

**Cause:** the `claude` adapter pipes the bundle into `claude --print` as the prompt, so
the bundle must fit the CLI's context window. That window is **appreciably smaller than
the model's 1M API window** — measured 2026-08-31, the CLI accepted 600,000 repomix
tokens and rejected 630,000.

**Fix:** curate below ~550,000 tokens (era's ceiling, which leaves headroom for the
CLI's own system prompt). The preflight now catches this before dispatch, so seeing this
message from a normal round means the ceiling needs re-measuring — likely after a CLI
upgrade.

**Re-measuring after a CLI upgrade:** bisect with a **tail canary**. Pipe slices of a
real bundle to `claude --print`, each with a unique marker appended at the very end, and
ask only for the marker back. Echoing it proves the *tail* reached the model; a bare
"OK" only proves the request was accepted, and `--autocompact` defaults to on. Rejection
happens *before* inference (~6 s, unbilled), so only the first accepted probe costs
anything. Update `max_bundle_tokens` in `backends/_registry.json`.

---

## An opencode seat stalls on a bundle over 50 KiB

**First: the forensics used to lie.** Before 2026-08-31 every artifact under
`%TEMP%\opencode-stall-debug` was 0 bytes even when the process was producing output —
the snapshot read the capture files without flushing their write buffers, and
`FileStream.Length` counts buffered bytes the file does not yet have. If you are looking
at an artifact older than that fix, **its emptiness is not evidence.** New artifacts are
real.

**What the path does:** above 51,200 bytes the model reads the bundle from disk with its
own Read tool, because attaching truncates silently at exactly 50 KiB. Verified with
canaries at 25/50/75% depth: both default opencode seats covered 109,066 / 314,720 /
668,389-byte bundles in full (57 s / 85 s / 256 s).

**It is nevertheless intermittent, and the cause is not known.** The same seat lost
rounds at 74,740 and 79,294 bytes — sizes the probes clear comfortably — so it is
neither size nor model. Concurrency was the leading hypothesis; it was tested on
2026-08-31 (10 trials under a live `opencode serve` plus 22 external `opencode run`
contenders vs 10 with none) and produced **0 stalls in both arms**, so it is now the
least-supported explanation rather than the first thing to check.

**Fix:** re-dispatch — the failures observed so far have not recurred on a retry. If it persists, capture
the (now real) stall artifact and check whether the model is chunk-reading or wandering
into unrelated shell commands. `ERA_OPENCODE_READ_TOOL=0` forces attach as a diagnostic
— you will get a review of the first 50 KiB, and it warns.

---

## "PermissionError: Permission denied while scanning directory" (exit 1)

**Cause:** repomix aborts the **entire run** when it cannot read one directory.
The usual culprit is a live application holding its own data directory — a running
headful Chrome or puppeteer profile, e.g.
`scripts/puppeteer_user_data/headful/CertificateRevocation/<n>`.

**A `.repomixignore` in the reviewed repo CANNOT fix this.** repomix hands that
file to globby as an `ignoreFile` (`'**/.repomixignore'`, `fileSearch.js`
`getIgnoreFilePatterns` — verified in 1.12.0), and globby has to **glob for the
file before it can read it**, so it walks the locked directory while searching for
the very file that would have excluded it. Only globby's `ignore` option — era's
`customPatterns`, filled from `Get-EraVendorIgnorePatterns` — prunes traversal.
A repo that added `.repomixignore` for this crashed identically on the next round.

**Narrowing `-IncludeFiles` does not help either:** the full-tree walk happens
regardless, hunting for ignore files.

**Fix:** the common browser-profile directories are already pruned
(`**/puppeteer_user_data/**`, `**/chrome_user_data/**`, `**/chrome-profile/**`).
For anything else, add the pattern to `Get-EraVendorIgnorePatterns` in
`workflow.ps1`. The quickest unblock is to close the application holding the
directory and re-run — exit 1 means nothing was dispatched and nothing was spent.

These patterns are also a **privacy control**: a live browser profile holds session
cookies and auth tokens, and era uploads the bundle to a third party.

---

## "NOTE: <reviewer> cited BUNDLE line numbers rather than the file's own"

**Not a fabrication, and era translates it for you.** A repomix bundle prints each
file's OWN line number on every content line (`  471: $x = 1`), and that is what
era checks citations against. But a seat on the **read-tool** delivery path does
not read the bundle through era — it opens the file with its own Read tool, and
that tool counts lines from the top of the whole bundle. A model that cites what
its tool told it names the right file and a line number that does not exist in it.

Measured across 62 archived seat-responses (25 rounds): **128 of 155 citations past end-of-file
(83%) were this**, not invention — out of 1,570 checked. A further 203 (12.9%)
sit where the two frames OVERLAP and cannot be told apart — though only ~40 of
those are in responses that use the bundle frame anywhere else, so the real
exposure is nearer 2.5%. One of them, reported as fabricated, was
`runtimes/resolve-model.ps1:1780` — bundle line 1780 is in-file line 169, which is
exactly the line that finding was about.

era now prints the translation (`opencode.ps1:3156 -> opencode.ps1:471`), so the
pointer is usable. The read-tool prompt also tells the model which numbering to
cite, so this should get rarer.

---

## "WARNING: <reviewer> cited line numbers that do not exist in the bundled files, in either coordinate frame"

**Cause:** the reviewer invented `file:line` references. Measured on one model
across two separate rounds: lines 5891, 5360 and 3612 cited in a 2,834-line file.

era reads the line count of every file in the bundle and checks each citation
against it. Only citations whose file is unambiguously in the bundle are checked;
a basename that appears at more than one path is skipped rather than guessed.

**This does not fail the round, deliberately.** In the observed cases the prose
findings were often correct and twice genuinely novel — it is the line numbers,
not the reasoning, that are unreliable. Read the finding, then locate it yourself
rather than trusting the citation. If a model does this consistently, that is a
reason to weight its findings differently, not to drop the seat.

---

## A reviewer failed with `agentic-narration-capture`

That one error code covers **three** different faults, and the round summary now
names which fired:

| Branch | What happened | What to do |
|---|---|---|
| `bundle-access-refusal` | The model says it could not **see** the bundle | Look at delivery (the `via=` field), not the prompt. Re-dispatching buys the same refusal. |
| `sub-floor-non-answer` | The model answered, but too briefly and with no heading or list to be accepted | **Often not narration at all** — read the response before assuming the model misbehaved. Measured: a correct 280-character answer was rejected while 301- and 324-character answers of near-identical content passed. |
| `tool-intent-narration` | The model narrated tool use instead of reviewing | Re-dispatch usually fixes it. |

Before this split, all three reported the same generic message listing all three
possibilities, so a `sub-floor` rejection on a strong reviewer read as "the model
misbehaved" when it had in fact answered correctly and briefly.

---

## "WARNING: model hint '<x>' matches N claude/opencode models" / "[agy] WARNING: model hint '<x>' matches N models at the same tier"

**Cause:** `-Model` and `-AgyModel` hints are resolved by an exact pass first and a **substring**
pass second, and the substring matcher is `a.Contains(b) -or b.Contains(a)`. A
short hint can therefore match more than one family — against the shipped
registry, `o` and `s` each match both `sonnet` and `opus`, and `u` matches both
`opus` and `haiku`.

era picks the alphabetically-first match, tells you on **stderr** which models
matched and which it took, and carries on. It used to pick whichever the
hashtable happened to enumerate first, which varied **between processes** — so the
same hint could resolve to a different model run to run, and you were billed for a
model you had not asked for.

**Fix:** give a more specific hint (`opus`, `sonnet 4.6`, `gemini 3.1 pro low`).
Exact hints never reach the substring pass and are unaffected.

**The same warning now comes from three other places**, because this one rule had
four implementations and only the claude branch had it. Measured against the
shipped registry: `deepseek` matches two opencode models, `minimax` eight, `flash`
fourteen; and `-AgyModel gemini` used to return **three different models across
five processes** because `backends/agy.ps1` named its match accumulator `$matches`,
which is an automatic variable PowerShell overwrites on every `-match`. All four
now sort, tie-break the same way, and say when a hint was ambiguous.

---

## "opencode: this seat's Ns budget was spent waiting for the run lock" (nothing spent)

**Cause:** era's opencode seats are serialised behind one global mutex, because
opencode keeps a single SQLite database and two concurrent `opencode run`
processes fail with `database is locked`. The **default panel has two opencode
seats**, so the second one queues behind the first. Since v2.8 that wait is
bounded by the seat's own budget (the dispatcher waits `TimeoutSec + 30` and then
tree-kills the seat, so time spent queueing is time the run does not get), and a
seat that reaches the front with too little budget left refuses instead of
starting a run that would be killed before it finished.

Before v2.8 the wait was a fixed 900s against a 600s default budget, and the
adapter's own deadline started *after* it — so a queued seat believed it had a
further full budget and was recorded as a plain "Timed out (global)".

**Fix:** raise the reviewer timeout, or run fewer opencode seats in one panel
(`-Reviewer gemini,opus,deepseek-flash` drops to one). Nothing was spent.

---

## "registry max_bundle_tokens is ignored for opencode … delivery"

**Cause:** an override only binds where the channel is bounded in that unit.
opencode's channel is bounded in **bytes** (it truncates an attached file at
51,200 and reads larger ones from disk), and no opencode adapter reads a token
ceiling at all — so enforcing one in the plan refused rounds the adapter would
have delivered, which is the expensive direction. Use `max_bundle_bytes` for
opencode. `max_bundle_tokens` still binds on `claude`, where the CLI itself
rejects on tokens.

The same rule already applied to `max_bundle_bytes` on opencode's **attach** mode:
51,200 is where the transport truncates, not a preset tunable.

---

## Invoking era from WSL: two silent footguns

`/era` **always runs on Windows PowerShell**, whichever shell you launch it from —
the `pwsh` on a WSL PATH is a shim that `exec`s `pwsh.exe`, and every run reports
`Win32NT`. That is by design and not worth changing: of the four backends, `agy`
and `repomix` have no Linux install at all, and `claude` and `opencode` keep
*separate* credential stores per platform which expire independently (see the
`claude` WSL credential fallback above — a measured incident took `opus` from
115/119 lifetime to 0/4 in a day on an expired Windows token while the WSL agent
kept working).

What that does mean is that a WSL front door crosses a process boundary, and two
things silently fall through it.

**1. `ERA_*` environment variables do not cross.** WSL forwards only what is named
in `WSLENV`, which does not include them. So this looks right and does nothing:

```bash
ERA_OPENCODE_READ_TOOL=1 pwsh <skill>/runtimes/era.ps1 ...   # variable never arrives
```

era takes its default path and nothing reports the discrepancy. Set the variable
**inside** the PowerShell command instead:

```bash
pwsh -Command "\$env:ERA_OPENCODE_READ_TOOL='1'; & '<skill>/runtimes/era.ps1' ..."
```

**2. `pwsh -Command "& script.ps1"` collapses the exit code.** A script that calls
`exit 2` returns **1** through `-Command`, and `pwsh -File` returns 2. era's whole
outcome contract rests on telling those apart — exit 1 spent nothing and re-running
is free, exit 2 already cost money — so the `-Command` form silently destroys the
distinction. Measured:

| invocation | `exit 2` becomes |
|---|---|
| `pwsh -Command "& script.ps1"` | **1** |
| `pwsh -File script.ps1` | 2 |
| `pwsh script.ps1` (implicit `-File`) | 2 |

The documented dispatch line already uses the safe form. Use `pwsh <path>` or
`pwsh -File`, never `-Command "& ..."`.

**A related trap inside PowerShell itself:** `Set-Location` does not change
`[Environment]::CurrentDirectory`, so `Test-Path` (PowerShell-aware) can succeed on
a relative path while `[System.IO.File]::ReadLines()` on the same path throws
FileNotFound. Always resolve to an absolute path before handing one to a .NET API.
That defect shipped once here, in citation grounding, where it made the check
silently do nothing.
