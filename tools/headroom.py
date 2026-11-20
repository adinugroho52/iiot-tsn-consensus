#!/usr/bin/env python3
"""
headroom.py -- the spare capacity a view change needs, per committee size.

    tools/headroom.py results_fault/summary.csv

Takes the f4 and f5 cells with every held round re-proposed (window 0), groups
them by committee size n and trigger (crash with a 4-round timeout, equivocation)
and orders each group by spare capacity on the busiest link, as a share of its
load: (C - M) / M, with C and M from vc_budget.py. The threshold lies between
the largest share that stormed and the smallest that recovered; a group where a
storm sits above a recovery is flagged as not monotonic.

Outcomes are classified as in fault_report.py.
"""
import csv
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fault_report  # noqa: E402


def classify(rows):
    """Run fault_report's classification in place (it prints; silence it)."""
    import contextlib
    import io
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
        tmp = f.name
    out = tmp + ".out"
    with contextlib.redirect_stdout(io.StringIO()):
        fault_report.main([tmp, "--csv", out])
    res = {r["cell"]: r["outcome"] for r in csv.DictReader(open(out))}
    os.unlink(tmp)
    os.unlink(out)
    return res


def main(argv):
    if not argv:
        sys.exit(__doc__)
    rows = [r for r in csv.DictReader(open(argv[0])) if r["set"] in ("f4", "f5")]
    if not rows:
        sys.exit("no f4 or f5 cells in " + argv[0])
    outcome = classify(rows)
    groups = {}
    for r in rows:
        if r["window"] != "0" or r["attack"] not in ("crash", "equivocate"):
            continue
        if r["attack"] == "crash" and r["timeout_rounds"] != "4":
            continue
        m = re.match(r"n(\d+)", r["config"])
        n = int(m.group(1)) if m else 16
        C, M = int(r["pred_C"]), int(r["pred_M"])
        groups.setdefault((r["attack"], n), []).append(((C - M) / M, C, M, outcome[r["cell"]]))

    print(f"{'trigger':11} {'n':>3} {'M':>4}  spare/M: outcome  ->  threshold")
    for (atk, n) in sorted(groups):
        g = sorted(groups[(atk, n)])
        fails = [s for s, _, _, o in g if o.startswith(("storm", "stuck"))]
        oks = [s for s, _, _, o in g if not o.startswith(("storm", "stuck"))]
        cells = "  ".join(f"{s:4.0%}:{'X' if o.startswith(('storm', 'stuck')) else '.'}"
                          for s, _, _, o in g)
        lo = max(fails) if fails else None
        hi = min(oks) if oks else None
        if lo is None:
            th = f"below {hi:.0%}"
        elif hi is None:
            th = f"above {lo:.0%}"
        elif lo < hi:
            th = f"between {lo:.0%} and {hi:.0%}"
        else:
            th = f"NOT MONOTONIC (storm at {lo:.0%}, recovery at {hi:.0%})"
        print(f"{atk:11} {n:3d} {g[0][2]:4d}  {cells}  ->  {th}")
    print("\nX = storm or stuck, . = recovered (with or without extra delay or churn)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
