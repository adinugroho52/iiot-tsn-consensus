#!/usr/bin/env python3
"""
vc_budget.py -- the consensus-window counting rule (C5) extended to a view change.

C5 compares, on the busiest link, the consensus frames one round sends (M) with
the whole frames the consensus windows pass in one round (C). A view change adds
a one-off burst on top of the steady load:

    B = VIEW-CHANGE (all-to-all from the live nodes) + NEW-VIEW (new primary to all)
        + R x M'                          (R re-proposed rounds, M' = a round's
                                           frames with the new primary and the
                                           faulty nodes silent)

The window drains that burst only with its spare capacity S = C - M' per round.
While it drains, every frame of a new round queues behind it, so a round waits
roughly B/C rounds per phase that crosses the link. If that wait reaches the
view timeout, correct nodes time out with no fault present, send another burst,
and the view changes feed themselves: a storm in a configuration that passes C5.

Predictions for one link, T = round interval, T_vto = view timeout:
    c5fail    with --flood-*, the steady load with the flooder exceeds C
              (c5pass otherwise; no view change is assumed).
    drop      B > 800, the TAS class queue limit: frames are lost, not delayed.
    storm     (B/C) T >= T_vto: even one phase's wait reaches the timeout.
    safe      3 (B/C) T < T_vto: all three phases together stay under it.
    boundary  between the two: the experiment decides.
    drain     B/S rounds until the backlog is gone; with S = 0 it never drains
              and every later round carries the extra delay for good.

These are first-order counts (the burst is treated as arriving at once, and a
round's three phases as crossing the link one after another). They say where to
look; the simulation says what happens.

Usage (defaults are E15's 1 Gbps configuration with a crashed primary):
    tools/vc_budget.py --cons-frac 0.30 --interval-ms 4
    tools/vc_budget.py --cons-frac 0.275 --interval-ms 4 --repropose 2
    tools/vc_budget.py --rate 100e6 --switches 8 --n 10 --cons-frac 0.60 --interval-ms 8
    tools/vc_budget.py --cons-frac 0.30 --interval-ms 4 --crash "" --flood-node 15 --flood-factor 2
    tools/vc_budget.py ... --csv          # one CSV row, for tables

--crash "" models a view change with every node alive (equivocation, a spurious
timeout). A flooding node makes the verdict c5fail when its extra frames alone
exceed the busiest link's capacity.
"""
import argparse
import math
import sys

OVERHEAD = 30          # IP 20 + UDP 8 + PPP 2, as FRAME_OVERHEAD in the simulator
QUEUE_LIMIT = 800      # TAS per-class queue (TransmissonGateQdisc default)
KEEP = 64              # rounds the full model holds (re-proposed with --reproposeWindow=0)


def place(n, switches):
    return [i % switches for i in range(n)]


def path(a, b, sw):
    """Directed links a frame from validator a to validator b crosses."""
    links = [f"v{a}-up"]
    s, t = sw[a], sw[b]
    step = 1 if t > s else -1
    for k in range(s, t, step):
        links.append(f"sw{k}->sw{k + step}")
    links.append(f"v{b}-down")
    return links


MULT = {}             # sender -> copies of every frame (--flood-node/--flood-factor)


def add(load, senders, n, sw):
    """Every sender sends to every other node (also to silent ones: the sockets do)."""
    for a in senders:
        k = MULT.get(a, 1)
        for b in range(n):
            if b != a:
                for l in path(a, b, sw):
                    load[l] = load.get(l, 0) + k


def round_load(n, sw, primary, live, withhold=()):
    load = {}
    if primary in live:
        add(load, [primary], n, sw)                                      # PRE-PREPARE
    add(load, [i for i in live if i != primary], n, sw)                  # PREPARE
    add(load, [i for i in live if i not in withhold], n, sw)             # COMMIT
    return load


def unicast(load, senders, dest, n, sw, frames=1):
    """Every sender sends `frames` frames to one node."""
    for a in senders:
        if a == dest:
            continue
        for l in path(a, dest, sw):
            load[l] = load.get(l, 0) + frames * MULT.get(a, 1)


def to_all(load, sender, n, sw, frames=1):
    for b in range(n):
        if b != sender:
            for l in path(sender, b, sw):
                load[l] = load.get(l, 0) + frames * MULT.get(sender, 1)


def hs_round(n, sw, v, live):
    """Chained HotStuff, view v: leader v mod n proposes to all, every live
    replica votes to the next leader."""
    load = {}
    if v % n in live:
        to_all(load, v % n, n, sw)
    unicast(load, [i for i in live], (v + 1) % n, n, sw)
    return load


def rf_round(n, sw, leader, live):
    """Raft: AppendEntries leader -> each follower, acknowledgement back."""
    load = {}
    to_all(load, leader, n, sw)
    unicast(load, [i for i in live if i != leader], leader, n, sw)
    return load


def sustained(loads):
    """Per link, the mean over a rotation of rounds; the busiest link's mean."""
    links = set().union(*loads)
    mean = {l: sum(L.get(l, 0) for L in loads) / len(loads) for l in links}
    worst = max(max(L.values()) for L in loads)
    return mean, worst


