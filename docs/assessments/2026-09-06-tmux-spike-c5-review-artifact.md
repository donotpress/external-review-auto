ERA-BUNDLE-TAIL: docs/specs/2026-09-06-model-drift-detection-design.md
## Critical issues (must fix before implementation)
1. docs/specs/2026-09-06-model-drift-detection-design.md:213 — `variant-undeclared` has no backend scope. §5 says agy variants are `n/a (tier is in the id)` and only opencode variants are `compared`, but §6 does not say the finding applies only where §5 `variants` is `compared`. A literal implementer flags every agy preset. — Add "applies only where §5 variants = compared (opencode only in v1)".
2. docs/specs/2026-09-06-model-drift-detection-design.md:350-351 — §9 acceptance ("every currently active preset resolving") is unscoped. Claude presets cannot resolve against any enumeration by construction (§7:296-298) and cmdc is unconsumed; read literally, migration acceptance is impossible. — Scope to presets on backends with `probe? = yes` and `consumed? = yes`, and state what "resolving" means (id present in fresh capture; variant check for opencode).

## Important issues (should fix)
1. docs/specs/2026-09-06-model-drift-detection-design.md:81 vs :93,:101,:117,:137,:167 — "four units" but five numbered subsections (4.1–4.5). — Fix the count to five or fold Reporter explicitly.
2. docs/specs/2026-09-06-model-drift-detection-design.md:157-165 + :212 — With `notObserved` cut, a preset added after the last capture is absent from `models` and reports as `model-withdrawn` (error in default panel) even when the model exists. Naming `_captured` in the message is honest but the severity still fires on a legitimate add. — Phrase the finding as "absent from snapshot captured <date>" (not "withdrawn") and add the workflow rule "refresh when adding a preset".
3. docs/specs/2026-09-06-model-drift-detection-design.md:283-286 vs :108-111 — §7 still describes opencode JSON as carrying `status`/`cost`/`limit`, which §4.2 explicitly dropped from the parse shape. A literal implementer re-collects exactly what was cut. — Trim §7 to the parsed fields (ids, display, variants).
4. docs/specs/2026-09-06-model-drift-detection-design.md:83-84 — "only §4.1 touches the outside world" is false: §4.4 runs fetch, writes snapshots, and prints. — Rephrase to "of the pure units, only ..." or list §4.4 as I/O.

## Minor / nits
1. docs/specs/2026-09-06-model-drift-detection-design.md:169-172 — "every backend whose coverage is `unmeasured`" conflates field-level `unmeasured` with backend-level `probe? = no`. — Use the finding names (`backend-unmeasurable` / `backend-unconsumed`).
2. (none further — disposition tables are declared history, not contradictions, per instructions.)

## Verdict
NOT READY — fix the two one-sentence scope gaps (§6 variant-undeclared, §9 acceptance) and the unit count, then build; the subtraction itself held.

## Open questions for the author
1. Subtraction check: absence is now key-absence plus a `_captured` date in the message — do you accept false-positive `model-withdrawn` on post-capture preset adds until the next refresh?
2. §4.4 sufficiency: a dead capture pipeline stays green offline until `MaxSnapshotAgeDays` trips unless someone runs refresh — is refresh on a mandated cadence (CI schedule?), or is the 30-day bound the accepted detection latency? (Unverified against any scheduler config — none in bundle.)
3. Cut candidate: cmdc snapshotting in v1 is `consumed? = no` with zero findings reading it — keep as seed data or defer until a cmdc backend exists? Nothing else left looks over-built.
4. Snapshot filenames, directory layout, and the preset→backend mapping needed by the comparator and completeness test depend on `backends/_registry.json` and `runtimes/_era-defaults.ps1`, which are not in the bundle — marked unverified; confirm the implementer has them.
ERA-CANARY-e36c7e99f3940342
