# /era Skill — Internals Reference

> **Who is this for?** Maintainers, contributors, and anyone debugging the skill's dispatch layer. LLM callers invoking `/external-review-auto` do not need this file — `SKILL.md` has everything needed to run a review.

---

## Hardening guarantees (CLI adapters)

All three CLI adapters (`agy.ps1`, `claude.ps1`, `opencode.ps1`) implement the same defensive pattern:

1. **Private hidden console** via `ProcessStartInfo.CreateNoWindow=$true` — child's TTY state can't escape into the parent terminal (prevents TUI mouse-tracking sequences leaking as keystrokes).
2. **Env-var scrub** of `CLAUDECODE`, `AI_AGENT`, `CLAUDE_CODE_*`, `ANTIGRAVITY_*`, `OPENCODE_YOLO` from the child's env block — avoids fast-exit by CLIs' built-in recursion guards when invoked from inside another agent.
3. **try/catch in workflow.ps1's ThreadJob** — adapter exceptions become structured error results, not silently-zeroed metadata.
4. **Agy-specific:** Run-ID-correlated transcript capture. Each dispatch prepends a
   `[Run ID: <guid>]` to the prompt; agy echoes it into the transcript's USER entry.
   `Get-AgyTranscriptResponse` scans the combined new + pre-existing session
   transcripts (**`transcript_full.jsonl` only** — `transcript.jsonl` is
   token-truncated and would silently lose long reviews) for the GUID and returns
   the first `PLANNER_RESPONSE` after it. This is concurrent-safe: a sibling
   dispatch sharing the same bundle path can't win, because the GUID is unique. A
   legacy new-session-dir / temporal-floor heuristic remains only as a fallback for
   callers that pass neither `-DispatchId` nor `-BundlePath`.
   - **Honest capture + self-heal:** a thrown stall/timeout, an empty capture, or a
     `Test-AgenticNarrationCapture` hit (a tool-intent narration or bundle-refusal)
     is treated as a bad attempt and retried once in-adapter; a final bad capture
     returns `ExitCode=-1` / `content_ok=false`, never a silent success.
   - **`--sandbox` is OUT** (live probe, 2026-06-04): `agy --print --sandbox` hangs
     indefinitely. The adapter keeps `--dangerously-skip-permissions` and guards
     agentic-loop captures via prompt-hardening + the detector + retry, NOT `--sandbox`.
5. **Opencode-specific (stateless):** `opencode run -m <id>` selects the model
   directly (probe-verified: it overrides `recent[0]` and does **not** mutate the
   user's `model.json`), and the bundle is **attached via `-f <file>`** rather than
   read by an agentic tool call. So the adapter passes `-m <model> --variant <v>` on
   the CLI and touches no state — no `state.json` swap, no `recent[]` manipulation,
   no startup mutex. Concurrent opencode dispatches run in parallel. The shared
   `Test-AgenticNarrationCapture` detector still backstops any non-review capture.
   - **Opt-in variant insurance:** `ERA_OPENCODE_VARIANT_STATE=1` additionally writes
     the resolved variant into `model.json`'s variant map (in case a provider honors
     the state file over `--variant`), restored **byte-identical** under a brief
     `era-opencode-variant-mutex`. Off by default → fully stateless.

---

## Variant resolution (opencode adapter)

Opencode models can expose reasoning-effort variants (`low`/`medium`/`high`/`max`). The adapter resolves one per invocation from `_registry.json` (populated by `update-models`), picking the highest-effort tier present (`max → high → medium → low`), falling back to `"default"` for models that declare none (e.g. `glm-5.1`).

The resolved variant is **passed via the `--variant` CLI flag** and used to widen the stall threshold for reasoning-heavy variants. It is NOT written to `model.json` by default (the old pre-run swap was removed — see §5 above). Caveat: opencode exposes no reasoning telemetry, so `--variant`'s real effect is unverifiable; the optional `ERA_OPENCODE_VARIANT_STATE=1` insurance also writes the state-file variant entry for belt-and-suspenders.

---

## Safe opencode invocation for subagents and debug

**Never run `& opencode <args>` directly from a PowerShell tool call, subagent, or debug script.** opencode is a Bubble-Tea TUI that writes directly to the console host (`CONOUT$`) — when launched via the call operator, those direct-console writes bypass stdout redirection and inherit the parent terminal. Mouse-tracking sequences (`CSI ?1003h`) get left enabled, and the parent shell starts seeing `CSI [555;col;row;1M` mouse-position reports flooding its prompt. Force-killing such a child (`Stop-Process -Force`) also leaves the terminal in mouse-report mode without cleanup, and subsequent opencode launches may fall back to the interactive model picker because their console state looks borked.

`backends/opencode.ps1` is hardened inline (`ProcessStartInfo` + `CreateNoWindow=$true` gives the child a private hidden conhost). For all other use cases, invoke through:

```ps1
& ~/.claude/skills/external-review-auto/runtimes/safe-opencode.ps1 `
    -OpencodeArgs 'run','-m','opencode-go/glm-5.1','Reply with OK' `
    -TimeoutSec 180 -StallSec 60
```

