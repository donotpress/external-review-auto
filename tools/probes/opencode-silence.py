#!/usr/bin/env python3
"""
How long does a WORKING opencode run stay silent?

The probe behind docs/assessments/2026-09-04-stall-threshold-measured.md, and the
source of every constant in Resolve-OpencodeStallPlan (backends/opencode.ps1).

WHY IT IS PYTHON AND NOT POWERSHELL, unlike its two neighbours in this directory:
the corpus is a 5.5 GB SQLite database and Windows PowerShell ships no SQLite
provider. Python's stdlib does. `py tools/probes/opencode-silence.py` works from
the same shell everything else in this repo runs from.

WHAT IT MEASURES
----------------
era's stall detector kills a run after N seconds of no growth in the bytes
opencode has written. So the quantity that decides whether a threshold is safe is
not how long a turn TAKES -- it is the longest stretch inside that turn during
which opencode writes nothing.

The two are not the same and the difference is large. The turn most often quoted
as the reason to raise the threshold ran 693.4s and emitted 26,525 output tokens;
its longest SILENT stretch was 570.2s, because the last 123s were the answer
streaming to stdout. Sizing a stall threshold off turn duration overstates the
requirement by exactly that streaming tail.

WHICH PARTS ARE VISIBLE, measured rather than assumed. From era's own captures in
%TEMP%\\opencode-stall-debug:

  * a `tool` part -> visible. opencode narrates every tool call to stderr
    ("-> Read bundle.xml [offset=730]"); those lines are the only thing in the
    stderr artifacts of the killed runs.
  * a `text` part -> visible, and streamed: the 2026-09-02 timeout artifact holds
    88 bytes of a mid-turn text part on stdout.
  * a `reasoning` part -> INVISIBLE. The exitfail artifact of 2026-09-04 records
    "stdout bytes: 0, stderr bytes: 167" over a 473.8s run whose database turn
    holds a single 457.3s reasoning part carrying 114,762 characters. opencode
    prints none of it.

So: silence = the gaps between the union of {tool, text} part intervals, plus the
lead-in from the turn's creation and the tail to its completion.

A LIVE opencode.db CANNOT BE READ -- it returns "disk I/O error" while opencode
holds it. Copy it first:

    cp ~/.local/share/opencode/opencode.db /tmp/oc-snap.db      # WSL/Linux
    Copy-Item $env:USERPROFILE\\.local\\share\\opencode\\opencode.db $env:TEMP\\oc-snap.db
"""

import argparse
import collections
import json
import os
import re
import sqlite3
import sys

VISIBLE = {"text", "tool"}

# cwds era dispatches into. Everything else in the database is an interactive or
# /dispatching-to-minimax session against a real repo.
ERA_CWD = re.compile(r"era-wire-|era-repro|era-probe|era-r\d|awc-era|eqm-era-review|oc-concurrency", re.I)


def load(db):
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    turns = {}
    for mid, tc, data in con.execute(
        "select id, time_created, data from message "
        "where json_extract(data,'$.role')='assistant'"
    ):
        j = json.loads(data)
        t = j.get("time") or {}
        tok = j.get("tokens") or {}
        turns[mid] = dict(
            id=mid,
            created=t.get("created", tc),
            completed=t.get("completed"),
            cwd=(j.get("path") or {}).get("cwd") or "",
            model=j.get("modelID"),
            variant=j.get("variant"),
            finish=j.get("finish"),
            tin=tok.get("input") or 0,
            tout=tok.get("output") or 0,
            parts=[],
        )
    for mid, tc, tu, data in con.execute(
        "select message_id, time_created, time_updated, data from part"
    ):
        turn = turns.get(mid)
        if turn is None:
            continue
        j = json.loads(data)
        kind = j.get("type")
        # A part row is written when the part OPENS and updated as it streams, so
        # the row's own columns already carry [start, end]. The nested time object
        # agrees with them (checked); it is used where it exists and the columns
        # are the fallback.
        if kind == "tool":
            tt = (j.get("state") or {}).get("time") or {}
        else:
            tt = j.get("time") or {}
        turn["parts"].append(
            dict(
                type=kind,
                start=tt.get("start", tc),
                end=tt.get("end", tu or tc),
                chars=len(j.get("text") or ""),
            )
        )
    for turn in turns.values():
        turn["parts"].sort(key=lambda p: p["start"])
    return list(turns.values())


