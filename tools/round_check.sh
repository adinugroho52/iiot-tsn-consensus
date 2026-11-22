#!/usr/bin/env bash
#
# round_check.sh -- do consensus rounds overlap? The receive-capture check behind
# the counting rule for the consensus window (README, rule 4).
#
# The rule is necessary in every configuration. It is also sufficient whenever one
# round, started on empty consensus queues, delivers all of its frames before the
# next round starts: the next round then finds the queues empty again and, the
# model being deterministic, repeats it. This script tests that condition for every
# feasible TAS configuration of the paper (68): one run per configuration, with
# exactly the flags the sweep driver uses for it (tools/sweep.sh --dry-run), plus a
# receive capture on every validator's port. tools/round_check.py then finds, for
# every round, when its last frame (the last fragment of a fragmented message)
# arrives. Expected: no late round in 61 configurations; rounds overlap in the
# other 7 (e8_100M with 2, 3, 5 and 6 slices, and the three feasible e12
# configurations), where the rule is observed rather than proved.
#
# Each run is checked as soon as it ends and its captures are then deleted, so the
# disk never holds more than one run's captures (at most about 160 MB); KEEP_PCAP=1
# keeps them. The runs' own results are those of the sweep, so only the check
# matters here.
#
# Run from the ns-3 root, with tools/ installed as in the README:
#
#   tools/round_check.sh            about 45 minutes of simulation, plus checking
#
# Rerunning skips configurations already in results_rounds/check.txt.
#
set -uo pipefail

NS3="${NS3:-./ns3}"
PROG="${PROG:-iiot-consensus-tsn}"
OUT="${OUT:-results_rounds}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT/log" "$OUT/pcap" "$OUT/check"
# Build once; the runs use --no-build so their logs hold only the simulator's output.
"$NS3" build "$PROG" > /dev/null 2>&1 || { echo "building $PROG failed; run: $NS3 build $PROG" >&2; exit 1; }
CAP="--pcapPoints=validators --pcapMode=rx --pcapStart=0.5s --pcapStop=5.9s"
[[ -f "$OUT/check.txt" ]] || printf '%-40s %7s %12s %10s %12s %10s %9s\n' run rounds 'tail max us' 'T_con us' 'slack us' 'late rnds' tails > "$OUT/check.txt"