Returns a `PSCustomObject` with `Stdout`, `Stderr`, `ExitCode`, `WallClockSec`, `OutputBytes`. Includes the same stall detector (kill if no output growth for `$StallSec` seconds) as the adapter. (The adapter is now stateless by default, so there is no state.json mutation/mutex to omit.) Use `-Quiet` to suppress the log lines.

---

## Two-phase watchdog (opencode adapter)

`opencode.ps1` implements two layers of stall protection inside its 10-second polling loop:

**Phase 1 — First-token deadline** (default 120s, minimum 10s):
`$firstTokenDeadline` is a total wall-clock from process start. `$hasSeenOutput` flips to `$true` on the first byte of captured output. If zero output has ever been seen when the deadline elapses, the process tree is killed (`Kill($true)`) and the dispatch throws `"opencode: no response within ${N}s — possible limit/popup block"`. This catches blocking TUI popups (e.g. usage limit dialogs) that produce no stdout/stderr. Configurable via `ERA_OPENCODE_FIRST_TOKEN_SEC` (positive integer ≥ 10; values 1–9 clamp to 10s; non-integer/empty/negative fall back to 120s).

**Phase 2 — Post-first-output stall detector** (existing, unchanged):
After the first byte is seen (`$hasSeenOutput=$true`), Phase 1 is permanently disabled and Phase 2 takes over. Polls every 10s; kills if no output growth for the variant-aware threshold — `120s` (default), `300s` (`high`), `600s` (`max`), each widened by a bundle-size overlay (~20ms/token). The widened thresholds stop a reasoning-heavy variant that thinks silently for minutes from being killed prematurely. On kill, a forensic snapshot is written to `%TEMP%\opencode-stall-debug\`.

---

## Resolver gotcha (era.ps1 maintainer note)

`era.ps1`'s `param()` block declares `[string]$Provider`. PowerShell parameters are **case-insensitive**, so any local `$provider` (e.g. as a `foreach` iteration variable) is the *same* variable — and `[string]`-typed assignment silently coerces a PSCustomObject to its `.ToString()`. This is why the model-hint resolver iterates `$registry._opencode_model_map.PSObject.Properties` directly and binds the value to `$providerEntry` (not `$provider`). Don't rename `$providerEntry` back to `$provider` without dropping the param type or renaming the param.

---

## Module layout

```
external-review-auto/
├── SKILL.md              ← Entry point for LLMs. Keep small (~2,000 tokens).
├── references/
│   ├── internals.md      ← This file. Hardening details, maintainer notes.
│   └── troubleshooting.md ← Edge cases and known errors with fixes.
├── runtimes/
│   ├── era.ps1           ← Single entry point (all CLI flags)
│   ├── update-models.ps1 ← opencode model registry sync (extracted from era.ps1)
│   └── shell.md          ← Standalone shell install guide
├── workflow.ps1          ← Core functions (round reservation, dispatch, manifests, metadata)
└── backends/
    ├── agy.ps1                 ← agy CLI adapter (Run-ID transcript capture + retry)
    ├── claude.ps1              ← Claude CLI adapter (stdin pipe → stdout)
    ├── opencode.ps1            ← opencode adapter (`-f` attach, stateless)
    ├── _capture-validation.ps1 ← shared non-review detector (agy + opencode)
    ├── geminiapi.ps1           ← Direct Gemini REST API (no CLI)
    ├── anthropic.ps1           ← Direct Anthropic REST API (no CLI)
    ├── openaicompat.ps1        ← OpenAI-compatible API adapter (DeepSeek, MiniMax, etc.)
    └── _registry.json          ← Preset → (backend, model_id, pricing) mapping
```

---

## opencode-go over HTTP (v1.8)

opencode-go models are reachable as a plain OpenAI-compatible HTTP API, so the
`openaicompat` adapter serves them directly — retiring the opencode TUI driver for
these models (and its watchdog / stall-snapshot / narration-detector machinery).

- **Presets** (`_registry.json`): `deepseek-http`, `glm-http`, `minimax-http`,
  `kimi-http` → `backend: openaicompat`, `api_base: https://opencode.ai/zen/go/v1`,
  `api_key_env: OPENCODE_API_KEY`, `max_tokens: 16384`. Plus `nvidia` →
  `integrate.api.nvidia.com/v1`, `NVIDIA_API_KEY` (free NIM tier).
- **registryHash carries REST fields.** era.ps1's `$registryHash` builder now copies
  `api_base`/`api_key_env`/`api_key_header`/`max_tokens` (it previously dropped them),
  because era.ps1 passes `$registryHash` — not the raw registry — to
  `Invoke-ReviewerDispatch`. Without this, openaicompat presets dispatched via era.ps1
  throw "requires ModelInfo.api_base".
- **Key resolution** (`workflow.ps1::Resolve-EraAuthJsonKeys`): for any requested
  `api_key_env` not already in the process env, the key is sourced from opencode's
  `auth.json` (`OPENCODE_API_KEY`→`opencode-go`, `MINIMAX_API_KEY`→`minimax`,
  `NVIDIA_API_KEY`→`nvidia`; `type:api` entries only). Never overwrites an existing env
  var; set at process scope, visible to the ThreadJob adapters (same process).
