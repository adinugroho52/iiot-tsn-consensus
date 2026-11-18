#!/usr/bin/env bash
#
# sweep.sh -- resumable experiment driver for iiot-consensus-tsn
#
# Run from the ns-3 root:   tools/sweep.sh --list | --dry-run EXP | EXP [EXP ...]
# Every run gets --ctrlPeriod=1000us --stopAt=6.0s (override with --stopat, --ctrl-period).
# Options: --link RATE  --shaper tas|prio|fifo  --ctrl-frac F  --extra "--flag=value"
#          --seeds "1 2 3"  --jobs N (untested against ./ns3 run)  --force  --list  --dry-run
#
# Experiments (cells at the defaults; knobs are E<n>_* environment variables, see each block):
#   e1   alignment vs path length at a 5 us window, naive against aligned          12
#   e2   consensus load: committee size x message size (1 Gbps)                    20
#   e3   consensus round interval at 16 validators, 1 kB                            5
#   e4   control/consensus window split                                             5
#   e5   shaper comparison: tas, prio, fifo over path length (100 Mbps default)    12
#   e6   control burst sweep: the capacity cliff                                    9
#   e7   feasibility frontier: control burst x shaper x path length               84
#   e8   joint map: control burst x committee x message size x shaper              81
#   e9   alignment fragility: systematic per-hop offset error, window width         21
#   e10  device transmit queue size: priority blocking, TAS isolation               24
#   e11  consensus window slices                                                    14
#   e12  uncertainty: 20 random draws (clock error, round phase, placement)        180
#   e13  burst capacity by traffic class and device queue size                       8
#   figs packet captures for the figures (4 runs)
# `all` runs everything except e12 and figs. Summarise with frontier.py (e5-e8) and
# uncertainty.py (e12).
#
# Resumption is by row in summary.csv, written only after a run exits zero: an
# interrupted sweep continues where it stopped. --force re-runs regardless.
# The model is deterministic until a random option is on, so one run per cell is enough.
#
# Layout:
#   results/csv/      per-frame latency (and consensus) CSVs
#   results/log/      full stdout per run, including the summary block
#   results/pcap/     captures from the figure runs
#   results/summary.csv   one parsed row per run, with the realised configuration
#   results/failed.txt    cells that exited non-zero
#
set -uo pipefail

# --- locate ns-3 -------------------------------------------------------------
NS3="${NS3:-./ns3}"
PROG="${PROG:-iiot-consensus-tsn}"

# --- knobs -------------------------------------------------------------------
SEEDS="${SEEDS:-1}"               # the model is deterministic; see note below
STOPAT="${STOPAT:-6.0s}"          # 2.0s gives only 1400 control samples
CTRL_PERIOD="${CTRL_PERIOD:-1000us}"
LINK_RATE="${LINK_RATE:-}"        # empty = simulator default
CTRL_FRAC="${CTRL_FRAC:-}"        # empty = simulator default
SHAPER="${SHAPER:-}"              # empty = simulator default (tas)
EXTRA=()                          # anything else to pass on every run
JOBS=1
DRY=0
FORCE=0
LIST=0

OUT="results"
CSV="$OUT/csv"; LOG="$OUT/log"; PCAP="$OUT/pcap"
SUMMARY="$OUT/summary.csv"
FAILED="$OUT/failed.txt"


# --- argument parsing --------------------------------------------------------
WANT=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)    JOBS="$2"; shift 2 ;;
    --jobs=*)  JOBS="${1#*=}"; shift ;;
    --dry-run|-n) DRY=1; shift ;;
    --force)   FORCE=1; shift ;;
    --list|-l) LIST=1; shift ;;
    --seeds)   SEEDS="$2"; shift 2 ;;
    --seeds=*) SEEDS="${1#*=}"; shift ;;
    --stopat)  STOPAT="$2"; shift 2 ;;
    --link)    LINK_RATE="$2"; shift 2 ;;
    --link=*)  LINK_RATE="${1#*=}"; shift ;;
    --ctrl-frac)   CTRL_FRAC="$2"; shift 2 ;;
    --ctrl-frac=*) CTRL_FRAC="${1#*=}"; shift ;;
    --ctrl-period) CTRL_PERIOD="$2"; shift 2 ;;
    --shaper)  SHAPER="$2"; shift 2 ;;
    --shaper=*) SHAPER="${1#*=}"; shift ;;
    --extra)   EXTRA+=("$2"); shift 2 ;;
    -h|--help) sed -n '/^#/!q;p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *)  WANT+=("$1"); shift ;;
  esac
