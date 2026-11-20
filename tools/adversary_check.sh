#!/usr/bin/env bash
#
# adversary_check.sh -- check the full PBFT model and the Byzantine behaviours.
#
# Run from the ns-3 root, like tools/sweep.sh, after building iiot-consensus-tsn:
#
#     tools/adversary_check.sh            # all 13 scenarios, about 5 minutes
#     tools/adversary_check.sh crash1     # one scenario by name
#
# Each scenario is one short run (4 s, attack window [1.0 s, 2.5 s), so 1.5 s of
# recovery) with an expectation stated before the run. The script prints PASS or
# FAIL per check and a few figures worth reading, and keeps every log in
# results_adv/. It does not replace the regression check: for that, run
# tools/verify_reproducibility.sh --quick, whose sets must stay IDENTICAL.
#
set -uo pipefail

NS3="${NS3:-./ns3}"
PROG="${PROG:-iiot-consensus-tsn}"
OUT="${OUT:-results_adv}"
mkdir -p "$OUT"
"$NS3" build "$PROG" > /dev/null 2>&1 || { echo "building $PROG failed; run: $NS3 build $PROG" >&2; exit 1; }

BASE="--ctrlPeriod=1000us --stopAt=4.0s --run=1 --pbftModel=full"
WIN="--attackStart=1.0s --attackStop=2.5s"
PASS=0; FAIL=0

# get <log> <line pattern> <field>: the field-th whitespace field of the first matching line
get() { grep -m1 -E "$2" "$1" | awk -v k="$3" '{print $k}'; }

check() {  # check <scenario> <description> <shell condition>
  if eval "$3"; then echo "  PASS  $2"; PASS=$((PASS+1))
  else echo "  FAIL  $2"; FAIL=$((FAIL+1)); fi
}

run() {  # run <name> <flags...>; sets L to the log path
  local name="$1"; shift
  L="$OUT/$name.log"
  if ! "$NS3" run --no-build "$PROG $BASE $*" > "$L" 2>&1; then
    echo "  FAIL  $name: the run exited non-zero, see $L"; FAIL=$((FAIL+1)); return 1
  fi
}

lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 < b+0)}'; }   # numeric a < b
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }  # numeric a >= b
# all <done> <total> <per-round>: done covers total, allowing the last round (opened
# just before the run stops) to be still in flight
all() { awk -v a="$1" -v b="$2" -v k="$3" 'BEGIN{exit !(a+0 >= b-k && a+0 <= b+0)}'; }

# Figures read from the adversary section.
summary() {
  local L="$1"
  printf '        views %s  VIEW-CHANGE %s  NEW-VIEW %s  quorum-done %s of %s  stall %s us  safety %s\n' \
    "$(get "$L" '^  views entered' 3)" "$(get "$L" '^  broadcasts  view-change' 3)" \
    "$(get "$L" '^  broadcasts  view-change' 5)" "$(get "$L" '^  rounds quorum-done' 3)" \
    "$(get "$L" '^  rounds opened' 3)" "$(get "$L" '^  longest stall' 3)" \
    "$(get "$L" '^  safety violations' 3)"
  printf '        control during: missed %s  p99 %s us   outside: missed %s  p99 %s us\n' \
    "$(get "$L" '^  control during' 6)" "$(get "$L" '^  control during' 8)" \
    "$(get "$L" '^  control outside' 6)" "$(get "$L" '^  control outside' 8)"
}

