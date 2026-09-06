# `wsl.exe` does not exec directly — it hands your arguments to `bash -c`

**Measured 2026-09-06.** One boundary fact that produced four unrelated-looking
bugs in a single afternoon. Recorded here because the symptoms never point at the
cause, and because a peer session independently spent a night on the same class.

## The fact

```
wsl.exe -d Ubuntu -- some-cmd arg1 arg2
```
does **not** exec `some-cmd`. The arguments are handed to `bash -c`, so every one
of them is shell-parsed before the target program sees it. The giveaway is an
error naming a shell you never invoked:

```
/bin/bash: -c: line 1: unexpected EOF while looking for matching `''
```

## The four symptoms

| What you see | What is happening |
|---|---|
| `wslpath -u 'C:\Users\Joshua\AppData'` → `C:UsersJoshuaAppData`, exit 1 | bash ate the backslashes as escapes. Forward slashes survive |
| `tmux list-windows -F '#{window_name}'` → `-F expects an argument` | bash read `#` as a **comment** and dropped the rest of the line |
| A command passed as `sh -c 'a; b'` dies instantly | it is re-parsed by a *second* shell |
| An argument containing `"$@"` arrives empty | .NET's `ProcessStartInfo` adds its **own** Windows-style quoting on top of whatever you added |

The last one is why escaping is not the fix. Single-quoting each argument solves
the first two and then breaks on the fourth, because two independent quoting
layers are composing. Adding a third layer is a queue of future bugs.

## The fix that holds

**Write a script file; let only its path cross the boundary.**

```powershell
[System.IO.File]::WriteAllText($winPath, ($body -replace "`r`n", "`n"))  # LF only
wsl.exe -d $distro -- bash /mnt/c/.../script.sh
```

Then there is exactly one shell, on the Linux side, whose rules you know, and you
build the command text with a quoting helper you control. `backends/tmux.ps1`
does this; see `Invoke-EraTmuxScript`.

Two details that bite:

- **LF endings.** bash rejects a script with CRLF lines (`\r: command not found`),
  and PowerShell's `Set-Content` supplies CRLF on Windows.
- **Do not call `wslpath` to translate the path you need for the call** — that is
  a chicken-and-egg across the same broken boundary. `C:\X\Y` → `/mnt/c/X/Y` is
  deterministic; compute it locally and **verify it once** with a `test -d`, so a
  wrong mapping fails loudly instead of pointing a process at nothing.

## A second, independent boundary fact

`wsl.exe` runs a **non-login, non-interactive** bash. Its PATH is the system
default only:

```
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/usr/lib/wsl/lib
```

Measured consequences on this box: `command -v opencode`, `command -v claude` and
`command -v cmdc` all return **nothing**, while a login shell finds all three
under `~/.nvm/...` and `~/.local/bin`. And `tmux` resolves to `/usr/bin/tmux`
(3.6), not the `~/.local/bin/tmux` (3.7c) an interactive shell uses — so a
version-dependent flag can work when you test it by hand and fail in production.

Resolving a program's absolute path is **not sufficient**: `cmdc` is
`#!/usr/bin/env node`, and `node` is not on that PATH either, so it fails on the
interpreter after you have carefully found the script. Run the target under
`bash -l` when it may be an interpreted launcher.
