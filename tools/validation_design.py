#!/usr/bin/env python3
"""
validation_design.py -- choose the validation cells for tools/recovery_rule.py and
register its predictions before anything runs.

    tools/validation_design.py tools/validation/v1_cells.csv

Every cell is in a configuration no earlier set used (round intervals of 6, 8,
10 and 12 ms; HotStuff and Raft at n = 10 and at 100 Mbps; PBFT at n = 10 and 16
on new windows), and inside the rule's stated domain: a one-off fault (crash or
equivocation) with a timeout above the normal latency, plus a few no-fault cells
at each new configuration's C5 edge. Within each group of configurations the
script picks the candidates whose predicted wait / timeout lies nearest 0.7, 0.9,
1.1 and 1.3, so the set straddles the boundary rather than sitting far from it.

beta is fixed at 0.9 here, before the runs (the middle of the 0.85-0.95 range
that f1 and f4 gave). The output lists each cell with its simulator flags, the
predicted outcome and the margin. Commit it and record its SHA-256 before
running tools/fault_sweep.sh v1: that is the registration.
"""
import csv
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import recovery_rule as rr  # noqa: E402

BETA = 0.9
TARGETS = (0.7, 0.9, 1.1, 1.3)
WIN = "--attackStart=1.0s --attackStop=2.5s"


def flags(proto, n, net, k, T, catchup, attack, to_rounds, window):
    rate = "1Gbps" if net == "g" else "100Mbps"
    sw = 4 if net == "g" else 8
    frame_us = rr.FRAME_US * (1 if net == "g" else 10)
    frac = (k * frame_us + 4) / 1000
    f = (f"--linkRate={rate} --nSwitches={sw} --nValidators={n} --consensusMsgSize=1024 "
         f"--consFrac={frac:.4f} --consensusInterval={T}ms --protocol={proto}")
    if catchup:
        f += f" --raftCatchup={catchup}"
    if attack in ("crash", "equivocate"):
        f += f" --attack={attack} {WIN}"
    f += f" --viewTimeout={int(to_rounds * T * 1000)}us"
    if proto == "pbft":
        f += f" --reproposeWindow={window}"
    return f


def cell_name(proto, n, net, k, T, catchup, attack, to_rounds, window):
    tag = {"pbft": "pbft", "hotstuff": "hs", "raft": "raft"}[proto]
    cfg = f"{tag}n{n}{net}k{k}{'c%d' % catchup if catchup else ''}t{T}"
    name = f"v1-{cfg}-{attack}-to{to_rounds:g}"
    if proto == "pbft":
        name += f"-w{window}"
    return name


# Groups of new configurations: (protocol, n, net, T, k range, attacks, timeouts, windows, catch-ups)
GROUPS = [
    ("pbft", 16, "g", 6, range(22, 60), ("crash", "equivocate"), (4,), (0,), (0,)),
    ("pbft", 16, "g", 8, range(16, 50), ("crash",), (2, 4), (0,), (0,)),
    ("pbft", 16, "g", 6, range(22, 40), ("crash", "equivocate"), (2,), (2,), (0,)),
    ("pbft", 10, "g", 6, range(8, 30), ("crash", "equivocate"), (4,), (0,), (0,)),
    ("pbft", 10, "m", 10, range(5, 10), ("crash", "equivocate"), (2, 4), (0, 2), (0,)),
    ("hotstuff", 10, "g", 4, range(3, 12), ("crash", "equivocate"), (2, 4), (0,), (0,)),
    ("hotstuff", 16, "g", 6, range(3, 12), ("crash", "equivocate"), (2, 4), (0,), (0,)),
    ("hotstuff", 10, "m", 8, range(2, 10), ("crash", "equivocate"), (2, 4), (0,), (0,)),
    ("raft", 10, "g", 4, range(3, 40), ("crash",), (2, 4), (0,), (0, 2, 4)),
    ("raft", 16, "g", 6, range(3, 40), ("crash",), (2, 4), (0,), (2, 4)),
    ("raft", 10, "m", 8, range(2, 10), ("crash",), (2, 4), (0,), (0, 2, 4)),
]


def main(argv):
    if not argv:
        sys.exit(__doc__)
    out = argv[0]
    chosen = []
    for proto, n, net, T, ks, attacks, tos, wins, cus in GROUPS:
        cands = []
        for k in ks:
            for atk in attacks:
                for to in tos:
                    for w in wins:
                        for cu in cus:
                            name = cell_name(proto, n, net, k, T, cu, atk, to, w)
                            c = rr.parse_cell(name)
                            pred, why = rr.predict(c, BETA)
                            if why.startswith("C5"):
                                continue                       # steady-state cells come below
                            cands.append((c["margin"], name, pred, why,
                                          flags(proto, n, net, k, T, cu, atk, to, w), atk, to, w))
        used = set()
        for tgt in TARGETS:
            best = min((x for x in cands if x[1] not in used and x[0] is not None),
                       key=lambda x: abs(x[0] - tgt), default=None)
            if best and abs(best[0] - tgt) <= 0.08:
                used.add(best[1])
                chosen.append(best)
    # No-fault cells at the C5 edge of each new HotStuff and Raft configuration.
    for proto, n, net, T in (("hotstuff", 10, "g", 4), ("hotstuff", 10, "m", 8),
                             ("raft", 10, "g", 4), ("raft", 10, "m", 8)):
        for k in range(1, 12):
            name = cell_name(proto, n, net, k, T, 0, "none", 4, 0)
            c = rr.parse_cell(name)
            pred, why = rr.predict(c, BETA)
            if pred == "ok":                                   # the smallest k that passes, and one below
                for kk in (k - 1, k):
                    nm = cell_name(proto, n, net, kk, T, 0, "none", 4, 0)
                    cc = rr.parse_cell(nm)
                    p2, w2 = rr.predict(cc, BETA)
                    chosen.append((None, nm, p2, w2, flags(proto, n, net, kk, T, 0, "none", 4, 0),
                                   "none", 4, 0))
                break

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["cell", "set", "config", "attack", "timeout_rounds", "window", "prediction",
                    "margin", "beta", "reason", "flags"])
        for m, name, pred, why, fl, atk, to, win in chosen:
            parts = name.split("-")
            w.writerow([name, "v1", parts[1], atk, f"{to:g}", win, pred,
                        "-" if m is None else f"{m:.3f}", BETA, why, fl])
    digest = hashlib.sha256(open(out, "rb").read()).hexdigest()
    fails = sum(1 for x in chosen if x[2] == "fail")
    band = sum(1 for x in chosen if x[0] is not None and abs(x[0] - 1) <= 0.10)
    print(f"{len(chosen)} cells: {fails} predicted to fail, {len(chosen) - fails} to recover, "
          f"{band} inside the +-10% band")
    print(f"wrote {out}\nsha256 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
