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

## SETTLED: agy DOES write stdout under era's own spawn

`backends/agy.ps1:4` and `:10` state that "agy --print does NOT write stdout —
responses must be retrieved from the session transcript". **That is stale.**

The first version of this document reported stdout working only from a bash
spawn on Linux and explicitly refused to act on it, because the adapter's claim
is about a different condition: era's Windows `.NET ProcessStartInfo` spawn.
**That condition has now been measured directly.**

The probe replicates the adapter's spawn exactly — `UseShellExecute=$false`,
`CreateNoWindow=$true`, all three streams redirected, stdin closed immediately,
the same agent env-var scrub, and the same `CopyToAsync` async drain to a file.

**Positive control first**, because a null result is worthless from an
instrument that captures nothing:

| run | exit | stdout | stderr |
|---|---|---|---|
| control — `cmd.exe /c echo CONTROL-STDOUT-OK` | 0 | **19 B**, correct | 0 |
| subject — `agy --print` (trivial prompt) | 0 | **20 B** `DOTNET-STDOUT-PROBE` | 0 |
| subject — `agy --print` (**full agentic review**) | 0 | **1,458 B / 21 lines** | 0 |

The agentic run is the one that matters: a 26,304-byte, 401-file bundle named in
the prompt (era's real delivery shape), requiring an actual file-read tool call.
Stdout carried the **complete** review — the canary value only obtainable by
opening the file, the file count exactly right at 401, and the defect correctly
named. The transcript was written too (59,388 bytes), so this is not
stdout *instead of* the transcript; both are populated.

### What this does and does not license

**It does NOT license deleting the transcript polling**, and the reason is not
caution — it is that the poll loop has a **second job the comment does not
mention**. Besides capture, it is the LIVENESS signal: it watches transcript
mtime to set `$activitySeen` / `$lastActivityTime`, which drive the Tier-1
"nothing ever started" and Tier-2 "went quiet" stall detectors and the straggler
abandonment.

`CopyToAsync` yields nothing until the process exits, so stdout **cannot**
provide liveness. Delete the polling and era loses stall detection on this seat
entirely — a hung agy would burn the full bundle-scaled timeout instead of being
abandoned early.

So the accurate statement is narrower than "the machinery is dead weight":

* the **capture** path could take stdout as the primary source and keep the
  transcript scrape as fallback (the run-id matcher exists because transcripts
  are shared and ambiguous — a problem stdout simply does not have);
* the **liveness** path must stay regardless.

### Both remaining unknowns are now measured too

The first version of this section listed large responses and concurrency as
unmeasured and load-bearing. Both were measured 2026-09-07, same harness.

**Large response — no truncation.** A prompt forcing 400 ordered output lines
from a 26,091-byte / 400-file bundle:

```
EXIT=0   STDOUT_BYTES=20,091
matching module lines = 400 (expected 400)
has m0: True   has m399: True
END-OF-REVIEW-3TQ9ZK present        <-- truncation detector
transcript longest content = 20,090 chars
stdout - transcript = 1 char        (a trailing newline)
```

The END marker is the instrument: had stdout been cut short, the tail would be
missing while the transcript kept it. Instead stdout and the transcript agree to
within one newline at 20 KB, and every one of the 400 lines is present in order.

**Concurrency — no cross-contamination.** Four seats started as `Start-ThreadJob`
in ONE pwsh process, which is exactly how the panel runs, each told to emit a
different canary:

```
seat 1 pid=71552 exit=0 bytes=15 own-canary=True foreign-canaries=none
seat 2 pid=72596 exit=0 bytes=15 own-canary=True foreign-canaries=none
seat 3 pid=64412 exit=0 bytes=17 own-canary=True foreign-canaries=none
seat 4 pid=63568 exit=0 bytes=15 own-canary=True foreign-canaries=none
distinct PIDs = 4 (expect 4)
```

Every seat received its own canary and **no seat saw another's**. Each redirected
pipe belongs to one process, so the shared-and-ambiguous problem that forced the
run-id matcher onto the transcript path does not exist on stdout.

### Where that leaves the adapter

The capture path can take **stdout as primary**, with the transcript scrape kept
as fallback. Nothing above licenses removing the transcript machinery outright,
for two separate reasons:

* **Liveness** (above) — `CopyToAsync` yields nothing until exit, so the stall
  detectors still need transcript mtime.
* **The kill path is untested.** When era kills agy at its hard deadline, stdout
  is whatever had been flushed, and the transcript may hold more of a partial
  answer. Every measurement here is of a process that exited on its own. An
  implementer should measure the killed case before deciding what the fallback
  owes on that path.

**OWNER: whoever attempts the simplification.** `backends/agy.ps1` is still
unchanged; this document settles facts and hands over a scoped follow-up.