want() { [[ $# -eq 0 ]] && return 0; for w in "${SEL[@]}"; do [[ "$w" == "$1" ]] && return 0; done; return 1; }
SEL=("$@")
sel() { [[ ${#SEL[@]} -eq 0 ]] || want "$1"; }

# --- 1. full model, no attack: nothing to recover from -----------------------
if sel noattack; then
  echo "noattack: full model, n=4, no fault. Expect no view change and every round committed by every node."
  if run noattack; then
    r=$(get "$L" '^  rounds started' 3); c=$(get "$L" '^  rounds committed' 3); v=$(get "$L" '^  views entered' 3)
    check noattack "no view change (views entered $v)" '[[ "$v" == 0 ]]'
    check noattack "all node-rounds committed ($c of $((r*4)))" 'all "$c" "$((r*4))" 4'
  fi
fi

# --- 2. crashed primary, f = 1 ----------------------------------------------
if sel crash1; then
  echo "crash1: n=4, the primary crashes. Expect a view change, no safety violation, a stall of about one view timeout (40 ms), and the crashed node catching up after the window."
  if run crash1 --attack=crash $WIN; then
    check crash1 "views entered > 0" 'ge "$(get "$L" "^  views entered" 3)" 1'
    check crash1 "no safety violation" '[[ "$(get "$L" "^  safety violations" 3)" == 0 ]]'
    check crash1 "longest stall below 200 ms" 'lt "$(get "$L" "^  longest stall" 3)" 200000'
    check crash1 "the crashed node caught up to a view" 'ge "$(get "$L" "^  caught up to a view" 6)" 1'
    summary "$L"
  fi
fi

# --- 3. two crashed validators, beyond f = 1 ---------------------------------
if sel crash2; then
  echo "crash2: n=4, two validators crash (more than f). Expect no progress during the window (2 correct nodes cannot form a quorum of 3), no safety violation, and progress again after it."
  if run crash2 --attack=crash --nByzantine=2 $WIN; then
    check crash2 "no safety violation" '[[ "$(get "$L" "^  safety violations" 3)" == 0 ]]'
    check crash2 "longest stall at least 1 s (the window is 1.5 s)" 'ge "$(get "$L" "^  longest stall" 3)" 1000000'
    check crash2 "rounds still complete overall (quorum-done > 0)" 'ge "$(get "$L" "^  rounds quorum-done" 3)" 1'
    summary "$L"
  fi
fi

# --- 4. two consecutive faulty primaries, n = 7, f = 2 -----------------------
if sel crash7; then
  echo "crash7: n=7, validators 0 and 1 crash, so the primaries of views 0 and 1 are both down. Expect two view changes in a row (the second after a doubled timeout) and no safety violation."
  if run crash7 --nValidators=7 --attack=crash --nByzantine=2 $WIN; then
    check crash7 "highest view at least 2" 'ge "$(grep -m1 "^  views entered" "$L" | sed "s/.*highest view \([0-9]*\).*/\1/")" 2'
    check crash7 "no safety violation" '[[ "$(get "$L" "^  safety violations" 3)" == 0 ]]'
    summary "$L"
  fi
fi

# --- 5. equivocating primary ------------------------------------------------
if sel equivocate; then
  echo "equivocate: n=4, the primary sends two digests. Expect no quorum on either, a view change, and no safety violation."
  if run equivocate --attack=equivocate $WIN; then
    check equivocate "equivocations > 0" 'ge "$(get "$L" "^  equivocations" 2)" 1'
    check equivocate "views entered > 0" 'ge "$(get "$L" "^  views entered" 3)" 1'
    check equivocate "no safety violation" '[[ "$(get "$L" "^  safety violations" 3)" == 0 ]]'
    summary "$L"
  fi
fi

# --- 6. one withholding backup (= f) ----------------------------------------
if sel withhold1; then
  echo "withhold1: n=4, one backup never sends COMMIT. With f = 1 that is tolerated: expect every round to complete and no view change."
  if run withhold1 --attack=withhold --byzSelect=last $WIN; then
    check withhold1 "no view change" '[[ "$(get "$L" "^  views entered" 3)" == 0 ]]'
    check withhold1 "every opened round quorum-done" 'all "$(get "$L" "^  rounds quorum-done" 3)" "$(get "$L" "^  rounds opened" 3)" 1'
    summary "$L"
  fi
fi

# --- 7. two withholding backups (> f) ---------------------------------------
if sel withhold2; then
  echo "withhold2: n=4, two backups withhold. No round can commit and the withholders do not ask for a view change, so expect a stall for the window and no safety violation."
  if run withhold2 --attack=withhold --nByzantine=2 --byzSelect=last $WIN; then
    check withhold2 "longest stall at least 1 s" 'ge "$(get "$L" "^  longest stall" 3)" 1000000'
    check withhold2 "no safety violation" '[[ "$(get "$L" "^  safety violations" 3)" == 0 ]]'
    summary "$L"
  fi
fi

# --- 8. flooding validator --------------------------------------------------
if sel flood; then
  echo "flood: n=4, one backup sends 8 copies of everything. Expect extra frames, every round still complete, and the control loop untouched under TAS."
  if run flood --attack=flood --byzSelect=last $WIN; then
    check flood "flood extra frames > 0" 'ge "$(get "$L" "^  flood extra frames" 4)" 1'
    check flood "every opened round quorum-done" 'all "$(get "$L" "^  rounds quorum-done" 3)" "$(get "$L" "^  rounds opened" 3)" 1'
    check flood "no control deadline missed during the attack" '[[ "$(get "$L" "^  control during" 6)" == 0 ]]'
    summary "$L"
  fi
fi

# --- 9. mismarking validator ------------------------------------------------
if sel mismark; then
  echo "mismark: n=16, 1024 B, one backup sends its consensus frames at the control codepoint. Expect mismarked frames; read the control p99 during against outside the window."
  if run mismark --nValidators=16 --consensusMsgSize=1024 --attack=mismark --byzSelect=last $WIN; then
    check mismark "mismarked frames > 0" 'ge "$(get "$L" "^  mismarked frames" 3)" 1'
    summary "$L"
  fi
fi

# --- 10. delaying validator -------------------------------------------------
if sel delay; then
  echo "delay: n=4, one backup adds 2 ms to every reaction. Tolerated (f = 1): expect every round complete; the commit latency is worth a look."
  if run delay --attack=delay --attackDelay=2ms --byzSelect=last $WIN; then
    check delay "every opened round quorum-done" 'all "$(get "$L" "^  rounds quorum-done" 3)" "$(get "$L" "^  rounds opened" 3)" 1'
    echo "        commit latency mean $(get "$L" '^  commit latency mean' 4) us, max $(get "$L" '^  commit latency max' 4) us"
  fi
fi

# --- 11. injector at the control codepoint ----------------------------------
if sel inject; then
  echo "inject: one compromised end station sends 4 x 1024 B every 200 us at the control codepoint. Expect injected frames to arrive; read the control loop during against outside."
  if run inject --attack=inject $WIN; then
    check inject "injected frames arrived > 0" 'ge "$(get "$L" "^  injected frames" 6)" 1'
    echo "        injected sent $(get "$L" '^  injected frames' 4), arrived $(get "$L" '^  injected frames' 6)"
    summary "$L"
  fi
fi

# --- 12. spurious view changes from a short timeout --------------------------
if sel shorttimeout; then
  echo "shorttimeout: n=4, no fault, view timeout 1 ms (below the 1.4 ms commit latency). Expect view changes without any attacker, and every round still committed."
  if run shorttimeout --viewTimeout=1ms; then
    r=$(get "$L" '^  rounds started' 3); c=$(get "$L" '^  rounds committed' 3)
    check shorttimeout "view changes happen (views entered > 0)" 'ge "$(get "$L" "^  views entered" 3)" 1'
    check shorttimeout "all node-rounds committed ($c of $((r*4)))" 'all "$c" "$((r*4))" 4'
    echo "        msgs/round $(get "$L" '^  msgs/round actual' 3) (24 without view changes)"
  fi
fi

# --- 13. bounded re-proposal window ------------------------------------------
# --reproposeWindow=N: at a view change, uncommitted rounds more than N ticks old
# are abandoned instead of re-proposed. Equivocation is the case where they were
# actually proposed (a crashed primary proposes nothing), so the oracle can tell
# an abandoned round from a committed one.
if sel window; then
  echo "window: n=4, the primary equivocates, --reproposeWindow=2. Expect the forked rounds older than 2 ticks to be abandoned at the view change, every other opened round quorum-done, and no safety violation."
  if run window --attack=equivocate --reproposeWindow=2 $WIN; then
    o=$(get "$L" '^  rounds opened' 3); q=$(get "$L" '^  rounds quorum-done' 3); a=$(get "$L" '^  rounds abandoned' 3)
    nr=$(grep -m1 '^  re-propose window' "$L" | sed 's/.*(\([0-9]*\) node-rounds.*/\1/')
    check window "rounds abandoned > 0 ($a)" 'ge "$a" 1'
    check window "node-rounds abandoned > 0 ($nr)" 'ge "$nr" 1'
    check window "opened = quorum-done + abandoned ($o = $q + $a, one round may be in flight)" 'all "$((q+a))" "$o" 1'
    check window "no safety violation" '[[ "$(get "$L" "^  safety violations" 3)" == 0 ]]'
    summary "$L"
  fi
fi

echo
echo "$PASS passed, $FAIL failed. Logs in $OUT/."
[[ $FAIL -eq 0 ]]
