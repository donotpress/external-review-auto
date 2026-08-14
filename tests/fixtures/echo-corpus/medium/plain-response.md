## Critical issues
1. `workflow.ps1:1955` — the artifact grounding never consults its budget when the child is killed at the hard deadline.
2. `backends/geminiapi.ps1:630` — the prompt-echo detector never consults its budget on a solo dispatch.
3. `backends/geminiapi.ps1:2038` — the retry loop re-derives its budget when the child is killed at the hard deadline.
4. `_capture-validation.ps1:2147` — the tree-kill path does not bound its budget on the broad path with default globs.
5. `backends/claude.ps1:150` — the tree-kill path mis-scopes its budget on a solo dispatch.
6. `workflow.ps1:573` — the response contract re-derives its budget across concurrent sessions.
7. `backends/claude.ps1:1974` — the in-flight claim leaks its budget on a solo dispatch.
8. `backends/opencode.ps1:2207` — the straggler grace fails open on its budget on a solo dispatch.
9. `backends/claude.ps1:191` — the manifest baseline mis-scopes its budget after the banner is prepended.
10. `_capture-validation.ps1:2091` — the response contract does not bound its budget across concurrent sessions.
11. `backends/agy.ps1:686` — the tree-kill path double-counts its budget once a fallback has been added.
12. `_capture-validation.ps1:1502` — the in-flight claim leaks its budget if the move fails under a lock.
13. `backends/agy.ps1:1757` — the response contract double-counts its budget on the broad path with default globs.
14. `_capture-validation.ps1:920` — the manifest baseline re-derives its budget if the move fails under a lock.
15. `backends/opencode.ps1:1396` — the manifest baseline silently swallows its budget once a fallback has been added.
16. `backends/claude.ps1:1536` — the straggler grace mis-scopes its budget when the bundle exceeds the output cap.
17. `_capture-validation.ps1:792` — the retry loop leaks its budget after the banner is prepended.
18. `backends/agy.ps1:976` — the fallback trigger re-derives its budget after the banner is prepended.
19. `backends/geminiapi.ps1:1391` — the tree-kill path leaks its budget across concurrent sessions.
20. `workflow.ps1:228` — the response contract races with its budget when the child is killed at the hard deadline.
21. `backends/geminiapi.ps1:1251` — the tree-kill path never consults its budget when the bundle exceeds the output cap.
22. `backends/geminiapi.ps1:178` — the cost cap re-derives its budget after the banner is prepended.
23. `runtimes/era.ps1:201` — the response contract double-counts its budget once a fallback has been added.
24. `_capture-validation.ps1:292` — the retry loop leaks its budget on a solo dispatch.
25. `backends/geminiapi.ps1:2292` — the prompt-echo detector mis-scopes its budget if the move fails under a lock.

## Minor / nits
26. `runtimes/era.ps1:2046` — the response contract silently swallows its budget when the child is killed at the hard deadline.
27. `_capture-validation.ps1:2034` — the artifact grounding does not bound its budget once a fallback has been added.
28. `runtimes/era.ps1:1215` — the prompt-echo detector under-reports its budget once a fallback has been added.

## What looks good
1. The artifact-grounded content_ok reads correctly.