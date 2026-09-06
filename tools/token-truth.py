#!/usr/bin/env python3
"""Ground-truth vendor-side token usage for era seats.

WHY THIS EXISTS. era's own numbers cannot compare two transports. Input cost is
derived from era's OWN repomix token count (workflow.ps1:2957,3007) and output
from ceil(chars/4) in each adapter -- the SAME estimator on both arms of an A/B,
so a comparison built on era's metadata measures the estimator, not the
transport. That is the vacuity class this repo keeps finding in its own probes.

So usage is read from the vendors' own records instead:
  * opencode  -> opencode.db, `session` table (tokens_input/output/reasoning/cache, cost)
  * claude    -> ~/.claude/projects/<mangled-cwd>/<uuid>.jsonl, per-turn `usage`

TWO DATABASES, NOT ONE. era spawns the WINDOWS opencode, which stores under
C:/Users/Joshua/.local/share/opencode. A tmux-transported seat would run the WSL
opencode, which stores under /home/joshua/.local/share/opencode. A reader that
knows only one would report zero for one arm of the A/B and look clean doing it.
Both are searched, and which one answered is reported.

ATTRIBUTION IS NEVER GUESSED. A seat is matched to a session by
(working directory, model id, time window). Zero matches is reported as
`unmatched` and more than one as `ambiguous` -- never silently collapsed to a
number. An ambiguous row is not evidence.

The db is opened read-only and IS NOT COPIED: the Windows one is 5.2 GB.
"""
import argparse, datetime as dt, glob, json, os, sqlite3, sys

OPENCODE_DBS = [
    ("windows", "/mnt/c/Users/Joshua/.local/share/opencode/opencode.db"),
    ("wsl",     os.path.expanduser("~/.local/share/opencode/opencode.db")),
]
CLAUDE_PROJECTS = os.path.expanduser("~/.claude/projects")


def _model_id(raw):
    if raw and str(raw).startswith("{"):
        try:
            return json.loads(raw).get("id")
        except Exception:
            return None
    return raw


def opencode_sessions(lo_ms, hi_ms, model_sub, dir_sub):
    """Every session matching the filters, across both databases."""
    out = []
    for origin, path in OPENCODE_DBS:
        if not os.path.exists(path):
            continue
        try:
            c = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            rows = c.execute(
                "select directory,model,tokens_input,tokens_output,tokens_reasoning,"
                "tokens_cache_read,tokens_cache_write,cost,time_created "
                "from session where time_created between ? and ?", (lo_ms, hi_ms)).fetchall()
            c.close()
        except Exception as e:
            print(f"  [warn] {origin} db unreadable: {type(e).__name__}: {e}", file=sys.stderr)
            continue
        for r in rows:
            mid = _model_id(r[1])
            if model_sub and (not mid or model_sub not in mid):
                continue
            if dir_sub and dir_sub.lower() not in str(r[0]).replace("\\", "/").lower():
                continue
            out.append(dict(origin=origin, directory=r[0], model=mid, input=r[2] or 0,
                            output=r[3] or 0, reasoning=r[4] or 0, cache_read=r[5] or 0,
                            cache_write=r[6] or 0, cost=r[7] or 0.0, created_ms=r[8]))
    return out


