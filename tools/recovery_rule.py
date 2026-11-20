#!/usr/bin/env python3
"""
recovery_rule.py -- one rule for when a fault turns into a storm, scored on every
fault_sweep.sh cell.

    tools/recovery_rule.py results_fault/summary.csv            # outcomes via fault_report.py
    tools/recovery_rule.py --outcomes outcomes.csv              # cell,outcome[,...] rows
    ... [--beta B | --fit f1] [--list]

THE RULE (for PBFT, chained HotStuff and Raft alike). C and M are the consensus
frames per round the busiest link passes and carries (tools/vc_budget.py; the
worst round for HotStuff, the attacker's frames included). T is the round
interval, T_to the timeout (Raft: the mean election timeout, 1.5 x
--viewTimeout), L0 the normal latency the timeout races: the commit (p99 of a
no-fault run) for PBFT and Raft, the proposal's arrival for HotStuff.

  1. Steady state: if M > C, the configuration fails (C5).
  2. Trigger: a crash or an equivocation always starts a recovery; a timeout
     at or below L0 starts one with no fault at all; flooding that passes C5
     starts none.
  3. Recovery burst B, the frames the recovery puts on the busiest link at once:
       PBFT      VIEW-CHANGE + NEW-VIEW + R re-proposed rounds (vc_budget.py),
                 R = the stalled rounds, capped by --reproposeWindow
       HotStuff  NEW-VIEW + the block carrying the stalled rounds (vc_budget.py)
       Raft      the larger of the post-election catch-up (n-1 followers x
                 min(R, L) entries) and, after a crash, the returning node's
                 backlog (min(window rounds, L) entries); L = --raftCatchup
  4. The burst delays the next rounds by about beta x B / C rounds. If
     L0 + beta x (B / C) x T stays below T_to, the recovery ends: RECOVERS.
  5. Otherwise a second timeout fires. Unbounded recovery (PBFT window 0, Raft
     without a catch-up limit) re-sends everything outstanding, which only
     grows: STORM. Bounded recovery (a PBFT re-propose window, a Raft catch-up
     limit, HotStuff, whose catch-up block carries one stall) storms only if
     there is no spare capacity S = C - M to drain it.

beta is the one free parameter: the share of the counted burst that is queued
at once (the three phases of a round do not arrive together; measured queue
peaks were 0.2-0.5 of B). --fit f1 picks beta on f1 alone and scores the rest
as held out. The rule was written after f1-p3 were seen, so the score measures
how far one mechanism accounts for all of them, not foresight; a fresh set is
the real test.
"""
import argparse
import contextlib
import csv
import io
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vc_budget as vb  # noqa: E402

FRAME_US = 8.432          # 1024 B + 30 B at 1 Gbps
FAULT_S = 1.5             # fault window length in fault_sweep.sh


