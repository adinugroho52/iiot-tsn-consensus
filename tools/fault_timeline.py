#!/usr/bin/env python3
"""
fault_timeline.py -- does a storm outlive the fault?

    tools/fault_timeline.py results_fault/csv/f1-w300t4-crash-to2-w0-rounds.csv [...]
    tools/fault_timeline.py --summary results_fault/csv/*-rounds.csv

Reads the per-round oracle CSV that fault_sweep.sh writes for every cell
(--adversaryCsv) and bins rounds by the time they were opened. For each bin it
prints the rounds opened and the share that reached a quorum (2f+1 trusted nodes,
same digest). The fault window of fault_sweep.sh is [1.0 s, 2.5 s).

With --summary, one line per file: the quorum share before, during and after the
fault. A share after the fault far below the one before means the view changes
kept going once the faulty node was back: the storm sustains itself.
"""
import csv
import sys

FAULT = (1.0, 2.5)
BIN = 0.5


def load(path):
    rows = []
    for r in csv.DictReader(open(path)):
        t = int(r["opened_ns"])
        if t < 0:
            continue                      # never opened (no proposal reached the oracle)
        rows.append((t / 1e9, r["quorum_complete"] == "1"))
    return rows


def share(rows, lo, hi):
    sel = [q for t, q in rows if lo <= t < hi]
    return (sum(sel) / len(sel), len(sel)) if sel else (float("nan"), 0)


def main(argv):
    if not argv:
        sys.exit(__doc__)
    summary = argv[0] == "--summary"
    files = argv[1:] if summary else argv
    if summary:
        print(f"{'cell':36} {'before':>13} {'during':>13} {'after':>13}  (quorum share, rounds)")
    for path in files:
        rows = load(path)
        name = path.rsplit("/", 1)[-1].replace("-rounds.csv", "")
        if not rows:
            print(f"{name:36} no rounds")
            continue
        end = max(t for t, _ in rows)
        if summary:
            parts = []
            for lo, hi in ((0.0, FAULT[0]), FAULT, (FAULT[1], end + 1)):
                s, k = share(rows, lo, hi)
                parts.append(f"{s:6.0%} {k:5d}" if k else f"{'-':>6} {0:5d}")
            print(f"{name:36} " + "  ".join(f"{p:>13}" for p in parts))
            continue
        print(f"\n{name}   (fault window {FAULT[0]}-{FAULT[1]} s)")
        print(f"  {'bin (s)':>11} {'opened':>7} {'quorum':>7}  share")
        t = 0.0
        while t <= end:
            s, k = share(rows, t, t + BIN)
            if k:
                mark = " *" if FAULT[0] <= t < FAULT[1] else ""
                bar = "#" * round(20 * s)
                print(f"  {t:4.1f}-{t + BIN:4.1f}  {k:7d} {round(s * k):7d}  {s:5.0%} {bar}{mark}")
            t += BIN
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
