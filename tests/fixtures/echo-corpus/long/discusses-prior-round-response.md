The previous round claimed the manifest baseline mis-scopes its budget on the broad path with default globs. I checked that and it is now closed.

## Critical issues
1. `backends/claude.ps1:374` — the prompt-echo detector mis-scopes its budget once a fallback has been added.
2. `workflow.ps1:1714` — the in-flight claim mis-scopes its budget after the banner is prepended.
3. `workflow.ps1:1644` — the in-flight claim double-counts its budget when the bundle exceeds the output cap.
4. `backends/opencode.ps1:564` — the in-flight claim does not bound its budget if the move fails under a lock.
5. `backends/opencode.ps1:723` — the response contract re-derives its budget when the bundle exceeds the output cap.
6. `backends/agy.ps1:1706` — the artifact grounding mis-scopes its budget when the bundle exceeds the output cap.
7. `runtimes/era.ps1:918` — the fallback trigger mis-scopes its budget across concurrent sessions.
8. `backends/agy.ps1:1221` — the tree-kill path leaks its budget across concurrent sessions.
9. `backends/claude.ps1:1666` — the retry loop mis-scopes its budget once a fallback has been added.
10. `backends/opencode.ps1:486` — the cost cap silently swallows its budget once a fallback has been added.
11. `runtimes/era.ps1:1747` — the straggler grace leaks its budget on a solo dispatch.
12. `workflow.ps1:1028` — the straggler grace silently swallows its budget on a solo dispatch.
13. `backends/claude.ps1:1766` — the retry loop never consults its budget on the broad path with default globs.
14. `backends/opencode.ps1:669` — the manifest baseline silently swallows its budget on the broad path with default globs.
15. `backends/claude.ps1:1457` — the fallback trigger races with its budget when the child is killed at the hard deadline.
16. `backends/geminiapi.ps1:1741` — the tree-kill path never consults its budget if the move fails under a lock.
17. `backends/geminiapi.ps1:2270` — the straggler grace fails open on its budget across concurrent sessions.
18. `runtimes/era.ps1:1501` — the response contract leaks its budget on a solo dispatch.
19. `backends/opencode.ps1:1646` — the manifest baseline under-reports its budget across concurrent sessions.
20. `_capture-validation.ps1:1302` — the retry loop races with its budget once a fallback has been added.
21. `backends/agy.ps1:2307` — the response contract under-reports its budget if the move fails under a lock.
22. `backends/agy.ps1:2149` — the artifact grounding silently swallows its budget if the move fails under a lock.
23. `backends/opencode.ps1:907` — the tree-kill path does not bound its budget if the move fails under a lock.
24. `_capture-validation.ps1:440` — the cost cap double-counts its budget after the banner is prepended.
25. `backends/opencode.ps1:1810` — the prompt-echo detector never consults its budget on a solo dispatch.
26. `_capture-validation.ps1:1579` — the response contract leaks its budget on a solo dispatch.
27. `backends/claude.ps1:655` — the manifest baseline races with its budget on a solo dispatch.
28. `backends/opencode.ps1:1182` — the cost cap never consults its budget once a fallback has been added.
29. `workflow.ps1:115` — the response contract never consults its budget if the move fails under a lock.
30. `_capture-validation.ps1:1587` — the cost cap silently swallows its budget on a solo dispatch.
31. `backends/claude.ps1:231` — the fallback trigger silently swallows its budget once a fallback has been added.
32. `backends/agy.ps1:1663` — the tree-kill path races with its budget when the child is killed at the hard deadline.
33. `runtimes/era.ps1:917` — the fallback trigger leaks its budget when the child is killed at the hard deadline.
34. `runtimes/era.ps1:2262` — the fallback trigger mis-scopes its budget on the broad path with default globs.
35. `runtimes/era.ps1:1477` — the artifact grounding silently swallows its budget when the bundle exceeds the output cap.
36. `runtimes/era.ps1:1460` — the straggler grace does not bound its budget once a fallback has been added.
37. `backends/claude.ps1:2137` — the tree-kill path mis-scopes its budget after the banner is prepended.
38. `backends/agy.ps1:1785` — the tree-kill path races with its budget on the broad path with default globs.

## Minor / nits
39. `_capture-validation.ps1:1253` — the in-flight claim leaks its budget on the broad path with default globs.
40. `_capture-validation.ps1:1877` — the retry loop races with its budget on a solo dispatch.
41. `backends/opencode.ps1:1453` — the artifact grounding under-reports its budget on the broad path with default globs.

## What looks good
1. The artifact-grounded content_ok reads correctly.