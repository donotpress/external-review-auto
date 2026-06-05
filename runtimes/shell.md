# Standalone shell entry: era

The skill root is at `~/.claude/skills/external-review-auto`. Two install options. Pick one.

## Option 1: Add the runtimes/ folder to PATH

**PowerShell (Windows / pwsh):**
```powershell
$path = Join-Path $HOME '.claude/skills/external-review-auto/runtimes'
[Environment]::SetEnvironmentVariable('Path', "$env:Path;$path", 'User')
# Restart your shell.
```

**Bash / Zsh (macOS / Linux):**
```bash
export PATH="$PATH:$HOME/.claude/skills/external-review-auto/runtimes"
# Add to ~/.bashrc or ~/.zshrc for permanence.
```

Then invoke directly: `era.ps1 -TopicSlug my-spec -Reviewer gemini,opus`.

## Option 2: Drop a one-line shim into a folder already on PATH

**Windows (.cmd shim):**
Create `era.cmd` on your `$PATH`:
```bat
@pwsh -File "%USERPROFILE%\.claude\skills\external-review-auto\runtimes\era.ps1" %*
```

**macOS / Linux (bash shim):**
Create an executable `era` script on your `$PATH`:
```bash
#!/usr/bin/env bash
pwsh -File "$HOME/.claude/skills/external-review-auto/runtimes/era.ps1" "$@"
```

Then invoke: `era -TopicSlug my-spec -Reviewer gemini`.

## Verify

```powershell
era -TopicSlug test-smoke
# Expected: workflow runs, writes .external-reviews/test-smoke/round-1-*
```
