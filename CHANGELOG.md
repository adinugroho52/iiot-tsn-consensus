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

## v1.2.0

Experiments that answer one question are now one experiment with parts, as e9 (formerly e12) already was, and the
rest are renumbered to match the paper. Runs, flags and results are unchanged; only names differ.

| Before | Now | Run names | Environment knobs |
|---|---|---|---|
| e2, e3, e4 | e2 (a), (b), (c) | `e2-a-…`, `e2-b-…`, `e2-c-…` | — |
| e5 | e3 | `e3-…` | — |
| e6, e7 | e4 (a), (b) | `e4-a-…`, `e4-b-…` | `E6_*` → `E4A_*`, `E7_*` → `E4B_*` |
| e8 to e15 | e5 to e12 | `e5-…` to `e12-…` | `E8_*` → `E5_*`, …, `E15_*` → `E12_*` |
| figs_e14 | figs_e11 | `fig-e11` | — |

- `sweep.sh e2` and `sweep.sh e4` run every part; `e2a`, `e2b`, `e2c`, `e4a` and `e4b` run one. `all` still leaves out
  the uncertainty draws (now e9) and the capture sets.
- `tools/reference/` sets are renamed to match (`e2e3e4` → `e2`; `e6` and `e7` → `e4`; `e6_100M` and `e7_100M` →
  `e4_100M`; `e14` → `e11`; `e15` → `e12`; `figs_e14` → `figs_e11`; and so on). Every checksum is unchanged, since no run
  log or per-frame CSV carries its run's name, except two files of `figs_e11`: its run log and capture manifest name
  the capture files, so they now say `fig-e11` where they said `fig-e14`. Every capture in that set is byte-identical
  to v1.1.0's.
- `tools/round_check.sh` labels its runs with the new set and run names.
- `frontier.py` ignores the part letter in a tag, so it reads results under either numbering.
  `verify_reproducibility.sh --quick` now covers part (a) of e4 through its 150 µs-deadline set.

