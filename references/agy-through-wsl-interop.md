# agy survives WSL interop — the Linux-native question is settled

**Measured 2026-09-06** from a Linux (WSL2 Ubuntu) bash session on this box,
against `agy.exe` 1.1.27. Every command and its output is reproduced below.

## The question this answers

era is Windows-hosted PowerShell. A Windows process cannot hold a UNC path as
its working directory, so era refuses to bundle any repo outside a Windows drive
(`runtimes/era.ps1:1881`). A Linux-native era would erase that limitation rather
than document it — era has only two platform gates (`runtimes/era.ps1:430`,
`workflow.ps1:1365`) and both already handle the non-Windows case.

**agy was the presumed blocker.** It is the gemini seat, a quarter of the default
panel, and the only backend with no Linux build. If a full review flow could not
be driven from Linux, the answer was "stay on Windows" and the question was
closed.

**It is not the blocker.** A full review flow, in era's exact production shape,
completed against a repo in `/home` — driven from a Linux cwd, reading the bundle
over a UNC path.

## What was measured

### 1. agy runs from Linux at all

`/etc/wsl.conf` sets `interop.appendWindowsPath=false`, so agy is not on the WSL
PATH; it is reached by absolute path.

```
$ AGY=/mnt/c/Users/Joshua/AppData/Local/agy/bin/agy.exe
$ "$AGY" --version          → 1.1.27          exit 0
$ "$AGY" --help             → full usage      exit 0
$ "$AGY" models             → 14 models       exit 0
```

### 2. A Windows process launched from Linux gets a UNC cwd it cannot hold

This is the fact era's refusal rests on, re-measured here with a control that
returns the other answer:

```
$ ( cd /home/joshua/era-interop-probe && /mnt/c/Windows/System32/cmd.exe /c cd )
'\\wsl.localhost\Ubuntu\home\joshua\era-interop-probe'
CMD.EXE was started with the above path as the current directory.
UNC paths are not supported.  Defaulting to Windows directory.
C:\Windows

$ ( cd /mnt/c/Users/Joshua && /mnt/c/Windows/System32/cmd.exe /c cd )   # control
C:\Users\Joshua
```

Confirms M11 in `docs/specs/2026-09-06-tmux-tui-transport-design.md`, measured
independently by an earlier session.

### 3. But a Windows process CAN read UNC *files*

The limitation is on the working directory, not on file access. This is the
distinction the whole question turns on, and it had not been separated before:

```
$ cmd.exe /c type '\\wsl.localhost\Ubuntu\home\joshua\era-interop-probe\src\widget.py'
# era interop probe fixture
SECRET_CANARY = "CANARY-9K4T-LINUX-HOME"
...                                              exit 0

$ cmd.exe /c type '...\src\nope.py'              # negative control
The system cannot find the file specified.       exit 1
```

### 4. agy completes a real review of a Linux-home repo — era's production shape