# set.cell | round interval | the run's flags
RUNS=(
  "e11.e11-100M-q8-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --linkRate=100Mbps --ctrlTos=16 --devQueue=8p --ctrlBurst=40 --ctrlFrac=0.2 --consFrac=0.2 --nSwitches=4 --nValidators=4 --consensusMsgSize=256"
  "e4_100M.e4-a-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=100Mbps --run=1 --ctrlBurst=1"
  "e5_100M.e5-tas-s8-n4-m2048-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=100Mbps --consFrac=0.60 --run=1 --shaper=tas --nSwitches=8 --nValidators=4 --consensusMsgSize=2048 --ctrlBurst=1"
  "e5_100M.e5-tas-s8-n10-m256-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=100Mbps --consFrac=0.60 --run=1 --shaper=tas --nSwitches=8 --nValidators=10 --consensusMsgSize=256 --ctrlBurst=1"
  "e5_100M.e5-tas-s8-n16-m256-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=100Mbps --consFrac=0.60 --run=1 --shaper=tas --nSwitches=8 --nValidators=16 --consensusMsgSize=256 --ctrlBurst=1"
  "e5_100M.e5-tas-s8-n4-m256-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=100Mbps --consFrac=0.60 --run=1 --shaper=tas --nSwitches=8 --nValidators=4 --consensusMsgSize=256 --ctrlBurst=1"
  "e5_100M.e5-tas-s8-n4-m1024-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=100Mbps --consFrac=0.60 --run=1 --shaper=tas --nSwitches=8 --nValidators=4 --consensusMsgSize=1024 --ctrlBurst=1"
  "e10.e10-tos16-q1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --ctrlTos=16 --devQueue=1p --ctrlBurst=300 --ctrlFrac=0.2 --consFrac=0.2 --nSwitches=4 --nValidators=4 --consensusMsgSize=256"
  "e2.e2-c-c0.20-k0.20-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=16 --consensusMsgSize=1024 --ctrlFrac=0.20 --consFrac=0.20"
  "e2.e2-a-v10-m2048-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=10 --consensusMsgSize=2048"
  "e2.e2-a-v13-m2048-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=13 --consensusMsgSize=2048"
  "e2.e2-a-v16-m2048-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=16 --consensusMsgSize=2048"
  "e2.e2-a-v4-m2048-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=4 --consensusMsgSize=2048"
  "e2.e2-a-v7-m2048-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=7 --consensusMsgSize=2048"
  "e5.e5-tas-s8-n10-m2048-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --shaper=tas --nSwitches=8 --nValidators=10 --consensusMsgSize=2048 --ctrlBurst=1"
  "e5.e5-tas-s8-n4-m2048-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --shaper=tas --nSwitches=8 --nValidators=4 --consensusMsgSize=2048 --ctrlBurst=1"
  "e1.e1-naive-s12-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=12 --ctrlFrac=0.005 --perHopOffset=0"
  "e1.e1-aligned-s16-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=16 --ctrlFrac=0.005"
  "e1.e1-naive-s2-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=2 --ctrlFrac=0.005 --perHopOffset=0"
  "e2.e2-a-v10-m256-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=10 --consensusMsgSize=256"
  "e2.e2-a-v13-m256-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=13 --consensusMsgSize=256"
  "e2.e2-a-v16-m256-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=16 --consensusMsgSize=256"
  "e1.e1-aligned-s4-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=4 --ctrlFrac=0.005"
  "e2.e2-a-v7-m256-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=7 --consensusMsgSize=256"
  "e1.e1-aligned-s6-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=6 --ctrlFrac=0.005"
  "e5.e5-tas-s8-n10-m256-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --shaper=tas --nSwitches=8 --nValidators=10 --consensusMsgSize=256 --ctrlBurst=1"
  "e5.e5-tas-s8-n16-m256-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --shaper=tas --nSwitches=8 --nValidators=16 --consensusMsgSize=256 --ctrlBurst=1"
  "e1.e1-naive-s8-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=8 --ctrlFrac=0.005 --perHopOffset=0"
  "e2.e2-a-v10-m512-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=10 --consensusMsgSize=512"
  "e2.e2-a-v13-m512-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=13 --consensusMsgSize=512"
  "e2.e2-a-v16-m512-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=16 --consensusMsgSize=512"
  "e2.e2-a-v4-m512-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=4 --consensusMsgSize=512"
  "e2.e2-a-v7-m512-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=7 --consensusMsgSize=512"
  "e3_1G.e3-tas-s12-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=1Gbps --run=1 --shaper=tas --nSwitches=12 --nValidators=16 --consensusMsgSize=1024"
  "e3_1G.e3-tas-s16-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=1Gbps --run=1 --shaper=tas --nSwitches=16 --nValidators=16 --consensusMsgSize=1024"
  "e2.e2-a-v10-m1024-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=10 --consensusMsgSize=1024"
  "e2.e2-a-v13-m1024-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=13 --consensusMsgSize=1024"
  "e2.e2-b-i20ms-r1|20ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=16 --consensusMsgSize=1024 --consensusInterval=20ms"
  "e2.e2-a-v16-m1024-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=16 --consensusMsgSize=1024"
  "e2.e2-a-v4-m1024-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=4 --consensusMsgSize=1024"
  "e2.e2-a-v7-m1024-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=7 --consensusMsgSize=1024"
  "e5.e5-tas-s8-n10-m1024-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --shaper=tas --nSwitches=8 --nValidators=10 --consensusMsgSize=1024 --ctrlBurst=1"
  "e3_1G.e3-tas-s8-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=1Gbps --run=1 --shaper=tas --nSwitches=8 --nValidators=16 --consensusMsgSize=1024"
  "e5.e5-tas-s8-n4-m1024-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --shaper=tas --nSwitches=8 --nValidators=4 --consensusMsgSize=1024 --ctrlBurst=1"
  "e8.e8-s16-n16-m1024-k12-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=16 --nValidators=16 --consensusMsgSize=1024 --consSlices=12"
  "e8.e8-s4-n16-m1024-k12-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=4 --nValidators=16 --consensusMsgSize=1024 --consSlices=12"
  "e8.e8-s16-n16-m1024-k2-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=16 --nValidators=16 --consensusMsgSize=1024 --consSlices=2"
  "e8.e8-s4-n16-m1024-k2-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=4 --nValidators=16 --consensusMsgSize=1024 --consSlices=2"
  "e8.e8-s16-n16-m1024-k3-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=16 --nValidators=16 --consensusMsgSize=1024 --consSlices=3"
  "e8.e8-s4-n16-m1024-k3-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=4 --nValidators=16 --consensusMsgSize=1024 --consSlices=3"
  "e8.e8-s16-n16-m1024-k4-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=16 --nValidators=16 --consensusMsgSize=1024 --consSlices=4"
  "e8.e8-s4-n16-m1024-k4-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=4 --nValidators=16 --consensusMsgSize=1024 --consSlices=4"
  "e8.e8-s16-n16-m1024-k6-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=16 --nValidators=16 --consensusMsgSize=1024 --consSlices=6"
  "e8.e8-s4-n16-m1024-k6-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=4 --nValidators=16 --consensusMsgSize=1024 --consSlices=6"
  "e8.e8-s16-n16-m1024-k8-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=16 --nValidators=16 --consensusMsgSize=1024 --consSlices=8"
  "e8.e8-s4-n16-m1024-k8-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nSwitches=4 --nValidators=16 --consensusMsgSize=1024 --consSlices=8"
  "e2.e2-c-c0.20-k0.50-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=16 --consensusMsgSize=1024 --ctrlFrac=0.20 --consFrac=0.50"
  "e8_100M.e8-s8-n10-m1024-k1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=100Mbps --consFrac=0.60 --run=1 --nSwitches=8 --nValidators=10 --consensusMsgSize=1024 --consSlices=1"
  "e8_100M.e8-s8-n10-m1024-k2-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=100Mbps --consFrac=0.60 --run=1 --nSwitches=8 --nValidators=10 --consensusMsgSize=1024 --consSlices=2"
  "e8_100M.e8-s8-n10-m1024-k3-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=100Mbps --consFrac=0.60 --run=1 --nSwitches=8 --nValidators=10 --consensusMsgSize=1024 --consSlices=3"
  "e8_100M.e8-s8-n10-m1024-k5-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=100Mbps --consFrac=0.60 --run=1 --nSwitches=8 --nValidators=10 --consensusMsgSize=1024 --consSlices=5"
  "e8_100M.e8-s8-n10-m1024-k6-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=100Mbps --consFrac=0.60 --run=1 --nSwitches=8 --nValidators=10 --consensusMsgSize=1024 --consSlices=6"
  "e8_100M.e8-s8-n10-m1024-k7-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --linkRate=100Mbps --consFrac=0.60 --run=1 --nSwitches=8 --nValidators=10 --consensusMsgSize=1024 --consSlices=7"
  "e2.e2-b-i5ms-r1|5ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --nValidators=16 --consensusMsgSize=1024 --consensusInterval=5ms"
  "e5.e5-tas-s8-n16-m2048-b1-r1|10ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --shaper=tas --nSwitches=8 --nValidators=16 --consensusMsgSize=2048 --ctrlBurst=1"
  "e12.e12-1g-w300-t4ms-r1|4ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --linkRate=1Gbps --nSwitches=4 --nValidators=16 --consensusMsgSize=1024 --consensusInterval=4ms"
  "e12.e12-1g-w275-t4ms-r1|4ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --linkRate=1Gbps --nSwitches=4 --nValidators=16 --consensusMsgSize=1024 --consFrac=0.275 --consensusInterval=4ms"
  "e12.e12-100m-k1-t8ms-r1|8ms|--ctrlPeriod=1000us --stopAt=6.0s --run=1 --linkRate=100Mbps --consFrac=0.60 --nSwitches=8 --nValidators=10 --consensusMsgSize=1024 --consSlices=1 --consensusInterval=8ms"
)

