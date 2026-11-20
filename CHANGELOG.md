# Changelog

Development stages, oldest first. The repository holds the merged result.

1. **Packet capture.** `pcap-tap.h`: nanosecond timestamps, capture window and byte budget, role-named files, a manifest and the gate schedule per port; a Wireshark dissector for the control and consensus payloads. TAS install and capture share one named port table.
2. **Experiment driver.** `sweep.sh`: resumable by `summary.csv` rows, realised configuration read back from each log, parsed summaries.
3. **Shaper baselines.** `--shaper tas|prio|fifo`, `--qdiscSize`.
4. **Control load.** `--ctrlBurst`, `--ctrlPayload` (the derived alignment offset follows the payload).
5. **Experiments e7 and e8** (frontier and joint map) with `frontier.py`; **e9** alignment fragility; **e10** `--devQueue`; **e11** `--consSlices`; **e12** `--offsetJitter`, `--randomRoundPhase`, `--randomPlacement` with `uncertainty.py`; **e13** `--ctrlTos`.

## Final cleanup

- Removed the unused experiment `pilot` (the model is deterministic, so extra seeds add nothing without a random option).
- `e1` now runs at the 5 µs window by default; at the default window naive and aligned are identical.
- `e4` honours `--seeds`; `e9` no longer lists one cell twice; `all` runs everything except `e12` and `figs`.
- Default `--ctrlPeriod` is 1000 µs (it was 500 µs, which queued half the control frames for most of a cycle behind a single window).
- Struct padding in the control and consensus payloads is zeroed, so captures are byte-identical across machines.
- Echo text no longer says the guard band "strands the remainder": consensus windows follow strict fit, and burst source ports gain one frame per device-queue slot.
- The source headers of `iiot-consensus-tsn.cc` and `control-loop-app.h` no longer say "skeleton, not compiled".
- `PCAP-NOTES.md` became `docs/CAPTURES.md`; added `tests/`.

## Verification

- Built and run end to end on ns-3.49 with the TAS module at commit `3d00954`: all 684 runs reproduce the results the paper reports. `tools/reference/` records them as summaries and file checksums.
- Added `tools/verify_reproducibility.sh`, which rebuilds the stack from scratch, reruns every experiment set and compares the results with the reference, and `tools/compare_reference.py`, which does the comparison.

## Capacity mechanism (e14)

- Found the cause of the extra capacity of burst ports and of the backlog one frame above capacity, in the TAS module itself: its fit test and its dequeue pacing both use the frame time at the network-layer size, which is shorter than the frame time on the wire. Rule 3 of the README now gives the release count with the pacing limit, and the one-frame-above-capacity late count.
- Added experiment `e14` (7 runs) and the capture set `figs_e14` (1 run) to `sweep.sh`, with their predictions in the block comments; the `e13` comment no longer states the superseded hypothesis. `all` now leaves out every capture set (`figs*`).
- `tests/check_sweep.sh` and `tools/verify_reproducibility.sh` cover the new sets; the paper now has 691 runs (about 20 h serially), and `--quick` includes `figs_e14`.
- `tools/reference/e14` and `tools/reference/figs_e14` hold their reference results, from runs on ns-3.49 with the TAS module at commit `3d00954`. The other reference sets are unchanged, and the simulator source is unchanged, so every earlier run still reproduces.

## Consensus-window rule (e15)

- Rule 4 of the README is now proved necessary in every configuration and sufficient wherever consensus rounds do not overlap. Added `tools/round_check.sh` and `tools/round_check.py`, which rerun the 68 feasible TAS configurations with receive captures at every validator and report whether every round leaves the network before the next one starts: no overlap in 61, so the rule is proved for them; rounds overlap in the other 7, where it is observed.
- `round_check.py` reassembles fragmented messages: a message above 1472 bytes travels as two IP fragments, matched by source, destination and IP ID (ns-3 numbers IDs per source-destination pair), and a message counts as delivered when its last fragment arrives.
- Added experiment `e15` (6 runs) to `sweep.sh`: configurations placed just inside and just outside the limit of rule 4, with the predicted outcome of each in the block comment. The counting rule now covers 84 TAS configurations (68 feasible, 16 not).
- `tests/check_sweep.sh` and `tools/verify_reproducibility.sh` cover `e15`; the paper now has 697 runs (about 20 h serially).
- `tools/reference/e15` holds the summaries and run-log checksums of `e15`, from runs on ns-3.49 with the TAS module at commit `3d00954`. Its runs also write per-frame and per-commit CSVs, which the reference does not list; `tools/compare_reference.py make` adds their checksums from any run. The simulator source and every other reference set are unchanged.

## v1.0.0 (2026-11-20)

The code and reference results behind the submitted manuscript, archived on Zenodo.

- Covers experiments `e1`–`e15` and the capture sets `figs` and `figs_e14`: 697 runs, all reproducing `tools/reference/` on ns-3.49 with the TAS module at commit `3d0095446779809896024821451442ed6f01f2be`.
- Added `CITATION.cff`. The README now names the release, gives the full TAS commit hash, and has a "Citing" section.
- The simulator source, the tools and the reference results are unchanged from the stages above.

## v1.0.1 (2026-11-20)

- Records the Zenodo DOIs: v1.0.0 is 10.5281/zenodo.24384365; all versions, 10.5281/zenodo.24384364. Documentation only; no code or reference results changed.
