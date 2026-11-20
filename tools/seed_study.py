#!/usr/bin/env python3
"""
seed_study.py -- how much of a Raft cell's outcome is chance?

    tools/seed_study.py results_fault/summary.csv tools/validation/v1_cells.csv

Reads the v1s cells (each Raft cell of the registered validation set v1, run
with --run=1..5), classifies each run as fault_report.py does, and prints per
cell: the registered prediction and margin, the five outcomes, the share that
failed (storm or stuck), and whether seed 1 reproduced the v1 run.

This is a stochasticity study: v1 stays scored on its registered predictions.
Here a prediction "holds" for a cell if most seeds agree with it, and a cell is
"split" when the seeds disagree among themselves.
"""
import contextlib
import csv
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fault_report  # noqa: E402


def outcomes(summary):
    tmp = summary + ".seed.tmp"
    with contextlib.redirect_stdout(io.StringIO()):
        fault_report.main([summary, "--csv", tmp])
    rows = {r["cell"]: r for r in csv.DictReader(open(tmp))}
    os.unlink(tmp)
    return rows


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    rows = outcomes(argv[0])
    reg = [r for r in csv.DictReader(open(argv[1])) if r["config"].startswith("raft")]
    fails = lambda o: o.startswith(("storm", "stuck"))
    held = split = total = 0
    print(f"{'cell':34} {'pred':4} {'margin':>6}  seeds 1-5 (F = storm/stuck, . = recovered)  "
          f"fail share  seed1=v1")
    for r in reg:
        base = r["cell"][len("v1-"):]
        runs = [rows.get(f"v1s-{base}-r{s}") for s in range(1, 6)]
        if not all(runs):
            print(f"{r['cell']:34} incomplete ({sum(1 for x in runs if x)} of 5 seeds)")
            continue
        outs = [x["outcome"] for x in runs]
        nf = sum(fails(o) for o in outs)
        total += 1
        majority = "fail" if nf >= 3 else "ok"
        held += majority == r["prediction"]
        split += 0 < nf < 5
        v1 = rows.get(r["cell"])
        same = "-" if not v1 else ("yes" if v1["outcome"] == outs[0] and
                                   v1["quorum_done"] == runs[0]["quorum_done"] else "NO")
        marks = "".join("F" if fails(o) else "." for o in outs)
        print(f"{r['cell']:34} {r['prediction']:4} {r['margin']:>6}  {marks:5}  "
              f"{' '.join(o[:9] for o in outs):49} {nf}/5        {same}")
    print(f"\nprediction agrees with the majority of seeds: {held} of {total}")
    print(f"cells whose seeds disagree among themselves: {split} of {total}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
