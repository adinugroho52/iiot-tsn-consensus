#!/usr/bin/env python3
"""
assemble_results.py -- every table and figure of the second paper from the sweep
results, in one run.

    tools/assemble_results.py results_fault/summary.csv \\
        --csvdir results_fault/csv --registered tools/validation/v1_cells.csv \\
        --out results_paper

Writes to --out:
  all_cells.csv          one row per cell: parameters, C and M, outcome (as
                         fault_report.py classifies it), the recovery rule's
                         prediction and margin at beta 0.9, and the key figures
  table_*.csv/.tex       T1 protocols, T2 headroom, T3 f1 grid, T4 rule scores,
                         T5 control isolation (booktabs LaTeX, IEEEtran-ready)
  fig_*.pdf/.png         timeline, headroom, protocols, rule margin
  README.txt             what each file holds and where it came from

A set or a figure whose cells are missing is skipped with a note, so the script
can run on a partial sweep. Matplotlib is the only dependency beyond the tools.
"""
import argparse
import contextlib
import csv
import io
import math
import os
import sys
import zlib
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fault_report  # noqa: E402
import recovery_rule as rr  # noqa: E402

BETA = 0.9
# Categorical slots 1-3 of the validated reference palette (all-pairs safe).
BLUE, ORANGE, AQUA = "#2a78d6", "#eb6834", "#1baf7a"
INK, INK2, GRID = "#0b0b0b", "#52514e", "#e4e3df"
FAIL = ("storm", "stuck")
PROTOCOLS = ("pbft", "hotstuff")


def classify(summary):
    rows = list(csv.DictReader(open(summary)))
    if rows and "outcome" in rows[0]:
        return rows
    tmp = summary + ".asm.tmp"
    with contextlib.redirect_stdout(io.StringIO()):
        fault_report.main([summary, "--csv", tmp])
    rows = list(csv.DictReader(open(tmp)))
    os.unlink(tmp)
    return rows


def enrich(rows):
    out = []
    for r in rows:
        try:
            c = rr.parse_cell(r["cell"])
        except ValueError:
            continue
        pred, why = rr.predict(c, BETA)
        nf = rr.budget(c, "--no-fault", "--crash=")
        C, M = int(nf["C"]), int(nf["M"])
        # Parameters from the cell name (as recovery_rule.py reads them), so the
        # tables do not depend on how a summary row was written.
        r.update(config=c["config"], attack=c["attack"], timeout_rounds=f"{c['to_rounds']:g}",
                 window=str(c["window"]), set=c["set"])
        r.update(protocol=c["protocol"], n=c["n"], T_ms=c["T"], C=C, M=M, spare=C - M,
                 spare_share=f"{(C - M) / M:.3f}", rule_prediction=pred,
                 rule_margin="" if c["margin"] is None else f"{c['margin']:.3f}", rule_reason=why,
                 failed="1" if r["outcome"].startswith(FAIL) else "0")
        out.append(r)
    return out


def num(x, default=float("nan")):
    try:
        return float(x)
    except (TypeError, ValueError):
        return default


# ---- tables -----------------------------------------------------------------------

