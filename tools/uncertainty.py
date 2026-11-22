#!/usr/bin/env python3
"""
uncertainty.py -- intervals for runs that differ only in --run (sweep.sh e9).

Groups summary.csv rows by (experiment, tag), where the tag carries everything
except the run number, and reports for each group:

  * mean, 95% confidence half-width (Student t), sd, min and max for each metric
  * the share of runs in which any control frame missed its deadline, with a 95%
    Wilson interval. For narrow-window alignment each run either misses every
    frame or none, so this share is the number that matters there.

  uncertainty.py results_e9
  uncertainty.py results_e9 --validators 16 --csv uncertainty.csv

A metric that does not vary across runs is printed once and marked "const": the
model is deterministic wherever no random option is on, so a zero-width interval
there is a fact about the model, not an estimate.

Two things to keep in mind when you quote these:
  * The interval describes variation over the random draws the patch adds (gate
    phase error, round start phase, validator placement). It says nothing about
    effects that are not modelled.
  * 20 runs gives a usable mean but a rough tail; do not quote p99.9 from it.
"""
import argparse, csv, math, os, sys
from collections import defaultdict

T95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365, 8: 2.306,
       9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145, 15: 2.131,
       16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093, 20: 2.086, 25: 2.060, 30: 2.042,
       40: 2.021, 60: 2.000}


def tcrit(df):
    if df < 1:
        return float('nan')
    ks = [k for k in T95 if k <= df]
    return T95[max(ks)] if df < 120 else 1.96


def wilson(k, n, z=1.96):
    if n == 0:
        return float('nan'), float('nan')
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, c - h), min(1.0, c + h)


def stats(v):
    n = len(v)
    m = sum(v) / n
    sd = math.sqrt(sum((x - m) ** 2 for x in v) / (n - 1)) if n > 1 else 0.0
    half = tcrit(n - 1) * sd / math.sqrt(n) if n > 1 else float('nan')
    return m, half, sd, min(v), max(v)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dirs', nargs='+')
    ap.add_argument('--validators', type=int, default=16, help='committee size, for the commit rate')
    ap.add_argument('--csv', default='uncertainty.csv')
    a = ap.parse_args()

    groups = defaultdict(list)
    for d in a.dirs:
        for r in csv.DictReader(open(os.path.join(d, 'summary.csv'))):
            groups[(r['exp'], r['tag'])].append(r)
    if not groups:
        sys.exit('no rows')

    metrics = [('ctrl_max_us', 'ctrl max us', lambda r: float(r['ctrl_max_us'])),
               ('ctrl_p99_us', 'ctrl p99 us', lambda r: float(r['ctrl_p99_us'])),
               ('miss_ratio', 'miss ratio', lambda r: float(r['miss_ratio'])),
               ('commit', 'commit rate', lambda r: int(r['cons_committed']) / max(1, int(r['cons_rounds']) * a.validators)),
               ('cons_mean_us', 'cons mean us', lambda r: float(r['cons_mean_us'])),
               ('cons_p99_us', 'cons p99 us', lambda r: float(r['cons_p99_us']))]

    out = []
    for (exp, tag) in sorted(groups):
        rows = groups[(exp, tag)]
        n = len(rows)
        runs = sorted({int(r['run']) for r in rows})
        print(f"\n== {exp} {tag}: {n} runs (run ids {runs[0]}..{runs[-1]}) ==")
        late = sum(1 for r in rows if float(r['miss_ratio']) > 0)
        lo, hi = wilson(late, n)
        print(f"   runs with any late frame: {late}/{n} = {late / n:.2f}   (95% Wilson {lo:.2f} to {hi:.2f})")
        out.append((exp, tag, n, 'late_run_share', late / n, '', lo, hi))
        for key, label, f in metrics:
            try:
                v = [f(r) for r in rows]
            except (ValueError, KeyError):
                continue
            m, half, sd, vmin, vmax = stats(v)
            if sd == 0:
                print(f"   {label:>13}: {m:12.4g}   const")
            else:
                print(f"   {label:>13}: {m:12.4g} +/- {half:<10.4g} sd {sd:<10.4g} range {vmin:.4g} to {vmax:.4g}")
            out.append((exp, tag, n, key, m, half, vmin, vmax))
    with open(a.csv, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['exp', 'tag', 'runs', 'metric', 'mean_or_share', 'ci95_half_width', 'min_or_lo', 'max_or_hi'])
        w.writerows(out)
    print(f"\nwrote {a.csv}")


if __name__ == '__main__':
    main()