def claude_turns(lo_ms, hi_ms, dir_sub):
    """Per-turn usage from claude session transcripts in the window.

    TWO FILTERS, BOTH LOAD-BEARING. era dispatches its claude seats with the repo
    as cwd, so the seat transcripts land in the SAME project directory as any
    interactive Claude Code session working on that repo. Measured: the driving
    session was 311 turns of `entrypoint: cli`, each seat 1-2 turns of
    `entrypoint: sdk-cli`. Without the entrypoint filter the reader matches the
    operator's own conversation and reports its tokens as the seat's.

    `<synthetic>` turns are dropped too: those are the failed Windows claude.exe
    credential attempt that precedes the WSL retry (see the fallback note in
    backends/claude.ps1), not model work.
    """
    # DEDUPE BY REALPATH. Measured: ~/.claude/projects holds BOTH
    # `-mnt-c-Users-Joshua-...` and `-mnt-c-users-joshua-...`, two symlinks that
    # resolve to the same Windows-side directory. Globbing over names counts every
    # transcript twice and reports `AMBIGUOUS (2 transcripts)` for a seat that ran
    # exactly once -- an instrument artifact indistinguishable, in the output,
    # from a real double dispatch.
    agg, seen = [], set()
    for proj in sorted(glob.glob(os.path.join(CLAUDE_PROJECTS, "*"))):
        if dir_sub and dir_sub.lower().replace("/", "-") not in os.path.basename(proj).lower():
            continue
        for f in glob.glob(os.path.join(proj, "*.jsonl")):
            real = os.path.realpath(f)
            if real in seen:
                continue
            seen.add(real)
            # DECIDE THE FILE FIRST, THEN COUNT. An earlier version broke out of
            # the line loop on the first non-sdk-cli `entrypoint`, which is
            # ordering-dependent: any usage record appearing before that line was
            # already counted, and the operator's own 311-turn session matched
            # anyway. Classify the whole file, then count only if it is a seat.
            tot = dict(input=0, output=0, cache_read=0, cache_write=0, thinking=0, turns=0)
            entrypoints, pending, msg_ids = set(), [], set()
            try:
                for line in open(f, encoding="utf-8", errors="replace"):
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    if d.get("entrypoint"):
                        entrypoints.add(d["entrypoint"])
                    msg = d.get("message") or {}
                    u = msg.get("usage")
                    if not u or msg.get("model") == "<synthetic>":
                        continue
                    ts = d.get("timestamp")
                    if ts:
                        try:
                            ms = dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1000
                        except Exception:
                            ms = None
                        if ms is not None and not (lo_ms <= ms <= hi_ms):
                            continue
                    # DEDUPE ON MESSAGE ID. Measured: a seat transcript records the
                    # SAME assistant turn twice -- identical usage, once with empty
                    # content and once with the text -- so summing records doubles
                    # every claude figure. Caught only by printing per-turn detail;
                    # the total looked entirely plausible.
                    mid = msg.get("id") or d.get("requestId")
                    if mid is not None:
                        if mid in msg_ids:
                            continue
                        msg_ids.add(mid)
                    pending.append(u)
            except Exception:
                continue
            if entrypoints != {"sdk-cli"} or not pending:
                continue
            for u in pending:
                tot["turns"] += 1
                tot["input"] += u.get("input_tokens", 0)
                tot["output"] += u.get("output_tokens", 0)
                tot["cache_read"] += u.get("cache_read_input_tokens", 0)
                tot["cache_write"] += u.get("cache_creation_input_tokens", 0)
                tot["thinking"] += (u.get("output_tokens_details") or {}).get("thinking_tokens", 0)
            hit = True
            if hit:
                tot["file"] = f
                agg.append(tot)
    return agg


