#!/usr/bin/env python3
"""
fault_report.py -- classify the outcome of every fault_sweep.sh cell and score
the vc_budget.py predictions against it.

    tools/fault_report.py results_fault/summary.csv [--csv outcomes.csv]

Outcome of a cell (T = round interval, from the configuration name):
    storm      more than 3 view changes per node (views entered / n: PBFT
               views, HotStuff timeouts, Raft elections) and rounds were lost or abandoned
               (more than 5% abandoned): view changes kept coming at a cost.
    churn      more than 3 view changes per node but every round still reached a
               quorum: view changes cost bandwidth, not liveness.
    stuck      rounds lost (opened, never quorum-done, not abandoned) beyond
               those still in flight at the end (ceil(commit p99 / T) + 1),
               without many views: liveness lost.
    views      2 or 3 view changes per node, then recovery.
    recovered  otherwise.
A recovered cell is marked "+delay" when its median commit latency is more than
1.5 times the lowest median of its configuration: the burst left a backlog that
never drained (zero spare capacity).

Scoring: safe, boundary and c5pass predict recovery; storm, drop and c5fail
predict that it fails (storm or stuck).
"""
import csv
import math
import re
import sys
from collections import Counter, defaultdict


def committee(config):
    """n from the configuration name (f5 n7..., v1 pbftn10..., else 10 at 100 Mbps, 16)."""
    m = re.match(r"(?:pbft|hs|raft)?n(\d+)", config)
    return int(m.group(1)) if m else (10 if config.startswith("100m") else 16)


def interval_ms(config):
    m = re.search(r"t(\d+(?:\.\d+)?)$", config)
    return float(m.group(1)) if m else 1.0


def main(argv):
    if not argv:
        sys.exit(__doc__)
    rows = list(csv.DictReader(open(argv[0])))
    out_csv = argv[argv.index("--csv") + 1] if "--csv" in argv else None

    best_p50 = defaultdict(lambda: math.inf)
    for r in rows:
        try:
            best_p50[r["config"]] = min(best_p50[r["config"]], float(r["commit_p50_us"]))
        except ValueError:
            pass

    for r in rows:
        T = interval_ms(r["config"])
        opened, q = int(r["rounds_opened"] or 0), int(r["quorum_done"] or 0)
        ab = int(r["abandoned"] or 0)
        # View changes per node: the views entered by all nodes over n (PBFT views,
        # HotStuff pacemaker timeouts, Raft elections started). The highest view
        # would not do: in HotStuff the view is the block height.
        mv = int(r["views_entered"] or 0) / committee(r["config"])
        r["vc_node"] = f"{mv:.1f}"
        p99 = float(r["commit_p99_us"] or 0) / 1000
        inflight = math.ceil(p99 / T) + 1
        lost = opened - q - ab
        if mv > 3 and (lost > inflight or ab > 0.05 * opened):
            out = "storm"
        elif mv > 3:
            out = "churn"
        elif lost > inflight:
            out = "stuck"
        elif mv >= 2:
            out = "views"
        else:
            out = "recovered"
        if out in ("recovered", "views", "churn") and float(r["commit_p50_us"] or 0) > 1.5 * best_p50[r["config"]]:
            out += "+delay"
        r["outcome"], r["lost"] = out, lost
        pred = r["prediction"]
        fails = out.startswith(("storm", "stuck"))
        if pred in ("safe", "boundary", "c5pass"):
            r["score"] = "ok" if not fails else "MISS"
        elif pred in ("storm", "drop", "c5fail"):
            r["score"] = "ok" if fails else "MISS"
        else:
            r["score"] = "-"

    key = lambda r: (r["set"], r["config"], r["attack"], float(r["timeout_rounds"]), int(r["window"]))
    print(f"{'cell':34} {'pred':9} {'outcome':16} {'score':5} {'vc/n':>5} {'quorum':>11} "
          f"{'ab':>4} {'lost':>5} {'peak':>4} {'drops':>7} {'p50ms':>7} {'p99ms':>8} {'ctrl miss/p99':>14}")
    for r in sorted(rows, key=key):
        print(f"{r['cell']:34} {r['prediction']:9} {r['outcome']:16} {r['score']:5} {r['vc_node']:>5} "
              f"{r['quorum_done'] + '/' + r['rounds_opened']:>11} {r['abandoned']:>4} {r['lost']:>5} "
              f"{r['cons_peak']:>4} {r['cons_drops']:>7} {float(r['commit_p50_us'] or 0) / 1000:7.2f} "
              f"{float(r['commit_p99_us'] or 0) / 1000:8.2f} "
              f"{r['ctrl_missed'] + '/' + r['ctrl_p99_us']:>14}")

    print("\nprediction -> outcome")
    for (p, o), k in sorted(Counter((r["prediction"], r["outcome"]) for r in rows).items()):
        print(f"  {p:9} -> {o:16} {k}")
    sc = Counter(r["score"] for r in rows if r["score"] != "-")
    if sc:
        print(f"\npredictions right {sc['ok']} of {sc['ok'] + sc['MISS']}")
    missed = sum(int(r["ctrl_missed"] or 0) for r in rows)
    print(f"control deadlines missed over all cells: {missed}")
    unsafe = [r["cell"] for r in rows if int(r["safety"] or 0) > 0]
    print(f"safety violations: {'none' if not unsafe else ', '.join(unsafe)}")

    if out_csv:
        with open(out_csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