done
[[ ${#WANT[@]} -eq 0 ]] && WANT=(all)

# COMMON is assembled here, AFTER argument parsing, so that a later option can
# never clobber an earlier one. An earlier version rebuilt this array inside the
# --stopat handler, which silently dropped --linkRate from an entire sweep.
COMMON=(--ctrlPeriod="$CTRL_PERIOD" --stopAt="$STOPAT")
[[ -n "$LINK_RATE" ]] && COMMON+=(--linkRate="$LINK_RATE")
[[ -n "$CTRL_FRAC"  ]] && COMMON+=(--ctrlFrac="$CTRL_FRAC")
[[ -n "$SHAPER"     ]] && COMMON+=(--shaper="$SHAPER")
[[ ${#EXTRA[@]} -gt 0 ]] && COMMON+=("${EXTRA[@]}")

mkdir -p "$CSV" "$LOG" "$PCAP"

echo "flags on every run: ${COMMON[*]}"
echo "seeds: $SEEDS"

wants() {
  local e="$1"
  for w in "${WANT[@]}"; do
    [[ "$w" == "$e" ]] && return 0
    [[ "$w" == "all" && "$e" != "figs" && "$e" != "e12" ]] && return 0
  done
  return 1
}

# --- summary parsing ---------------------------------------------------------
# Fields are pulled from the simulator's stdout block by label. Anything the
# run did not print comes out empty rather than shifting other columns.
init_summary() {
  [[ -f "$SUMMARY" ]] && return
  echo "cell,exp,tag,run,shaper,link,cycle_us,ctrl_win_us,perhop_ns,ctrl_sent,ctrl_recv,ctrl_missed,miss_ratio,ctrl_min_us,ctrl_mean_us,ctrl_p99_us,ctrl_max_us,cons_rounds,cons_msgs,cons_committed,cons_mean_us,cons_p50_us,cons_p99_us,cons_max_us,wall_s" > "$SUMMARY"
}

# Value is the Nth whitespace-separated field of the matching line. Taking a
# field index rather than "first number on the line" matters: the p99 and p50
# labels contain digits, so a naive number-grab returns 99 and 50 instead of
# the latency.
val() {  # val <file> <line-regex> <field-index>
  awk -v n="$3" '$0 ~ re { print $n; exit }' re="$2" "$1" 2>/dev/null
}

parse_run() {  # parse_run <cell> <exp> <tag> <run> <logfile> <wall>
  local cell="$1" exp="$2" tag="$3" run="$4" f="$5" wall="$6"

  local sent recv missed ratio cmin cmean cp99 cmax
  sent=$(  val "$f" '^  sent '     2)
  recv=$(  val "$f" '^  received ' 2)
  missed=$(val "$f" '^  missed '   2)
  ratio=$( val "$f" '^  missed '   4)
  cmin=$(  val "$f" '^  min '      2)
  cmean=$( val "$f" '^  mean '     2)
  cp99=$(  val "$f" '^  p99 '      2)
  cmax=$(  val "$f" '^  max '      2)

  local rounds msgs committed kmean kp50 kp99 kmax
  rounds=$(   val "$f" '^  rounds started'      3)
  msgs=$(     val "$f" '^  messages sent'       3)
  committed=$(val "$f" '^  rounds committed'    3)
  kmean=$(    val "$f" '^  commit latency mean' 4)
  kp50=$(     val "$f" '^  commit latency p50'  4)
  kp99=$(     val "$f" '^  commit latency p99'  4)
  kmax=$(     val "$f" '^  commit latency max'  4)

  # Realised configuration, read back from the log rather than from the flags we
  # think we passed. A sweep whose flags did not take effect is then visible in
  # the data instead of only in the logs.
  local shp link cyc cwin phop
  shp=$( val "$f" '^  shaper '       2)
  link=$(val "$f" '^  link '         2)
  cyc=$( val "$f" '^  cycle '        2)
  cwin=$(val "$f" '^  windows '      3)
  phop=$(val "$f" '^  perHopOffset ' 2)

  echo "$cell,$exp,$tag,$run,$shp,$link,$cyc,$cwin,$phop,$sent,$recv,$missed,$ratio,$cmin,$cmean,$cp99,$cmax,$rounds,$msgs,$committed,$kmean,$kp50,$kp99,$kmax,$wall" >> "$SUMMARY"
}

# --- run one cell ------------------------------------------------------------
# run_cell <cell-name> <exp> <tag> <run> <output-csv> [extra flags...]
# The output-csv argument is retained for readability at the call sites; the
# resume decision is made from summary.csv, not from that file.
run_cell() {
  local cell="$1" exp="$2" tag="$3" run="$4" sentinel="$5"; shift 5
  local logf="$LOG/$cell.log"

  # Completion is judged by a row in summary.csv, which is written only after
  # the run exits zero and parses. Using the output CSV instead would count a
  # crashed run as done, because the simulator writes its CSV incrementally and
  # a partial file is indistinguishable from a complete one by existence alone.
  if [[ $FORCE -eq 0 ]] && grep -q "^$cell," "$SUMMARY" 2>/dev/null; then
    [[ $LIST -eq 1 ]] && echo "  done  $cell"
    return 0
  fi
  if [[ $LIST -eq 1 ]]; then echo "  TODO  $cell"; return 0; fi

  local args=("$PROG" "${COMMON[@]}" "--run=$run" "$@")
  if [[ $DRY -eq 1 ]]; then
    printf '%s run "%s"\n' "$NS3" "${args[*]}"
    return 0
  fi

  local t0 t1 rc
  t0=$(date +%s)
  "$NS3" run "${args[*]}" > "$logf" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "$cell (exit $rc)" >> "$FAILED"
    echo "FAIL  $cell  -- see $logf" >&2
    return 0        # keep the sweep going
  fi
  t1=$(date +%s)

  parse_run "$cell" "$exp" "$tag" "$run" "$logf" "$((t1-t0))"
  echo "ok    $cell  ($((t1-t0))s)"
}

# Bounded parallelism without GNU parallel.
throttle() {
  while [[ $(jobs -rp | wc -l) -ge $JOBS ]]; do wait -n 2>/dev/null || sleep 0.2; done
}
launch() {
  if [[ $JOBS -le 1 || $DRY -eq 1 || $LIST -eq 1 ]]; then run_cell "$@"
  else throttle; run_cell "$@" & fi
}

init_summary

# =============================================================================
# e1 -- phase alignment vs path length, with a 5 us control window
# (at the default 200 us window naive and aligned are identical on any path
#  that fits, because the window is far wider than the per-hop transit)
# =============================================================================
if wants e1; then
  echo "== e1: phase alignment vs nSwitches"
  for S in 2 4 6 8 12 16; do
    for R in $SEEDS; do
      c="e1-naive-s$S-r$R"
      launch "$c" e1 "naive-s$S" "$R" "$CSV/$c.csv" \
        --nSwitches=$S --ctrlFrac=0.005 --perHopOffset=0 --latencyCsv="$CSV/$c.csv"
      c="e1-aligned-s$S-r$R"
      launch "$c" e1 "aligned-s$S" "$R" "$CSV/$c.csv" \
        --nSwitches=$S --ctrlFrac=0.005 --latencyCsv="$CSV/$c.csv"
    done
  done
  wait
fi

# =============================================================================
# e2 -- consensus load: committee size x message size
# =============================================================================
if wants e2; then
  echo "== e2: nValidators x consensusMsgSize"
  for V in 4 7 10 13 16; do
    for M in 256 512 1024 2048; do
      for R in $SEEDS; do
        c="e2-v$V-m$M-r$R"
        launch "$c" e2 "v$V-m$M" "$R" "$CSV/$c.csv" \
          --nValidators=$V --consensusMsgSize=$M \
          --latencyCsv="$CSV/$c.csv" --consensusCsv="$CSV/$c-cons.csv"
      done
    done
  done
  wait
fi

# =============================================================================
# e3 -- round rate at the heavy cell
# =============================================================================
if wants e3; then
  echo "== e3: consensusInterval at v16/1024"
  for I in 20ms 10ms 5ms 2ms 1ms; do
    for R in $SEEDS; do
      c="e3-i$I-r$R"
      launch "$c" e3 "i$I" "$R" "$CSV/$c.csv" \
        --nValidators=16 --consensusMsgSize=1024 --consensusInterval=$I \
        --latencyCsv="$CSV/$c.csv" --consensusCsv="$CSV/$c-cons.csv"
    done
  done
  wait
fi

# =============================================================================
# e4 -- bandwidth partition sensitivity
# =============================================================================
if wants e4; then
  echo "== e4: ctrlFrac / consFrac"
  for F in "0.10:0.30" "0.20:0.30" "0.30:0.30" "0.20:0.20" "0.20:0.50"; do
    CF="${F%%:*}"; KF="${F##*:}"
    for R in $SEEDS; do
      c="e4-c$CF-k$KF-r$R"
      launch "$c" e4 "c$CF-k$KF" "$R" "$CSV/$c.csv" \
        --nValidators=16 --consensusMsgSize=1024 \
        --ctrlFrac=$CF --consFrac=$KF --latencyCsv="$CSV/$c.csv"
    done
  done
  wait
fi

# =============================================================================
# e5 -- shaper comparison: does time gating beat plain strict priority?
#
# Run at 100 Mbps deliberately. At 1 Gbps a 1054 B consensus frame is 8.4 us,
# so strict priority blocks control by at most 8.4 us per hop and never misses
# a 1000 us deadline -- the comparison is degenerate and TAS wins nothing. At
# 100 Mbps that frame is 84.3 us, so accumulated blocking crosses the deadline
# somewhere around 12 hops and the three disciplines separate.
#
# 10 Mbps would separate them harder but is not usable: a 1054 B frame is
# 843 us there, larger than the 300 us consensus window, so under TAS it can
# never be transmitted at all and consensus deadlocks. The baselines have no
# windows and would run fine, which would make the comparison meaningless.
# =============================================================================
if wants e5; then
  echo "== e5: tas vs prio vs fifo (100 Mbps unless --link overrides)"
  lr=()
  [[ -z "$LINK_RATE" ]] && lr=(--linkRate=100Mbps)
  for SH in tas prio fifo; do
    for S in 4 8 12 16; do
      for R in $SEEDS; do
        c="e5-$SH-s$S-r$R"
        launch "$c" e5 "$SH-s$S" "$R" "$CSV/$c.csv" \
          --shaper=$SH --nSwitches=$S --nValidators=16 --consensusMsgSize=1024 \
          "${lr[@]}" --latencyCsv="$CSV/$c.csv" --consensusCsv="$CSV/$c-cons.csv"
      done
    done
  done
  wait
fi

# =============================================================================
# e6 -- contested control: how many control frames per cycle can a window carry?
#
# Needs the --ctrlBurst patch. Each period the PLC sends B frames back to back,
# modelling B streams that share one period and phase. A window of W holds
# floor(W / frame time) frames, so the first miss is expected at one frame past
# that. The model is deterministic, so one run per burst size is enough.
#   1 Gbps  : ./sweep.sh e6                          (window holds 265)
#   100 Mbps: E6_BURSTS="1 10 20 25 26 27 30" ./sweep.sh --link 100Mbps e6
# =============================================================================
if wants e6; then
  echo "== e6: control burst sweep"
  for B in ${E6_BURSTS:-1 50 100 200 260 265 266 270 300}; do
    c="e6-b$B-r1"
    launch "$c" e6 "b$B" 1 "$CSV/$c.csv" \
      --ctrlBurst=$B --latencyCsv="$CSV/$c.csv"
  done
  wait
fi

# =============================================================================
# e7 -- feasibility frontier: control load x shaper x path length
#
# Needs the --ctrlBurst patch. Every cell writes its per-frame latency CSV, so
# frontier.py can apply any deadline offline and no rerun is needed per deadline.
#   1 Gbps  : ./sweep.sh e7
#   100 Mbps: E7_BURSTS="1 5 10 15 20 26" ./sweep.sh --link 100Mbps e7
# Keep the largest burst below the window capacity (265 at 1 Gbps, 26 at
# 100 Mbps for 64 B payloads): a run exactly at capacity keeps a stuck backlog.
# =============================================================================
if wants e7; then
  echo "== e7: control burst x shaper x switches"
  for SH in tas prio fifo; do
    for S in ${E7_SWITCHES:-4 8 12 16}; do
      for B in ${E7_BURSTS:-1 50 100 150 200 250 265}; do
        c="e7-$SH-s$S-b$B-r1"
        launch "$c" e7 "$SH-s$S-b$B" 1 "$CSV/$c.csv" \
          --shaper=$SH --nSwitches=$S --nValidators=16 --consensusMsgSize=1024 \
          --ctrlBurst=$B --latencyCsv="$CSV/$c.csv"
      done
    done
  done
  wait
fi

# =============================================================================
# e8 -- joint map: control load x consensus load x shaper, one path length
#
# Needs the --ctrlBurst patch. e7 holds consensus fixed; this adds the consensus
# axes (committee size, message size) so frontier.py can report where control
# AND consensus both hold. Under TAS the two should be independent; under
# priority and FIFO they interact, which is what this map is for.
#   1 Gbps  : ./sweep.sh e8
#   100 Mbps: E8_BURSTS="1 10 20" ./sweep.sh --link 100Mbps e8
# =============================================================================
if wants e8; then
  echo "== e8: shaper x validators x message size x control burst"
  S=${E8_SWITCHES:-8}
  for SH in tas prio fifo; do
    for N in ${E8_VALIDATORS:-4 10 16}; do
      for M in ${E8_MSGSIZES:-256 1024 2048}; do
        for B in ${E8_BURSTS:-1 100 200}; do
          c="e8-$SH-s$S-n$N-m$M-b$B-r1"
          launch "$c" e8 "$SH-s$S-n$N-m$M-b$B" 1 "$CSV/$c.csv" \
            --shaper=$SH --nSwitches=$S --nValidators=$N --consensusMsgSize=$M \
            --ctrlBurst=$B --latencyCsv="$CSV/$c.csv"
        done
      done
    done
  done
  wait
fi

# =============================================================================
# e9 -- how fragile is gate alignment?
#
# Uses only existing flags. Phase of port k is k x --perHopOffset, so an offset
# that is eps ns too small drifts by k x eps ns by hop k: windows open early and
# close early relative to the frame. A frame is late for its window at hop k once
# the drift exceeds what the window can absorb, so tolerance falls with path
# length and grows with window width. A negative eps (offset too large) only
# makes the frame wait, so it costs latency, not misses.
#   (a) sweep eps at a 5 us window     (b) sweep window width at a fixed eps
# E9_BASE is the derived offset in ns: 852 at 1 Gbps with 64 B payloads.
# =============================================================================
if wants e9; then
  echo "== e9: alignment fragility"
  S=${E9_SWITCHES:-16}
  BASE=${E9_BASE:-852}
  for E in ${E9_EPS:-0 100 200 250 260 270 280 300 310 320 400 852 -500 -5000}; do
    c="e9-s$S-w5-e$E-r1"
    launch "$c" e9 "s$S-w5-e$E" 1 "$CSV/$c.csv" \
      --nSwitches=$S --ctrlFrac=0.005 --perHopOffset=$((BASE - E))ns \
      --latencyCsv="$CSV/$c.csv"
  done
  FIX=${E9_FIXEPS:-200}
  for W in ${E9_WINDOWS:-2 3 3.5 4 5 10 20 50}; do
    # W = 5 at the same error is already a cell of sweep (a)
    [[ "$W" == "5" && " ${E9_EPS:-0 100 200 250 260 270 280 300 310 320 400 852 -500 -5000} " == *" $FIX "* ]] && continue
    F=$(awk -v w="$W" 'BEGIN{printf "%.5f", w/1000}')
    c="e9-s$S-w$W-e$FIX-r1"
    launch "$c" e9 "s$S-w$W-e$FIX" 1 "$CSV/$c.csv" \
      --nSwitches=$S --ctrlFrac=$F --perHopOffset=$((BASE - FIX))ns \
      --latencyCsv="$CSV/$c.csv"
  done
  wait
fi

# =============================================================================
# e10 -- does the device transmit queue explain strict priority's extra blocking?
#
# Needs the --devQueue patch. A frame already handed to the device queue cannot be
# overtaken, so with a queue of q packets a control frame can wait behind the
# frame in service plus q committed frames at every hop: (q + 1) frames per hop.
# Hypothesis: priority's worst-case control latency rises with q. TAS should not,
# if its gates really isolate control. 1 Gbps, 16 validators, 1 kB messages.
# =============================================================================
if wants e10; then
  echo "== e10: device queue size"
  for SH in prio tas fifo; do
    for S in ${E10_SWITCHES:-4 16}; do
      for Q in ${E10_QUEUES:-1 2 4 8}; do
        c="e10-$SH-s$S-q$Q-r1"
        launch "$c" e10 "$SH-s$S-q$Q" 1 "$CSV/$c.csv" \
          --shaper=$SH --nSwitches=$S --nValidators=16 --consensusMsgSize=1024 \
          --devQueue=${Q}p --latencyCsv="$CSV/$c.csv"
      done
    done
  done
  wait
fi

# =============================================================================
# e11 -- consensus slices: trade gate-wait latency against per-slice stranding
#
# Needs the --consSlices patch. Cutting the consensus window into K slices spread
# over the cycle shortens the wait for the next window, so each PBFT phase
# finishes sooner. Total consensus time is unchanged, but every slice strands up
# to one frame, so capacity becomes K * floor((window / K) / frame time) frames
# per cycle, which is not monotone in K.
#   1 Gbps  : ./sweep.sh e11
#   100 Mbps: E11_VALIDATORS=10 E11_SWITCHES=8 E11_SLICES="1 2 3 4 5 6 7" \
#             ./sweep.sh --link 100Mbps --extra --consFrac=0.60 e11
# =============================================================================
if wants e11; then
  echo "== e11: consensus slices"
  N=${E11_VALIDATORS:-16}
  M=${E11_MSG:-1024}
  for S in ${E11_SWITCHES:-4 16}; do
    for K in ${E11_SLICES:-1 2 3 4 6 8 12}; do
      c="e11-s$S-n$N-m$M-k$K-r1"
      launch "$c" e11 "s$S-n$N-m$M-k$K" 1 "$CSV/$c.csv" \
        --nSwitches=$S --nValidators=$N --consensusMsgSize=$M \
        --consSlices=$K --latencyCsv="$CSV/$c.csv"
    done
  done
  wait
fi

# =============================================================================
# e12 -- uncertainty: independent runs with the random options switched on
#
# Needs the --offsetJitter patch. The model is deterministic until a random option
# is on, so --run only means something here. Each run is a different, repeatable
# draw. Summarise with uncertainty.py.
#   (a) yield of a narrow-window alignment under independent per-port clock error:
#       with a 5 us window each run either misses (every frame) or never does, so
#       the interesting number is the share of runs that miss, versus sigma.
#       Independent errors do not accumulate along the path the way a systematic
#       per-hop drift does (e9): a frame is late by about the largest earlier
#       error minus the current one. Expect the transition near sigma = 1 to 2 us
#       (about 0.1 at 1000 ns, 0.4 at 1250 ns, 0.7 at 1500 ns, 0.95 at 2000 ns),
#       not near the 270 ns per hop that e9 found.
#   (b) the shaper comparison with random consensus round phase and validator
#       placement, so every headline number gets an interval.
#   ./sweep.sh e12                       E12_SEEDS="1 2 3 4 5" for a quick look
# =============================================================================
if wants e12; then
  echo "== e12: independent runs"
  SEEDS12=${E12_SEEDS:-$(seq -s ' ' 1 20)}
  for SIG in ${E12_SIGMAS:-0 500 1000 1250 1500 2000}; do
    for R in $SEEDS12; do
      c="e12-a-sig$SIG-r$R"
      launch "$c" e12 "a-sig$SIG" "$R" "$CSV/$c.csv" \
        --nSwitches=16 --ctrlFrac=0.005 --offsetJitter=${SIG}ns --latencyCsv="$CSV/$c.csv"
    done
  done
  for SH in tas prio fifo; do
    for R in $SEEDS12; do
      c="e12-b-$SH-r$R"
      launch "$c" e12 "b-$SH" "$R" "$CSV/$c.csv" \
        --shaper=$SH --nSwitches=${E12_SWITCHES:-8} --nValidators=16 --consensusMsgSize=1024 \
        --ctrlBurst=${E12_BURST:-100} --randomRoundPhase=true --randomPlacement=true \
        --latencyCsv="$CSV/$c.csv"
    done
  done
  wait
fi

# =============================================================================
# e13 -- why does the control class admit one frame more than strict fit?
#
# Needs the --ctrlTos and --devQueue patches. Hypothesis: with a q-packet device
# queue, the qdisc commits frame m while frame m-q is starting, and the gate's
# fit test runs at that moment against the qdisc-size frame time d, so
#   capacity = floor((W - d) / frame time) + 1 + q.
# At 1 Gbps, 64 B payloads, W = 200 us that is 266, 267, 269, 273 for q = 1, 2, 4, 8.
# Strict fit with no committed frame would stay at 265. The same burst is sent in
# the control class (ToS 16) and in the consensus class (ToS 24) with equal windows,
# so any class dependence shows up directly. Delivered frames per cycle =
# ctrl_recv / 5400 for a 6 s run.
# =============================================================================
if wants e13; then
  echo "== e13: control class vs consensus class, by device queue size"
  for TOS in ${E13_TOS:-16 24}; do
    for Q in ${E13_QUEUES:-1 2 4 8}; do
      c="e13-tos$TOS-q$Q-r1"
      launch "$c" e13 "tos$TOS-q$Q" 1 "$CSV/$c.csv" \
        --ctrlTos=$TOS --devQueue=${Q}p --ctrlBurst=${E13_BURST:-300} \
        --ctrlFrac=0.2 --consFrac=0.2 --nSwitches=4 --nValidators=4 --consensusMsgSize=256 \
        --latencyCsv="$CSV/$c.csv"
    done
  done
  wait
fi

# =============================================================================
# figs -- captures. Three of them. Captures show mechanism, not statistics.
# =============================================================================
if wants figs; then
  echo "== figs: captures"
  # pcapPrefix is relative to the ns-3 working directory, so the captures land
  # under results/pcap/ without any directory juggling.
  fig() {
    local name="$1"; shift
    local logf="$LOG/$name.log"
    if [[ $LIST -eq 1 ]]; then echo "  fig   $name"; return; fi
    if [[ $DRY -eq 1 ]]; then
      printf '%s run "%s %s"\n' "$NS3" "$PROG" "$*"; return
    fi
    if "$NS3" run "$PROG $*" > "$logf" 2>&1; then echo "ok    $name"
    else echo "$name" >> "$FAILED"; echo "FAIL  $name -- see $logf" >&2; fi
  }

  fig fig-baseline "${COMMON[*]} --run=1 --pcapPoints=path \
    --pcapStart=0.5s --pcapStop=0.52s --pcapPrefix=$PCAP/fig-baseline"

  fig fig-naive "${COMMON[*]} --run=1 --perHopOffset=0 --pcapPoints=path \
    --pcapStart=0.5s --pcapStop=0.53s --pcapPrefix=$PCAP/fig-naive"

  fig fig-stress "${COMMON[*]} --run=1 --nValidators=16 --consensusMsgSize=1024 \
    --consensusInterval=2ms --pcapPoints=path \
    --pcapStart=0.5s --pcapStop=0.55s --pcapPrefix=$PCAP/fig-stress"

  fig fig-e2e "${COMMON[*]} --run=1 --pcapPoints=control --pcapMode=rx \
    --pcapStart=0.5s --pcapStop=0.52s --pcapPrefix=$PCAP/fig-e2e"
fi

# --- wrap up -----------------------------------------------------------------
wait
if [[ $DRY -eq 0 && $LIST -eq 0 ]]; then
  echo
  echo "summary   $SUMMARY  ($(($(wc -l < "$SUMMARY") - 1)) rows)"
  if [[ -s "$FAILED" ]]; then
    echo "FAILURES  $FAILED  ($(wc -l < "$FAILED") cells) -- rerun after fixing;"
    echo "          completed cells are skipped automatically"
  fi
fi