def max_silence(turn):
    """Longest stretch with nothing on stdout/stderr, in seconds."""
    spans = sorted((p["start"], p["end"]) for p in turn["parts"] if p["type"] in VISIBLE)
    merged = []
    for start, end in spans:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    gaps, cursor = [], turn["created"]
    for start, end in merged:
        gaps.append((start - cursor) / 1000.0)
        cursor = max(cursor, end)
    if turn["completed"]:
        gaps.append((turn["completed"] - cursor) / 1000.0)
    return max([g for g in gaps if g >= 0] + [0.0])


def ttft(turn):
    """Creation -> the first sign of any kind that the provider answered."""
    if not turn["parts"]:
        return None
    v = (turn["parts"][0]["start"] - turn["created"]) / 1000.0
    return v if v >= 0 else None


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100.0 * (len(xs) - 1))))] if xs else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("db", help="a COPY of opencode.db")
    args = ap.parse_args()
    if not os.path.exists(args.db):
        # Degrade politely, like the two PowerShell probes beside this one: the
        # corpus is a local opencode database and is not in the repository, so on
        # any other checkout there is nothing to measure and that is not an error
        # to debug.
        print(f"nothing to measure: no opencode database at {args.db}")
        print("copy one first -- see the module docstring; the live file returns "
              "'disk I/O error' while opencode holds it.")
        return

    turns = load(args.db)
    for t in turns:
        t["silence"] = max_silence(t)
        t["textchars"] = sum(p["chars"] for p in t["parts"] if p["type"] == "text")
        t["era"] = bool(ERA_CWD.search(t["cwd"]))

    # "Productive" = the turn finished AND wrote an answer. Those are the turns a
    # stall threshold must not kill; everything else is a failure the detector is
    # allowed to catch.
    productive = [t for t in turns if t["completed"] and t["textchars"] > 0]
    print(f"assistant turns: {len(turns)}   productive: {len(productive)}\n")

    print("MAX SILENCE per productive turn, by model")
    print(f"  {'model':30s} {'n':>5} {'p50':>7} {'p95':>7} {'p99':>7} {'max':>7}")
    for model, group in sorted(
        collections.Counter(t["model"] for t in productive).most_common()
    ):
        g = [t["silence"] for t in productive if t["model"] == model]
        print(
            f"  {str(model):30s} {len(g):5d} {pct(g,50):7.1f} {pct(g,95):7.1f} "
            f"{pct(g,99):7.1f} {max(g):7.1f}"
        )

    print("\nFALSE KILLS: productive turns a given threshold would have killed")
    era_seats = [
        t for t in productive
        if t["model"] and (t["model"].startswith("deepseek") or t["model"].startswith("muse-spark"))
    ]
    print(f"  ({len(era_seats)} of them are on models era dispatches; {len(productive)} overall)")
    for th in (120, 180, 240, 300, 420, 570, 600, 704, 764, 785, 824, 900):
        a = len([t for t in era_seats if t["silence"] > th])
        b = len([t for t in productive if t["silence"] > th])
        print(f"  {th:5d}s -> era seats {a:4d} ({100.0*a/len(era_seats):5.2f}%)"
              f"   all models {b:4d} ({100.0*b/len(productive):5.2f}%)")

    print("\nTERM 1 -- PREFILL / QUEUE (input-driven): turn created -> first part")
    firsts = [(t, ttft(t)) for t in turns]
    firsts = [(t, v) for t, v in firsts if v is not None]
    vals = [v for _, v in firsts]
    print(f"  all turns n={len(vals)}  p50={pct(vals,50):.1f}s  p95={pct(vals,95):.1f}s "
          f" p99={pct(vals,99):.1f}s  max={max(vals):.1f}s")
    buckets = collections.defaultdict(list)
    for t, v in firsts:
        if t["model"] == "deepseek-v4-flash":
            buckets[min(9, t["tin"] // 10000)].append(v)
    print("  deepseek-v4-flash by input-token bucket (does prefill scale with the bundle?)")
    for k in sorted(buckets):
        v = buckets[k]
        print(f"    in {k*10:3d}k-{(k+1)*10:3d}k  n={len(v):4d} p50={pct(v,50):6.1f}s "
              f"p95={pct(v,95):6.1f}s max={max(v):6.1f}s")

    print("\nTERM 2 -- GENERATION (output-driven): ms per output token while silent")
    for model in sorted({t["model"] for t in productive if t["model"]}):
        r = [t["silence"] * 1000.0 / t["tout"] for t in productive
             if t["model"] == model and t["tout"] > 8000 and t["silence"] > 5]
        if len(r) < 5:
            continue
        print(f"  {model:30s} n={len(r):4d} p50={pct(r,50):5.1f} p95={pct(r,95):5.1f} "
              f"p99={pct(r,99):5.1f} max={max(r):5.1f}")
    for model in ("deepseek-v4-flash", "muse-spark-1.3-contributor"):
        o = [t["tout"] for t in turns if t["model"] == model and t["tout"]]
        if o:
            print(f"  {model:30s} output tokens: max={max(o)}  turns at exactly 32000: "
                  f"{len([x for x in o if x == 32000])}")

    print("\nWHICH VARIABLE DRIVES SILENCE (Pearson r, productive turns, silence > 5s)")
    sel = [t for t in productive if t["silence"] > 5 and t["tin"] and t["tout"]]

    def corr(xs, ys):
        n = len(xs)
        mx, my = sum(xs) / n, sum(ys) / n
        sx = (sum((x - mx) ** 2 for x in xs) / n) ** 0.5
        sy = (sum((y - my) ** 2 for y in ys) / n) ** 0.5
        return 0 if sx == 0 or sy == 0 else sum(
            (x - mx) * (y - my) for x, y in zip(xs, ys)) / (n * sx * sy)

    for label, key in (("input (bundle) tokens", "tin"), ("output tokens", "tout")):
        ds = [t for t in sel if t["model"] == "deepseek-v4-flash"]
        print(f"  vs {label:24s} all={corr([t[key] for t in sel],[t['silence'] for t in sel]):+.3f}"
              f"   deepseek-v4-flash={corr([t[key] for t in ds],[t['silence'] for t in ds]):+.3f}")

    print("\nCONTROL -- what a turn killed MID-GENERATION leaves behind")
    # Load-bearing for reading any killed run: opencode persists a reasoning part
    # incrementally, so a torn-down turn keeps whatever it had produced. A killed
    # turn holding ZERO reasoning characters was therefore not generating.
    killed = [t for t in turns if not t["completed"]]
    kept = sorted(
        ((sum(p["chars"] for p in t["parts"] if p["type"] == "reasoning"), t) for t in killed),
        key=lambda x: -x[0])
    print(f"  {len(killed)} turns never completed; {len([1 for c, _ in kept if c > 1000])} of them "
          f"still hold >1,000 chars of partial reasoning:")
    for chars, t in kept:
        if chars <= 1000:
            continue
        spans = [p for p in t["parts"] if p["type"] == "reasoning"]
        dur = max((p["end"] - p["start"]) / 1000.0 for p in spans)
        print(f"    {t['model']}/{t['variant']:<6} kept {chars:7d} chars over {dur:6.1f}s")
    print("  -> so a killed turn with ZERO reasoning chars was not generating when it died.")

    print("\nTHE OTHER DIRECTION -- turns that finished with NO answer at all")
    dud = [t for t in turns
           if t["completed"] and t["textchars"] == 0 and t["finish"] != "tool-calls"]
    g = [t["silence"] for t in dud]
    if g:
        print(f"  n={len(dud)}  silence p50={pct(g,50):.1f}s p90={pct(g,90):.1f}s max={max(g):.1f}s"
              f"   under 120s: {len([x for x in g if x < 120])}")
        print("  -> the failures and the successes occupy the SAME silence range, which is")
        print("     why no threshold separates them and why the number below is a bound on")
        print("     work, not a discriminator.")


if __name__ == "__main__":
    main()
