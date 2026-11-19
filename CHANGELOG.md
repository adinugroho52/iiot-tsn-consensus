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
