# /era alias for opencode

## Workflow Rules (required reading for driving models)

### Quick Reference

0. Locate skill root -> 1. Resolve input -> 2. Select mode -> 3. Curate files ->
4. Write prompt -> 5. Dispatch `era.ps1` -> 6. Wait -> 7. Triage ->
8. Converged (0 criticals)? Done. Otherwise fix, write round N+1 prompt, loop back to step 3.

**Terminal condition:** 0 critical issues. **Always bundle source code.**

### Three rules that prevent runaway loops

**1. Reuse the same topic slug across all rounds.**
All rounds of a review go into one topic directory. Pass the same `-TopicSlug`
every time. era.ps1 increments the round number automatically (`round-1`,
`round-2`, ...). Never create `my-spec-r2`, `my-spec-r3` as separate slugs —
that defeats round tracking, `{{PREVIOUS_ROUND}}` auto-substitution, and
`--diff` delta bundling.

**2. Amend the existing spec — don't create new files per round.**
When the reviewer finds issues, fix them in the *same* spec file. A new file
per round means the reviewer sees a fresh document each time, finds new issues
in the new content, and the loop never converges. One spec file gets
progressively cleaner across rounds.

**3. Triage before incorporating — don't auto-accept everything.**
Not every reviewer finding should be acted on. Reject findings that add
complexity beyond the original scope. Push back in the next round's prompt
when a finding is wrong. Auto-incorporating everything is the #1 cause of
scope expansion loops. Validate at least one empirical claim per round.

### Convergence check

After each round, check the reviewer's response:
- **0 critical issues** -> converged, report to user
- **Criticals present** -> fix, write round N+1 prompt with
  `{{PREVIOUS_ROUND}}` or a verbatim summary, dispatch again
- **Round 5+ with growing response size** -> likely diverging; stop and
  reassess rather than continuing the loop

---

## Setup

opencode supports user-defined commands via `~/.config/opencode/opencode.json`. To bind `/era` to this skill:

1. Open `~/.config/opencode/opencode.json` (create if missing).
2. Merge this snippet into the top-level object:

   ```jsonc
   {
     "command": {
       "era": {
         "type": "skill",
         "skill": "external-review-auto",
         "description": "Short alias for /external-review-auto"
       }
     }
   }
   ```

3. Quit and restart opencode.
4. Verify with `/era` (no args) — should resolve to the same workflow as `/external-review-auto`.

**Notes:**
- This is a one-time setup; the skill does not auto-write `opencode.json`.
- If `opencode.json` already has a `command` object, merge the `era` key in rather than replacing.
- Same workflow, same artifacts, same costs as `/external-review-auto`.
