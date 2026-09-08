# era findings from round `awc-audit` round-2, 2026-09-08

Reported by `ai-workspace-config-82` (Claude Code, WSL). Round ran from a staged
copy at `C:\Users\Joshua\AppData\Local\Temp\era-H2S3JR`, 146,503-token bundle,
4 seats requested, 3 usable. Everything below is MEASURED unless tagged.

Artifacts, all still on disk:
- `<stage>/.external-reviews/awc-audit/round-2-*`
- `C:\Users\Joshua\AppData\Local\Temp\opencode-stall-debug\exitfail-20260908-002423-679-pid75484-{context,stderr,stdout}.txt`
- driver log: `/tmp/claude-1000/.../scratchpad/era-run.log`

---

## 1. HIGHEST VALUE — `first-token sec` appears to be filled with the stall
threshold when no token ever arrived, which disarms the stall detector

From the forensic context file, verbatim:

    model            : opencode-go/deepseek-v4-flash
    variant          : high
    delivery         : read-tool
    bundle bytes     : 515721
    exit code        : -1
    wall clock sec   : 726.8
    effective budget : 1485s of 1800s
    stall threshold  : 1210.8s  (did NOT fire, or this throw would not be the one reporting)
    first-token sec  : 1211
    stdout bytes     : 0
    stderr bytes     : 1129

Three of those cannot all be true at once:

* `stdout bytes : 0` — no token was ever produced.
* `first-token sec : 1211` — asserts a token arrived at 1211s.
* `wall clock sec : 726.8` — the run ended 484s BEFORE that.

And `1211` is `ceil(1210.8)`, i.e. exactly the stall threshold. INFERRED (I
cannot see the code): when no first token is observed, the field is being
initialised to the threshold (or to `ceil` of it) rather than left unset, so the
stall comparison `first_token > threshold` evaluates "not a stall" by 0.2s and
the detector can never fire on the case it exists for. The seat then runs to
exit=-1 and reports as a generic failure.

This is a never-asked question recorded as a negative answer: "no token was
observed" is being written down as "a token arrived, late". Suggested shape —
keep the field UNSET/`null` when `stdout bytes == 0`, and make the stall check
treat unset as *stalled*, not as *not stalled*. Please verify the initialisation
before changing anything; my read is inferential.

Entry point for the throw: `backends/opencode.ps1:1440`
(`Invoke-OpencodeReview`), per the script stack trace in
`round-2-deepseek-flash-error.log`.

## 2. `Wall clock` in the run summary disagrees with the dispatcher's own elapsed lines

    [dispatch] 720s elapsed of 1830s budget; 3/4 done; still running: deepseek-flash
    [dispatch] Abandoned straggler 'deepseek-flash' after 300s grace: tree-killed its child process.
    Done. Wall clock: 119.7s | Tokens: 146503

Round start 00:12, last log write 00:24:24 — ~12 minutes. `119.7s` is off by ~6x
and is the number a reader takes away. It looks like it measures a sub-phase
(bundle? final segment?) while being labelled as the round. Either relabel it or
sum the dispatch window. A field whose name does not describe what it measures is
the defect class this round was auditing, and it is in era's own summary line.

## 3. read-tool delivery paged a 7,748-line bundle in ~800-line chunks, then died

From stderr: 11 `Read ... [offset=N]` calls walking 0 → 7668, plus a shell-out
(`(Get-Content -LiteralPath $f).Count` → 7748) to discover the length. The seat
consumed essentially the whole bundle and produced zero bytes. Worth asking
whether `read-tool` seats should get a size ceiling well below the 1,048,576-byte
limit era currently checks against — the delivery gate said "fits" and it did
not, in practice, at 515,721 bytes. The limit that passed is a byte limit; the
thing that broke is a *turn count*.

## 4. `-Doctor` reports ThreadJob `[MISS]` on PowerShell 7.6 — false negative

    [MISS] ThreadJob module
            fix: Install-Module -Name ThreadJob -Force -Scope CurrentUser
    NOT READY -- need: the [MISS] core prereq(s) above

Measured on this box:

    Get-Command Start-ThreadJob     -> AVAILABLE from module Microsoft.PowerShell.ThreadJob
    Get-Module -ListAvailable *ThreadJob* -> Microsoft.PowerShell.ThreadJob 2.2.0
    Start-ThreadJob { 2+2 }; Receive-Job -Wait -> 4

