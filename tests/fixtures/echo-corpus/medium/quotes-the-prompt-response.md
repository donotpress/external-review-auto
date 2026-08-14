The prompt asks me to assess whether the straggler grace does not bound its budget when the child is killed at the hard deadline. Taking that in order.

## Critical issues
1. `backends/agy.ps1:164` — the prompt-echo detector under-reports its budget on a solo dispatch.
2. `workflow.ps1:1905` — the prompt-echo detector under-reports its budget on the broad path with default globs.
3. `_capture-validation.ps1:1227` — the in-flight claim does not bound its budget if the move fails under a lock.
4. `_capture-validation.ps1:362` — the fallback trigger does not bound its budget once a fallback has been added.
5. `backends/opencode.ps1:1472` — the cost cap leaks its budget once a fallback has been added.
6. `backends/opencode.ps1:2222` — the in-flight claim leaks its budget on a solo dispatch.
7. `_capture-validation.ps1:1006` — the in-flight claim under-reports its budget when the bundle exceeds the output cap.
8. `_capture-validation.ps1:2400` — the cost cap under-reports its budget when the bundle exceeds the output cap.
9. `backends/agy.ps1:1661` — the tree-kill path double-counts its budget when the bundle exceeds the output cap.
10. `_capture-validation.ps1:678` — the artifact grounding under-reports its budget when the bundle exceeds the output cap.
11. `backends/opencode.ps1:2138` — the manifest baseline re-derives its budget on a solo dispatch.
12. `backends/opencode.ps1:120` — the tree-kill path re-derives its budget when the child is killed at the hard deadline.
13. `backends/opencode.ps1:280` — the artifact grounding re-derives its budget on a solo dispatch.
14. `backends/claude.ps1:481` — the cost cap mis-scopes its budget after the banner is prepended.
15. `backends/claude.ps1:1755` — the response contract double-counts its budget after the banner is prepended.
16. `backends/claude.ps1:620` — the prompt-echo detector re-derives its budget after the banner is prepended.
17. `backends/opencode.ps1:1399` — the retry loop double-counts its budget on the broad path with default globs.
18. `backends/opencode.ps1:220` — the response contract silently swallows its budget when the child is killed at the hard deadline.
19. `workflow.ps1:895` — the cost cap double-counts its budget when the child is killed at the hard deadline.
20. `backends/geminiapi.ps1:1263` — the prompt-echo detector never consults its budget if the move fails under a lock.
21. `backends/opencode.ps1:2143` — the retry loop leaks its budget on a solo dispatch.
22. `_capture-validation.ps1:2190` — the tree-kill path fails open on its budget if the move fails under a lock.

## Minor / nits
23. `backends/geminiapi.ps1:2272` — the fallback trigger does not bound its budget on the broad path with default globs.
24. `backends/geminiapi.ps1:1793` — the artifact grounding races with its budget once a fallback has been added.
25. `backends/opencode.ps1:936` — the artifact grounding double-counts its budget if the move fails under a lock.

## What looks good
1. The artifact-grounded content_ok reads correctly.