#!/usr/bin/env bash
#
# protocol_check.sh -- check the HotStuff model before the protocol comparison
# uses it. Same layout as tools/adversary_check.sh: run from the
# ns-3 root after building iiot-consensus-tsn.
#
#     tools/protocol_check.sh             # all scenarios, a few minutes
#     tools/protocol_check.sh hs-crash    # one scenario by name
#
# Each scenario is one short run (4 s, 10 ms rounds unless stated, fault window
# [1.0 s, 2.5 s)) with its expectation stated first. Logs go to results_proto/.
# PBFT is not touched by these models: tools/verify_reproducibility.sh --quick
# and tools/adversary_check.sh must still pass as before.
#
set -uo pipefail

NS3="${NS3:-./ns3}"
PROG="${PROG:-iiot-consensus-tsn}"
OUT="${OUT:-results_proto}"
mkdir -p "$OUT"
"$NS3" build "$PROG" > /dev/null 2>&1 || { echo "building $PROG failed; run: $NS3 build $PROG" >&2; exit 1; }

BASE="--ctrlPeriod=1000us --stopAt=4.0s --run=1"
WIN="--attackStart=1.0s --attackStop=2.5s"
PASS=0; FAIL=0

get() { grep -m1 -E "$2" "$1" | awk -v k="$3" '{print $k}'; }
check() { if eval "$3"; then echo "  PASS  $2"; PASS=$((PASS+1)); else echo "  FAIL  $2"; FAIL=$((FAIL+1)); fi; }
run() {
  local name="$1"; shift
  L="$OUT/$name.log"
  if ! "$NS3" run --no-build "$PROG $BASE $*" > "$L" 2>&1; then
    echo "  FAIL  $name: the run exited non-zero, see $L"; FAIL=$((FAIL+1)); return 1
  fi
}
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 < b+0)}'; }
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }
near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d <= t)}'; }
# all <done> <total> <slack>: done covers total, allowing slack rounds still in flight
all() { awk -v a="$1" -v b="$2" -v k="$3" 'BEGIN{exit !(a+0 >= b-k && a+0 <= b+0)}'; }

summary() {
  local L="$1"
  printf '        views %s (highest %s)  view-change %s  new-view %s  quorum-done %s of %s  stall %s us  safety %s\n' \
    "$(get "$L" '^  views entered' 3)" \
    "$(grep -m1 '^  views entered' "$L" | sed -n 's/.*highest view \([0-9]*\).*/\1/p')" \
    "$(get "$L" '^  broadcasts  view-change' 3)" "$(get "$L" '^  broadcasts  view-change' 5)" \
    "$(get "$L" '^  rounds quorum-done' 3)" "$(get "$L" '^  rounds opened' 3)" \
    "$(get "$L" '^  longest stall' 3)" "$(get "$L" '^  safety violations' 3)"
  printf '        msgs/round %s (expected %s)  commit p50 %s us  p99 %s us\n' \
    "$(get "$L" '^  msgs/round actual' 3)" "$(get "$L" '^  msgs/round expected' 3)" \
    "$(get "$L" '^  commit latency p50' 4)" "$(get "$L" '^  commit latency p99' 4)"
}

