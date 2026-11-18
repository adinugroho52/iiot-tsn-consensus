#!/usr/bin/env bash
# Checks that every experiment in tools/sweep.sh lists the expected number of cells.
# Run from the repository root: tests/check_sweep.sh
set -uo pipefail
ROOT=$(pwd); T=$(mktemp -d); cd "$T"; bad=0
declare -A EXPECT=([e1]=12 [e2]=20 [e3]=5 [e4]=5 [e5]=12 [e6]=9 [e7]=84 [e8]=81 [e9]=21 [e10]=24 [e11]=14 [e12]=180 [e13]=8 [figs]=4)
for e in "${!EXPECT[@]}"; do
  got=$("$ROOT/tools/sweep.sh" --list "$e" 2>/dev/null | grep -cE '^  (TODO|fig)')
  if [[ "$got" == "${EXPECT[$e]}" ]]; then printf "ok    %-5s %s cells\n" "$e" "$got"; else printf "FAIL  %-5s expected %s, got %s\n" "$e" "${EXPECT[$e]}" "$got"; bad=1; fi
done
exit $bad
