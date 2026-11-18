#!/usr/bin/env python3
"""
frontier.py -- feasibility frontier for the control burst sweeps (sweep.sh e7,
also reads e6 cells).

For each shaper and path length it finds the largest control burst B (frames per
cycle) that still meets a deadline, with no late frame and no dropped frame.

Why it works offline: every cell writes one latency per delivered frame, so any
deadline can be applied here without rerunning. Dropped frames never reach the
sink, so they are counted from the number expected, not from the summary's
miss ratio, which only sees frames that arrived.

  frontier.py results_e7_1G [results_e7_100M ...]
  frontier.py results_e7_1G --deadlines 150,250,500,1000 --plot frontier.png

A cell fails a deadline when (late + lost) / expected > --tol (default 0). The
frontier is the largest B for which that cell and every smaller B in the grid
pass. For TAS a closed form is printed beside it:

    min(capacity - 1, floor((D - hops * hop) / frame) + 1)
    capacity = floor(window / frame) + 1       (measured, see the 95 B run)

capacity - 1 because a run exactly at capacity keeps a stuck backlog.
Tags are read as  <shaper>-s<switches>-b<burst>  (e7),  b<burst>  (e6, 4
switches assumed), or  <shaper>-s<switches>  (e5, burst 1 assumed; pass
--burst N if those cells were run with --extra --ctrlBurst=N).

Joint map (e8 cells, tag <shaper>-s<sw>-n<validators>-m<bytes>-b<burst>): for each
committee size x message size it prints the largest control burst for which
control meets the deadline AND consensus still commits at least --commit-min of
its rounds (default 99%; add --cons-p99 US for a commit-latency limit). "x" means
consensus already fails at the smallest burst; 0 means control fails there.
"""
import argparse, csv, math, os, re, sys
from collections import defaultdict


def rate_bps(s):
    m = re.match(r'([\d.]+)\s*([GMK]?)bps', s, re.I)
    return float(m.group(1)) * {'G': 1e9, 'M': 1e6, 'K': 1e3, '': 1}[m.group(2).upper()]


def latencies(path):
    with open(path) as f:
        return [int(x) for x in f.read().split() if x.lstrip('-').isdigit()]


def measured(logpath):
    txt = open(logpath).read()
    m = re.search(r'measured over\s+\[([\d.]+) s,\s*([\d.]+) s\]', txt)
    return (float(m.group(1)), float(m.group(2))) if m else None


def parse_tag(tag, burst_default):
    """-> (shaper, switches, burst, validators, msg_bytes); last two None unless e8."""
    m = re.match(r'^(tas|prio|fifo)-s(\d+)-n(\d+)-m(\d+)-b(\d+)$', tag)
    if m:
        return m.group(1), int(m.group(2)), int(m.group(5)), int(m.group(3)), int(m.group(4))
    m = re.match(r'^(?:(tas|prio|fifo)-s(\d+)-)?b(\d+)$', tag)
    if m:
        return m.group(1), int(m.group(2) or 4), int(m.group(3)), None, None
    m = re.match(r'^(tas|prio|fifo)-s(\d+)$', tag)
    if m:
        return m.group(1), int(m.group(2)), burst_default, None, None
    return None


def load(d, burst_default, payload, validators):
    cells = []
    for r in csv.DictReader(open(os.path.join(d, 'summary.csv'))):
        p = parse_tag(r['tag'], burst_default)
        if not p:
            continue
        sh, s, B, n, msg = p
        sh = sh or r['shaper'].split()[0]
        cf = os.path.join(d, 'csv', r['cell'] + '.csv')
        lf = os.path.join(d, 'log', r['cell'] + '.log')
        if not (os.path.exists(cf) and os.path.exists(lf)):
            print(f"skip {r['cell']}: missing csv or log", file=sys.stderr)
            continue
        win = measured(lf)
        if not win:
            print(f"skip {r['cell']}: no 'measured over' line", file=sys.stderr)
            continue
        a, b = win
        sent = int(r['ctrl_sent'])
        ticks = sent / B
        period = b / ticks                      # sources start at 0.1 s and stop at stopAt = b + 0.1 s
        expected = B * round((b - a) / period)
        nn = n or validators
        rounds = int(r['cons_rounds'] or 0)
        commit = int(r['cons_committed'] or 0) / (rounds * nn) if rounds else 0.0
        cells.append(dict(cell=r['cell'], shaper=sh, s=s, B=B, link=r['link'], n=n, msg=msg,
                          commit=commit, cons_p99=float(r['cons_p99_us'] or 0),
                          win_us=float(r['ctrl_win_us']), lat=latencies(cf),
                          expected=expected, payload=payload))
    return cells