SEL=("$@")
sel() { [[ ${#SEL[@]} -eq 0 ]] && return 0; local w; for w in "${SEL[@]}"; do [[ "$w" == "$1" ]] && return 0; done; return 1; }

quorum_all() {  # every opened round quorum-done, allowing $2 in flight
  check "$1" "every opened round quorum-done (allowing $2 in flight)" \
    'all "$(get "$L" "^  rounds quorum-done" 3)" "$(get "$L" "^  rounds opened" 3)" '"$2"
}
safe() { check "$1" "no safety violation" '[[ "$(get "$L" "^  safety violations" 3)" == 0 ]]'; }

# --- HotStuff ----------------------------------------------------------------------
if sel hs-noattack; then
  echo "hs-noattack: chained HotStuff, n=4, no fault. Expect no timeout, 2(n-1) = 6 messages per round, every round committed by every node, and a commit latency of about three rounds (30 ms): a block commits when its great-grandchild arrives."
  if run hs-noattack --protocol=hotstuff; then
    r=$(get "$L" '^  rounds started' 3); c=$(get "$L" '^  rounds committed' 3)
    check hs-noattack "no timeout (views entered $(get "$L" '^  views entered' 3))" '[[ "$(get "$L" "^  views entered" 3)" == 0 ]]'
    check hs-noattack "msgs/round about 6" 'near "$(get "$L" "^  msgs/round actual" 3)" 6 0.2'
    check hs-noattack "node-rounds committed ($c of $((r*4)), the last 4 rounds may be in flight)" 'all "$c" "$((r*4))" 16'
    check hs-noattack "commit latency p50 between 2 and 4 rounds" 'ge "$(get "$L" "^  commit latency p50" 4)" 20000 && lt "$(get "$L" "^  commit latency p50" 4)" 40000'
    summary "$L"
  fi
fi

if sel hs-crash; then
  echo "hs-crash: n=4, validator 0 crashes. It leads every 4th view: expect a timeout and a NEW-VIEW each time its turn comes, orphaned rounds carried by the next block, no safety violation, and every round still reaching a quorum."
  if run hs-crash --protocol=hotstuff --attack=crash $WIN; then
    check hs-crash "NEW-VIEWs sent > 0" 'ge "$(get "$L" "^  broadcasts  view-change" 3)" 1'
    check hs-crash "proposals made on NEW-VIEWs > 0" 'ge "$(get "$L" "^  broadcasts  view-change" 5)" 1'
    safe hs-crash
    quorum_all hs-crash 5
    summary "$L"
  fi
fi

if sel hs-equivocate; then
  echo "hs-equivocate: n=4, validator 0 sends two blocks when it leads. Neither half reaches 2f+1 votes, so the next leader times out; expect equivocations, timeouts, no safety violation, every round reaching a quorum."
  if run hs-equivocate --protocol=hotstuff --attack=equivocate $WIN; then
    check hs-equivocate "equivocations > 0" 'ge "$(get "$L" "^  equivocations" 2)" 1'
    check hs-equivocate "timeouts > 0" 'ge "$(get "$L" "^  views entered" 3)" 1'
    safe hs-equivocate
    quorum_all hs-equivocate 5
    summary "$L"
  fi
fi

if sel hs-withhold; then
  echo "hs-withhold: n=4, one replica never votes. 3 votes remain = 2f+1: expect no timeout and every round reaching a quorum."
  if run hs-withhold --protocol=hotstuff --attack=withhold --byzSelect=last $WIN; then
    check hs-withhold "no timeout" '[[ "$(get "$L" "^  views entered" 3)" == 0 ]]'
    quorum_all hs-withhold 5
    summary "$L"
  fi
fi

if sel hs-n16; then
  echo "hs-n16: n=16 on E15's 1 Gbps network, 4 ms rounds, 300 us window (PBFT needs 128 frames per round there; HotStuff 8 on average). Expect 30 messages per round and every round committed."
  if run hs-n16 --protocol=hotstuff --linkRate=1Gbps --nSwitches=4 --nValidators=16 --consensusMsgSize=1024 --consensusInterval=4ms; then
    r=$(get "$L" '^  rounds started' 3); c=$(get "$L" '^  rounds committed' 3)
    check hs-n16 "msgs/round about 30" 'near "$(get "$L" "^  msgs/round actual" 3)" 30 0.5'
    check hs-n16 "node-rounds committed ($c of $((r*16)))" 'all "$c" "$((r*16))" 64'
    check hs-n16 "consensus queue peak below 40 frames" 'lt "$(get "$L" "^  consensus peak" 3)" 40'
    summary "$L"
  fi
fi

echo
echo "$PASS passed, $FAIL failed. Logs in $OUT/."
[[ $FAIL -eq 0 ]]