## v2.0.0 (2026-11-21)

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
- View-change escalation (Castro-Liskov): a node whose request gets no NEW-VIEW within the timeout asks for the next view and doubles the timeout. Without it a lost VIEW-CHANGE or NEW-VIEW stopped the node for good. The report counts escalations and nodes at the view cap.
- Report sections "queues" (consensus peak per port, drops per class) and "agreement" (the oracle's figures in a run without an attack), both only in `full` runs or under an attack, so `v1` logs are unchanged.
- `--protocol=hotstuff|raft`: chained HotStuff and Raft as traffic models on the same round clock, adversary hooks and oracle. A message carrying k rounds of payload is sent as k frames. Raft refuses `--attack=equivocate`; a crashed Raft leader restarts as a follower. `--raftCatchup` limits entries per follower per tick.
- Tools: `fault_sweep.sh` (sets `f1`-`f5`, `p1`, `p2`, `v1`, `v1s`), `vc_budget.py`, `fault_report.py`, `fault_timeline.py`, `headroom.py`, `protocol_check.sh`, `recovery_rule.py`, `validation_design.py`, `seed_study.py`, `assemble_results.py`.
- Registered validation set `tools/validation/v1_cells.csv` (40 cells, predictions at beta 0.9, SHA-256 `0b1d7df59c06a451ced87a095ffb77dcb8025abcb3c17daab38bc3b4b8fcf57f`), committed before its runs.
- Raft logs say "a majority of trusted nodes" for the quorum (the count was always a majority; the label said 2f+1).
- `tools/verify_paper2.sh`: rebuilds the stack, checks the registered predictions' hash and the sweep's cell list against the reference, runs `adversary_check.sh` and `protocol_check.sh`, the full fault sweep (329 cells), `assemble_results.py`, and compares with `tools/reference/paper2/` through `tools/compare_paper2.py` (isolation and safety, outcomes and rule predictions, every cell value and every table). Resumable, `-j N`, `--quick`, `--sets`, `--check-only`; packs `paper2-repro-results.tar.gz`. `tools/verify_reproducibility.sh` is unchanged.
- `tools/reference/paper2/`: `all_cells.csv` and the five table CSVs of the authors' run (ns-3.49, TAS module `3d00954`); no figures.
- `tools/compare_reference.py`, run without set names, lists only first-paper sets, so it skips `reference/paper2/`.
- `fault_sweep.sh`: sets `p2` and `p3` merged into one set, `p2` (55 cells). The 32 cells of `p3` are now named `p2-*`; four of them (HotStuff at k = 4: crash with timeouts 2 and 4, equivocate, flood2) ran exactly the same command as a `p2` cell and are dropped. Every remaining command is unchanged, so no result changes; the paper now has 329 cells. The rule's scores no longer count those four twice: 194/214 overall and 161/178 held out with beta fitted on f1 (was 197/218, 164/182), 197/214 and 162/178 fitted on f4 (was 199/218, 164/182); the fitted betas and the registered validation are unchanged.
- This is the codebase and results behind the second paper, v1.x results still reproduce with `--pbftModel=v1`

## Unreleased

Raft is removed: the second paper studies the Byzantine-fault-tolerant protocols, PBFT and HotStuff. PBFT and HotStuff
are unchanged, and every remaining cell runs the same command as before.

- Simulator: `--protocol=raft` and `--raftCatchup` are removed, with the Raft model (leader, elections, AppendEntries,
  catch-up limit) and its report lines. `--protocol` takes `pbft` or `hotstuff`. The Raft model drew its election
  timeouts from its own random streams (1000 + node), created only in Raft runs, so no PBFT or HotStuff run changes.
- `fault_sweep.sh`: `p1` (9 cells) and `p2` (31 cells) hold PBFT and HotStuff only, and the Raft seed set `v1s` is gone.
  `v1` runs the 25 PBFT and HotStuff cells of the registered file. The file itself is unchanged, its 15 Raft rows
  included, since its SHA-256 is the registration; `fault_sweep.sh` and `recovery_rule.py` skip those rows.
- `vc_budget.py`, `recovery_rule.py`, `fault_report.py`: Raft load, burst and latency models removed. The rule's PBFT and
  HotStuff predictions are unchanged: `validation_design.py`, with its Raft groups removed, writes exactly the 25 PBFT
  and HotStuff rows of the registered file.
- `protocol_check.sh`: the four Raft scenarios (12 checks) are removed; 5 HotStuff scenarios, 17 checks.
- `tools/seed_study.py` (the Raft seed study) is removed.
- `assemble_results.py`: the rule table reports the registered set for PBFT, HotStuff and both together (17/20
  decisive, 5/5 in the band); development scores 169/186 (beta fitted on f1) and 172/186 (on f4).
- `verify_paper2.sh` checks 211 cells (`f1`-`f5`, `p1`, `p2`, `v1`) and 17 protocol checks. `tools/reference/paper2/`
  is the 2.0.0 reference without its Raft cells, cut without rerunning, with its tables rebuilt.
- `docs/PAPER2.md` and the README describe PBFT and HotStuff only.
- `tools/validation/v1_cells.csv`: the 15 Raft rows are removed. The remaining 25 rows are byte-identical to the file registered before the v1 runs (commit 3002952, SHA-256 0b1d7df5…cf57f); new SHA-256 97c20de3…0da4, which validation_design.py reproduces.
- `tools/reference/paper2/rounds-sha256.txt`: the SHA-256 of every cell's per-round CSV (211), from the authors' rerun
  after the Raft removal. `compare_paper2.py --csvdir` checks them, so the data behind the timeline figure are verified
  too; `verify_paper2.sh` passes the sweep's `csv/` folder.
- `verify_paper2.sh`: figures are optional. Without matplotlib it builds and checks the tables and says the figures were
  not drawn; `--figures` makes matplotlib required (checked at step 1, before anything is built), and `--python PATH`
  runs every Python step with that interpreter, e.g. a virtual environment's, without activating it. `python.txt`
  records the interpreter and matplotlib version on every run, `--check-only` included; `environment.txt` no longer
  does.
- `tools/requirements-paper2.txt`: matplotlib 3.11.2, the version that drew the paper's figures. `docs/PAPER2.md`
  shows how to set up an environment with it.
- `docs/PAPER2.md`: the registered-validation section says how the 25-row file derives from the one registered before
  the v1 runs (commit `3002952`, 40 cells).
