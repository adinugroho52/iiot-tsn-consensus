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

## v1.1.0 (2026-11-20)

Captures and run logs are now byte-identical across machines. No result changes: every summary statistic, run log, per-frame CSV and frame timing is the same as in v1.0.0.

- Packets are built in a zeroed buffer. `Packet::AddPaddingAtEnd()` leaves the bytes it adds uninitialised, so the padding after the control and consensus payload structs held leftover memory that differed between machines. Every other byte of every frame was already identical (checked against a v1.0.0 rerun on a second machine: 92 capture files, 32,401 frames).
- `tools/sweep.sh` and `tools/round_check.sh` build the program once and run each simulation with `./ns3 run --no-build`, as does the smoke test in `tools/verify_reproducibility.sh`. With Ninja, `./ns3 run` printed two build-tool lines at the top of every log.
- `tools/reference/figs`, `figs_c005_8sw` and `figs_e14`: new checksums for 76 capture files. Their summaries and every other checksum are unchanged.

## Unreleased (second paper)

- `--pbftModel=v1|full`. `v1`, the default, keeps release 1.x's consensus code path, so every earlier run reproduces: `e1`, `e2e3e4`, `e6`, `e10`, `e11`, `e15`, `figs` and `figs_e14` (112 runs, captures included) are identical to `tools/reference/`. `full` counts votes per proposal, counts a node's own COMMIT (needed to tolerate f faults: only 2f correct peers remain), prepares only for a proposal it holds and re-checks earlier PREPAREs and COMMITs when the PRE-PREPARE arrives, rotates the primary (view v mod n), and adds the Castro-Liskov view change with exponential backoff. Messages of a view a node has not entered yet are held and replayed. Ported from the August adversarial branch, fixing a stall there: a backup whose PREPAREs arrived before its PRE-PREPARE never sent its COMMIT.
- Consensus header grows from 24 to 32 bytes by appending view (byte 24) and digest (byte 28) to release 1.x's layout. Both are 0 in the `v1` model and for an honest proposal, so v1 messages are byte-identical and `tools/round_check.py` reads both versions. Message sizes do not change: the header sits inside `--consensusMsgSize`.
- New report section "pbft model" (in `full`, or with `--pbftStats`): VIEW-CHANGE and NEW-VIEW broadcasts, views entered, and node-rounds whose PREPAREs from 2f senders arrived before the PRE-PREPARE.
- Byzantine behaviours, ported from the August adversarial branch (`scratch/adversary.h`), for the `full` model: `crash`, `withhold`, `equivocate`, `flood`, `delay` and `mismark` validators, chosen with `--nByzantine` and `--byzSelect`, inside an attack window; and `inject`, compromised end stations at switch 0 sending to the IO device in a chosen class. An oracle, which sends nothing, records commits by correct nodes and reports rounds completed by a quorum, safety violations (rounds in which correct nodes committed different digests, each counted once; the August version counted every later commit) and the longest stall. The control loop is reported inside and outside the attack window; without an attack its statistics and per-frame CSV are unchanged.
- A node that sees messages of a higher view from f+1 distinct senders moves to that view, standing in for state transfer: without it a validator that was crashed could not rejoin.
- `tools/iiot-tsn-dissector.lua` decodes VIEW-CHANGE, NEW-VIEW, view and digest, and flags consensus messages sent at the control codepoint (`iiotbft.mismarked == 1`).
- `tools/adversary_check.sh`: twelve short runs, each with its expected outcome, for the full model and every behaviour.
- Full model: backups count their own PREPARE; f+1 VIEW-CHANGE join rule (Castro–Liskov).
- Oracle trusts crash-only nodes (crash-recovery model).
- Fixed: `--attack=inject` crashed (injectors were built before the attack was parsed).
- New option `--reproposeWindow` (default 0, behaviour unchanged).
