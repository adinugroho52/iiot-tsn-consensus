#!/usr/bin/env bash
#
# fault_sweep.sh -- the fault experiments (F) of the second paper: does a view
# change break a configuration that passes the consensus-window counting rule?
#
# Run from the ns-3 root, like tools/sweep.sh:
#
#     tools/fault_sweep.sh                 # every set, one job at a time
#     tools/fault_sweep.sh -j 4 f1         # one set, four jobs in parallel
#     tools/fault_sweep.sh --dry-run f2    # print the commands only
#
# Every cell starts from one of E12's configurations of the first paper (the
# counting rule at its edge) and runs the full PBFT model for 6 s; a fault, when
# there is one, lasts from 1.0 s to 2.5 s, which leaves 3.4 s to see whether
# the network recovers or keeps changing views on its own.
#
# Before each run, tools/vc_budget.py states a prediction from frame counts alone
# (safe, boundary, storm, drop, c5pass, c5fail); summary.csv puts the prediction
# beside what the run measured. The simulation is deterministic (--run=1), so a
# single run per cell is the result, not a sample.
#
# Output in $OUT (default results_fault/): summary.csv, log/<cell>.log and
# csv/<cell>-rounds.csv (per-round open, commit and quorum times from the
# oracle). Finished cells are skipped on a rerun.
#
# Sets:
#   f1  crashed primary (36 cells): configuration x view timeout (2, 4, 8 rounds)
#       x re-propose window (all held, 2, 1). The main question.
#   f2  no fault (24 cells): configuration x view timeout (0.5, 1, 2 rounds) x
#       window (all held, 2). A timeout near the commit latency fires with no
#       fault; does the view change it causes settle or feed itself?
#   f3  Byzantine load (12 cells): flooding (2 and 8 copies) and equivocation,
#       with and without a re-propose window of 2.
#   f4  headroom (36 cells): 1 Gbps, 4 ms rounds, consensus window 300 to 440 us
#       (12 to 80 spare frames per round on the busiest link), under the four
#       triggers that broke w300t4 in f1-f3. Where does the storm stop?
#   f5  headroom vs committee size (38 cells): n = 7, 10, 13 at 1 Gbps, 4 ms
#       rounds, crash and equivocation with every held round re-proposed. Does
#       the f4 threshold (as a share of the load) carry over?
#   p1  protocols, no fault (9 cells): PBFT and chained HotStuff at n = 16
#       (E12's 1 Gbps network, 4 ms rounds) with the consensus window cut to
#       around each protocol's own load: the smallest window each needs.
#   p2  HotStuff under faults (31 cells): chained HotStuff with its window at
#       8 to 32 frames per round (-50% to +100% spare over its worst round, 16
#       frames, which binds; p1), under the triggers of f1-f4.
#   v1  validation (25 cells): configurations no earlier set used, with the
#       recovery rule's predictions registered in tools/validation/v1_cells.csv
#       before the runs (tools/validation_design.py).
set -uo pipefail

NS3="${NS3:-./ns3}"
PROG="${PROG:-iiot-consensus-tsn}"
OUT="${OUT:-results_fault}"
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
JOBS=1; DRY=0; SETS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -j) JOBS="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    f1|f2|f3|f4|f5|p1|p2|v1) SETS+=("$1"); shift ;;
    *) echo "unknown argument: $1 (sets are f1 f2 f3 f4 f5 p1 p2 v1)" >&2; exit 2 ;;
  esac
