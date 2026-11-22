#!/usr/bin/env bash
# Checks that every experiment in tools/sweep.sh lists the expected number of cells.
# Run from the repository root: tests/check_sweep.sh
set -uo pipefail
ROOT=$(pwd); T=$(mktemp -d); cd "$T"; bad=0
declare -A EXPECT=([e1]=12 [e2]=30 [e2a]=20 [e2b]=5 [e2c]=5 [e3]=12 [e4]=93 [e4a]=9 [e4b]=84 [e5]=81 [e6]=21 [e7]=24 [e8]=14 [e9]=180 [e10]=8 [e11]=7 [e12]=6 [figs]=4 [figs_e11]=1)
for e in "${!EXPECT[@]}"; do
  got=$("$ROOT/tools/sweep.sh" --list "$e" 2>/dev/null | grep -cE '^  (TODO|fig)')
  if [[ "$got" == "${EXPECT[$e]}" ]]; then printf "ok    %-5s %s cells\n" "$e" "$got"; else printf "FAIL  %-5s expected %s, got %s\n" "$e" "${EXPECT[$e]}" "$got"; bad=1; fi
done
exit $bad
