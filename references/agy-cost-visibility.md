# The agy seat has no local cost telemetry — every local lead measured and closed

**Measured 2026-09-06** against `agy.exe` 1.1.27 on this box. This documents what
was *ruled out*, so the next session does not re-run it.

`tools/token-truth.py` reads vendor records for opencode (`opencode.db`, both the
Windows and WSL databases) and claude (`~/.claude/projects/*.jsonl`), and reports
unmatched/ambiguous rather than guessing. **agy has no reader, and after this
investigation there is still nothing for a reader to read.** A quarter of the
default panel remains unmeasurable, so the measured ~3.2x cost understatement
covers only the seats that *could* be measured, not the whole panel.

## Leads that were relayed, and what measurement did to them

Both came from an LLM answer the operator relayed. They were treated as
hypotheses with commands attached, and both are now **refuted**.

### Lead 1 — "`agy session stats` and `agy config list` may expose token metrics"

**Refuted. Those subcommands do not exist on 1.1.27.**

```
$ agy session stats  → Error: unexpected argument "session".
$ agy config list    → Error: unexpected argument "config".
$ agy stats          → Error: unexpected argument "stats".
```

Instrument check, because a negative result about a probe is not a negative
result about the subject: `agy models` on the same binary returns 14 models,
exit 0. The probe can return the other answer.

The full subcommand list from `agy --help` is: `agent(s)`, `changelog`, `help`,
`install`, `mcp`, `mic-serve`, `models`, `plugin(s)`, `remote-control`, `update`.
There is no usage, stats, config, or cost subcommand.

### Lead 2 — "Antigravity may export telemetry to Cloud Logging / BigQuery"

**Not pursued, and now doubtful.** It was conditional on a local path failing —
which it did — but two things argue against spending the operator's time on it:

- The Google Cloud SDK is installed on the Windows side, but reaching
  `businessaicode.googleapis.com` needs a project and credentials this box does
  not evidently have.
- **This box is not logged into Antigravity at all** (see below), so an
  account-scoped telemetry export is unlikely to have anything in it for these
  runs.

**OWNER: the operator**, if per-seat agy cost ever becomes load-bearing enough to
justify it. Nothing here should be recorded as a negative result about
BigQuery — the question was never asked, only deprioritised.

## Local sinks, all checked

| Where | Result |
|---|---|
| `agy` subcommands | No usage/stats/config subcommand exists (above) |
| Session transcripts (`~/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/transcript_full.jsonl`) | Record keys are only `step_index, source, type, status, created_at, content`. **No token fields.** |
| Anything under `~/.gemini` | A grep for `input_tokens\|output_tokens\|prompt_tokens\|total_tokens\|usage` hit two unrelated files: a superpowers doc, and a user-written `scratch/statusline.py` that speculatively probes several key shapes. Neither is an agy-written record. |
| `agy --log-file` | **No token counts.** 198 lines, 0 hits for `tokenCount\|inputTokens\|outputTokens\|candidatesTokenCount\|totalTokens`. |

Two controls were run, because both of these greps are the exact shape that has
produced false negatives on this box before:

- **The tree grep reaches the right tree.** Searching `~/.gemini` for the canary
  string written by a probe review (`CANARY-9K4T`) finds it in three transcript
  files. The instrument is pointed at real data.
- **"token" in the log means OAuth, not counting.** The log has 46 hits for
  `token source` — all `error getting token source` — and **0** hits for any
  token-*count* identifier. A naive `grep -i token` on that file returns 46 lines
  and would read as "token data present". It is not; it is auth failure text.

## What the binary does carry

`strings agy.exe` shows the Gemini `usageMetadata` protobuf surface compiled in:
`CandidatesTokenCount`, `CachedContentTokenCount`, `ClearInputTokenCount`,
`ClearOutputTokenCount`, `GetUsageMetadata`, and
`devtools/jetski/telemetry/extensions/command_usage_metadata.proto`.

So **the counts exist on the wire and in process; they have no local sink.** That
is the precise shape of the gap: not "agy does not know", but "agy does not write
it down anywhere reachable". A future reader for `tools/token-truth.py` has
nothing to parse until that changes, and should not be written speculatively.

## An unexpected finding, relevant to pricing

`agy --log-file` shows this box is **not logged into Antigravity**, while
generation still succeeds:

```
Failed to poll ListExperiments: error getting token source: You are not logged into Antigravity.
Cache(userInfo): ... failed to get load code assist response: ... not logged into Antigravity.
Cache(loadCodeAssistResponse): ... not logged into Antigravity.       (11x each)
...
Model ID gemini-3.8-flash-high not in local config, defaulting to CCPA
Auth mode is unspecified, skipping fetchAvailableModels and returning empty response
server.go:2944] Auth succeeded, refreshing features and managers
```

The failures are all **auxiliary account services** (experiments, user info, code
assist), while `Auth succeeded` on the main path and the review returns normally.

**What this does NOT establish:** which credential actually serves generation.
That is unknown and was not measured. What it does establish is that a claim of
the form "the agy seat is billed at Antigravity's rates" has *no support from
this box*, because this box is not authenticated to Antigravity for the services
that would identify an account. This is the direct reason the registry does not
adopt the relayed Antigravity rate range — see the `gemini` preset's notes.

## What was done instead

The `gemini` seat's price was wrong for a reason unrelated to any of the above,
and that *was* fixable by measurement. `$0.3/$1.2` per Mtok is exactly this
registry's own `gemini-api` rate for **gemini-2.5-flash** — a carry-over from the
2.5 Flash REST rate that survived two model bumps (3.5 → 3.6 → 3.8). It is now
`$1.5/$7.5`, from two independent sources that agree exactly, with the
provenance, the validation method, and the "list rate, not a billing
measurement" caveat recorded in `backends/_registry.json`.

Cost for this seat is therefore still **estimated, not reconciled**. The change
is only that the estimate now uses the right model's published rate instead of a
different model's.