done
[[ ${#SETS[@]} -eq 0 ]] && SETS=(f1 f2 f3 f4 f5 p1 p2)   # v1 only by name
wants() { local s; for s in "${SETS[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }

LOG="$OUT/log"; CSV="$OUT/csv"; SUMMARY="$OUT/summary.csv"
mkdir -p "$LOG" "$CSV"
if [[ $DRY -eq 0 ]]; then
  "$NS3" build "$PROG" > /dev/null 2>&1 || { echo "building $PROG failed; run: $NS3 build $PROG" >&2; exit 1; }
fi

COLS="cell,set,config,attack,timeout_rounds,window,pred_C,pred_M,pred_Mflood,pred_B,pred_wait_ms,pred_wait3_ms,pred_drain_rounds,prediction,views_entered,max_view,view_changes,new_views,rounds_opened,quorum_done,abandoned,safety,stall_us,cons_peak,cons_peak_port,cons_drops,ctrl_drops,commit_p50_us,commit_p99_us,commit_max_us,msgs_per_round,ctrl_missed,ctrl_p99_us,ctrl_p99_during_us,ctrl_p99_outside_us,escalations,view_cap_nodes,wall_s"
[[ -f "$SUMMARY" || $DRY -eq 1 ]] || echo "$COLS" > "$SUMMARY"

# --- configurations: E12 of the first paper (E15 before v1.2.0) ----------------------------------
# name | simulator flags | vc_budget.py flags | round interval (ms)
E15_1G="--linkRate=1Gbps --nSwitches=4 --nValidators=16 --consensusMsgSize=1024"
E15_100M="--linkRate=100Mbps --consFrac=0.60 --nSwitches=8 --nValidators=10 --consensusMsgSize=1024 --consSlices=1"
CONFIGS=(
  "w300t6|$E15_1G --consensusInterval=6ms|--cons-frac 0.30 --interval-ms 6|6"
  "w300t4|$E15_1G --consensusInterval=4ms|--cons-frac 0.30 --interval-ms 4|4"
  "w275t4|$E15_1G --consFrac=0.275 --consensusInterval=4ms|--cons-frac 0.275 --interval-ms 4|4"
  "100mt8|$E15_100M --consensusInterval=8ms|--rate 100e6 --switches 8 --n 10 --cons-frac 0.60 --interval-ms 8|8"
)
# The view cap is a safety valve for short checks; here it would cut a storm off
# (at the default 64, two f1 cells stopped only because every node hit it).
BASE="--pbftModel=full --ctrlPeriod=1000us --stopAt=6.0s --run=1 --maxViewChanges=1000"
WIN="--attackStart=1.0s --attackStop=2.5s"

# --- helpers -------------------------------------------------------------------
get() { grep -m1 -E "$2" "$1" 2>/dev/null | awk -v k="$3" '{print $k}'; }

parse() {  # parse <log> -> the measured columns
  local L="$1" hv
  hv=$(grep -m1 '^  views entered' "$L" | sed -n 's/.*highest view \([0-9]*\).*/\1/p')
  local aband; aband=$(get "$L" '^  rounds abandoned' 3); [[ -z "$aband" ]] && aband=0
  local esc; esc=$(get "$L" '^  escalations' 2); [[ -z "$esc" ]] && esc=0
  local cap; cap=$(get "$L" '^  view cap reached' 4); [[ -z "$cap" ]] && cap=0
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' \
    "$(get "$L" '^  views entered' 3)" "$hv" \
    "$(get "$L" '^  broadcasts  view-change' 3)" "$(get "$L" '^  broadcasts  view-change' 5)" \
    "$(get "$L" '^  rounds opened' 3)" "$(get "$L" '^  rounds quorum-done' 3)" "$aband" \
    "$(get "$L" '^  safety violations' 3)" "$(get "$L" '^  longest stall' 3)" \
    "$(get "$L" '^  consensus peak' 3)" "$(get "$L" '^  consensus peak' 6 | tr -d ';')" \
    "$(get "$L" '^  drops ' 5)" "$(get "$L" '^  drops ' 3)" \
    "$(get "$L" '^  commit latency p50' 4)" "$(get "$L" '^  commit latency p99' 4)" \
    "$(get "$L" '^  commit latency max' 4)" "$(get "$L" '^  msgs/round actual' 3)" \
    "$(get "$L" '^  missed ' 2)" "$(get "$L" '^  p99 ' 2)" \
    "$(get "$L" '^  control during' 8)" "$(get "$L" '^  control outside' 8)" "$esc" "$cap"
}

run_cell() {  # run_cell <cell> <set> <config> <attack> <timeout_rounds> <window> <pred args> <sim flags>
  local cell="$1" set="$2" cfg="$3" atk="$4" tr="$5" win="$6" pargs="$7" flags="$8"
  local L="$LOG/$cell.log"
  local cmd="$PROG $BASE $flags --adversaryCsv=$CSV/$cell-rounds.csv"
  if [[ $DRY -eq 1 ]]; then echo "$NS3 run \"$cmd\""; return; fi
  if [[ -f "$LOG/$cell.done" ]]; then echo "done  $cell"; return; fi
  local pred="-,-,-,-,-,-,-,-"
  if [[ -n "$pargs" ]]; then
    # shellcheck disable=SC2086
    pred=$(python3 -I "$TOOLS/vc_budget.py" $pargs --csv | tail -1 |
           awk -F, '{print $1","$2","$3","$10","$13","$14","$16","$17}')
  fi
  local t0=$SECONDS
  if "$NS3" run --no-build "$cmd" > "$L" 2>&1; then
    echo "$cell,$set,$cfg,$atk,$tr,$win,$pred,$(parse "$L"),$((SECONDS - t0))" >> "$SUMMARY"
    touch "$LOG/$cell.done"
    echo "ok    $cell  (predicted ${pred##*,})"
  else
    echo "FAIL  $cell: exited non-zero, see $L"
  fi
}

throttle() { while [[ $(jobs -rp | wc -l) -ge $JOBS ]]; do wait -n 2>/dev/null || sleep 0.2; done; }
launch() { if [[ $JOBS -le 1 || $DRY -eq 1 ]]; then run_cell "$@"; else throttle; run_cell "$@" & fi; }

timeout_flag() {  # timeout_flag <rounds> <interval ms> -> --viewTimeout in us, and the vc_budget ms
  awk -v r="$1" -v t="$2" 'BEGIN{printf "%d %g", r*t*1000, r*t}'
}

# --- f1: crashed primary ---------------------------------------------------------
# Prediction (vc_budget.py): at w300t4 a crashed primary leaves a burst of about
# 576 frames on the middle trunk, a 16.5 ms wait against a 16 ms timeout: storm,
# in a configuration that passes the counting rule with 12 frames to spare. A
# re-propose window of 2 or a longer timeout should bring it back to boundary or
# safe. w275t4 has no spare capacity, so a backlog never drains. The 100 Mbps
# configuration has the same structure with 6 frames to spare.
if wants f1; then
  echo "== f1: crashed primary"
  for c in "${CONFIGS[@]}"; do
    IFS='|' read -r name flags pflags T <<< "$c"
    for tr in 2 4 8; do
      read -r vto_us vto_ms <<< "$(timeout_flag "$tr" "$T")"
      for w in 0 2 1; do
        cell="f1-$name-crash-to$tr-w$w"
        launch "$cell" f1 "$name" crash "$tr" "$w" \
          "$pflags --timeout-ms $vto_ms --repropose $w" \
          "$flags --attack=crash $WIN --viewTimeout=${vto_us}us --reproposeWindow=$w"
      done
    done
  done
  wait
fi

# --- f2: no fault, short timeouts --------------------------------------------------
# No prediction from the counts: whether a timeout fires depends on the commit
# latency, which the run measures. The question is what happens after the first
# spurious view change.
if wants f2; then
  echo "== f2: no fault, short view timeouts"
  for c in "${CONFIGS[@]}"; do
    IFS='|' read -r name flags pflags T <<< "$c"
    for tr in 0.5 1 2; do
      read -r vto_us vto_ms <<< "$(timeout_flag "$tr" "$T")"
      for w in 0 2; do
        cell="f2-$name-none-to$tr-w$w"
        launch "$cell" f2 "$name" none "$tr" "$w" "" \
          "$flags --viewTimeout=${vto_us}us --reproposeWindow=$w"
      done
    done
  done
  wait
fi

# --- f3: Byzantine load --------------------------------------------------------------
# Flooding: validator 15 (on the last switch, so its frames cross the middle
# trunk) sends k copies of everything. It adds 16 (k-1) frames per round there:
# k = 2 breaks the counting rule at w300t4 (144 > 140) but not at w300t6 (210).
# Equivocation forces one view change with every node alive.
if wants f3; then
  echo "== f3: Byzantine load"
  for c in "${CONFIGS[@]:0:3}"; do
    IFS='|' read -r name flags pflags T <<< "$c"
    for k in 2 8; do
      cell="f3-$name-flood$k"
      launch "$cell" f3 "$name" "flood$k" 4 0 \
        "$pflags --crash= --flood-node 15 --flood-factor $k" \
        "$flags --attack=flood --byzSelect=last --floodFactor=$k $WIN"
    done
    for w in 0 2; do
      cell="f3-$name-equivocate-w$w"
      launch "$cell" f3 "$name" equivocate 4 "$w" \
        "$pflags --crash= --repropose $w" \
        "$flags --attack=equivocate $WIN --reproposeWindow=$w"
    done
  done
  wait
fi

# --- f4: how much headroom does a view change need? -----------------------------
# f1-f3 bracket it: 12 spare frames per round (w300t4) stormed under every
# trigger with unbounded re-proposal, 82 (w300t6) never did. f4 fills the gap at
# 4 ms rounds by widening the consensus window: C = 4 x floor(W / 8.432 us).
#   W (us)   300  310  320  330  340  360  380  400  440
#   C        140  144  148  156  160  168  180  188  208
#   spare     12   16   20   28   32   40   52   60   80
# Triggers: crashed primary (timeout 4 rounds, all held rounds re-proposed),
# crashed primary (timeout 2 rounds, window 2: the second mechanism),
# equivocation, and flooding x2 (144 frames: exactly fills W = 310 us).
if wants f4; then
  echo "== f4: headroom"
  for W in 300 310 320 330 340 360 380 400 440; do
    frac=$(awk -v w="$W" 'BEGIN{printf "%g", w/1000}')
    name="w${W}t4"
    flags="$E15_1G --consFrac=$frac --consensusInterval=4ms"
    pflags="--cons-frac $frac --interval-ms 4"
    launch "f4-$name-crash-to4-w0" f4 "$name" crash 4 0 \
      "$pflags --timeout-ms 16 --repropose 0" \
      "$flags --attack=crash $WIN --viewTimeout=16000us --reproposeWindow=0"
    launch "f4-$name-crash-to2-w2" f4 "$name" crash 2 2 \
      "$pflags --timeout-ms 8 --repropose 2" \
      "$flags --attack=crash $WIN --viewTimeout=8000us --reproposeWindow=2"
    launch "f4-$name-equivocate-w0" f4 "$name" equivocate 4 0 \
      "$pflags --crash= --repropose 0" \
      "$flags --attack=equivocate $WIN --reproposeWindow=0"
    launch "f4-$name-flood2" f4 "$name" flood2 4 0 \
      "$pflags --crash= --flood-node 15 --flood-factor 2" \
      "$flags --attack=flood --byzSelect=last --floodFactor=2 $WIN"
  done
  wait
fi

# --- f5: does the headroom threshold scale with the committee? ----------------------
# f4 found, at n = 16, storms below about 25% spare (crash) and 31-41% spare
# (equivocation), as shares of the busiest link's load M. f5 repeats the two
# triggers at n = 7, 10 and 13 (same 4 switches, round-robin placement). The
# window holds k frames per cycle, so C = 4k; W = k x 8.432 us + 4 us.
#   n    M    k (C)                                        spare / M
#   7    24   7..11 (28..44)                               17 33 50 67 83 %
#   10   48   13 14 15 16 17 18 20 (52..80)                 8 17 25 33 42 50 67 %
#   13   84   23 24 26 28 30 32 34 (92..136)               10 14 24 33 43 52 62 %
# n = 16 is f4 (w300..w440).
if wants f5; then
  echo "== f5: headroom vs committee size"
  for spec in "7|7 8 9 10 11" "10|13 14 15 16 17 18 20" "13|23 24 26 28 30 32 34"; do
    n="${spec%%|*}"
    for k in ${spec#*|}; do
      frac=$(awk -v k="$k" 'BEGIN{printf "%.4f", (k * 8.432 + 4) / 1000}')
      name="n${n}c$((4 * k))t4"
      flags="--linkRate=1Gbps --nSwitches=4 --nValidators=$n --consensusMsgSize=1024 --consFrac=$frac --consensusInterval=4ms"
      pflags="--n $n --cons-frac $frac --interval-ms 4"
      launch "f5-$name-crash-to4-w0" f5 "$name" crash 4 0 \
        "$pflags --timeout-ms 16 --repropose 0" \
        "$flags --attack=crash $WIN --viewTimeout=16000us --reproposeWindow=0"
      launch "f5-$name-equivocate-w0" f5 "$name" equivocate 4 0 \
        "$pflags --crash= --repropose 0" \
        "$flags --attack=equivocate $WIN --reproposeWindow=0"
    done
  done
  wait
fi

# --- p1, p2: the protocol comparison -------------------------------------------------
# Busiest-link load per round at n = 16 (tools/vc_budget.py --protocol ...):
#   PBFT 128 (middle trunk, all-to-all), HotStuff 8 on average over the leader
#   rotation (16 in the worst single round).
# The window passes k frames per cycle, C = 4k per 4 ms round; W = k x 8.432 + 4 us.
pcell() {  # pcell <set> <protocol> <k> <attack> <timeout rounds|-> <extra sim flags> <vc_budget extra|""> [name suffix]
  local set="$1" proto="$2" k="$3" atk="$4" tr="$5" extra="$6" pextra="$7" sfx="${8:-}"
  local frac; frac=$(awk -v k="$k" 'BEGIN{printf "%.4f", (k * 8.432 + 4) / 1000}')
  local tag; case "$proto" in pbft) tag=pbft ;; hotstuff) tag=hs ;; esac
  local name="${tag}k${k}${sfx}t4"
  local flags="$E15_1G --consFrac=$frac --consensusInterval=4ms --protocol=$proto"
  local tflag="" tname="" pt=""
  if [[ "$tr" != "-" ]]; then
    tflag="--viewTimeout=$(awk -v r="$tr" 'BEGIN{printf "%d", r*4000}')us"
    tname="-to$tr"; pt="--timeout-ms $(awk -v r="$tr" 'BEGIN{print r*4}')"
  fi
  local pargs=""
  [[ -n "$pextra" ]] && pargs="--protocol $proto --cons-frac $frac --interval-ms 4 $pt $pextra"
  launch "$set-$name-$atk$tname" "$set" "$name" "$atk" "${tr/-/4}" 0 "$pargs" "$flags $tflag $extra"
}

if wants p1; then
  echo "== p1: protocols, no fault, window cut to each protocol's load"
  for k in 31 32 33 35; do pcell p1 pbft "$k" none - "" "--no-fault" ; done
  for k in 1 2 3 4 35; do pcell p1 hotstuff "$k" none - "" "--no-fault" ; done
  wait
fi

# p2. HotStuff: C = 8 to 32 (k = 2..8) is -50% to +100% spare over its worst
# round. A no-fault run at a short timeout (half a round) checks whether the
# timeout alone starts a storm where the window is tight (k <= 4).
if wants p2; then
  echo "== p2: HotStuff under faults"
  for k in 2 3 4 5 6 7 8; do
    pcell p2 hotstuff "$k" crash 4 "--attack=crash $WIN" "--crash 0"
    pcell p2 hotstuff "$k" crash 2 "--attack=crash $WIN" "--crash 0"
    [[ $k -le 4 ]] && pcell p2 hotstuff "$k" none 0.5 "" ""
    pcell p2 hotstuff "$k" flood2 - "--attack=flood --byzSelect=last --floodFactor=2 $WIN" ""
    pcell p2 hotstuff "$k" equivocate - "--attack=equivocate $WIN" "--crash="
  done
  wait
fi

# --- v1: the registered validation cells -----------------------------------------------
# The cells and their flags come from the registered file, so what runs is what
# was predicted. Check its SHA-256 against the one recorded at registration.
if wants v1; then
  echo "== v1: validation (registered predictions)"
  REG="$TOOLS/validation/v1_cells.csv"
  [[ -f "$REG" ]] || { echo "missing $REG" >&2; exit 1; }
  echo "registered file sha256 $(sha256sum "$REG" | cut -d' ' -f1)"
  while IFS='|' read -r cell set cfg atk tr win fl; do
    launch "$cell" "$set" "$cfg" "$atk" "$tr" "$win" "" "$fl"
  done < <(python3 -I -c '
import csv, sys
for r in csv.DictReader(open(sys.argv[1])):
    print("|".join([r["cell"], r["set"], r["config"], r["attack"], r["timeout_rounds"], r["window"], r["flags"]]))
' "$REG")
  wait
fi

[[ $DRY -eq 1 ]] || echo "summary: $SUMMARY"