def other_protocol(a, n, sw, C, T, vto):
    """C5 and a first-burst estimate for hotstuff and raft (same verdict rules)."""
    dead = {int(x) for x in a.crash.split(",") if x != ""}
    live = [i for i in range(n) if i not in dead]
    if a.protocol == "hotstuff":
        mean, worst = sustained([hs_round(n, sw, v, list(range(n))) for v in range(n)])
        after, _ = sustained([hs_round(n, sw, v, live) for v in range(n)])
        # A crashed leader costs one timeout each time its turn comes; the next
        # leader proposes a block carrying the rounds of the stall.
        stall = vto
        R = min(KEEP, math.ceil(stall / T))
        newp = next(i for i in range(1, n + 1) if i % n in live) % n
        burst = {}
        unicast(burst, live, newp, n, sw)                       # NEW-VIEW
        to_all(burst, newp, n, sw, frames=R)                    # the catch-up block
        unicast(burst, live, (newp + 1) % n, n, sw)             # its votes
    else:
        mean, worst = sustained([rf_round(n, sw, 0, list(range(n)))])
        newp = next(i for i in range(n) if i in live)
        after, _ = sustained([rf_round(n, sw, newp, live)])
        stall = 1.5 * vto                                       # mean randomised election timeout
        R = min(KEEP, math.ceil(stall / T))
        burst = {}
        to_all(burst, newp, n, sw)                              # RequestVote
        unicast(burst, live, newp, n, sw)                       # votes
        to_all(burst, newp, n, sw, frames=R)                    # entries of the stall
        unicast(burst, live, newp, n, sw)                       # acknowledgements
    # HotStuff: the next leader cannot propose before the votes reach it, so each
    # round must clear the link within the round: the worst round binds, not the
    # mean (p1: a window above the mean but below the worst round collapsed).
    M = worst if a.protocol == "hotstuff" else math.ceil(max(mean.values()))
    bott = max(mean, key=mean.get)
    worst_l = max(burst, key=lambda l: burst[l])
    B, Mp = burst[worst_l], math.ceil(after.get(worst_l, 0))
    return M, worst, bott, 1, newp, stall, R, worst_l, B, Mp


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--n", type=int, default=16)
    ap.add_argument("--switches", type=int, default=4)
    ap.add_argument("--msg", type=int, default=1024, help="consensus message size, B")
    ap.add_argument("--rate", type=float, default=1e9, help="link rate, bit/s")
    ap.add_argument("--cycle-us", type=float, default=1000.0)
    ap.add_argument("--cons-frac", type=float, default=0.30)
    ap.add_argument("--slices", type=int, default=1)
    ap.add_argument("--interval-ms", type=float, default=4.0)
    ap.add_argument("--timeout-ms", type=float, default=None, help="default 4 x interval")
    ap.add_argument("--backoff", type=float, default=2.0)
    ap.add_argument("--crash", default="0", help="comma-separated crashed validators")
    ap.add_argument("--repropose", type=int, default=0, help="--reproposeWindow (0 = all held)")
    ap.add_argument("--flood-node", type=int, default=None,
                    help="validator that sends --flood-factor copies of every frame")
    ap.add_argument("--flood-factor", type=int, default=1)
    ap.add_argument("--protocol", default="pbft", choices=["pbft", "hotstuff", "raft"])
    ap.add_argument("--no-fault", action="store_true",
                    help="no view change: the verdict is C5 alone (c5pass or c5fail)")
    ap.add_argument("--csv", action="store_true")
    a = ap.parse_args(argv)

    n, sw = a.n, place(a.n, a.switches)
    T = a.interval_ms
    vto = a.timeout_ms if a.timeout_ms is not None else 4 * T
    tau_us = (a.msg + OVERHEAD) * 8 / a.rate * 1e6
    per_slice = math.floor((a.cons_frac * a.cycle_us / a.slices) / tau_us)
    C = round(T * 1000 / a.cycle_us) * a.slices * per_slice
    dead = {int(x) for x in a.crash.split(",") if x != ""}
    live = [i for i in range(n) if i not in dead]

    if a.protocol != "pbft":
        M, Mworst, bott, views, newp, stall, R, worst, B, Mp = other_protocol(a, n, sw, C, T, vto)
        S = C - Mp
        wait1 = B / C * T
        verdict = ("drop" if B > QUEUE_LIMIT else "storm" if wait1 >= vto
                   else "safe" if 3 * wait1 < vto else "boundary")
        if a.no_fault:
            verdict = "c5pass" if M <= C else "c5fail"
        drain = (B / S) if S > 0 else math.inf
        if a.csv:
            print("C,M,Mflood,C5,views,new_primary,stall_ms,R,burst_link,B,Mprime,S,wait_ms,"
                  "wait3_ms,timeout_ms,drain_rounds,verdict")
            print(",".join(str(x) for x in [C, M, M, "pass" if M <= C else "fail", views, newp,
                  f"{stall:.1f}", R, worst, B, Mp, S, f"{wait1:.2f}", f"{3 * wait1:.2f}",
                  f"{vto:.1f}", "inf" if math.isinf(drain) else f"{drain:.1f}", verdict]))
            return 0
        print(f"protocol             {a.protocol}")
        print(f"capacity C           {C} frames/round  (frame {tau_us:.3f} us)")
        how = ("worst single round, which binds; the mean over the leader rotation is "
               "lower" if a.protocol == "hotstuff" else "fixed leader")
        print(f"normal load M        {M} on {bott} ({how}) -> C5 {'pass' if M <= C else 'FAIL'}"
              f" (slack {C - M})")
        print(f"fault                crashed {sorted(dead) or '-'}; next leader {newp}; "
              f"stall {stall:.1f} ms")
        print(f"catch-up             R = {R} rounds in one message (R frames per receiver)")
        print(f"burst                B = {B} frames on {worst}  (steady M' = {Mp}, spare S = {S})")
        print(f"wait behind burst    {wait1:.2f} ms one phase, {3 * wait1:.2f} ms three; "
              f"timeout {vto:.1f} ms")
        print(f"prediction           {verdict}")
        return 0

    normal = round_load(n, sw, 0, list(range(n)))
    M = max(normal.values())
    bott = max(normal, key=normal.get)
    # A flooding node: C5 again with its frames multiplied (steady state, no view change).
    Mflood = M
    if a.flood_node is not None and a.flood_factor > 1:
        MULT[a.flood_node] = a.flood_factor
        Mflood = max(round_load(n, sw, 0, list(range(n))).values())
        MULT.clear()

    # Views until a live primary: each dead primary costs one timeout, doubling.
    views, stall = 1, vto
    while (views % n) in dead:
        stall += vto * a.backoff ** views
        views += 1
    newp = views % n
    after = round_load(n, sw, newp, live)
    pending = min(KEEP, math.ceil(stall / T))
    R = min(pending, a.repropose) if a.repropose > 0 else pending

    burst = {}
    for _ in range(views):                       # one VIEW-CHANGE round per view
        add(burst, live, n, sw)
    add(burst, [newp], n, sw)                    # NEW-VIEW
    for l, v in after.items():
        burst[l] = burst.get(l, 0) + R * v

    # The link that waits longest after the burst.
    worst = max(burst, key=lambda l: burst[l])
    B, Mp = burst[worst], after.get(worst, 0)
    S = C - Mp
    wait1 = B / C * T
    if a.no_fault:
        verdict = "c5pass" if M <= C else "c5fail"
    elif a.flood_node is not None:
        # Flooding provokes no view change by itself: only the steady count matters.
        verdict = "c5fail" if Mflood > C else "c5pass"
    elif B > QUEUE_LIMIT:
        verdict = "drop"
    elif wait1 >= vto:
        verdict = "storm"
    elif 3 * wait1 < vto:
        verdict = "safe"
    else:
        verdict = "boundary"
    drain = (B / S) if S > 0 else math.inf

    if a.csv:
        cols = ["C", "M", "Mflood", "C5", "views", "new_primary", "stall_ms", "R", "burst_link",
                "B", "Mprime", "S", "wait_ms", "wait3_ms", "timeout_ms", "drain_rounds",
                "verdict"]
        vals = [C, M, Mflood, "pass" if M <= C else "fail", views, newp, f"{stall:.1f}", R, worst, B,
                Mp, S, f"{wait1:.2f}", f"{3 * wait1:.2f}", f"{vto:.1f}",
                "inf" if math.isinf(drain) else f"{drain:.1f}", verdict]
        print(",".join(cols))
        print(",".join(str(v) for v in vals))
        return 0

    print(f"capacity C           {C} frames/round  ({per_slice} per slice x {a.slices} x "
          f"{round(T * 1000 / a.cycle_us)} cycles; frame {tau_us:.3f} us)")
    print(f"normal load M        {M} on {bott}  -> C5 {'pass' if M <= C else 'FAIL'}"
          f" (slack {C - M})")
    if Mflood != M:
        print(f"with flooding        {Mflood} on the busiest link (node {a.flood_node} x "
              f"{a.flood_factor}) -> C5 {'pass' if Mflood <= C else 'FAIL'}")
    print(f"fault                crashed {sorted(dead) or '-'}; {views} view change(s) to "
          f"primary {newp}; stall {stall:.1f} ms")
    print(f"re-proposed rounds   R = {R}  (pending {pending}"
          f"{', window ' + str(a.repropose) if a.repropose else ''})")
    print(f"burst                B = {B} frames on {worst}  (steady M' = {Mp}, spare S = {S})")
    print(f"wait behind burst    {wait1:.2f} ms one phase, {3 * wait1:.2f} ms three phases;"
          f" timeout {vto:.1f} ms")
    print(f"drain                {'never (S <= 0)' if math.isinf(drain) else f'{drain:.1f} rounds'}")
    print(f"prediction           {verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
