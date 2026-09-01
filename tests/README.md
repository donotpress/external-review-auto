# Tests

Pester 5 unit tests covering the high-risk surface of `/era`. Run before merging anything that touches `backends/`, `workflow.ps1`, or `runtimes/era.ps1`.

## Prerequisites

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
```

## Running

```powershell
# All tests
pwsh -Command "Invoke-Pester -Path tests/"

# One test file
pwsh -Command "Invoke-Pester -Path tests/Get-AgyTranscriptResponse.Tests.ps1"

# Verbose output (see every It block as it runs)
pwsh -Command "Invoke-Pester -Path tests/ -Output Detailed"
```

Tests are pure PowerShell with no network or live backend spawning (961 tests as of v2.7.1). ⚠️ `BundleDeliveryWiring.Tests.ps1` copies the whole skill tree and forks a real `era.ps1` per case, which is why it is the slowest file by a wide margin — it exists because the unit test it replaced passed while the feature was dead, so the cost is deliberate. Budget for it when running the full suite. Most are fast; a few (`Resolve`, `SpecReview`, `Invoke-Era`, `AutoDetect`) fork `pwsh` to exercise `era.ps1`/`resolve.ps1` end-to-end, so a full run is **~20 min** as of v2.7, up from ~8 (one `Slow`-tagged ThreadJob test alone takes ~30s; exclude it with `-ExcludeTagFilter Slow`). No external dependencies.

## What's covered

| File | Surface |
|---|---|
| `Get-AgyTranscriptResponse.Tests.ps1` | The Run-ID-correlated transcript capture in `backends/agy.ps1` — GUID match across combined new/existing sessions, USER-anchored path fallback, `transcript_full`-only preference, the legacy new-session/temporal-floor fallback, entry filtering, edge cases. The most bug-prone code in the skill. |
| `RetryLoop.Tests.ps1` | `Invoke-AgyReview`'s retry loop (mocks `_SpawnAndCaptureOnce`): a thrown stall/timeout is retried once (not bypassed), the per-reviewer cost-cap gates the retry, and a final bad capture returns an honest `ExitCode=-1`. |
| `AgenticCapture.Tests.ps1` | The shared `Test-AgenticNarrationCapture` detector (narration, length-floor, bundle-unavailable refusal branches; false-positive guards) and `Write-ReviewMetadata`'s honest fields (`content_ok`, `retry_count`, `first_attempt` cost). |
| `BackendCaptureHardening.Tests.ps1` | Cross-adapter invariants: shareable (`FileShare.ReadWrite`) capture sinks, the shared detector wiring, opencode's `-f` attach + message-first arg order, and opencode being stateless-by-default with opt-in variant insurance. |
| `ProcessTreeKill.Tests.ps1` | All three native-process adapters tree-kill (`Kill($true)`) on stall/timeout and carry no bare `.Kill()` that would orphan a child. |
| `AgyModelFlag.Tests.ps1` | Per-process `--model` selection, removal of the settings.json swap + global mutex, Run-ID params, and per-reviewer default `--model` resolution for heterogeneous agy batches. |
| `Resolve.Tests.ps1` | `runtimes/resolve.ps1` natural-language → typed flags (family/tier matching, topic-vs-reviewer disambiguation, last-`use` split, `reasoner` routing) + the Layer-1↔Layer-2 contract. |
| `SpecReview.Tests.ps1` / `Invoke-Era.Tests.ps1` / `AutoDetect.Tests.ps1` / `PromptTokens.Tests.ps1` | `era.ps1` end-to-end paths: `-SpecReview` frontmatter parsing, dispatch/metadata, `-AutoDetect`, and `{{PREVIOUS_ROUND}}` token substitution. |
| `CostPrompt.Tests.ps1` | Cost guard in `workflow.ps1::Invoke-CostPrompt` — force-mode passthrough, cap bypass, `Get-ForceMode`, `Get-PerReviewerCap` tiers. |
| `Regex.Tests.ps1` | The empty-bundle `<file ... >` counter and the ANSI strip (SGR + CSI private-mode). |
| `Registry.Tests.ps1` | `_registry.json` structural integrity — required fields, backend↔`.ps1` resolution, REST presets declare `api_base`/`api_key_env`. |
| `EnvScrub.Tests.ps1` | CLI adapters scrub agent-context env vars, use `CreateNoWindow=$true`, avoid `Start-Process -NoNewWindow`. |
| `ClaudeTruncation.Tests.ps1` | `Test-ClaudeTruncation` precision-anchored stderr detection (true positives + tricky false positives). |
| `DetectorCoverage.Tests.ps1` | The shared non-review detector **and** `Test-EraPromptEcho` must run on **all six** adapters, not just the agentic two. Cross-adapter source invariants plus behavioural tests for `geminiapi` / `openaicompat` / `anthropic` with `Invoke-RestMethod` mocked (no network, no key): a bundle-unavailable refusal or a sub-floor non-answer fails honestly and writes no artifact, while a structured review still passes. |
| `DispatchThreadJob.Tests.ps1` | `Invoke-ReviewerDispatch` driven with **real ThreadJobs** via `-SkillRootOverride` + a fake backend (no mocking, no network): result keying and `Preset` stamping, per-reviewer response suffix incl. `SuffixReviewerList`, adapter-exception isolation, stray success-stream output before *and* after the result, `no-structured-output`, per-reviewer model/provider overrides, bundle-size timeout scaling and its 1800s cap, `-PidFile`/`-ResolvedAgyModel` splatted only when declared, per-reviewer agy `--model` resolution, and the straggler tree-kill (~2s). One `Slow`-tagged test (~30s) covers the global-timeout path that produced case (a) of the 2026-08-09 void round. |
| `EchoCalibration.Tests.ps1` | The prompt-echo threshold, calibrated against the **committed** corpus in `tests/fixtures/echo-corpus/` (three length regimes, deterministic, non-repetitive). Asserts regime COVERAGE — calibrating on one regime again is itself a failure — and MARGIN, so it fails when separation narrows rather than after a case flips. Records that the forward direction cannot separate the populations (legit max 0.450 > TP min 0.350) and the reverse can (0.100 vs 1.000). |
| `DiffPromptPreservation.Tests.ps1` | `-Diff` must not discard caller-supplied prompt content. `Merge-EraDiffPrompt` plus the `$script:PromptCarriesCallerContent` marking at all five sites (`-PromptOverrideFile` explicit and auto-detected, `-SpecReview`, both `-ConversationFile` paths). |
| `IgnoreParity.Tests.ps1` | The manifest baseline and the diff walk must ignore what repomix ignores. `Get-EraVendorIgnorePatterns` / `Get-EraIgnoreSets` / `Test-EraPathIgnored` as one shared rule, matched to repomix 1.12.0 semantics (root-relative dirs, not bare names), plus era.ps1 passing them to both walks. |
| `RecoveryFallback.Tests.ps1` | `Get-EraRecoverableFailures` — which failures the one bounded fallback re-dispatch can recover. Any adapter's deliberate capture-failure code (`response-contract`, `agentic-narration-capture`, `prompt-echo`) on **any** backend, plus a flaky agy capture on any error; a free-text adapter exception (network, bad model id, auth) deliberately does **not** buy a retry. Also pins that widening *what* recovers did not widen *how many* re-dispatches run, nor bypass the per-reviewer cost cap. |
| `OpencodeAttachLimit.Tests.ps1` | The 51,200-byte attach cap as a source-level contract: the constant is explicit, the real bundle is measured rather than a caller-supplied size, size alone routes over the cap to the Read tool, `-f` stays gated behind the not-read-tool branch, and a force-attached oversized bundle warns loudly (a truncated review looks exactly like a successful one). |
| `BlindSeat.Tests.ps1` | The comment-stripped seat. Line numbers must survive intact — era validates `file:line` citations against the bundle, so a stripped seat whose lines had shifted would have every citation flagged as fabricated and the feature would poison its own output. Also: whole-line comments blanked across PowerShell/Python/JS, block bodies blanked without a one-line block swallowing the code after it, code left alone, a Markdown `#` heading NOT treated as a comment, and a trailing comment left in place as documented. Plus the wiring — one seat gets the alternate bundle and the others do not, the stripped copy is built after repomix from the finished bundle, and naming an undispatched seat warns rather than silently doing nothing. |
| `FieldReports20260901.Tests.ps1` | Three issues from a field report: the browser-profile ignore patterns (present, and spelled with the load-bearing `**/` prefix that stops them being root-anchored) plus the permission-abort message that says what is *not* the fix; citation grounding against a synthetic 2,834-line bundle reproducing the reported fabrications, including the refusal to guess on an ambiguous basename and the "findings may still be real" wording; and the non-review branch split — a short bundle refusal must be named a refusal rather than sub-floor, the error *code* must stay `agentic-narration-capture` so recovery still triggers, and no branch may leak from a previous call. Also covers model-hint determinism — the registries are iterated in a defined order, an ambiguous hint resolves identically across five calls, the ergonomic exact hints are undisturbed, and the ambiguity warning stays off stdout so `resolve.ps1`'s JSON contract holds — plus the recorded rationale for refusing a whole panel rather than dropping doomed seats. Extended after the 2026-09-01 design panel: a registry key must not appear to move a fixed transport limit (an override *below* the 51,200 attach cap used to refuse rounds the adapter would have delivered — D3's shape surviving D3's fix), every channel carries a `measured`/`chosen`/`derived`/`none` classification, a `derived` ceiling may never refuse, and `-PremiseCheck` appends its section before repomix embeds the prompt in the bundle. |
| `BundleDeliveryWiring.Tests.ps1` | **End-to-end** wiring for the delivery gate, written because the unit test above it passed while the feature was dead. Copies the skill tree to a temp dir, edits the copied `_registry.json`, runs the real `era.ps1` against a real git repo, and asserts on what era prints — `max_bundle_bytes` / `max_bundle_tokens` honoured, `0` treated as a real ceiling rather than as absent, a non-numeric value warned about and ignored, and exit **1** with nothing dispatched. Free and hermetic: an over-ceiling bundle is refused at preflight before any reviewer runs. Verified by negative control — with the two projection lines removed it prints the built-in ceiling and dispatches. |
| `BundleDeliveryPreflight.Tests.ps1` | Each seat's delivery channel vs. the bundle era actually built. `Get-EraBackendDelivery` (opencode `attach` under 51,200 bytes / `read-tool` above it, `claude` by tokens, `agy` unbounded, unmeasured providers never refused) and `Get-EraBundleDeliveryPlan` driven with the REAL sizes from the rounds that failed — 74,740 / 109,066 / 314,720 / 668,389 / 2,396,233 bytes and repomix's own 711,253-token count — plus the `era.ps1` wiring: the plan runs before the cost prompt, refuses with exit 1, and gates its override behind `-ForceBundleSize` rather than `-Force`. Pins the measured `claude` ceiling inside its bisected bracket, so neither a regression to the old derived 150,000 nor a rise above the measured accept point passes. |
| `OpencodeReadToolDelivery.Tests.ps1` | The over-the-cap Read-tool path, and the snapshot bug that once hid how it behaves. Includes a **live .NET repro** of that bug — 218 bytes copied into a `FileStream` gives `Length` 218 and an on-disk length of 0 until `Flush()` — because it is the reason six stall artifacts read as "the process produced nothing" and the reason the path was briefly retired. Asserts the snapshot flushes *before* it reads, that size alone routes to the Read tool, that the refusal only fires past the verified 1,048,576-byte ceiling and costs a second rather than a timeout, and that the source records the canary measurements **and** the unexplained intermittency — a comment reporting only the passes is arguing for its conclusion. |
| `VoidRound.Tests.ps1` | A round that produced no usable review must not report success. `content_ok` and `Test-EraReviewerArtifact` are grounded in the response artifact on disk, not in the adapter's `ContentOk` flag (which agy sets `$true` even when its process was killed) and not in a clean exit code (which for REST backends only means the HTTP call worked); `Get-EraVoidRoundReport` plus the `era.ps1` gate that exits **2** — distinct from the preflight exit 1 — when nothing readable was produced. |

## What's NOT covered

- **Live backend dispatches** — running agy/claude/opencode would require live auth, real network, and minutes of wall clock. Use the manual smoke-test pattern (small bundle + `--reviewer <preset>`) for those.
- **`era.ps1` argument parsing** — covered implicitly by smoke tests; would benefit from a future test file if argument logic grows.

## When to add tests

- Adding a new backend → extend `Registry.Tests.ps1` + add to `EnvScrub.Tests.ps1` if CLI.
- Touching `Get-AgyTranscriptResponse` → run the existing tests and add one for the new behavior.
- Changing a regex anywhere → add cases to `Regex.Tests.ps1`.
- Bug fix → add a regression test in the file closest to the fix's concern.
