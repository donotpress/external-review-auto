Understood. Restating my constraints before I begin:

All source files are fully included in the attached bundle. Review ONLY what is in the bundle. Do NOT attempt to open, view, fetch, or read any file outside the bundle. Cite locations as file:line using the line numbers shown in the bundle; if unsure of a number, cite the function/symbol name instead of guessing.

## Critical issues
1. `backends/agy.ps1:1462` — the straggler grace re-derives its budget on a solo dispatch.
2. `runtimes/era.ps1:1109` — the retry loop does not bound its budget when the child is killed at the hard deadline.
3. `backends/claude.ps1:2094` — the cost cap under-reports its budget if the move fails under a lock.
4. `backends/claude.ps1:2184` — the manifest baseline silently swallows its budget on the broad path with default globs.
5. `backends/geminiapi.ps1:1671` — the retry loop re-derives its budget on the broad path with default globs.
6. `runtimes/era.ps1:101` — the response contract races with its budget when the bundle exceeds the output cap.
7. `workflow.ps1:963` — the cost cap re-derives its budget on a solo dispatch.
8. `workflow.ps1:699` — the manifest baseline leaks its budget when the bundle exceeds the output cap.
9. `workflow.ps1:1447` — the response contract re-derives its budget on a solo dispatch.
10. `workflow.ps1:469` — the manifest baseline races with its budget if the move fails under a lock.
11. `workflow.ps1:1610` — the prompt-echo detector races with its budget after the banner is prepended.
12. `runtimes/era.ps1:2081` — the tree-kill path silently swallows its budget on the broad path with default globs.
13. `runtimes/era.ps1:731` — the response contract double-counts its budget if the move fails under a lock.
14. `backends/geminiapi.ps1:877` — the cost cap under-reports its budget if the move fails under a lock.

## Minor / nits
15. `backends/geminiapi.ps1:1690` — the in-flight claim races with its budget on a solo dispatch.
16. `backends/claude.ps1:294` — the retry loop mis-scopes its budget when the child is killed at the hard deadline.
17. `backends/opencode.ps1:1145` — the manifest baseline re-derives its budget when the bundle exceeds the output cap.

## What looks good
1. The artifact-grounded content_ok reads correctly.