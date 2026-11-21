#!/usr/bin/env python3
"""
compare_paper2.py -- check the second paper's results against its reference.

    tools/compare_paper2.py check NEW REFERENCE [--sets f1 p1 ...]
    tools/compare_paper2.py make  NEW REFERENCE

NEW is a folder written by tools/assemble_results.py (all_cells.csv and the
table_*.csv files); REFERENCE is tools/reference/paper2/ in this repository,
assembled from the authors' runs (ns-3.49, TAS module commit 3d00954).

`check` reports on three levels, from what the paper claims to bit identity:

  1. isolation and safety: no cell missed a control deadline and no cell
     violated safety (Section 5.6). This is checked on NEW alone.
  2. outcomes: every cell has the outcome (recovered, churn, storm, stuck) and
     the recovery-rule prediction of the reference. With --sets, only cells of
     those sets are compared; otherwise every reference cell must be present.
  3. values: every column of every cell (views, rounds, drops, latencies...)
     equals the reference, and every table the paper prints (table_*.csv)
     equals the reference. Tables are compared only on a full run, since a
     partial sweep yields partial tables.

The simulation is deterministic (Raft's random election timeouts are seeded by
the run number), so a matching build reproduces all three levels exactly.
Exit status 0 if every level holds, 1 otherwise. `make` copies the reference
files from NEW into REFERENCE (for maintainers, after a deliberate change).
"""
import argparse
import csv
import os
import shutil
import sys

TABLES = ("table_protocols.csv", "table_headroom.csv", "table_f1grid.csv",
          "table_rule.csv", "table_control.csv")
KEY_COLS = ("outcome", "rule_prediction")


def load_cells(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    return {r["cell"]: r for r in rows}


def load_rows(path):
    with open(path, newline="") as f:
        return list(csv.reader(f))


def check(new, ref, sets):
    ok = True
    newc = load_cells(os.path.join(new, "all_cells.csv"))
    refc = load_cells(os.path.join(ref, "all_cells.csv"))
    if sets:
        refc = {k: v for k, v in refc.items() if v["set"] in sets}
        newc = {k: v for k, v in newc.items() if v["set"] in sets}

    # 1. isolation and safety, on the new results alone
    missed = [c for c, r in newc.items() if r.get("ctrl_missed", "0") not in ("0", "")]
    unsafe = [c for c, r in newc.items() if r.get("safety", "0") not in ("0", "")]
    print("1. isolation and safety")
    print(f"   cells checked                 {len(newc)}")
    print(f"   cells with missed deadlines   {len(missed)}" + (f"  {missed[:5]}" if missed else ""))
    print(f"   cells with safety violations  {len(unsafe)}" + (f"  {unsafe[:5]}" if unsafe else ""))
    if missed or unsafe:
        ok = False

    # 2. outcomes and 3a. cell values
    missing = sorted(set(refc) - set(newc))
    extra = sorted(set(newc) - set(refc))
    out_diff, val_diff = [], []
    for cell in sorted(set(refc) & set(newc)):
        a, b = refc[cell], newc[cell]
        if any(a.get(k) != b.get(k) for k in KEY_COLS):
            out_diff.append((cell, {k: (a.get(k), b.get(k)) for k in KEY_COLS if a.get(k) != b.get(k)}))
        cols = [k for k in a if a.get(k) != b.get(k)]
        if cols:
            val_diff.append((cell, cols))
    by_set = {}
    for r in refc.values():
        by_set.setdefault(r["set"], [0, 0, 0])[0] += 1
    for cell, _ in out_diff:
        by_set[refc[cell]["set"]][1] += 1
    for cell, _ in val_diff:
        by_set[refc[cell]["set"]][2] += 1
    for cell in missing:
        by_set[refc[cell]["set"]][1] += 1
        by_set[refc[cell]["set"]][2] += 1

    print("\n2. outcomes and recovery-rule predictions   3a. cell values")
    print(f"   {'set':<5} {'cells':>5} {'outcome diffs':>14} {'value diffs':>12}")
    for s in sorted(by_set, key=lambda x: (x[0], len(x), x)):
        n, o, v = by_set[s]
        print(f"   {s:<5} {n:>5} {o:>14} {v:>12}")
    if missing:
        ok = False
        print(f"   MISSING {len(missing)} cells, e.g. {missing[:5]}")
    if extra:
        print(f"   note: {len(extra)} cells not in the reference, e.g. {extra[:3]}")
    for cell, d in out_diff[:20]:
        ok = False
        print("   OUTCOME " + cell + "  " + ", ".join(f"{k}: reference {x} now {y}" for k, (x, y) in d.items()))
    for cell, cols in val_diff[:20]:
        ok = False
        a, b = refc[cell], newc[cell]
        shown = ", ".join(f"{k} {a[k]} -> {b[k]}" for k in cols[:4])
        print(f"   VALUES  {cell}  {shown}{' ...' if len(cols) > 4 else ''}")
    if len(out_diff) > 20 or len(val_diff) > 20:
        print("   (first 20 of each shown)")

    # 3b. the tables of the paper
    print("\n3b. tables of the paper")
    if sets:
        print("   skipped: a partial sweep (--sets) yields partial tables")
    else:
        for t in TABLES:
            pr, pn = os.path.join(ref, t), os.path.join(new, t)
            if not os.path.isfile(pn):
                print(f"   MISSING    {t}")
                ok = False
                continue
            a, b = load_rows(pr), load_rows(pn)
            if a == b:
                print(f"   identical  {t}")
            else:
                ok = False
                print(f"   DIFFERS    {t}")
                for i in range(max(len(a), len(b))):
                    ra = a[i] if i < len(a) else []
                    rb = b[i] if i < len(b) else []
                    if ra != rb:
                        print(f"      reference: {','.join(ra)}")
                        print(f"      now:       {','.join(rb)}")

    n_out = len(refc) - len(out_diff) - len(missing)
    print("\nverdict")
    print(f"   isolation and safety hold      {'yes' if not (missed or unsafe) else 'NO'}")
    print(f"   outcomes reproduced            {n_out}/{len(refc)}")
    print(f"   cells identical in every value {len(refc) - len(val_diff) - len(missing)}/{len(refc)}")
    print(f"   result: {'REPRODUCED' if ok else 'NOT REPRODUCED (see above)'}")
    return 0 if ok else 1


def make(new, ref):
    os.makedirs(ref, exist_ok=True)
    for f in ("all_cells.csv",) + TABLES:
        shutil.copyfile(os.path.join(new, f), os.path.join(ref, f))
        print(f"wrote {os.path.join(ref, f)}")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("mode", choices=("check", "make"))
    ap.add_argument("new")
    ap.add_argument("reference")
    ap.add_argument("--sets", nargs="*", default=None,
                    help="compare only these sets (cells only, no tables)")
    a = ap.parse_args(argv)
    if a.mode == "make":
        return make(a.new, a.reference)
    return check(a.new, a.reference, set(a.sets) if a.sets else None)


if __name__ == "__main__":
    sys.exit(main())
