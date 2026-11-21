# iiot-tsn-consensus

An ns-3 simulation of PBFT-style consensus traffic sharing a Time-Sensitive Networking (802.1Qbv) chain with a
periodic control loop. It answers three questions at packet level: can consensus share a TSN cycle without
disturbing the control loop, what does each way of sharing cost, and what simple rules predict when each
arrangement is feasible.

Topology: PLC, then `n` switches, then an IO device, with validators attached to the switches. Every egress port runs
one of three disciplines (`--shaper`): the time-aware shaper (TAS), strict priority, or one FIFO. Consensus is modelled
as a message pattern (fixed leader, no view change, signatures as a fixed delay), so only message timing and size are
simulated, not a blockchain.

## Status

Release v1.0.0 (Zenodo, DOI [10.5281/zenodo.24384365](https://doi.org/10.5281/zenodo.24384365)) is the revision the paper's results come from. Built on ns-3.49 with the TAS module
at commit `3d00954`, all 697 runs reproduce the reference results in `tools/reference/` exactly;
`tools/verify_reproducibility.sh` repeats that check from scratch (see "Reproducing the paper's results" below). Later
versions are listed in `CHANGELOG.md`.

The second paper's results come from v2.0.0.

## Requirements

- ns-3 with the DenKrysos TAS module in `contrib/tsn` (<https://github.com/DenKrysos/Time-Aware-Shaper-TAS-in-ns-3>).
  This project is built on that module. The reference results were produced on ns-3.49 with the module at commit
  `3d0095446779809896024821451442ed6f01f2be` (7 July 2025, short form `3d00954`). `pcap-tap.h` handles both forms of
  `PcapHelper::CreateFile` (the `DataLinkType` enum up to 3.48, and `uint16_t` after it).
- `g++` (for the tests), `bash`, `python3` (3.8+; `matplotlib` only for `--plot`). Wireshark is optional.
- For `tools/verify_reproducibility.sh`: `git`, `cmake` and `make` as well, and network access to clone ns-3 and the
  TAS module.

## Install and smoke test

```bash
cp scratch/* <ns-3>/scratch/
cp -r tools tests <ns-3>/
cd <ns-3>
./ns3 build iiot-consensus-tsn
./ns3 run "iiot-consensus-tsn --stopAt=0.7s --run=1"
```

Expected: control min, mean, p99 and max all 4.26 µs, 0 missed (4 switches, 1 Gbps, 5 hops of 852 ns). Anything else
means the build or the tree differs from the one the results came from.

`tests/schedule_test.sh` and `tests/check_sweep.sh` need no ns-3 and run from the repository root.

## Layout

```
scratch/   iiot-consensus-tsn.cc  control-loop-app.h  pcap-tap.h  adversary.h   -> ns-3 scratch/
tools/     sweep.sh  frontier.py  uncertainty.py  iiot-tsn-dissector.lua
           verify_reproducibility.sh  compare_reference.py  reference/     rebuild, rerun and check
           verify_paper2.sh  compare_paper2.py  reference/paper2/    the same for the second paper
           round_check.sh  round_check.py                            do consensus rounds overlap?
           adversary_check.sh                                        full PBFT model and Byzantine behaviours
docs/      CAPTURES.md                                              packet captures and the dissector
tests/     schedule_test.sh  check_sweep.sh
CHANGELOG.md                                                        how the code got here, and releases
CITATION.cff                                                        citation metadata (GitHub and Zenodo)
LICENSE.md                                                          MIT Licence
```

## Main options

| Option | Default | Meaning |
|---|---|---|
| `--shaper` | `tas` | `tas`, `prio` (strict priority, no gates) or `fifo` |
| `--linkRate` | `1Gbps` | every link |
| `--nSwitches`, `--nValidators` | 4, 4 | path length and committee size |
| `--cycle`, `--ctrlFrac`, `--consFrac` | 1000 µs, 0.20, 0.30 | gate cycle and window shares; best effort gets the rest |
| `--perHopOffset` | derived | gate phase of port k is k × this; derived default aligns windows to the control frame's arrival |
| `--ctrlPeriod`, `--ctrlDeadline` | 1000 µs, 1000 µs | keep the period equal to the cycle |
| `--ctrlPayload`, `--ctrlBurst`, `--ctrlTos` | 64 B, 1, 16 | control frame size, frames per period, ToS in decimal (16 = control class, 24 = consensus class) |
| `--consensusMsgSize`, `--consensusInterval`, `--verifyDelay` | 256 B, 10 ms | consensus load |
| `--consSlices` | 1 | cut the consensus window into K slices spread over the cycle |
| `--devQueue`, `--qdiscSize` | `1p`, `800p` | device transmit queue below the qdisc, and queue depth for the baselines |
| `--offsetJitter`, `--randomRoundPhase`, `--randomPlacement` | off | random clock error, round start phase, validator placement; `--run` selects the draw |
| `--consensusInBe` | false | send consensus in best effort |
| `--warmup`, `--stopAt`, `--cooldown`, `--run` | 0.5 s, 2.0 s, 100 ms, 1 | measurement window and RNG run |
| `--latencyCsv`, `--consensusCsv` | off | per-frame latency and per-commit latency |
| `--pbftModel` | `v1` | `v1`: the normal case of release 1.x, reproduced exactly; `full`: per-digest quorums, own COMMIT counted, rotating primary and view change |
| `--viewChange`, `--viewTimeout`, `--viewBackoff`, `--maxViewChanges` | on, 4 × round interval, 2, 64 | view change in the `full` model |
| `--viewChangeSize`, `--newViewSize` | 0 (= `--consensusMsgSize`) | size charged for VIEW-CHANGE and NEW-VIEW |
| `--pbftStats` | false | print the "pbft model" report section in the `v1` model too |
| `--attack`, `--nByzantine`, `--byzSelect` | none, 0, `primary` | Byzantine behaviours (`full` model): `crash`, `withhold`, `equivocate`, `flood`, `delay`, `mismark`, and `inject` (compromised end stations); how many validators, and which |
| `--attackStart`, `--attackStop` | `--warmup`, stop − cooldown | attack window; the control loop is reported inside and outside it |
| `--floodFactor`, `--attackDelay` | 8, 0 ms | strength of `flood` and `delay` |
| `--nInjectors`, `--injectClass`, `--injectFrame`, `--injectBurst`, `--injectInterval` | 0, `control`, 1024 B, 4, 200 µs | injectors at switch 0 sending to the IO device, with `--attack=inject` |
| `--adversaryCsv` | off | per-round safety and liveness detail from the oracle |
| `--pcap*` | off | see `docs/CAPTURES.md` |
| `--reproposeWindow` | 0 | Full model: on a view change, re-propose only uncommitted rounds from the last N round ticks and abandon older ones (PBFT log watermarks). 0 = all held rounds (up to 64). |

`./ns3 run "iiot-consensus-tsn --PrintHelp"` lists everything. The model is deterministic unless a random option is on.

## Experiments

`tools/sweep.sh` is the driver: `tools/sweep.sh --list`, `--dry-run e6`, `tools/sweep.sh e1 e5`. Each run needs a row in
`results/summary.csv` to count as done, so an interrupted sweep resumes. The header of the script lists every
experiment and its cell count. What each one showed:

| | Result |
|---|---|
| e1 | at a 5 µs control window aligned gates never miss; naive gates miss every frame from 6 switches |
| e2, e3, e4 | consensus under TAS at 1 Gbps commits fully up to 5 ms rounds and collapses at 2 ms; latency scales roughly with 1 ÷ window |
| e5 | TAS control latency is hops × one hop time with no misses; priority grows with path length; FIFO is bounded by its queue depth |
| e6 | control burst: latency of the last frame is exact, and a window has a hard capacity per cycle |
| e7, e8 | feasibility frontier and joint control × consensus map; TAS control is independent of consensus load, priority's is not |
| e9 | alignment tolerance to systematic per-hop drift is (window − frame) ÷ (hops − 1) |
| e10 | priority's worst case rises with device-queue size; TAS and FIFO do not |
| e11 | slicing the consensus window buys at most about 20% and can break feasibility |
| e12 | twenty random draws: TAS control identical in every draw, baselines vary widely with placement |
| e13 | the extra capacity of a burst port appears in both classes and grows with device-queue size, up to the qdisc's pacing limit |
| e14 | the capacity mechanism, predicted before the runs: at 100 Mbps the pacing limit gives 27 frames per cycle at every device-queue size; one frame above capacity, each switch holds back one frame per cycle |
| e15 | the consensus-window counting rule at its edge, outcomes stated before the runs: three configurations just inside the limit (one with demand equal to capacity) commit; three just outside it, one of them short by a single frame per round, do not |

Captures: `figs` (the paper's figures) and `figs_e14` (one e14 configuration on every port of the path) are run only by name.

Round overlap: `tools/round_check.sh` reruns each of the 68 feasible TAS configurations with receive captures at every
validator and reports, per configuration, whether the last frame of every round arrives before the next round starts
(rule 4). It writes `results_rounds/check.txt`; about 45 minutes.

Summaries: `tools/frontier.py results_e7 results_e8` (largest feasible control burst per shaper and deadline, and the
joint map) and `tools/uncertainty.py results_e12` (means with 95% intervals, and the share of runs with a late frame).

## Reproducing the paper's results

`tools/verify_reproducibility.sh` rebuilds everything from scratch and checks it against `tools/reference/`:

```bash
tools/verify_reproducibility.sh            # all 697 runs, about 20 h serially
tools/verify_reproducibility.sh --quick    # e1, e6, e9 and the captures, about 40 min
```

It clones ns-3.49 and the TAS module at commit `3d00954` into a work folder beside the repository (`--work` to choose
another), builds this code there, runs both tests and the smoke test, runs every experiment set of the paper, and
compares each run with the reference: every value of `summary.csv` except wall-clock time, and the SHA-256 of every run
log, per-frame CSV and capture file. The model is deterministic, so a matching build reports every set as `IDENTICAL`.
Rerunning the script resumes where it stopped; `--check-only` repeats the comparison without running anything.

It also packs `repro-results.tar.gz` (under 10 MB) with the summaries, logs, captures, checksums of the per-frame CSVs,
and a record of the environment, for sharing a run. `tools/compare_reference.py check <results> tools/reference`
compares any results folder laid out the same way. `--tas-src`, `--tas-commit`, `--ns3-tag` and `--profile` change the
build; with a different version, expect differences to show up in the comparison.

The second paper has its own script, `tools/verify_paper2.sh` (329 fault cells, about 7 h on one core, `-j N` to run
in parallel; `--quick` for f1, p1 and v1), checked against `tools/reference/paper2/`; see `docs/PAPER2.md`.

## Rules the experiments support

Scope matters for each; they are not general laws.

1. **Latency under TAS (aligned, backlog-free):** last frame of a burst of B has latency (B − 1) × frame time + hops × (frame time + link delay).
2. **Alignment tolerance:** an offset error of ε per hop (systematic drift) fits while (hops − 1) × ε ≤ window − frame time. Independent per-port errors do not accumulate; at 16 switches and a 5 µs window misses become likely above about 1 µs standard deviation.
3. **Capacity of a backlogged TAS port (this TAS module):** min(⌊(W − d) ÷ τ⌋ + 1 + q, ⌊(W − d) ÷ d⌋ + 1) frames per cycle, with τ the frame time on the wire, d the frame time at its network-layer size (no PPP header), which the qdisc uses both for its fit test and to pace its dequeues, and q the device-queue size. The first term counts frames that leave through the device queue after the gate closes; the second is the pacing limit. Exact in e6, e13, e14 and the overload capture; it is why small control frames gain extra frames per window and large consensus frames do not.
   **One frame above capacity** (B = ⌊W ÷ τ⌋ + 1 on an aligned path): every frame is delivered, but each switch holds back one frame per cycle, so n frames per cycle are late with n switches (e6, e14).
4. **Consensus window feasibility:** the whole frames per cycle the window holds (strict fit, K × ⌊(window ÷ K) ÷ frame⌋ with K slices) must cover the busiest link's frames per round divided by cycles per round. Classified all 84 TAS configurations of the paper correctly (68 feasible, 16 not), including the six of e15 placed at its edge, and did not change with device-queue size. It is necessary in every configuration. It is also sufficient wherever rounds do not overlap: if one round, started on empty queues, delivers its last frame before the next round starts, every round repeats it. `tools/round_check.sh` tests that with receive captures: no overlap in 61 of the 68 feasible configurations, so the rule is proved there; rounds overlap in 7 (e11 at 100 Mbps with 2, 3, 5 and 6 slices, and the three feasible e15 configurations), where it is observed. A message above 1472 bytes travels as two IP fragments (1502 and 598 bytes on the wire for 2048 B); the window count then applies the fit test to the fragments, which changes no classification here.
5. **Priority:** worst-case control latency is at most (switches + 1) × hop time + (q + 1) × switches × consensus frame time, and the measured baseline uses the ns-3 minimum of q = 1.

## Reproduction anchors

At `--ctrlPeriod=1000us --stopAt=6.0s`, `--run=1`, from the original runs:

| Run | Value |
|---|---|
| e1 (5 µs window) | aligned 16 switches: max 14.484 µs, no misses; naive 6 switches: p99 1000.85 µs; naive 16 switches: 2004.26 µs |
| e5 (100 Mbps, `--consFrac` 0.30) | tas-s16: control p99 129.54 µs, 838 rounds committed; prio-s8: p99 1039.98 µs, miss ratio 0.0233333; fifo-s4: p99 67186.5 µs |
| e5 with `--extra --consFrac=0.60` | tas-s16: 3324 rounds committed |
| e2 / e3 / e4 | v16-m1024: consensus p99 4435.63 µs; 2 ms rounds: 16978 of 2899 rounds × 16; c0.20-k0.50: p99 2528.38 µs |
| e6 | 1 Gbps B=265: max 202.79 µs; B=266 delivers 266 per cycle; 100 Mbps B=26: max 226.10 µs |
| e9 | 16 switches, 5 µs window: ε = 260 ns passes, ε = 270 ns misses |
| e10 | priority at 16 switches: 197.72 µs at q = 1, 483.10 µs at q = 8; TAS 14.484 µs; FIFO 550.56 µs |
| e12 part (b) | TAS control max 82.12 µs in all 20 draws |
| e14 | 100 Mbps, B = 40: 145800 received (27 per cycle) at q = 1, 2, 4, 8; B = 266 at 8, 12, 16 switches: 266 per cycle, 43200, 64800, 86400 late |
| e15 | 1 Gbps, 4 ms rounds: W_k = 300 µs commits 23182 of 23184, 275 µs 23177; 3 ms rounds at 300 µs 28454 of 30928; 260 µs 22917; 100 Mbps: 8 ms 7238 of 7240, 7 ms (12 s run) 16504 of 16850 |

## Known limits and open points

- One chain topology and one control-flow shape. Consensus is simplified: fixed leader, no view change, no failures, no ledger.
- The priority and FIFO baselines use a one-packet device queue, the ns-3 minimum, which adds blocking a hardware scheduler would not have (e10).
- Capacity above the window's limit (rule 3) is a property of this TAS module, not of IEEE 802.1Qbv; a hardware port may release a different number of frames.
- Run logs do not record `--devQueue`; the cell names do (e10, e13, e14).
- The TAS module covers gate scheduling only: no 802.1AS synchronisation, preemption, per-stream filtering or central configuration.
- `--jobs` in `sweep.sh` is untested against `./ns3 run`; serial runs are the safe default.

See `CHANGELOG.md` for how the code got here.

## AI assistance

This code and its documentation were written with the assistance of Claude (Anthropic; models Claude Opus 5.5, Claude
Sonnet 5.5 and Claude Fable 5.2): the simulation, the experiment and analysis scripts, the reproduction script and its
reference check, and this README and the other notes. The authors directed the work, ran every simulation, and
reviewed the code; the reference results in `tools/reference/` come from those runs, not from the AI system. The
accompanying paper discloses its own use of AI in its acknowledgment.

## Citing

If you use this code, please cite the release you used. For the paper's results that is v1.0.0, DOI [10.5281/zenodo.24384365](https://doi.org/10.5281/zenodo.24384364). `CITATION.cff` holds the full metadata, and GitHub's "Cite this repository" button formats it. The accompanying paper is under review; this section will give its reference
once it is published.

## Licence

The code in this repository is released under the MIT Licence; see `LICENSE.md`. It does not include ns-3 or the
DenKrysos TAS module, which it is built against: ns-3 is distributed under the GNU GPL version 2, and the TAS module
under its own licence. A binary built from this code together with ns-3 is subject to the terms of those licences.