def main():
    ap = argparse.ArgumentParser(description="Ground-truth token usage for an era round.")
    ap.add_argument("review_dir", help=".external-reviews/<slug>")
    ap.add_argument("round", type=int)
    ap.add_argument("--dir-sub", default="external-review-auto",
                    help="substring the seat's working directory must contain")
    ap.add_argument("--slack", type=int, default=180,
                    help="seconds of slack around each seat's measured wall clock")
    ap.add_argument("--json", action="store_true",
                    help="emit machine-readable rows instead of a table; a text table that "
                         "downstream analysis has to re-parse is not an instrument")
    a = ap.parse_args()

    meta_path = os.path.join(a.review_dir, f"round-{a.round}-metadata.json")
    meta = json.load(open(meta_path, encoding="utf-8"))
    end = dt.datetime.fromisoformat(meta["timestamp"].replace("Z", "+00:00"))
    end_ms = end.timestamp() * 1000

    # HARD FLOOR AT THE PREVIOUS ROUND'S END. A seat's measured wall clock does
    # not include the time it spent waiting on opencode's run queue, so a window
    # of `end - (wall + slack)` can start AFTER the session did and report
    # `unmatched` for a seat that ran perfectly -- measured on round 4. Widening
    # the slack instead would let a seat match the PREVIOUS round's session for
    # the same model, which is worse: a wrong number rather than no number.
    floor_ms = 0.0
    prev = os.path.join(a.review_dir, f"round-{a.round - 1}-metadata.json")
    if a.round > 1 and os.path.exists(prev):
        pm = json.load(open(prev, encoding="utf-8"))
        floor_ms = dt.datetime.fromisoformat(pm["timestamp"].replace("Z", "+00:00")).timestamp() * 1000

    results = []
    print(f"round {a.round}  ended {meta['timestamp']}  bundle_tokens={meta['reviewers'][0]['bundle_tokens']}")
    print(f"{'seat':16} {'backend':9} {'era est_out':>11} {'true out':>9} {'reasoning':>10} "
          f"{'true in':>9} {'cache rd':>9} {'attribution'}")

    for r in meta["reviewers"]:
        wall = r.get("wall_clock_sec") or 0
        lo_ms = max(end_ms - (wall + a.slack) * 1000, floor_ms)
        hi_ms = end_ms + a.slack * 1000
        if floor_ms:
            lo_ms = max(min(lo_ms, end_ms - 900 * 1000), floor_ms)
        est_out = r.get("est_output_tokens") or 0
        if r["backend"] == "opencode":
            model_sub = (r["model"] or "").split("/")[-1]
            got = opencode_sessions(lo_ms, hi_ms, model_sub, a.dir_sub)
            if len(got) == 1:
                s = got[0]
                note = f"ok ({s['origin']} db)"
                results.append(dict(round=a.round, seat=r["preset"], backend=r["backend"],
                                    era_est_output=est_out, true_output=s["output"],
                                    reasoning=s["reasoning"], true_input=s["input"],
                                    cache_read=s["cache_read"], cost=s["cost"],
                                    attribution="ok", source=s["origin"] + " db"))
                print(f"{r['preset']:16} {r['backend']:9} {est_out:>11} {s['output']:>9} "
                      f"{s['reasoning']:>10} {s['input']:>9} {s['cache_read']:>9} {note}")
            else:
                note = "UNMATCHED" if not got else f"AMBIGUOUS ({len(got)} sessions)"
                print(f"{r['preset']:16} {r['backend']:9} {est_out:>11} {'-':>9} {'-':>10} "
                      f"{'-':>9} {'-':>9} {note}")
        elif r["backend"] == "claude":
            got = claude_turns(lo_ms, hi_ms, a.dir_sub)
            if len(got) == 1:
                s = got[0]
                results.append(dict(round=a.round, seat=r["preset"], backend=r["backend"],
                                    era_est_output=est_out, true_output=s["output"],
                                    reasoning=s["thinking"], true_input=s["input"],
                                    cache_read=s["cache_read"], cost=None,
                                    attribution="ok", source=f"claude transcript ({s['turns']} turns)"))
                print(f"{r['preset']:16} {r['backend']:9} {est_out:>11} {s['output']:>9} "
                      f"{s['thinking']:>10} {s['input']:>9} {s['cache_read']:>9} ok ({s['turns']} turns)")
            else:
                note = "UNMATCHED" if not got else f"AMBIGUOUS ({len(got)} transcripts)"
                print(f"{r['preset']:16} {r['backend']:9} {est_out:>11} {'-':>9} {'-':>10} "
                      f"{'-':>9} {'-':>9} {note}")
        else:
            print(f"{r['preset']:16} {r['backend']:9} {est_out:>11} {'-':>9} {'-':>10} "
                  f"{'-':>9} {'-':>9} no vendor record reader")

    if a.json:
        print("---JSON---")
        print(json.dumps(results, indent=1))


if __name__ == "__main__":
    main()