era's agy adapter does **not** use `--add-dir`. It names the bundle path inside
the prompt text (`backends/agy.ps1:399`, "The review bundle is the file at
$BundlePath") and lets agy's own file-read tool open it. That exact shape was
run against a 22,522-byte, 301-file repomix bundle at a UNC path, with the
process launched from a Linux cwd:

```
$ ( cd /home/joshua/era-interop-probe && "$AGY" --dangerously-skip-permissions \
      --model gemini-3.8-flash-high --print-timeout 240s --print \
      "[Run ID: PROBE-7f3a] The review bundle is the file at \
       \\wsl.localhost\Ubuntu\home\joshua\era-interop-probe\bundle.xml. Read it, then ..." )

CANARY=CANARY-9K4T-LINUX-HOME
FILES=301
BUG=The default branch divides price by zero, raising a ZeroDivisionError
    when tier is neither gold nor silver.

real 0m20.444s     exit 0
```

`FILES=301` is exactly right (1 fixture + 300 padding files), so the whole
bundle was read, not sampled. The canary is a value obtainable only by opening
the Linux-native file. The bug is real and was found, so this is a review, not
just a file read.

### 5. The probe can return the other answer

The instrument check that the rest of this document depends on — pointed at a
bundle that does not exist, the same prompt does not confabulate:

```
CANARY=UNREADABLE
The file at `\\wsl.localhost\...\bundle-does-not-exist.xml` could not be opened
because it does not exist.
```

## Conclusion

**agy does not block a Linux-native era.** It needs no working directory: it is
given an absolute path and opens it, and UNC file access works. The one thing
that genuinely requires a real (non-UNC) cwd is the **bundling** step — repomix
and git, run by era itself — and on a Linux-native era that step is native and
the problem does not arise.

So the current refusal is correctly diagnosed but narrower than it looks. It is
a *bundling* limitation, not a *delivery* one. `runtimes/era.ps1:1881` says "era
runs as WINDOWS pwsh, and a Windows process cannot hold a UNC path as its working
directory" — that is exactly right about repomix, and it does not constrain agy.

**Per the handoff, this settles the fact and stops there. No migration is started
on the strength of this probe.** What it establishes is only that the
architectural objection to a Linux-native era is not agy.

### "Two platform gates" is true, and is not the same as "no Windows coupling"

Verified 2026-09-06: there are exactly **two** `$IsWindows`-style gates in
`runtimes/`, `workflow.ps1` and `backends/` — `runtimes/era.ps1:430` and
`workflow.ps1:1365` — and both already handle the non-Windows branch.

That number is easy to over-read. The same sweep finds **50 `.exe` references**
in production code, which are coupling whether or not they sit behind a gate:

| binary | refs | on a Linux-native era |
|---|---|---|
| `wsl.exe` | 33 | mostly **disappears** — the cmdc adapter exists to cross a boundary that would no longer be there |
| `claude.exe`, `opencode.exe` | 6 | become the Linux builds; both are already on the WSL login PATH |
| `pwsh.exe` | 3 | becomes the Linux PowerShell 7 build |
| `where.exe`, `node.exe`, `cmd.exe` | 6 | need Linux equivalents |
| `explorer.exe`, `WindowsTerminal.exe` | 2 | cosmetic (opening a folder / a window) |

`runtimes/era.ps1` is also the one file carrying `C:\`/`AppData` literals.

So the honest summary is: the *hard architectural* objection (a Windows-only
backend that cannot be driven from Linux) **does not exist**, and what remains is
a real but ordinary porting job — plus packaging, since PowerShell 7 has Linux
builds and none is installed here (`/home/joshua/.local/bin/pwsh` is a shim that
execs `pwsh.exe`). Nothing here estimates that job's size; it was not measured.

## An incidental finding, flagged not acted on

`backends/agy.ps1:4` states "agy --print does NOT write stdout — responses must
be retrieved from the session transcript", and the adapter carries a transcript
poller and run-id matcher to work around it.

**Measured: agy 1.1.27 driven from Linux bash writes the response to stdout.**
Stream-separated to be sure:

```
$ "$AGY" ... --print "Reply with exactly the token STDOUT-SEPARATION-OK ..." \
      1>out.txt 2>err.txt
exit 0
STDOUT: 21 bytes  → "STDOUT-SEPARATION-OK"
STDERR: 0 bytes
```

All four print-mode runs in this document returned their answer on stdout.

**This is not yet a contradiction of the adapter.** What is measured is that
stdout carries the response *when agy is spawned from bash on Linux*. It was
**not** measured whether stdout is empty under era's actual spawn (Windows .NET
`ProcessStartInfo`, redirected handles, no console) — which is the condition the
adapter's comment describes, and which may differ, or may be version drift since
the comment was written. Anyone who wants to simplify that adapter must measure
the Windows-.NET case first; the transcript poller stays until then.
