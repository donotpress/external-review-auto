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

Tests are pure PowerShell with no network or live backend spawning. Most are fast; a few (`Resolve`, `SpecReview`, `Invoke-Era`, `AutoDetect`) fork `pwsh` to exercise `era.ps1`/`resolve.ps1` end-to-end, so a full run is **~100s**. No external dependencies.

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

## What's NOT covered

- **Live backend dispatches** — running agy/claude/opencode would require live auth, real network, and minutes of wall clock. Use the manual smoke-test pattern (small bundle + `--reviewer <preset>`) for those.
- **`era.ps1` argument parsing** — covered implicitly by smoke tests; would benefit from a future test file if argument logic grows.
- **`workflow.ps1::Invoke-ReviewerDispatch` ThreadJob behavior** — ThreadJobs are hard to mock and the integration is exercised by every smoke test.

## When to add tests

- Adding a new backend → extend `Registry.Tests.ps1` + add to `EnvScrub.Tests.ps1` if CLI.
- Touching `Get-AgyTranscriptResponse` → run the existing tests and add one for the new behavior.
- Changing a regex anywhere → add cases to `Regex.Tests.ps1`.
- Bug fix → add a regression test in the file closest to the fix's concern.
