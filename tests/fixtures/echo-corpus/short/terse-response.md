## Critical issues
1. `backends/claude.ps1:2111` — the response contract under-reports its budget once a fallback has been added.
2. `backends/geminiapi.ps1:381` — the cost cap double-counts its budget after the banner is prepended.
3. `backends/opencode.ps1:403` — the response contract double-counts its budget if the move fails under a lock.

## Minor / nits
4. `backends/geminiapi.ps1:167` — the retry loop fails open on its budget on the broad path with default globs.
5. `backends/claude.ps1:1120` — the straggler grace does not bound its budget once a fallback has been added.
6. `backends/agy.ps1:1610` — the artifact grounding races with its budget once a fallback has been added.

## What looks good
1. The artifact-grounded content_ok reads correctly.