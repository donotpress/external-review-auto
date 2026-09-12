# Error-code catalog: seat `Error` values and what they buy

Single reference for every deliberate failure code (a guarded registry test
asserts each code below still exists in code). Free-text adapter exceptions
(network, auth, bad model id, `opencode run failed ...` without a trailer)
are NOT catalogued: they are diagnostics, not decisions.

| Code | Meaning | Recovery | Decoded where |
|---|---|---|---|
| `response-contract` | Call completed; answer violated the opted-in contract | Fallback when round void | adapter return |
| `agentic-narration-capture` | Call completed; model narrated instead of reviewing | Fallback when round void | shared capture detector |
| `prompt-echo` | Call completed; response is the prompt echoed | Fallback when round void | echo detector |
| `empty-capture` | Call completed; nothing usable in transcript | Fallback when round void | adapter return |
| `tmux-seat-exited`, `tmux-seat-truncated` | tmux transport seat died / was cut | Fallback when round void | tmux backend |
| `stall-or-timeout` | No usable transcript; process stalled or budget spent | Fallback when round void (agy) / retry inside adapter | adapter throw |
| `agy-stream-interrupted` | Model stream died interrupted on every attempt (transcript forensics) | Dead-transport fallback (REST), even in usable rounds | `Get-AgyStreamInterruption` + throw trailer |
| `opencode-no-output` | Exit -1 with zero stdout bytes (model never emitted) | Dead-transport fallback (REST), even in usable rounds | Stderr trailer → `Convert-EraAdapterResultError` at collection |
| `agy-quota-exhausted` | Gemini pool flag says empty; never dispatched | Dead-transport fallback (REST), even in usable rounds | `Get-AgyQuotaState` at adapter entry |
| `breaker-skip` | Backend on fatal streak; never dispatched | Fallback when round void | `Select-EraBreakerSkips` at dispatch |
| `timeout` | Abandoned at grace/budget with no adapter record | Not recoverable (nothing to re-run differently) | dispatcher synthetic |
| `no-structured-output` | Job returned no hashtable | Not recoverable | collection filter |

Category rule (`Get-EraFailureCategory`): the first three rows are
`answered-badly` (bundle WAS reviewed, answer rejected); everything else
failed is `not-delivered` (nothing was reviewed). Fatal-streak rule
(`Test-EraFatalFailure`): everything failed EXCEPT the answered-badly
three counts toward a backend streak.