PS 7.4+ ships it renamed as `Microsoft.PowerShell.ThreadJob`. Doctor checks the
legacy name, so it prints NOT READY on a ready machine. Running the suggested fix
then fails:

    Install-Package: The following commands are already available on this system:
    'Start-ThreadJob'. This module 'ThreadJob' may override the existing commands.
    ... use -AllowClobber

Suggested: probe for the COMMAND (`Get-Command Start-ThreadJob`), not the module
name — that is the capability actually required, and it is name-agnostic.

## 5. era's own artifacts trip its dirty-tree refusal

First dispatch from a freshly staged, freshly committed repo was refused:

    [era] REFUSING TO DISPATCH - the working tree has uncommitted changes.
           dirty  : 2 path(s)
              ?? .external-reviews/
              ?? era-run.log

`.external-reviews/` is era's OWN output directory. A `-PreflightOnly` run
creates it, and the next real dispatch then refuses because of it. Cost me one
round-trip; on a metered seat it would cost nothing but it reads as a bug in the
user's repo when it is not. Suggested: exclude `.external-reviews/` from the
dirty check (it is era-authored and never part of the reviewed range), or write a
`.gitignore` into it on creation.

## 6. Minor: the UNC refusal is excellent — one addition

The `repo root is not on a Windows drive` refusal was clear, correct, cost
nothing, and its printed recipe worked verbatim first try. Best error message I
hit all session. One addition worth considering: the recipe's `cp --parents ...`
stages the files but not a `.gitignore`, which is what led directly to finding 5
above. Adding `printf '.external-reviews/\n' > .gitignore` to the recipe closes
the loop.

## What went right, for the ledger

3 of 4 seats delivered usable reviews on a 146K bundle. The opus seat's review
was materially better than the audit it was reviewing — it found four confirmed
defects the local session had missed, including one (`exec ./run.sh` destroying a
cleanup trap) that superseded two sessions' worth of prior analysis. The panel
paid for itself on that single finding.

---

## EIGHTH ITEM, added 2026-09-08 — a feature, not a defect

era ALREADY WRITES AN EXPOSURE RECEIPT AND NOTHING SURFACES IT.
`round-N-manifest.json` carries, MEASURED from a real round:

    files (each with sha256), sources, source_hashes, reviewers_requested,
    git_head, git_branch, git_clean, git_dirty, timestamp, topic_slug, round

That is a precise record of what source code left this machine, to whom, from
which commit, and whether the tree was clean when it went. Today the only way to
read it is to already know the path. An `era.ps1 -Command exposure` - listing
what has been sent, to which vendors, when - would make it usable. qmax-code
advertises exactly this as a headline feature; era already has the data and just
does not surface it. Same shape as `guard.log` in ai-workspace-config: written,
never read.

## CONSTRAINTS on the seven fixes (authorised 2026-09-08, operator asleep)

- This skill is shared by every agent on this box. Keep every change backward
  compatible and do not break a round in flight.
- Gate on era's own suite (1218/0 as last reported); land nothing that reduces it.
- Do not touch any repo under `/mnt/c/Users/Joshua/Servers/`.
- Tag every claim MEASURED with its command, or INFERRED with what from.
- Where something is ambiguous, write it down rather than guessing - nobody is
  awake to ask.

## AND A NINTH, found while delivering the eighth

`tui-workspace say` reports success for a message that never arrived, and it
happened THREE times tonight against three different TUI states: an agent that
had just started (EQM-cmdc), one that had just finished and whose TUI was in a
completed-build view (era-oc, cleared by sending Escape), and one that was
actively mid-turn (era-oc again). The common cause is not length - MEASURED,
200/500/1000/1500/2000/2500/2900/3500 characters all land on an idle pane. It is
that A TUI THAT IS NOT IDLE DOES NOT TAKE INPUT, and `send-keys` exits 0
regardless.

A fix that verifies the paste actually appears before pressing Enter is written
on branch `ws-82j` of ai-workspace-config, unlanded. Its 2-second bound is too
short: it refused a long paste that then arrived anyway, leaving the text
unsubmitted in the input box. The bound should scale with text length, and the
message should say "the agent is busy" rather than "may still be starting",
because busy is the case that actually happens.