i=0
for entry in "${RUNS[@]}"; do
  i=$((i + 1))
  IFS='|' read -r label iv flags <<< "$entry"
  if grep -q "^$label " "$OUT/check.txt"; then echo "done  [$i/${#RUNS[@]}] $label"; continue; fi
  echo "run   [$i/${#RUNS[@]}] $label"
  if ! "$NS3" run --no-build "$PROG $flags $CAP --pcapPrefix=$OUT/pcap/$label" > "$OUT/log/$label.log" 2>&1; then
    echo "FAIL  $label -- see $OUT/log/$label.log"; continue
  fi
  grep -qi "budget" "$OUT/log/$label.log" && echo "WARN  $label: capture budget reached, see its log"
  python3 -I "$HERE/round_check.py" "$OUT/pcap" "$label=$iv" > "$OUT/check/$label.txt"
  row="$(grep "^$label " "$OUT/check/$label.txt" | grep -v warning)"
  grep -q "warning" "$OUT/check/$label.txt" && echo "WARN  $label: $(grep warning "$OUT/check/$label.txt")"
  if [[ -n "$row" ]]; then
    printf '%s\n' "$row" | awk '{printf "%-40s %7s %12s %10s %12s %10s %9s\n", $1,$2,$3,$4,$5,$6,$7}' >> "$OUT/check.txt"
  else
    echo "WARN  $label: the checker produced no row, see $OUT/check/$label.txt"
  fi
  [[ "${KEEP_PCAP:-0}" == 1 ]] || rm -f "$OUT/pcap/$label"-*
done

echo
cat "$OUT/check.txt"
echo
awk 'NR > 1 { n++; if ($6 == 0) ok++; else late++ } END { printf "%d configurations checked: %d with no overlap (rule proved), %d with overlapping rounds (rule observed)\n", n, ok, late }' "$OUT/check.txt"
