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
2. Merge this snippet into the top-level `"command"` object:

   ```jsonc
   {
     "command": {
       "era": {
         "template": "You are invoking the /external-review-auto skill (alias /era). The user's input is free-form English; you must parse it into typed `era.ps1` flags before invoking. DO NOT pass arguments through verbatim — `era.ps1` enforces typed parameter binding and will error on natural language.\n\nResolver rules:\n\n1. Strip filler words: `use`, `using`, `with`, `via`, `the`, `please`, `model`, `reviewer`, `try`, `run`.\n2. Match the remaining tokens against this table:\n   - `gemini` / `flash` / `gemini 3.5 flash` → `-Reviewer gemini`\n   - `gemini 3.1 pro` → `-Reviewer gemini-pro-high`\n   - `gemini 3.1 pro low` / `… budget` → `-Reviewer gemini-pro-low`\n   - `opus` / `claude opus` / bare `claude` → `-Reviewer opus`\n   - `sonnet` → `-Reviewer sonnet`\n   - `haiku` → `-Reviewer haiku`\n   - `deepseek` (no variant) → `-Reviewer deepseek` (default `opencode-go/deepseek-v4-pro`)\n   - `deepseek v4 flash` → `-Reviewer deepseek -Model 'opencode-go/deepseek-v4-flash'`\n   - `deepseek v4 pro` → `-Reviewer deepseek -Model 'opencode-go/deepseek-v4-pro'`\n   - `minimax` / `minimax m2.7` → `-Reviewer minimax -Model 'minimax/MiniMax-M2.7'`\n   - `gemini api` / `gemini rest` → `-Reviewer gemini-api`\n   - `opus api` / `claude direct` → `-Reviewer opus-api`\n3. Defaults when ambiguous:\n   - Highest tier wins: bare `pro`/`flash` → `-high`\n   - Latest minor wins: `deepseek v4` → latest v4; `minimax` → M2.7 latest\n   - Family alone → top model: `claude` → opus; `gemini` → 3.5 flash (default preset)\n   - CLI preset preferred over `-api` variant unless user says api/rest/direct\n4. Topic-slug detection: if first non-filler word matches NONE of the reviewer keywords (gemini, opus, sonnet, haiku, claude, deepseek, minimax, flash, pro, api, reasoner), treat it as `-TopicSlug` and use the default reviewer. Use the word `use` as an explicit splitter: `/era <topic> use <reviewer-spec>`.\n5. If the user already passed typed flags (e.g., `--reviewer X --model Y`), forward them verbatim — no re-parsing.\n6. If unsure, ask one short clarifying question; do not guess.\n\nBefore dispatching, echo your resolution to the user in one line: `Resolved /era <input> → era.ps1 -Reviewer X [-Model Y]. Dispatching.`\n\nDispatch: invoke `pwsh ~/.claude/skills/external-review-auto/runtimes/era.ps1 [-TopicSlug <slug>] -Reviewer <preset> [-Model <override>] -Force`. The full skill documentation is at `~/.claude/skills/era/SKILL.md` and `~/.claude/skills/external-review-auto/SKILL.md`.\n\nAfter dispatch:\n\n7. **Convergence loop (mandatory):** Read the response. Triage each finding — reject any that add complexity beyond scope. Fix accepted criticals in the EXISTING spec file (never create new spec files per round). Then dispatch again with the SAME -TopicSlug (era.ps1 increments the round number). Repeat until the reviewer returns 0 critical issues. Do NOT ask the user whether to continue — the loop is the default behavior.\n8. **Terminal condition:** 0 critical issues = converged. Report the final state to the user.\n\nUser input follows:",
         "description": "Run external review (auto-resolves model from natural language: 'use gemini 3.1 pro', 'deepseek v4 flash', etc.)"
       }
     }
   }
   ```

3. Quit and restart opencode.
4. Verify with `/era` (no args) — should auto-detect a spec, dispatch, and loop until 0 criticals.

**Notes:**
- This is a one-time setup; the skill does not auto-write `opencode.json`.
- If `opencode.json` already has a `command` object, merge the `era` key in rather than replacing.
- The `template` field contains the full resolver rules AND convergence loop — opencode does not load SKILL.md natively, so all workflow guidance must be inline here.
- Same workflow, same artifacts, same costs as `/external-review-auto`.
