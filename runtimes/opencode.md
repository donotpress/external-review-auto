# /era alias for opencode

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
