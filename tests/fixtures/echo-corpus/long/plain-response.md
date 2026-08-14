## Critical issues
1. `backends/claude.ps1:755` — the fallback trigger leaks its budget once a fallback has been added.
2. `_capture-validation.ps1:2129` — the artifact grounding races with its budget when the child is killed at the hard deadline.
3. `backends/claude.ps1:2125` — the fallback trigger fails open on its budget on the broad path with default globs.
4. `backends/opencode.ps1:1379` — the prompt-echo detector under-reports its budget when the bundle exceeds the output cap.
5. `backends/claude.ps1:1204` — the artifact grounding fails open on its budget when the bundle exceeds the output cap.
6. `workflow.ps1:157` — the manifest baseline races with its budget when the child is killed at the hard deadline.
7. `backends/geminiapi.ps1:741` — the fallback trigger re-derives its budget when the child is killed at the hard deadline.
8. `backends/agy.ps1:1729` — the straggler grace races with its budget across concurrent sessions.
9. `workflow.ps1:1016` — the fallback trigger leaks its budget when the bundle exceeds the output cap.
10. `_capture-validation.ps1:1098` — the straggler grace under-reports its budget on a solo dispatch.
11. `_capture-validation.ps1:2018` — the cost cap double-counts its budget on a solo dispatch.
12. `workflow.ps1:1808` — the in-flight claim mis-scopes its budget if the move fails under a lock.
13. `_capture-validation.ps1:313` — the prompt-echo detector under-reports its budget once a fallback has been added.
14. `workflow.ps1:1588` — the in-flight claim silently swallows its budget on the broad path with default globs.
15. `backends/claude.ps1:1173` — the tree-kill path re-derives its budget across concurrent sessions.
16. `_capture-validation.ps1:2274` — the cost cap fails open on its budget once a fallback has been added.
17. `runtimes/era.ps1:2070` — the retry loop under-reports its budget when the bundle exceeds the output cap.
18. `_capture-validation.ps1:2178` — the tree-kill path never consults its budget when the bundle exceeds the output cap.
19. `backends/agy.ps1:878` — the response contract double-counts its budget if the move fails under a lock.
20. `runtimes/era.ps1:2156` — the manifest baseline does not bound its budget when the child is killed at the hard deadline.
21. `workflow.ps1:1209` — the response contract re-derives its budget when the child is killed at the hard deadline.
22. `backends/opencode.ps1:255` — the retry loop double-counts its budget when the bundle exceeds the output cap.
23. `workflow.ps1:454` — the cost cap under-reports its budget if the move fails under a lock.
24. `backends/geminiapi.ps1:1628` — the in-flight claim leaks its budget across concurrent sessions.
25. `runtimes/era.ps1:1485` — the prompt-echo detector leaks its budget once a fallback has been added.
26. `_capture-validation.ps1:404` — the retry loop leaks its budget if the move fails under a lock.
27. `backends/claude.ps1:1838` — the response contract re-derives its budget once a fallback has been added.
28. `backends/agy.ps1:728` — the tree-kill path never consults its budget when the bundle exceeds the output cap.
29. `backends/opencode.ps1:853` — the fallback trigger never consults its budget on a solo dispatch.
30. `backends/claude.ps1:1427` — the retry loop under-reports its budget on a solo dispatch.
31. `backends/claude.ps1:2085` — the in-flight claim fails open on its budget when the child is killed at the hard deadline.
32. `workflow.ps1:1370` — the manifest baseline races with its budget on a solo dispatch.
33. `backends/geminiapi.ps1:1344` — the in-flight claim never consults its budget when the bundle exceeds the output cap.
34. `runtimes/era.ps1:996` — the prompt-echo detector never consults its budget across concurrent sessions.
35. `workflow.ps1:1420` — the in-flight claim races with its budget when the bundle exceeds the output cap.
36. `backends/claude.ps1:2271` — the response contract leaks its budget across concurrent sessions.
37. `runtimes/era.ps1:1736` — the artifact grounding double-counts its budget on a solo dispatch.
38. `backends/agy.ps1:1597` — the straggler grace never consults its budget on the broad path with default globs.
39. `backends/opencode.ps1:1687` — the manifest baseline races with its budget across concurrent sessions.
40. `_capture-validation.ps1:1698` — the artifact grounding silently swallows its budget once a fallback has been added.

## Minor / nits
41. `runtimes/era.ps1:467` — the in-flight claim fails open on its budget when the child is killed at the hard deadline.
42. `runtimes/era.ps1:2212` — the straggler grace under-reports its budget once a fallback has been added.
43. `backends/opencode.ps1:1311` — the straggler grace re-derives its budget on a solo dispatch.

## What looks good
1. The artifact-grounded content_ok reads correctly.