- **Reasoning models** (`openaicompat.ps1`): falls back to `message.reasoning_content`
  when `message.content` is empty, and uses a per-preset `max_tokens` (default 8192),
  so reasoning models (deepseek) don't return blank reviews.
- **Opt-in flag:** `ERA_USE_HTTP_OPENCODE=1` remaps the `deepseek`/`minimax` reviewer
  aliases to their `*-http` presets at resolve time (before availability checks).
  Default off; existing behavior byte-identical.
- **Auth headers (verified 2026-06-15):** the opencode OpenAI endpoint (`/zen/go/v1`)
  uses `Authorization: Bearer`; the Anthropic endpoint (`/zen/go/v1/messages`, used by
  `qwen3.7-max`) uses `x-api-key` (Bearer → 401). Each adapter's native default is
  correct. qwen (Anthropic-style) is DEFERRED to a future pass (would route via
  `anthropic.ps1` with an `api_base` override).

---

## Robustness hardening (v1.10)

Four fixes from failed-run analysis:

- **agy auto-fallback** (`workflow.ps1::Resolve-EraAgyFallback` + era.ps1 post-dispatch
  wiring): when an agy reviewer returns `ExitCode != 0` (capture failure after its
  in-adapter retry), era re-dispatches that work to a non-agy fallback via a second
  `Invoke-ReviewerDispatch` and adds it under its OWN preset key (correct
  backend/pricing in metadata); the failed agy entry is kept for telemetry. The
  fallback is appended to `$approvedList` so `Copy-PrimaryResponseAlias` (which already
  promotes only `ExitCode==0` reviewers) makes it the primary. Fallback target =
  `$env:ERA_AGY_FALLBACK` if valid/available/non-agy, else first available non-agy by
  preference; `off`/`0` disables. Triggers only on real agy failure.
- **`-SuffixReviewerList`** on `Invoke-ReviewerDispatch`: decouples response-filename
  suffix calc from the dispatch list, so the fallback re-dispatch passes the COMBINED
  list and doesn't clobber `round-N-response.md` in a multi-reviewer run.
- **git guard** (era.ps1 `$repoRoot`): only calls `git rev-parse` when `Get-Command git`
  succeeds; else falls back to cwd. Avoids the raw "term 'git' is not recognized" crash
  outside a git repo without git. (The `if (-not $repoRoot)` cwd fallback is retained.)
- **MSYS path normalization** (`workflow.ps1::ConvertTo-EraNativePath`, Windows-guarded):
  rewrites a leading `/c/…` to `C:/…` in `-IncludeFiles` so bash-on-Windows callers don't
  trip the out-of-repo file check. No-op on Linux (where `/c/…` is a real path).
- **Clean preflight errors** (`era.ps1::Stop-EraWithError`): known user mistakes (bad
  `-IncludeFiles`, empty bundle) print a single `[era] ERROR: …` line + exit 1 instead
  of a raw exception stack. (AutoDetect throws are unchanged — tests capture them via
  the error stream.)

---

## Parallel dispatches

Multiple `era.ps1` processes against the **same topic slug** can now run concurrently. Each process gets its own round number via atomic round-number reservation:

1. The process scans `<reviewDir>/round-*-manifest.json` and `round-*-claim.json` to find the highest existing round N.
2. It atomically creates `round-(N+1)-claim.json` via `FileMode.CreateNew` (fails if the file already exists).
3. On success it owns round N+1. On collision it increments N and retries immediately (no sleep, cap 50 retries).

This means two background jobs spawned against the same topic will naturally pick distinct round numbers (e.g. round 1 and round 2), run their reviews in parallel, and each emit an independent completion notification when done.

### Harness pattern — N independent notifications

```ps1
$j1 = Start-Job -ScriptBlock {
    & "$env:USERPROFILE/.claude/skills/external-review-auto/runtimes/era.ps1" `
        -TopicSlug my-topic -Reviewer gemini -Force -IncludeFiles 'docs/spec.md'
}
$j2 = Start-Job -ScriptBlock {
    & "$env:USERPROFILE/.claude/skills/external-review-auto/runtimes/era.ps1" `
        -TopicSlug my-topic -Reviewer deepseek -Model 'glm-5.1' -Force -IncludeFiles 'docs/spec.md'
}
Wait-Job -Job @($j1, $j2) -Timeout 600
Receive-Job -Job $j1
Receive-Job -Job $j2
```

Both jobs land in the same `.external-reviews/my-topic/` directory with distinct round-N files.

### Multi-reviewer single-process (unchanged behavior)

`-Reviewer gemini,deepseek` still reserves **one** round for the whole batch and dispatches reviewers as parallel ThreadJobs inside the single process. The caller sees one completion notification.

### Known limitation: orphaned claim files

If a process is killed mid-run (Ctrl-C, crash, Out-of-Memory), the `round-N-claim.json` it created is left behind. The next invocation will see it and skip that round number (treating it as claimed). Manual cleanup: `Remove-Item .external-reviews/<topic>/round-*-claim.json`.
