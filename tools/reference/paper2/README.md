# Reference results of the second paper

"Recovery bursts decide: PBFT, HotStuff and Raft under faults on IEEE 802.1Qbv
industrial networks" (Nugroho and Sari).

These files are the reference that `tools/verify_paper2.sh` checks a fresh run
against. They were written by `tools/assemble_results.py` from the authors' run
of every set (`tools/fault_sweep.sh f1 f2 f3 f4 f5 p1 p2 p3 v1 v1s`, 333 cells)
built with:

- ns-3.49
- the DenKrysos TAS module at commit `3d0095446779809896024821451442ed6f01f2be`
- the registered predictions `tools/validation/v1_cells.csv`, SHA-256
  `0b1d7df59c06a451ced87a095ffb77dcb8025abcb3c17daab38bc3b4b8fcf57f`

| File | Contents |
|---|---|
| `all_cells.csv` | one row per cell (333): parameters, outcome, recovery-rule prediction, key figures |
| `table_protocols.csv` | Table: protocols at their smallest window (p1) |
| `table_headroom.csv` | Table: headroom needed per trigger (f4, f5, p2, p3) |
| `table_f1grid.csv` | Table: the crashed-primary grid (f1) |
| `table_rule.csv` | Table: recovery-rule scores, including the registered validation (v1, v1s) |
| `table_control.csv` | Table: control-loop isolation per set |

The figures are not kept here; `assemble_results.py` redraws them from a run.
To refresh this reference after a deliberate change to the model, run
`tools/compare_paper2.py make NEW_RESULTS tools/reference/paper2` and say why in
the commit message.