def tas_closed_form(c, D):
    rate = rate_bps(c['link'])
    tf = (c['payload'] + 30) * 8 / rate * 1e6
    hop = tf + 0.1
    cap = math.floor(c['win_us'] / tf) + 1
    k = math.floor((D - (c['s'] + 1) * hop) / tf) + 1 if D >= (c['s'] + 1) * hop else 0
    return min(cap - 1, k)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dirs', nargs='+')
    ap.add_argument('--deadlines', default='150,250,500,1000', help='microseconds, comma separated')
    ap.add_argument('--tol', type=float, default=0.0, help='allowed fraction of late or lost frames')
    ap.add_argument('--burst', type=int, default=1, help='burst for tags that carry none (e5 cells)')
    ap.add_argument('--payload', type=int, default=64)
    ap.add_argument('--validators', type=int, default=16, help='committee size for cells whose tag carries none')
    ap.add_argument('--commit-min', type=float, default=0.99, help='consensus feasible if this share of rounds commit')
    ap.add_argument('--cons-p99', type=float, default=0.0, help='optional commit-latency limit in us (0 = off)')
    ap.add_argument('--plot', default='')
    ap.add_argument('--csv', default='frontier.csv')
    a = ap.parse_args()
    deadlines = [float(x) for x in a.deadlines.split(',')]

    cells = []
    for d in a.dirs:
        cells += load(d, a.burst, a.payload, a.validators)
    if not cells:
        sys.exit('no usable cells')

    # per cell verdicts
    print(f"{'link':>7} {'shaper':>6} {'sw':>3} {'B':>4} {'delivered':>9} {'lost%':>7} {'max us':>9}")
    for c in sorted(cells, key=lambda c: (c['link'], c['shaper'], c['s'], c['B'])):
        c['lost'] = max(0, c['expected'] - len(c['lat']))
        print(f"{c['link']:>7} {c['shaper']:>6} {c['s']:>3} {c['B']:>4} {len(c['lat']):>9} "
              f"{100 * c['lost'] / c['expected']:>7.2f} {max(c['lat']) / 1000:>9.2f}")

    # Control-only frontier: e5/e6/e7 cells, which share one fixed consensus load.
    # e8 cells vary the consensus load, so they are kept out of this grid and
    # reported only in the joint map below.
    grid = defaultdict(list)
    for c in cells:
        if c['n'] is None:
            grid[(c['link'], c['shaper'], c['s'])].append(c)

    out = []
    for D in deadlines if grid else []:
        print(f"\n=== deadline {D:g} us: largest feasible burst (frames per cycle) ===")
        links = sorted({k[0] for k in grid})
        for link in links:
            sws = sorted({k[2] for k in grid if k[0] == link})
            print(f"-- {link}")
            print(f"{'':>10}" + ''.join(f"{'s=' + str(s):>8}" for s in sws))
            for sh in ('tas', 'prio', 'fifo'):
                row = []
                for s in sws:
                    cs = sorted(grid.get((link, sh, s), []), key=lambda c: c['B'])
                    best = 0
                    for c in cs:
                        late = sum(1 for v in c['lat'] if v > D * 1000)
                        bad = (late + c['lost']) / c['expected']
                        if bad > a.tol:
                            break
                        best = c['B']
                    row.append(best if cs else None)
                    out.append((link, sh, s, D, best if cs else ''))
                print(f"{sh:>10}" + ''.join(f"{'-' if v is None else v:>8}" for v in row))
            ref = [grid[(link, 'tas', s)][0] for s in sws if grid.get((link, 'tas', s))]
            if ref:
                print(f"{'TAS model':>10}" + ''.join(f"{tas_closed_form(c, D):>8}" for c in ref))
    joint = [c for c in cells if c['n'] is not None]
    jrows = []
    for D in deadlines if joint else []:
        print(f"\n=== joint map, deadline {D:g} us: largest control burst per validators x bytes "
              f"(x = consensus fails: commit < {a.commit_min:.0%}) ===")
        for link in sorted({c['link'] for c in joint}):
            for s in sorted({c['s'] for c in joint if c['link'] == link}):
                keys = sorted({(c['n'], c['msg']) for c in joint if c['link'] == link and c['s'] == s})
                print(f"-- {link}, {s} switches")
                print(f"{'':>10}" + ''.join(f"{n}x{m}".rjust(10) for n, m in keys))
                for sh in ('tas', 'prio', 'fifo'):
                    row = []
                    for n, m in keys:
                        cs = sorted([c for c in joint if (c['link'], c['shaper'], c['s'], c['n'], c['msg']) == (link, sh, s, n, m)],
                                    key=lambda c: c['B'])
                        res = ''
                        for i, c in enumerate(cs):
                            cons_ok = c['commit'] >= a.commit_min and (not a.cons_p99 or c['cons_p99'] <= a.cons_p99)
                            late = sum(1 for v in c['lat'] if v > D * 1000)
                            ctrl_ok = (late + c['lost']) / c['expected'] <= a.tol
                            if i == 0 and not cons_ok:
                                res = 'x'
                                break
                            if not (cons_ok and ctrl_ok):
                                break
                            res = c['B']
                        row.append(0 if (cs and res == '') else res)
                        jrows.append((link, sh, s, n, m, D, row[-1]))
                    print(f"{sh:>10}" + ''.join(str(v).rjust(10) for v in row))
    if jrows:
        with open('joint.csv', 'w', newline='') as f:
            w = csv.writer(f)
            w.writerow(['link', 'shaper', 'switches', 'validators', 'msg_bytes', 'deadline_us', 'max_burst_or_x'])
            w.writerows(jrows)
        print("wrote joint.csv")

    with open(a.csv, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['link', 'shaper', 'switches', 'deadline_us', 'max_feasible_burst'])
        w.writerows(out)
    print(f"\nwrote {a.csv}")

    if a.plot and not out:
        print('nothing to plot: the control-only frontier needs e5/e6/e7 cells')
    elif a.plot:
        try:
            import matplotlib
            matplotlib.use('Agg')
            import matplotlib.pyplot as plt
        except ImportError:
            sys.exit('matplotlib not installed; skipping --plot')
        links = sorted({k[0] for k in grid})
        fig, ax = plt.subplots(len(links), len(deadlines), figsize=(4 * len(deadlines), 3.2 * len(links)),
                               squeeze=False, sharex=True)
        for i, link in enumerate(links):
            for j, D in enumerate(deadlines):
                for sh, mk in (('tas', 'o'), ('prio', 's'), ('fifo', '^')):
                    pts = sorted((s, v) for (l, h, s, d, v) in out if l == link and h == sh and d == D and v != '')
                    if pts:
                        ax[i][j].plot([p[0] for p in pts], [p[1] for p in pts], marker=mk, label=sh)
                ax[i][j].set_title(f"{link}, deadline {D:g} us", fontsize=9)
                ax[i][j].set_xlabel('switches')
                ax[i][j].set_ylabel('max frames per cycle')
                ax[i][j].grid(alpha=.3)
        ax[0][0].legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(a.plot, dpi=150)
        print(f"wrote {a.plot}")


if __name__ == '__main__':
    main()
