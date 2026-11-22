# Second paper: Byzantine-fault-tolerant consensus under faults

This note covers what the second paper adds to the simulator and tools: the full
PBFT model with view changes, Byzantine behaviours, chained HotStuff, the fault
and protocol experiment sets, the recovery-burst rule and its registered
validation. The first paper's runs are unaffected: the default
`--pbftModel=v1` reproduces `tools/reference/` byte for byte
(`tools/verify_reproducibility.sh --quick`).

## Models

**PBFT, `--pbftModel=full`.** Per-proposal (digest) quorums; a backup counts its
own PREPARE and every node its own COMMIT (Castro-Liskov's prepared and
committed-local predicates); PREPAREs and COMMITs that arrive before the
PRE-PREPARE are re-checked when it does. Primary of view v is v mod n. Every node
keeps the round clock (one request per tick). A backup that has not committed a
round within the view timeout sends VIEW-CHANGE to all; 2f+1 requests enter the
view, and its primary sends NEW-VIEW and re-proposes the uncommitted rounds it
holds (all of them, or the last N with `--reproposeWindow=N`). f+1 requests for a
higher view make a node join it; a request answered by no NEW-VIEW within the
timeout escalates to the next view with a doubled timeout. Messages of a view not
yet entered are held and replayed; f+1 senders in a higher view move a node there
(state transfer). Not modelled: certificates inside VIEW-CHANGE and NEW-VIEW (only
their size is charged), checkpoints, and retransmission (a dropped message is made
up only by a view change).

**Chained HotStuff, `--protocol=hotstuff`.** Leader v mod n proposes block v to
all once it holds a QC for v-1 (2f+1 votes) or 2f+1 NEW-VIEWs for v, not before
tick v; a block carries the rounds since its parent. Every replica votes to the
next leader. A block commits when its great-grandchild arrives (3-chain). A
replica with no proposal for its view within the pacemaker timeout sends NEW-VIEW
to the next leader. Not modelled: the lock (safeNode) check, signature
aggregation, block sync (a replica that missed a block cannot commit through it).

**Both:** every message is `--consensusMsgSize` (1024 B in the experiments);
a message carrying k rounds of payload is k frames. The oracle records commits by
trusted nodes (crash-only nodes are trusted) and reports rounds reaching a quorum
(2f+1), safety violations and the longest stall.

## Experiment sets (`tools/fault_sweep.sh`)

Run from the ns-3 root; results go to `results_fault/` (`summary.csv`, `log/`,
`csv/<cell>-rounds.csv`). Each fault lasts [1.0 s, 2.5 s) of a 6 s run.

| Set | Cells | Question |
|---|---|---|
| f1 | 36 | crashed primary on E12's configurations: view timeout x re-propose window |
| f2 | 24 | no fault, timeouts near the commit latency |
| f3 | 12 | flooding and equivocation |
| f4 | 36 | headroom at n = 16: consensus window 300-440 µs under four triggers |
| f5 | 38 | headroom at n = 7, 10, 13 |
| p1 | 9 | PBFT and HotStuff with the window cut to each protocol's load |
| p2 | 31 | HotStuff under faults: -50% to +100% spare over its worst round |
| v1 | 25 | registered validation (run by name) |

Checks before relying on the models: `tools/adversary_check.sh` (30 checks) and
`tools/protocol_check.sh` (17 checks).

## Analysis

- `tools/fault_report.py summary.csv`: each cell recovered, churn (many view
  changes, every round still reaching a quorum), storm or stuck, with
  `vc/n` = views entered / n, and each prediction scored.
- `tools/fault_timeline.py --summary csv/*-rounds.csv`: quorum share before,
  during and after the fault.
- `tools/headroom.py summary.csv`: the spare capacity each trigger needs, per n.
- `tools/vc_budget.py --protocol P ...`: C, M (worst round for HotStuff) and the
  first burst after a view change; `--no-fault` gives the C5 verdict alone.
- `tools/recovery_rule.py summary.csv [--fit f1 | --beta 0.9] [--list]`: the
  recovery-burst rule (see its header) fitted on one set and scored on the rest.