def write_table(out, name, header, body, caption, label, notes=""):
    with open(os.path.join(out, f"table_{name}.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(body)
    esc = lambda s: str(s).replace("%", r"\%").replace("_", r"\_").replace("&", r"\&")
    with open(os.path.join(out, f"table_{name}.tex"), "w") as f:
        f.write("\\begin{table}[t]\n\\centering\n")
        f.write(f"\\caption{{{caption}}}\n\\label{{{label}}}\n")
        f.write("\\begin{tabular}{" + "l" + "r" * (len(header) - 1) + "}\n\\toprule\n")
        f.write(" & ".join(esc(h) for h in header) + " \\\\\n\\midrule\n")
        for row in body:
            f.write(" & ".join(esc(x) for x in row) + " \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")
        if notes:
            f.write(f"\\\\[2pt]\\footnotesize {esc(notes)}\n")
        f.write("\\end{table}\n")


def t1_protocols(cells, out):
    p1 = [c for c in cells if c["set"] == "p1"]
    if not p1:
        return "T1 skipped: no p1 cells"
    body = []
    for proto in PROTOCOLS:
        mine = sorted((c for c in p1 if c["protocol"] == proto), key=lambda c: c["C"])
        if not mine:
            continue
        ok = [c for c in mine if c["failed"] == "0"]
        edge = min(ok, key=lambda c: c["C"]) if ok else None
        wide = max(mine, key=lambda c: c["C"])
        body.append([proto, mine[0]["M"], edge["C"] if edge else "-",
                     f"{num(wide['commit_p50_us']) / 1000:.1f}",
                     f"{num(edge['commit_p50_us']) / 1000:.1f}" if edge else "-",
                     f"{num(edge['commit_p99_us']) / 1000:.1f}" if edge else "-"])
    write_table(out, "protocols",
                ["Protocol", "Load M", "Smallest C passing", "p50 wide (ms)", "p50 at edge (ms)",
                 "p99 at edge (ms)"], body,
                "Busiest-link load per round and the smallest window that works (n = 16, 1 Gb/s, 4 ms rounds)",
                "tab:protocols",
                "M and C in 1024-B frames per round on the busiest link; wide = 35 frames per cycle (C = 140).")
    return f"T1: {len(body)} protocols"


def t2_headroom(cells, out):
    groups = defaultdict(list)
    for c in cells:
        if c["set"] not in ("f4", "f5") or c["window"] not in ("0", 0):
            continue
        if c["attack"] == "crash" and str(c["timeout_rounds"]) not in ("4", "4.0"):
            continue
        if c["attack"] not in ("crash", "equivocate"):
            continue
        groups[(c["attack"], c["n"])].append(c)
    if not groups:
        return "T2 skipped: no f4/f5 cells"
    body = []
    for (atk, n), g in sorted(groups.items()):
        g.sort(key=lambda c: num(c["spare_share"]))
        fails = [num(c["spare_share"]) for c in g if c["failed"] == "1"]
        oks = [num(c["spare_share"]) for c in g if c["failed"] == "0"]
        lo = max(fails) if fails else None
        hi = min(oks) if oks else None
        mono = "yes" if lo is None or hi is None or lo < hi else "no"
        body.append([atk, n, g[0]["M"], f"{lo:.0%}" if lo is not None else "-",
                     f"{hi:.0%}" if hi is not None else "-", mono])
    write_table(out, "headroom",
                ["Trigger", "n", "M", "Largest spare that stormed", "Smallest spare that recovered",
                 "Monotonic"], body,
                "Spare capacity a view change needs with unbounded re-proposal (PBFT, 4 ms rounds)",
                "tab:headroom", "Spare = (C - M) / M on the busiest link; view timeout 4 rounds.")
    return f"T2: {len(body)} groups"


def t3_grid(cells, out):
    f1 = [c for c in cells if c["set"] == "f1"]
    if not f1:
        return "T3 skipped: no f1 cells"
    cfgs = sorted({c["config"] for c in f1}, key=lambda s: ("100m" in s, s))
    cols = [(to, w) for to in ("2", "4", "8") for w in ("0", "2", "1")]
    sym = lambda o: "S" if o.startswith(FAIL) else ("R+" if "delay" in o else "R")
    idx = {(c["config"], str(int(num(c["timeout_rounds"]))), str(c["window"])): c for c in f1}
    body = []
    for cfg in cfgs:
        m = next(c for c in f1 if c["config"] == cfg)
        row = [cfg, m["spare"]]
        for to, w in cols:
            c = idx.get((cfg, to, w))
            row.append(sym(c["outcome"]) if c else "-")
        body.append(row)
    write_table(out, "f1grid", ["Config", "Spare"] + [f"to{to}/w{w}" for to, w in cols], body,
                "Crashed primary: outcome by view timeout (rounds) and re-propose window",
                "tab:f1grid", "S storm, R recovered, R+ recovered with lasting delay; w0 = every held "
                "round re-proposed.")
    return f"T3: {len(body)} configurations"


def t4_rule(cells, out, registered):
    body = []
    outcomes = {c["cell"]: c["outcome"] for c in cells}
    # Development cells: every cell outside the registered validation.
    parsed = {c["cell"]: rr.parse_cell(c["cell"]) for c in cells if not c["set"].startswith("v1")}
    for fit in ("f1", "f4"):
        fitset = {fit}
        if not any(p["set"] == fit for p in parsed.values()):
            continue
        grid = [round(0.05 * i, 2) for i in range(1, 21)]
        sub = {k: v for k, v in parsed.items()}
        best = max(grid, key=lambda b: (rr.score(sub, outcomes, b, fitset)[0], -abs(b - 0.5)))
        r_all, t_all = rr.score(sub, outcomes, best)
        held = {k: v for k, v in sub.items() if v["set"] != fit}
        r_h, t_h = rr.score(held, outcomes, best)
        body.append([f"beta fitted on {fit}", f"{best:.2f}", f"{r_h}/{t_h}", f"{r_all}/{t_all}"])
    if registered and os.path.isfile(registered):
        reg = [r for r in csv.DictReader(open(registered))]
        groups = [("pbft", ("pbft",)), ("hotstuff", ("hotstuff",)), ("all", PROTOCOLS)]
        for label, protos in groups:
            dec = [0, 0]
            band = [0, 0]
            for r in reg:
                p = rr.parse_cell(r["cell"])["protocol"]
                if p not in protos or r["cell"] not in outcomes:
                    continue
                actual = "fail" if outcomes[r["cell"]].startswith(FAIL) else "ok"
                m = num(r["margin"])
                k = band if not math.isnan(m) and abs(m - 1) <= 0.10 else dec
                k[0] += r["prediction"] == actual
                k[1] += 1
            if dec[1] + band[1]:
                body.append([f"v1 registered, {label}", "0.90", f"{dec[0]}/{dec[1]} decisive",
                             f"{band[0]}/{band[1]} band"])
    if not body:
        return "T4 skipped"
    write_table(out, "rule", ["Evaluation", "beta", "Held out / decisive", "All / band"], body,
                "Recovery-burst rule: fitted, held out and registered in advance", "tab:rule",
                "Band: predicted wait within 10% of the timeout, where the rule makes no claim.")
    return f"T4: {len(body)} rows"


def t5_control(cells, out):
    body = []
    for st in sorted({c["set"] for c in cells}):
        g = [c for c in cells if c["set"] == st]
        missed = sum(int(num(c["ctrl_missed"], 0)) for c in g)
        p99 = [num(c["ctrl_p99_us"]) for c in g if not math.isnan(num(c["ctrl_p99_us"]))]
        storms = sum(c["failed"] == "1" for c in g)
        unsafe = sum(int(num(c.get("safety"), 0)) > 0 for c in g)
        body.append([st, len(g), storms, missed, f"{min(p99):.2f}-{max(p99):.2f}" if p99 else "-",
                     unsafe])
    write_table(out, "control", ["Set", "Cells", "Storms", "Deadlines missed", "Control p99 (us)",
                                 "Cells with safety violations"], body,
                "Control-loop isolation and safety over every cell", "tab:control",
                "Control p99 differs between sets only by link rate (4.26 us at 1 Gb/s, 68.58 us at 100 Mb/s).")
    return f"T5: {len(body)} sets"


# ---- figures ----------------------------------------------------------------------

def style(plt):
    plt.rcParams.update({
        "font.size": 8, "axes.titlesize": 8, "axes.labelsize": 8, "legend.fontsize": 7,
        "xtick.labelsize": 7, "ytick.labelsize": 7, "axes.edgecolor": INK2, "axes.labelcolor": INK,
        "xtick.color": INK2, "ytick.color": INK2, "axes.grid": True, "grid.color": GRID,
        "grid.linewidth": 0.6, "axes.axisbelow": True, "axes.spines.top": False,
        "axes.spines.right": False, "legend.frameon": False, "pdf.fonttype": 42,
        "font.family": "serif",
    })


def save(fig, out, name):
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(out, f"fig_{name}.{ext}"), dpi=300, bbox_inches="tight")


def fig_timeline(plt, cells, csvdir, out):
    picks = [("f1-w300t4-crash-to4-w0", "300 \u00b5s, 4 ms: every held round re-proposed", ORANGE, "-", "x", 0),
             ("f1-w300t4-crash-to4-w2", "300 \u00b5s, 4 ms: re-propose window 2", BLUE, "--", "o", 1),
             ("f1-w300t6-crash-to4-w0", "300 \u00b5s, 6 ms: every held round re-proposed", AQUA, ":", "s", 2)]
    have = [p for p in picks if csvdir and os.path.isfile(os.path.join(csvdir, p[0] + "-rounds.csv"))]
    if not have:
        return "timeline skipped: no per-round CSVs"
    fig, ax = plt.subplots(figsize=(3.5, 2.0))
    ax.axvspan(1.0, 2.5, color="#efeeea", lw=0, zorder=0)
    ax.text(1.75, 1.04, "crash", ha="center", va="bottom", color=INK2, fontsize=7,
            transform=ax.get_xaxis_transform())
    BIN = 0.25
    for cell, label, col, ls, mk, off in have:
        t, q = [], []
        for r in csv.DictReader(open(os.path.join(csvdir, cell + "-rounds.csv"))):
            if int(r["opened_ns"]) >= 0:
                t.append(int(r["opened_ns"]) / 1e9)
                q.append(r["quorum_complete"] == "1")
        bins = defaultdict(list)
        for ti, qi in zip(t, q):
            bins[math.floor(ti / BIN)].append(qi)
        xs = sorted(bins)
        ax.plot([(b + 0.5) * BIN for b in xs], [100 * sum(bins[b]) / len(bins[b]) for b in xs],
                color=col, ls=ls, lw=1.5, marker=mk, ms=3.5, markevery=(off, 3), label=label)
    ax.set_xlabel("Time the round opened (s)")
    ax.set_ylabel("Rounds reaching a quorum (%)")
    ax.set_ylim(-3, 105)
    ax.legend(loc="lower left", bbox_to_anchor=(0, -0.62), ncol=1)
    save(fig, out, "timeline")
    plt.close(fig)
    return f"timeline: {len(have)} cells"


def fig_headroom(plt, cells, out):
    pts = [c for c in cells if c["set"] in ("f4", "f5") and str(c["window"]) == "0"
           and c["attack"] in ("crash", "equivocate")
           and not (c["attack"] == "crash" and int(num(c["timeout_rounds"])) != 4)]
    if not pts:
        return "headroom skipped: no f4/f5 cells"
    fig, axes = plt.subplots(1, 2, figsize=(7.16, 1.9), sharey=True)
    ns = sorted({c["n"] for c in pts})
    for ax, atk, line in zip(axes, ("crash", "equivocate"), (25, 40)):
        g = [c for c in pts if c["attack"] == atk]
        for c in g:
            y = ns.index(c["n"])
            x = 100 * num(c["spare_share"])
            if c["failed"] == "1":
                ax.scatter(x, y, marker="x", s=28, color=ORANGE, lw=1.5, zorder=3)
            else:
                ax.scatter(x, y, marker="o", s=26, facecolor="white", edgecolor=BLUE, lw=1.5, zorder=3)
        ax.axvline(line, color=INK2, ls="--", lw=0.8)
        ax.text(line + 1, len(ns) - 0.55, f"{line}%", color=INK2, fontsize=7)
        ax.set_title({"crash": "Crashed primary", "equivocate": "Equivocating primary"}[atk],
                     loc="left", color=INK)
        ax.set_xlabel("Spare capacity, (C - M) / M (%)")
        ax.set_xlim(0, 90)
    axes[0].set_yticks(range(len(ns)))
    axes[0].set_yticklabels([f"n = {n}" for n in ns])
    axes[0].set_ylim(-0.6, len(ns) - 0.4)
    h1 = axes[1].scatter([], [], marker="x", color=ORANGE, lw=1.5, label="storm")
    h2 = axes[1].scatter([], [], marker="o", facecolor="white", edgecolor=BLUE, lw=1.5, label="recovered")
    fig.legend(handles=[h1, h2], loc="upper center", bbox_to_anchor=(0.5, -0.12), ncol=2,
               handletextpad=0.3, columnspacing=1.5)
    save(fig, out, "headroom")
    plt.close(fig)
    return f"headroom: {len(pts)} cells"


def fig_protocols(plt, cells, out):
    p1 = [c for c in cells if c["set"] == "p1"]
    if not p1:
        return "protocols skipped: no p1 cells"
    names = {"pbft": "PBFT", "hotstuff": "HotStuff"}
    rows = []
    for proto in PROTOCOLS:
        mine = [c for c in p1 if c["protocol"] == proto]
        if not mine:
            continue
        ok = [c for c in mine if c["failed"] == "0"]
        wide = max(mine, key=lambda c: c["C"])
        rows.append((names[proto], min(c["C"] for c in ok) if ok else float("nan"),
                     num(wide["commit_p50_us"]) / 1000))
    fig, axes = plt.subplots(1, 2, figsize=(3.5, 0.6 + 0.35 * len(rows)), gridspec_kw={"wspace": 0.15})
    for ax, k, title, unit in ((axes[0], 1, "Window needed", "frames per round"),
                               (axes[1], 2, "Commit latency", "p50, wide window (ms)")):
        vals = [r[k] for r in rows]
        ys = range(len(rows))
        ax.barh(ys, vals, height=0.55, color=BLUE, edgecolor="white", lw=2)
        for y, v in zip(ys, vals):
            ax.text(v, y, f" {v:.0f}" if k == 1 else f" {v:.1f}", va="center", color=INK, fontsize=7)
        ax.set_yticks(list(ys))
        ax.set_yticklabels([r[0] for r in rows] if k == 1 else [])
        ax.invert_yaxis()
        ax.set_title(title, loc="left")
        ax.set_xlabel(unit)
        ax.set_xlim(0, max(vals) * 1.3)
        ax.grid(axis="y", visible=False)
    save(fig, out, "protocols")
    plt.close(fig)
    return f"protocols: {len(rows)}"


def fig_rule(plt, cells, out, registered):
    """Two panels: the cells the rule was developed on (f1-p2), and the
    registered validation cells (v1) alone, so the held-out evidence is not lost
    among the rest. Cells without a margin (C5 verdicts, no trigger) are left out."""
    reg = set()
    if registered and os.path.isfile(registered):
        reg = {r["cell"] for r in csv.DictReader(open(registered))}
    dev = [c for c in cells if c["rule_margin"] and not c["set"].startswith("v1")]
    val = [c for c in cells if c["rule_margin"] and c["cell"] in reg]
    if not dev and not val:
        return "rule skipped"
    rows = list(PROTOCOLS)
    names = {"pbft": "PBFT", "hotstuff": "HotStuff"}
    panels = [(dev, "Development cells (f1-p2)"), (val, "Registered validation (v1)")]
    panels = [p for p in panels if p[0]]
    fig, axes = plt.subplots(1, len(panels), figsize=(7.16, 1.7), sharey=True,
                             gridspec_kw={"wspace": 0.06,
                                          "width_ratios": [2, 1] if len(panels) > 1 else [1]})
    axes = axes if len(panels) > 1 else [axes]
    for ax, (pts, title) in zip(axes, panels):
        ax.axvspan(0.9, 1.1, color="#efeeea", lw=0, zorder=0)
        ax.axvline(1.0, color=INK2, lw=0.8, ls="--")
        for c in pts:
            # Deterministic jitter (hash() is salted per process; the figure must repeat).
            y = rows.index(c["protocol"]) + ((zlib.crc32(c["cell"].encode()) % 100) / 100 - 0.5) * 0.6
            x = min(num(c["rule_margin"]), 3.0)
            if c["failed"] == "1":
                ax.scatter(x, y, marker="x", s=18, color=ORANGE, lw=1.2, zorder=3)
            else:
                ax.scatter(x, y, marker="o", s=16, facecolor="white", edgecolor=BLUE, lw=1.1, zorder=3)
        ax.set_title(f"{title}, {len(pts)} cells", loc="left")
        hi = max(num(c["rule_margin"]) for c in pts)
        if hi > 1.6:
            ax.set_xlim(0, 3.15)
            ax.set_xlabel("Predicted wait / timeout (capped at 3)")
        else:
            ax.set_xlim(0.5, 1.5)
            ax.set_xlabel("Predicted wait / timeout")
    axes[0].set_yticks(range(len(rows)))
    axes[0].set_yticklabels([names[r] for r in rows])
    axes[0].set_ylim(len(rows) - 0.45, -0.55)
    import matplotlib.patches as mpatches
    h = [axes[0].scatter([], [], marker="x", color=ORANGE, lw=1.2, label="ran: storm or stuck"),
         axes[0].scatter([], [], marker="o", facecolor="white", edgecolor=BLUE, lw=1.1,
                         label="ran: recovered"),
         mpatches.Patch(color="#efeeea", label="within 10% of the boundary: no claim")]
    fig.legend(handles=h, loc="upper center", bbox_to_anchor=(0.5, -0.1), ncol=3,
               handletextpad=0.4, columnspacing=1.5)
    # The reading rule (left of the line: recovery predicted; right: a storm, except
    # bounded recovery with spare capacity) belongs in the caption, not the image.
    save(fig, out, "rule")
    plt.close(fig)
    return f"rule: {len(dev)} development, {len(val)} registered cells"


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("summary")
    ap.add_argument("--csvdir")
    ap.add_argument("--registered")
    ap.add_argument("--out", default="results_paper")
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    cells = enrich(classify(a.summary))
    keys = ["cell", "set", "protocol", "config", "attack", "timeout_rounds", "window", "n", "T_ms",
            "C", "M", "spare", "spare_share", "outcome", "failed", "vc_node", "quorum_done",
            "rounds_opened", "abandoned", "cons_peak", "cons_drops", "commit_p50_us",
            "commit_p99_us", "ctrl_missed", "ctrl_p99_us", "safety", "rule_prediction",
            "rule_margin", "rule_reason"]
    with open(os.path.join(a.out, "all_cells.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        for c in cells:
            w.writerow({k: c.get(k, "") for k in keys})
    log = [f"all_cells.csv: {len(cells)} cells"]
    log += [t1_protocols(cells, a.out), t2_headroom(cells, a.out), t3_grid(cells, a.out),
            t4_rule(cells, a.out, a.registered), t5_control(cells, a.out)]
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        style(plt)
        log += [fig_timeline(plt, cells, a.csvdir, a.out), fig_headroom(plt, cells, a.out),
                fig_protocols(plt, cells, a.out), fig_rule(plt, cells, a.out, a.registered)]
    except ImportError:
        log.append("figures skipped: matplotlib not installed (pip install matplotlib)")
    with open(os.path.join(a.out, "README.txt"), "w") as f:
        f.write("Assembled by tools/assemble_results.py from " + a.summary + "\n\n")
        f.write("\n".join(log) + "\n\n")
        f.write("Outcome: fault_report.py's classification. Rule: recovery_rule.py at beta 0.9.\n"
                "Registered predictions: " + (a.registered or "-") + "\n")
    print("\n".join(log))
    print(f"written to {a.out}/")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
