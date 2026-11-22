# Reference results of the second paper

Nugroho and Sari: PBFT and HotStuff under faults on IEEE 802.1Qbv industrial
networks.

These files are the reference that `tools/verify_paper2.sh` checks a fresh run
against. They were written by `tools/assemble_results.py` from the authors' run
of every set of the paper (`tools/fault_sweep.sh f1 f2 f3 f4 f5 p1 p2 v1`, 211 cells)
built with:

- ns-3.49
- the DenKrysos TAS module at commit `3d0095446779809896024821451442ed6f01f2be`
- the registered predictions `tools/validation/v1_cells.csv`, SHA-256
  `97c20de3318c24b366a84a430cf6649438f19532e8ebb5996bfc93bc351f0da4`

| File | Contents |
|---|---|
| `all_cells.csv` | one row per cell (211): parameters, outcome, recovery-rule prediction, key figures |
| `table_protocols.csv` | Table: protocols at their smallest window (p1) |
| `table_headroom.csv` | Table: headroom needed per trigger (f4, f5) |
| `table_f1grid.csv` | Table: the crashed-primary grid (f1) |
| `table_rule.csv` | Table: recovery-rule scores, including the registered validation (v1) |
| `table_control.csv` | Table: control-loop isolation per set |
| `rounds-sha256.txt` | SHA-256 of every cell's per-round CSV (`csv/<cell>-rounds.csv`), which the timeline figure is drawn from |

The figures are not kept here; `assemble_results.py` redraws them from a run, and
the comparison covers every number they are drawn from. To refresh this
reference after a deliberate change to the model, run
`tools/compare_paper2.py make NEW_RESULTS tools/reference/paper2 --csvdir <sweep>/csv`
and say why in the commit message.

`rounds-sha256.txt` comes from the authors' rerun after the Raft model was
removed (the same build otherwise); its 211 cells are those of `all_cells.csv`.