## Registered validation

`tools/validation/v1_cells.csv` lists 25 cells in configurations no earlier set
used, each with the rule's prediction at beta = 0.9 and its margin. It is the
file `tools/validation_design.py` wrote and that was committed before any v1 run
(commit `3002952`, 40 cells, SHA-256 `0b1d7df5...cf57f`) without the 15 Raft rows,
removed with the Raft model; the other 25 rows are unchanged, and
`validation_design.py` writes the file byte for byte. SHA-256:

    97c20de3318c24b366a84a430cf6649438f19532e8ebb5996bfc93bc351f0da4

`fault_sweep.sh v1` prints the file's hash before running it. Score with

    tools/recovery_rule.py results_fault/summary.csv --registered tools/validation/v1_cells.csv

which reads the registered predictions rather than recomputing them, and reports
cells within 10% of the boundary (the band where the rule makes no claim)
separately.

## Tables and figures

    tools/assemble_results.py results_fault/summary.csv --csvdir results_fault/csv \
        --registered tools/validation/v1_cells.csv --out <folder outside the repository>

writes `all_cells.csv`, the tables (CSV and booktabs LaTeX) and the figures (PDF
and PNG). Generated tables and figures belong with the paper, not in the
repository (`.gitignore` excludes `results_*/`).

## Reproducing the second paper

`tools/verify_paper2.sh` rebuilds the stack from scratch (ns-3.49, TAS module at
commit `3d00954`), runs both scenario checks (`adversary_check.sh`, 30 checks;
`protocol_check.sh`, 17), the full sweep of 211 cells, `assemble_results.py`, and
compares the result with `tools/reference/paper2/`:

    tools/verify_paper2.sh -j 4              # all 211 cells, about 3 h on one core
    tools/verify_paper2.sh --quick           # f1, p1 and v1 only (70 cells, about 1 h; cells only)
    tools/verify_paper2.sh --check-only      # assemble and compare an earlier run again

Before building it checks that `tools/validation/v1_cells.csv` still has its
registered hash and that `fault_sweep.sh` lists exactly the reference cells.
`tools/compare_paper2.py` reports three levels: control isolation and safety in
every cell (from the new run alone), each cell's outcome and rule prediction, and
every value of every cell, every table of the paper and the SHA-256 of every
per-round CSV (`tools/reference/paper2/rounds-sha256.txt`). The model is
deterministic, so a matching build reproduces all three exactly. The work folder
(default `paper2-work` beside the repository) keeps the sweep, the tables and the
figures; `paper2-repro-results.tar.gz` there packs the logs, summary, tables,
comparison and environment record for sharing. Exit status 0 means reproduced.
The sweep's cells add up to 2.6 h of single-core time on an AMD Ryzen 7 3700X and
3.5 h on an Intel Xeon E3-1230 v3; `-j N` divides that by about N.

**Figures are optional.** The comparison covers every number the figures are
drawn from, so they are not needed to verify the results; without matplotlib the
script builds and checks the tables and skips the figures. To draw them, give it
an interpreter with the pinned packages, in a virtual environment or any other
way you manage Python:

    python3 -m venv ~/venvs/paper2               # Debian/Ubuntu: apt install python3-venv first
    ~/venvs/paper2/bin/pip install -r tools/requirements-paper2.txt
    tools/verify_paper2.sh --python ~/venvs/paper2/bin/python3 --figures -j 4

`--python` runs every Python step with that interpreter (no need to activate the
environment); `--figures` stops at the first step if it has no matplotlib, rather
than finishing without figures. `python.txt` in the work folder and the archive
records the interpreter and the matplotlib version that drew them. To draw the
figures for a run that finished without them, rerun with `--check-only` and an
interpreter that has matplotlib.

## Notes on reading the results

- A configuration that breaks C5 by e frames per round fails only after about
  Q / e rounds, Q the 800-frame class queue: run long enough to see it (one v1 cell,
  over by 1 frame per round, needed more than 6 s).
- Every run is deterministic: one run per cell is the result, not a sample.