def parse_cell(cell):
    """Parameters of a fault_sweep.sh cell from its name."""
    parts = cell.split("-")
    st, cfg, atk = parts[0], parts[1], parts[2]
    to = 4.0
    win = 0
    for p in parts[3:]:
        if p.startswith("to"):
            to = float(p[2:])
        elif re.fullmatch(r"w\d+", p):
            win = int(p[1:])
    c = dict(set=st, config=cfg, attack=atk, to_rounds=to, window=win, protocol="pbft",
             n=16, switches=4, rate=1e9, catchup=0)
    m = re.fullmatch(r"w(\d+)t(\d+)", cfg)
    if m:
        c.update(frac=int(m.group(1)) / 1000, T=float(m.group(2)))
    elif cfg == "100mt8":
        c.update(frac=0.60, T=8.0, rate=1e8, n=10, switches=8)
    elif re.fullmatch(r"n(\d+)c(\d+)t(\d+)", cfg):
        n, cc, t = map(int, re.fullmatch(r"n(\d+)c(\d+)t(\d+)", cfg).groups())
        c.update(n=n, frac=((cc // 4) * FRAME_US + 4) / 1000, T=float(t))
    elif re.fullmatch(r"(pbft|hs|raft)n(\d+)([gm])k(\d+)(?:c(\d+))?t(\d+)", cfg):
        # Validation cells: protocol, n, g (1 Gbps, 4 switches) or m (100 Mbps,
        # 8 switches), k frames per cycle, optional Raft catch-up, T.
        pr, n, net, k, L, t = re.fullmatch(
            r"(pbft|hs|raft)n(\d+)([gm])k(\d+)(?:c(\d+))?t(\d+)", cfg).groups()
        rate = 1e9 if net == "g" else 1e8
        c.update(protocol={"pbft": "pbft", "hs": "hotstuff", "raft": "raft"}[pr], n=int(n),
                 rate=rate, switches=4 if net == "g" else 8,
                 frac=(int(k) * FRAME_US * 1e9 / rate + 4) / 1000, T=float(t),
                 catchup=int(L or 0))
    else:
        m = re.fullmatch(r"(pbft|hs|raft)k(\d+)(?:c(\d+))?t(\d+)", cfg)
        if not m:
            raise ValueError("unknown configuration " + cfg)
        proto = {"pbft": "pbft", "hs": "hotstuff", "raft": "raft"}[m.group(1)]
        c.update(protocol=proto, frac=(int(m.group(2)) * FRAME_US + 4) / 1000,
                 T=float(m.group(4)), catchup=int(m.group(3) or 0))
    fl = re.fullmatch(r"flood(\d+)", atk)
    c["flood"] = int(fl.group(1)) if fl else 0
    return c


def budget(c, *extra):
    """vc_budget.py --csv for this cell, as a dict."""
    args = ["--protocol", c["protocol"], "--n", str(c["n"]), "--switches", str(c["switches"]),
            "--rate", str(c["rate"]), "--cons-frac", f"{c['frac']:.4f}",
            "--interval-ms", str(c["T"]), "--timeout-ms", str(c["to_rounds"] * c["T"]),
            "--csv", *extra]
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        vb.main(args)
    head, row = out.getvalue().strip().splitlines()[-2:]
    return dict(zip(head.split(","), row.split(",")))


def flood_load(c):
    """Busiest-link load with node n-1 sending `flood` copies of every frame."""
    n = c["n"]
    sw = vb.place(n, c["switches"])
    vb.MULT.clear()
    vb.MULT[n - 1] = c["flood"]
    try:
        if c["protocol"] == "pbft":
            return max(vb.round_load(n, sw, 0, list(range(n))).values())
        if c["protocol"] == "hotstuff":
            # Every round has a link at the worst-round load (the leader's uplink,
            # the next leader's downlink), so that binds; the flooder adds its
            # extra frames once per rotation, when it leads, so only its mean over
            # the rotation can overload a link.
            loads = [vb.hs_round(n, sw, v, list(range(n))) for v in range(n)]
            mean, _ = vb.sustained(loads)
            vb.MULT.clear()
            worst = max(max(vb.hs_round(n, sw, v, list(range(n))).values()) for v in range(n))
            return max(worst, math.ceil(max(mean.values())))
        return max(vb.rf_round(n, sw, 0, list(range(n))).values())
    finally:
        vb.MULT.clear()


# p99 commit latency of the no-fault reference runs (f2 cells with a 2-round
# timeout, which never fires; p1 cells). Configurations without one use the
# protocol's default below.
MEASURED_L0 = {
    ("pbft", "w300t6"): 3.60, ("pbft", "w300t4"): 3.63, ("pbft", "w275t4"): 4.42,
    ("pbft", "100mt8"): 7.62,
    ("raft", "raftk4t4"): 8.43, ("raft", "raftk5t4"): 7.44, ("raft", "raftk35t4"): 4.56,
}


def normal_latency_ms(c):
    """L0: the normal latency the timeout races. PBFT and Raft time the commit
    (p99 from the p1 and f2 no-fault runs); HotStuff's pacemaker times only the
    proposal's arrival, one network hop after the tick, not the three-round commit."""
    if c["protocol"] == "hotstuff":
        return 1.0
    base = re.sub(r"c\d+t", "t", c["config"]) if c["protocol"] == "raft" else c["config"]
    if (c["protocol"], base) in MEASURED_L0:
        return MEASURED_L0[(c["protocol"], base)]
    if c["protocol"] == "raft":
        return c["T"] + 0.6              # followers learn the commit a tick later
    return 7.6 if c["rate"] < 1e9 else 3.6


def predict(c, beta):
    """('fail' | 'ok', reason). Sets c['margin'] to wait / timeout where it applies."""
    c["margin"] = None
    T = c["T"]
    to = c["to_rounds"] * T
    t_eff = 1.5 * to if c["protocol"] == "raft" else to
    L0 = normal_latency_ms(c)
    fault = c["attack"] in ("crash", "equivocate")
    nf = budget(c, "--no-fault", "--crash=")
    C, M = int(nf["C"]), int(nf["M"])
    Meff = flood_load(c) if c["flood"] else M
    if Meff > C:
        return "fail", f"C5: {Meff} > {C}"
    if c["flood"]:
        return "ok", "flood within C5, no recovery"
    if not fault and L0 < t_eff:
        return "ok", f"no trigger: L0 {L0:.1f} < timeout {t_eff:.1f} ms"
    # The recovery burst.
    if c["protocol"] == "raft":
        L = c["catchup"] or math.inf
        R = math.ceil(1.5 * to / T)
        B = (c["n"] - 1) * min(R, L)
        if c["attack"] == "crash":
            B = max(B, min(round(FAULT_S * 1000 / T), L))
        bounded = c["catchup"] > 0
    else:
        crash = "0" if c["attack"] == "crash" else ""
        extra = ["--crash=" + crash]
        if c["protocol"] == "pbft":
            extra += ["--repropose", str(c["window"])]
        B = int(budget(c, *extra)["B"])
        # HotStuff's catch-up block carries only the rounds of one stall, so it is
        # bounded like a PBFT re-propose window.
        bounded = c["protocol"] == "hotstuff" or c["window"] > 0
    wait = L0 + beta * B / C * T
    c["margin"] = wait / t_eff
    if wait < t_eff:
        return "ok", f"recovers: wait {wait:.1f} < timeout {t_eff:.1f} ms (B {B})"
    S = C - M
    if not bounded:
        return "fail", f"unbounded recovery re-triggers: wait {wait:.1f} >= {t_eff:.1f} ms (B {B})"
    # A bounded burst drains at S frames per round; it storms only when nothing
    # drains it (no spare capacity), so the delay never ends.
    if S <= 0:
        return "fail", f"bounded, but no spare capacity to drain it (S = {S})"
    return "ok", f"bounded and drained at {S} frames/round"


def load_outcomes(argv_path, outcomes_path):
    if outcomes_path:
        return {r[0]: r[1] for r in csv.reader(open(outcomes_path)) if r and r[0] != "cell"}
    import fault_report
    rows = list(csv.DictReader(open(argv_path)))
    tmp = argv_path + ".rule.tmp"
    with contextlib.redirect_stdout(io.StringIO()):
        fault_report.main([argv_path, "--csv", tmp])
    res = {r["cell"]: r["outcome"] for r in csv.DictReader(open(tmp))}
    os.unlink(tmp)
    return res if rows else {}


def score(cells, outcomes, beta, sets=None):
    right = total = 0
    for cell, c in cells.items():
        if sets and c["set"] not in sets:
            continue
        pred, _ = predict(c, beta)
        actual = "fail" if outcomes[cell].startswith(("storm", "stuck")) else "ok"
        total += 1
        right += pred == actual
    return right, total


def score_registered(path, outcomes):
    """Registered predictions against what ran; the +-10% band reported apart."""
    reg = list(csv.DictReader(open(path)))
    tally = {"decisive": [0, 0], "band": [0, 0]}
    lines, missing = [], []
    for r in reg:
        cell = r["cell"]
        if cell not in outcomes:
            missing.append(cell)
            continue
        actual = "fail" if outcomes[cell].startswith(("storm", "stuck")) else "ok"
        m = float(r["margin"]) if r["margin"] not in ("", "-") else None
        kind = "band" if m is not None and abs(m - 1) <= 0.10 else "decisive"
        ok = r["prediction"] == actual
        tally[kind][0] += ok
        tally[kind][1] += 1
        lines.append(f"  {'ok  ' if ok else 'MISS'} {cell:36} {kind:8} predicted {r['prediction']:4} "
                     f"ran {outcomes[cell]:16} margin {r['margin']}")
    for k, (rt, tt) in tally.items():
        print(f"  {k:8} {rt} of {tt}")
    if missing:
        print(f"  not run yet: {len(missing)} ({', '.join(missing[:4])}{' ...' if len(missing) > 4 else ''})")
    print()
    print("\n".join(lines))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("summary", nargs="?")
    ap.add_argument("--outcomes")
    ap.add_argument("--beta", type=float, default=None)
    ap.add_argument("--fit", default=None, help="comma-separated sets to fit beta on")
    ap.add_argument("--list", action="store_true", help="every cell, not only the misses")
    ap.add_argument("--registered", help="score predictions registered in this CSV "
                    "(cell,prediction,margin,...) instead of computing them")
    a = ap.parse_args(argv)
    if not a.summary and not a.outcomes:
        sys.exit(__doc__)
    outcomes = load_outcomes(a.summary, a.outcomes)
    if a.registered:
        return score_registered(a.registered, outcomes)
    cells = {}
    for cell in outcomes:
        try:
            cells[cell] = parse_cell(cell)
        except ValueError as e:
            print(f"skipped {cell}: {e}")

    grid = [round(0.05 * i, 2) for i in range(1, 21)]
    if a.beta is not None:
        beta, how = a.beta, "given"
    else:
        fit = set((a.fit or "f1").split(","))
        best = max(grid, key=lambda b: (score(cells, outcomes, b, fit)[0], -abs(b - 0.5)))
        beta, how = best, f"fitted on {','.join(sorted(fit))}"
        print("beta  " + "  ".join(f"{b:.2f}:{score(cells, outcomes, b, fit)[0]}" for b in grid))

    print(f"\nbeta = {beta:.2f} ({how})\n")
    by_set = {}
    misses = []
    for cell, c in sorted(cells.items()):
        pred, why = predict(c, beta)
        actual = "fail" if outcomes[cell].startswith(("storm", "stuck")) else "ok"
        ok = pred == actual
        s = by_set.setdefault(c["set"], [0, 0])
        s[0] += ok
        s[1] += 1
        near = c["margin"] is not None and abs(c["margin"] - 1) <= 0.10
        if not ok:
            s.append(near)
        if a.list or not ok:
            m = f"{c['margin']:.2f}" if c["margin"] is not None else "  - "
            misses.append(f"  {'ok  ' if ok else 'MISS'} {cell:34} rule {pred:4}  ran {outcomes[cell]:16} "
                          f"wait/timeout {m}  {why}")
    fit_sets = set((a.fit or "f1").split(",")) if a.beta is None else set()
    for st in sorted(by_set):
        r, t = by_set[st][:2]
        tag = "  (fit)" if st in fit_sets else ""
        print(f"  {st:3} {r:3} of {t:3}{tag}")
    held = [v for k, v in by_set.items() if k not in fit_sets]
    hr, ht = sum(v[0] for v in held), sum(v[1] for v in held)
    ar, at = sum(v[0] for v in by_set.values()), sum(v[1] for v in by_set.values())
    nearmiss = sum(sum(1 for x in v[2:] if x) for v in by_set.values())
    print(f"  all {ar:3} of {at:3}   held out {hr} of {ht}")
    print(f"  misses within 10% of the wait = timeout boundary: {nearmiss} of {at - ar}\n")
    print("\n".join(misses))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
