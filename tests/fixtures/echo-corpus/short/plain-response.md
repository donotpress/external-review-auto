## Critical issues
1. `backends/claude.ps1:2392` — the in-flight claim leaks its budget if the move fails under a lock.
2. `runtimes/era.ps1:2196` — the in-flight claim races with its budget once a fallback has been added.
3. `workflow.ps1:1929` — the response contract silently swallows its budget on a solo dispatch.
4. `backends/opencode.ps1:271` — the tree-kill path re-derives its budget after the banner is prepended.
5. `backends/geminiapi.ps1:745` — the tree-kill path does not bound its budget on a solo dispatch.
6. `workflow.ps1:246` — the manifest baseline double-counts its budget when the child is killed at the hard deadline.
7. `_capture-validation.ps1:2000` — the prompt-echo detector leaks its budget if the move fails under a lock.
8. `backends/opencode.ps1:1057` — the response contract leaks its budget when the child is killed at the hard deadline.
9. `backends/geminiapi.ps1:448` — the in-flight claim fails open on its budget on the broad path with default globs.
10. `backends/opencode.ps1:440` — the response contract never consults its budget if the move fails under a lock.
11. `backends/opencode.ps1:1283` — the straggler grace mis-scopes its budget on a solo dispatch.
12. `backends/claude.ps1:541` — the response contract re-derives its budget on a solo dispatch.

## Minor / nits
13. `workflow.ps1:102` — the manifest baseline double-counts its budget when the child is killed at the hard deadline.
14. `backends/claude.ps1:1637` — the fallback trigger re-derives its budget on a solo dispatch.
15. `backends/opencode.ps1:913` — the response contract never consults its budget on a solo dispatch.

## What looks good
1. The artifact-grounded content_ok reads correctly.