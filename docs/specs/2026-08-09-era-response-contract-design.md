# era: response contract and reliability cluster (P1 / P5 / P8 + convergence)

**Date:** 2026-08-09
**Status:** approved
**Origin:** 3-model panel design review — `.external-reviews/era-proposals/round-1-*`.
P1 was ranked #1 by `opus`, #4 by `deepseek-flash`, #7 by `gemini`; all three
independently agreed on its *design* (dispatcher-level, not per-adapter).

## Problem

**P1 — nothing verifies the answer matches the request.** Adapters check
non-empty text plus a finish reason, then return `ExitCode=0`.
`Copy-PrimaryResponseAlias` promotes on `ExitCode -eq 0` alone. A reviewer
returned **zero of ten requested verdicts three times** and each was recorded as
a normal success. The teeth, per `opus`: the promoted file is what
`Invoke-PromptTokenSubstitution` feeds into round N+1 — a contract-failed round
does not merely waste a round, it **poisons the next one**.

Observed first-hand this session: on the panel run, `round-1-response.md` was
byte-identical to `gemini`'s — the shortest and weakest of three. Promotion is an
ordering accident, not a quality judgement.

**Convergence dead code.** `era.ps1` selects `$primaryResult` by `$_.ContentOk`,
but only `agy` and `opencode` set that key — `geminiapi`, `anthropic`, `claude`
and `openaicompat` never do. It then reads `$primaryResult.ResponseChars`, which
**no adapter sets**. So `$currentResponseChars` is always 0 and two of the three
convergence signals can never fire. (This does not contradict the known
`workflow.ps1:1044` backfill: that is a *local* inside the metadata writer and
never mutates the result object.)

**P5 — `git status --porcelain` mis-parses renames and quoted paths.** The parse
strips three characters and keeps the remainder, so `R  old -> new` yields the
non-path `old -> new`, and `core.quotePath` wraps non-ASCII names in quotes that
survive into the path. Both then fail `Test-Path`.

**P8 — registry capabilities are ignored.** `max_tokens` is set only on
`openaicompat` presets; `geminiapi` and `anthropic` hardcode 8192 and ignore the
registry entirely. `$ModelInfo` is already passed to every adapter
(`workflow.ps1:848`), so the plumbing exists — only the values and the reads are
missing.

## Design

### Unit 1 — response contract (P1)

Three pure functions in `workflow.ps1`, plus one application site in `era.ps1`.

**Declaration travels with the prompt.** A prompt declares its contract with a
marker line:

```markdown
<!-- era-require: ORDER:, DROP-ENTIRELY:, MISSING: -->
```

`Get-EraResponseContract -PromptText <string> -> string[]` parses it off the
**finalised** prompt, so a `-PromptOverrideFile` carries its own contract and no
new parameter is needed. **No marker means lenient** — exactly today's
behaviour, so every existing caller is untouched.

**Matching is decoration-tolerant.** Measured on the panel run: `deepseek-flash`
answered `**P1: DO**` while `gemini` and `opus` answered `P1: DO`. A naive check
would have failed the sharpest response in the panel. `Test-ResponseContract`
normalises both sides — strip `*`, `` ` ``, `_`, `#`, collapse whitespace,
lowercase — then does an ordinal substring test. `.Contains()`, not `-like`, so a
required token containing `[` or `*` is not treated as a glob.

**Failure mirrors the opencode precedent exactly.** `opencode` already has this
shape: `Test-AgenticNarrationCapture` sets `ContentOk=$false` **and**
`ExitCode=-1`. Setting the same fields means every existing consumer already
behaves correctly with no changes:

| Consumer | Effect |
|---|---|
| `Copy-PrimaryResponseAlias` | skips it (promotes on `ExitCode -eq 0`) |
| metadata writer | records `content_ok=false` with a reason |
| agy fallback | re-dispatches for agy presets |

The response file stays on disk — it is evidence, not garbage. Only its
promotion to canonical is withheld.

The check runs in `era.ps1` immediately after `Invoke-ReviewerDispatch` and
**before** the agy-fallback block, so a contract failure can trigger the existing
fallback. Placement is the dispatcher layer, not the adapters: all six backends
converge there, and the two REST adapters have no retry path of their own.

### Unit 2 — convergence signal repair

`$primaryResult` filters on `$_.ExitCode -eq 0`; `$currentResponseChars` uses
`$primaryResult.Response.Length`. Two lines. This also composes with Unit 1: a
contract-failed reviewer is `ExitCode=-1`, so it is correctly excluded from the
convergence baseline.

### Unit 3 — porcelain parsing (P5)

One shared helper, `Get-EraPorcelainPaths -RepoRoot <string> -> string[]`, used
at both call sites (`era.ps1:350` and `era.ps1:909`).

`git status --porcelain -z` emits NUL-terminated records with no quoting and no
escaping. **Measured** on this box: a rename yields two fields, destination
first:

```
[R  new.md]  [old.md]  [?? probe.ps1]  [?? untracked.md]
```

The parser splits on NUL, takes `substring(3)` of each record as the path, and
when the XY status contains `R` or `C` skips the following field (the source).
The existing `.external-reviews` filter applies to the destination only.

### Unit 4 — registry capabilities (P8)

Deliberately narrowed to `max_tokens`, per `deepseek-flash`: the rest
(`attach_limit_bytes`, `supports_structured_output`) is speculative generality
until forced structured output actually consumes it.

`max_tokens: 8192` is added to the five `geminiapi`/`anthropic` presets — the
value they already hardcode, so this is **behaviour-preserving**. Both adapters
read `$ModelInfo.max_tokens` with an 8192 fallback, including in their truncation
warning text. Raising a cap becomes a config edit rather than a code edit.

## Testing

- **P1**: contract parsed from a marker; absent marker returns empty (lenient);
  decoration-tolerant match (`**P1: DO**` satisfies `P1:`) — the measured case;
  missing token reported; failure sets `ExitCode=-1`/`ContentOk=$false`; a
  contract-failed reviewer is not promoted to `round-N-response.md`.
- **Convergence**: `$primaryResult` selects a REST-adapter result that sets no
  `ContentOk`; `$currentResponseChars` is non-zero for a non-empty response.
- **P5**: a repo with a rename yields the destination path and not `old -> new`;
  a path with spaces survives; `.external-reviews` is still filtered.
- **P8**: every `geminiapi`/`anthropic` preset declares `max_tokens`; both
  adapter sources read `$ModelInfo.max_tokens`; the fallback is 8192.

## Risks

- **P1 can fail a round that would previously have "succeeded".** That is the
  point, and it is opt-in per prompt. No shipped prompt template gains a marker
  in this change, so default behaviour is unchanged.
- **P5 changes a parse used by `-AutoDetect`.** Mitigated by the helper being
  pure and directly tested against a real git repo with a rename.
- **P8 is behaviour-preserving by construction** (8192 in, 8192 out).

## Out of scope

P3 (repomix tree-kill and streaming job body), P6 (dropped by the panel),
API-level forced structured output (Gemini `responseSchema`, Anthropic
`tools`/`tool_choice`) — that is P1 phase 2 and depends on a
`supports_structured_output` capability this change deliberately omits.
