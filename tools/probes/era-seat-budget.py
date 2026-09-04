import json, glob, collections, sys, os#!/usr/bin/env python3
"""
Does era's per-seat budget ever actually bind on work that succeeds?

The probe behind the 600s -> 700s seat-budget floor in Get-EraDispatchPlan
(workflow.ps1). Committed for the same reason as its neighbours: the change it
supports is a constant, and a constant has to carry its measurement.

CORPUS: every `round-N-metadata.json` era has ever written, across the repos era
has been pointed at. era records `wall_clock_sec` and `bundle_tokens` per seat,
which is exactly the pair this question needs. 628 rounds / 1,174 seat-runs on the
machine the change was measured on. THE ARCHIVE IS NOT IN THIS REPOSITORY -- it
lives beside the reviewed code, one .external-reviews per repo, and it is
gitignored, so the numbers below cannot be re-derived from a fresh checkout alone.
Roots are discovered under $HOME or passed as arguments; with none present the
probe says there is nothing to measure rather than throwing.

WHAT IT ANSWERS, and the answers as of the run that motivated the change:

  * Does the budget bind on productive work?  Almost never -- 1 of 977 productive
    seat-runs ever exceeded it, and only 19 reached 80% of it. So raising the
    floor costs working seats nothing.

  * Then why raise it? Because the floor is not only a timeout, it is the CLAMP on
    the opencode stall threshold: min(appetite, budget - 30). At a 600s floor that
    is 569s, and a productive deepseek run in opencode.db went silent for 570.2s
    on a 7,794-token input -- squarely on the floor. It would have been killed 1.2
    seconds before delivering 11,520 characters of review.

  * What does it cost? A wedged seat on a small bundle burns 700s instead of 600s.
    11.8% of floor-regime seat-runs are non-productive.

Run:  python3 tools/probes/era-seat-budget.py
"""



def discover_roots(argv):
    """Where are this machine's round archives?

    NOT A HARDCODED LIST. The first cut of this probe pinned eight absolute paths
    naming a home directory and the private repositories era had been pointed at,
    in a repository that is public. Caught by the identifier sweep before it was
    committed; tests/ProbesCommitted.Tests.ps1 now fails any probe that hardcodes
    a home directory in either the Windows or the POSIX spelling.

    Pass roots as arguments, or let it search the usual places under $HOME.
    """
    if argv:
        return [r for r in argv if os.path.isdir(r)]
    home = os.path.expanduser("~")
    found, seen = [], set()
    # era writes .external-reviews beside the code it reviews, so look one and two
    # levels down from the places code usually lives -- bounded, never a full scan.
    homes = [home, os.getcwd()]
    # Under WSL the Windows-side repos are the ones era usually runs against, and
    # $HOME is the Linux one. Globbed, never named.
    homes += glob.glob("/mnt/*/Users/*")
    bases = []
    for h in homes:
        bases += [h] + [os.path.join(h, sub) for sub in
                        ("Servers", "src", "code", "projects", "repos",
                         os.path.join(".claude", "skills", "external-review-auto"),
                         os.path.join(".commandcode", "skills", "external-review-auto"))]
    for base in bases:
        for pat in (".external-reviews", "*/.external-reviews"):
            for d in glob.glob(os.path.join(base, pat)):
                rp = os.path.realpath(d)
                if os.path.isdir(rp) and rp not in seen:
                    seen.add(rp); found.append(rp)
    return found


ROOTS = discover_roots(sys.argv[1:])

def budget(tok):
    """era's own rule: Get-EraDispatchPlan, min(max(600, tokens*0.02), 1800)."""
    return min(max(600, int((tok or 0) * 0.02)), 1800)

if not ROOTS:
    print("nothing to measure: no .external-reviews archive found on this machine.")
    print("Pass one or more archive directories as arguments.")
    sys.exit(0)

seats, rounds = [], 0
for root in ROOTS:
    for f in glob.glob(root + '/**/round-*-metadata.json', recursive=True):
        try: d = json.load(open(f, encoding='utf-8'))
        except Exception: continue
        rounds += 1
        for r in (d.get('reviewers') or []):
            if r.get('wall_clock_sec') is None: continue
            r['_bt'] = r.get('bundle_tokens') or d.get('bundle_tokens')
            seats.append(r)

prod = [s for s in seats if s.get('content_ok') and s.get('exit_code') == 0 and s.get('_bt')]
def q(xs, p):
    xs = sorted(xs); return xs[min(len(xs)-1, int(round(p/100*(len(xs)-1))))]

print(f"rounds with metadata : {rounds}")
print(f"seat-runs with a wall clock : {len(seats)}")
print(f"  of which productive (content_ok, exit 0, bundle size known) : {len(prod)}\n")

print("WALL CLOCK PER PRODUCTIVE SEAT-RUN, by backend")
for b, ss in sorted(collections.Counter(s.get('backend') for s in prod).most_common()):
    w = [s['wall_clock_sec'] for s in prod if s.get('backend') == b]
    print(f"  {str(b):10s} n={len(w):4d} p50={q(w,50):6.1f} p90={q(w,90):6.1f} "
          f"p99={q(w,99):7.1f} max={max(w):7.1f}")

print("\nDOES THE BUDGET EVER BIND? wall clock vs the budget era would have granted")
overs = [s for s in prod if s['wall_clock_sec'] > budget(s['_bt'])]
print(f"  productive seat-runs that EXCEEDED their budget: {len(overs)} of {len(prod)} "
      f"({100.0*len(overs)/len(prod):.2f}%)")
near = [s for s in prod if s['wall_clock_sec'] > budget(s['_bt']) * 0.8]
print(f"  ...that even reached 80% of it            : {len(near)} of {len(prod)} "
      f"({100.0*len(near)/len(prod):.2f}%)")
if overs:
    for s in sorted(overs, key=lambda s: -s['wall_clock_sec'])[:10]:
        print(f"    {s.get('backend'):10s} tok={s['_bt']:>7} budget={budget(s['_bt']):5d} "
              f"wall={s['wall_clock_sec']:7.1f}")

print("\nTHE SLICE THAT MATTERS: the 600s-floor regime (<30,000 bundle tokens),")
print("where the new stall threshold clamps to 569s.")
floor = [s for s in prod if s['_bt'] < 30000]
oc = [s for s in floor if s.get('backend') == 'opencode']
for label, group in (('all backends', floor), ('opencode only', oc)):
    if not group: continue
    w = [s['wall_clock_sec'] for s in group]
    print(f"  {label:14s} n={len(w):4d} p50={q(w,50):6.1f} p95={q(w,95):6.1f} max={max(w):6.1f}"
          f"   above the 569s clamp: {len([x for x in w if x > 569])}")
if oc:
    print(f"  headroom, longest productive opencode run to the clamp: "
          f"{569 - max(s['wall_clock_sec'] for s in oc):.1f}s")
