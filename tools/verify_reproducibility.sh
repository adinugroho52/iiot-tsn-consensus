#!/usr/bin/env bash
#
# verify_reproducibility.sh -- rebuild the simulation stack from scratch, rerun
# every experiment of the paper, and check the results against the reference
# results in tools/reference/.
#
# What it does, in order:
#   1. checks that each experiment set below lists exactly the runs of the
#      reference (fails before anything is built if not);
#   2. clones ns-3 at a fixed tag and installs the DenKrysos TAS module in
#      contrib/tsn at a fixed commit (or from a clone you name);
#   3. copies this repository into the ns-3 tree, configures and builds;
#   4. runs the repository's own tests and the README smoke test;
#   5. runs all 691 runs of the paper (about 20 h serially), resumably;
#   6. compares every run with the reference: each summary value, and the
#      SHA-256 of every run log, per-frame CSV and capture file;
#   7. packs the results into WORK/repro-results.tar.gz (under 10 MB).
#
# The reference was produced with the defaults below: ns-3.49, TAS module commit
# 3d00954. The model is deterministic, so a matching build reproduces it exactly.
# The archive holds every summary.csv, every run log, the packet captures, a
# checksum of every per-frame CSV (the CSVs themselves, about 1.2 GB, stay in
# WORK/results) and a record of the environment, for sharing a run.
#
# Usage:
#   tools/verify_reproducibility.sh [options]
#
#   --repo DIR        this repository (default: the directory above this script)
#   --work DIR        where everything is built and run (default ./repro-work,
#                     or beside the repository if that would put it inside it)
#   --ns3-tag TAG     ns-3 release tag (default ns-3.49)
#   --tas-commit SHA  TAS module commit to check out (default 3d00954, the
#                     commit the reference was produced with)
#   --tas-src DIR     use an existing TAS clone instead of cloning one
#   --profile P       ns-3 build profile (default: ns-3's own default)
#   --quick           run only e1, e6, e9 and the figure captures (~40 min)
#   --check-only      skip steps 2-5: check and pack what is already in --work
#
# Rerunning the script resumes: finished experiment sets are skipped and an
# interrupted one continues from its last completed run.
#
# Exit status: 0 if every set completed and matches the reference, 1 if a run
# failed, is missing or differs, 2 on a setup error.

set -uo pipefail

# --- defaults ------------------------------------------------------------------
NS3_URL="https://gitlab.com/nsnam/ns-3-dev.git"
NS3_TAG="ns-3.49"
TAS_URL="https://github.com/DenKrysos/Time-Aware-Shaper-TAS-in-ns-3.git"
TAS_SRC=""
TAS_COMMIT="3d0095446779809896024821451442ed6f01f2be"   # reference build
TAS_COMMIT_SET=0
PROFILE=""
WORK=""
REPO=""
QUICK=0
CHECK_ONLY=0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$here/../scratch/iiot-consensus-tsn.cc" ]] && REPO="$(cd "$here/.." && pwd)"

die()  { echo "error: $*" >&2; exit 2; }
step() { printf '\n=== %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)         REPO="$2"; shift 2 ;;
    --work)         WORK="$2"; shift 2 ;;
    --ns3-tag)      NS3_TAG="$2"; shift 2 ;;
    --tas-src)      TAS_SRC="$2"; shift 2 ;;
    --tas-commit)   TAS_COMMIT="$2"; TAS_COMMIT_SET=1; shift 2 ;;
    --profile)      PROFILE="$2"; shift 2 ;;
    --quick)        QUICK=1; shift ;;
    --check-only)   CHECK_ONLY=1; shift ;;
    -h|--help)      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

[[ -n "$REPO" && -f "$REPO/scratch/iiot-consensus-tsn.cc" ]] || die "--repo must point at the iiot-tsn-consensus repository"
[[ -n "$TAS_SRC" && $TAS_COMMIT_SET -eq 1 ]] && die "give --tas-src or --tas-commit, not both"
REPO="$(cd "$REPO" && pwd -P)"
# The work folder must not sit inside the repository: the ns-3 tree is built
# there, and copying the repository into it would copy a folder into itself.
# The default moves beside the repository when the current folder is inside it.
inside_repo() { case "$1/" in "$REPO"/*) return 0 ;; esac; return 1; }
if [[ -z "$WORK" ]]; then
  WORK="$(pwd -P)/repro-work"
  inside_repo "$WORK" && WORK="$(dirname "$REPO")/repro-work"
fi
mkdir -p "$WORK" || die "cannot create $WORK"
WORK="$(cd "$WORK" && pwd -P)"
if inside_repo "$WORK"; then
  rmdir "$WORK" 2>/dev/null
  die "--work $WORK is inside the repository; choose a folder outside $REPO"
fi
REF="$REPO/tools/reference"
[[ -d "$REF" ]] || die "no reference results in $REF"
echo "repository  $REPO"
echo "work folder $WORK"
NS3_DIR="$WORK/ns-3"
RES="$WORK/results"
mkdir -p "$RES"

# --- experiment sets -------------------------------------------------------------
# name | environment (;-separated) | tools/sweep.sh arguments
# Each set writes one results folder; tools/reference/<name> holds its reference.
SETS=(
  "e1||e1"
  "e2e3e4||e2 e3 e4"
  "e5||e5"
  "e5_c60||--extra --consFrac=0.60 e5"
  "e5_1G||--link 1Gbps e5"
  "e5_1G_c60||--link 1Gbps --extra --ctrlBurst=100 e5"
  "e6||e6"
  "e6_100M|E6_BURSTS=1 10 20 25 26 27 30|--link 100Mbps e6"
  "e6_150deadline|E6_BURSTS=1 100 190 194 195 200|--extra --ctrlDeadline=150us e6"
  "e7||e7"
  "e7_100M|E7_BURSTS=1 5 10 15 20 26|--link 100Mbps e7"
  "e8||e8"
  "e8_100M|E8_BURSTS=1 10 20|--link 100Mbps --extra --consFrac=0.60 e8"
  "e9||e9"
  "e10||e10"
  "e11||e11"
  "e11_100M|E11_VALIDATORS=10;E11_SWITCHES=8;E11_SLICES=1 2 3 4 5 6 7|--link 100Mbps --extra --consFrac=0.60 e11"
  "e12||e12"
  "e13||e13"
  "e14||e14"
  "figs||figs"
  "figs_c005_8sw||--ctrl-frac 0.005 --extra --nSwitches=8 figs"
  "figs_e14||figs_e14"
)
if [[ $QUICK -eq 1 ]]; then
  q=(); for s in "${SETS[@]}"; do case "${s%%|*}" in e1|e6|e9|figs|figs_c005_8sw|figs_e14) q+=("$s");; esac; done; SETS=("${q[@]}")
fi

# ref_cells NAME : the run names of a set in the reference, sorted, one per line
ref_cells() {
  if [[ -s "$REF/$1/summary.csv" ]] && [[ "$(wc -l < "$REF/$1/summary.csv")" -gt 1 ]]; then
    tail -n +2 "$REF/$1/summary.csv" | cut -d, -f1 | LC_ALL=C sort
  else
    sed -n 's|^[0-9a-f]*  log/\(.*\)\.log$|\1|p' "$REF/$1/sha256.txt" | LC_ALL=C sort
  fi
}

# run_sweep DIR SET-ENV ARGS... : run tools/sweep.sh from DIR with the set's environment
run_sweep() {
  local dir="$1" envs="$2"; shift 2
  local -a e=()
  if [[ -n "$envs" ]]; then IFS=';' read -r -a e <<< "$envs"; fi
  ( cd "$dir" && env "${e[@]}" tools/sweep.sh "$@" )
}

# --- 1. check the experiment sets against the reference ----------------------------
step "1. checking experiment sets against the reference"
LIST_DIR="$WORK/listcheck"; rm -rf "$LIST_DIR"; mkdir -p "$LIST_DIR/tools"
cp "$REPO/tools/sweep.sh" "$LIST_DIR/tools/" || die "cannot read $REPO/tools/sweep.sh"
bad=0
for s in "${SETS[@]}"; do
  IFS='|' read -r name envs args <<< "$s"
  [[ -f "$REF/$name/sha256.txt" ]] || { echo "MISSING  $name: no reference"; bad=1; continue; }
  rm -rf "$LIST_DIR/results"
  # shellcheck disable=SC2086
  run_sweep "$LIST_DIR" "$envs" --list $args 2>/dev/null | awk '$1=="TODO"||$1=="fig"{print $2}' | LC_ALL=C sort > "$LIST_DIR/cells.txt"
  ref_cells "$name" > "$LIST_DIR/ref.txt"
  if cmp -s "$LIST_DIR/cells.txt" "$LIST_DIR/ref.txt"; then
    printf 'ok       %-15s %4d runs\n' "$name" "$(wc -l < "$LIST_DIR/ref.txt")"
  else
    printf 'MISMATCH %-15s %d runs, reference %d\n' "$name" "$(wc -l < "$LIST_DIR/cells.txt")" "$(wc -l < "$LIST_DIR/ref.txt")"
    bad=1
  fi
done
rm -rf "$LIST_DIR"
[[ $bad -eq 0 ]] || die "the experiment sets do not list the reference runs; nothing was built"

if [[ $CHECK_ONLY -eq 0 ]]; then
  # --- 2. ns-3 and the TAS module ---------------------------------------------------
  step "2. ns-3 $NS3_TAG and the TAS module"
  for t in git cmake g++ python3 make; do command -v "$t" >/dev/null || die "$t is not installed"; done
  if [[ ! -d "$NS3_DIR/.git" ]]; then
    git ls-remote --exit-code --tags "$NS3_URL" "refs/tags/$NS3_TAG" >/dev/null || die "no tag $NS3_TAG in $NS3_URL"
    git clone --quiet --depth 1 --branch "$NS3_TAG" "$NS3_URL" "$NS3_DIR" || die "cloning ns-3 failed"
  else
    echo "ns-3 already cloned in $NS3_DIR"
  fi

  if [[ ! -d "$NS3_DIR/contrib/tsn" ]]; then
    if [[ -n "$TAS_SRC" ]]; then
      [[ -d "$TAS_SRC" ]] || die "--tas-src $TAS_SRC does not exist"
      tas_tree="$(cd "$TAS_SRC" && pwd)"
    else
      tas_tree="$WORK/tas-clone"
      [[ -d "$tas_tree/.git" ]] || git clone --quiet "$TAS_URL" "$tas_tree" || die "cloning the TAS module failed"
      git -C "$tas_tree" checkout --quiet "$TAS_COMMIT" || die "no commit $TAS_COMMIT in the TAS repository"
    fi
    # The module is the directory whose model/ defines TasQueueDisc: either the
    # repository root or one folder inside it.
    hit="$(grep -rl --include='*.h' 'class TasQueueDisc' "$tas_tree" 2>/dev/null | grep -v '/build/' | head -1)"
    [[ -n "$hit" ]] || die "no TasQueueDisc header found in $tas_tree"
    module_dir="$(dirname "$(dirname "$hit")")"
    [[ -f "$module_dir/CMakeLists.txt" ]] || die "$module_dir has no CMakeLists.txt; install the module by hand in contrib/tsn"
    mkdir -p "$NS3_DIR/contrib"
    cp -r "$module_dir" "$NS3_DIR/contrib/tsn"
    rm -rf "$NS3_DIR/contrib/tsn/.git"
    {
      echo "source $tas_tree"
      echo "module_dir $module_dir"
      if git -C "$tas_tree" rev-parse HEAD >/dev/null 2>&1; then
        echo "commit $(git -C "$tas_tree" rev-parse HEAD)"
        echo "commit_date $(git -C "$tas_tree" log -1 --format=%cI)"
        echo "dirty $(git -C "$tas_tree" status --porcelain | wc -l) changed files"
      else
        echo "commit unknown (not a git clone)"
      fi
    } > "$WORK/tas.txt"
  fi
  cat "$WORK/tas.txt"

  # --- 3. install, configure, build ------------------------------------------------
  step "3. install and build"
  # Copy files only, never folders: the repository's tools/ and tests/ hold no
  # subfolders, and anything else found there (a work folder, results) stays out.
  # ns-3 has no tools/ or tests/ of its own, so they are rebuilt from scratch;
  # this also clears anything a failed earlier copy left there.
  rm -rf "$NS3_DIR/tools" "$NS3_DIR/tests"
  for d in scratch tools tests; do
    mkdir -p "$NS3_DIR/$d"
    for f in "$REPO/$d"/*; do
      [[ -f "$f" ]] || continue
      cp "$f" "$NS3_DIR/$d/" || die "copying $f into $NS3_DIR/$d failed"
    done
  done
  [[ -x "$NS3_DIR/tools/sweep.sh" ]] || die "tools/sweep.sh did not reach $NS3_DIR"
  cfg=(configure --disable-werror)
  [[ -n "$PROFILE" ]] && cfg+=(--build-profile="$PROFILE")
  ( cd "$NS3_DIR" && ./ns3 "${cfg[@]}" > "$WORK/configure.log" 2>&1 ) || die "configure failed, see $WORK/configure.log"
  ( cd "$NS3_DIR" && ./ns3 build iiot-consensus-tsn > "$WORK/build.log" 2>&1 ) || die "build failed, see $WORK/build.log"
  echo "built (logs: configure.log, build.log)"

  # --- environment record ------------------------------------------------------------
  {
    echo "date        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host        $(uname -srm)"
    [[ -r /etc/os-release ]] && echo "os          $(. /etc/os-release; echo "$PRETTY_NAME")"
    echo "cpu         $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //')"
    echo "compiler    $(g++ --version | head -1)"
    echo "cmake       $(cmake --version | head -1)"
    echo "python      $(python3 --version 2>&1)"
    echo "ns-3        $NS3_TAG $(git -C "$NS3_DIR" rev-parse HEAD 2>/dev/null || echo 'commit unknown')"
    echo "profile     ${PROFILE:-ns-3 default}"
    echo "repository  $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo 'not a git checkout') $( [[ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]] && echo '(uncommitted changes)')"
  } > "$WORK/environment.txt"

  # --- 4. tests and smoke test -------------------------------------------------------
  step "4. repository tests and smoke test"
  ( cd "$REPO" && tests/schedule_test.sh > "$WORK/schedule_test.log" 2>&1 ) && echo "ok    tests/schedule_test.sh" || die "tests/schedule_test.sh failed, see $WORK/schedule_test.log"
  ( cd "$REPO" && tests/check_sweep.sh   > "$WORK/check_sweep.log" 2>&1 )   && echo "ok    tests/check_sweep.sh"   || die "tests/check_sweep.sh failed, see $WORK/check_sweep.log"
  ( cd "$NS3_DIR" && ./ns3 run "iiot-consensus-tsn --stopAt=0.7s --run=1" > "$WORK/smoke.log" 2>&1 ) || die "smoke run failed, see $WORK/smoke.log"
  smoke_ok=1
  for k in min mean p99 max; do
    v="$(awk -v k="$k" '/=== control loop/{f=1} f && $1==k {print $2; exit}' "$WORK/smoke.log")"
    [[ "$v" == "4.26" ]] || smoke_ok=0
    printf '      control %-4s %s us\n' "$k" "${v:-?}"
  done
  missed="$(awk '/=== control loop/{f=1} f && $1=="missed" {print $2; exit}' "$WORK/smoke.log")"
  [[ "$missed" == "0" ]] || smoke_ok=0
  [[ $smoke_ok -eq 1 ]] || die "smoke test differs from the README (expected 4.26 us, 0 missed); see $WORK/smoke.log"
  echo "ok    smoke test: 4.26 us, 0 missed"

  # --- 5. experiments -------------------------------------------------------------------
  step "5. experiments (resumable; serial)"
  for s in "${SETS[@]}"; do
    IFS='|' read -r name envs args <<< "$s"
    out="$RES/$name"
    if [[ -f "$out/.complete" ]]; then echo "done  $name"; continue; fi
    mkdir -p "$out"; rm -f "$out/failed.txt"
    rm -rf "$NS3_DIR/results"; ln -s "$out" "$NS3_DIR/results"     # sweep.sh writes to ./results
    echo "run   $name  (sweep.sh $args)"
    # shellcheck disable=SC2086
    run_sweep "$NS3_DIR" "$envs" $args > "$out/sweep.log" 2>&1
    if [[ -s "$out/failed.txt" ]]; then
      echo "FAIL  $name: $(wc -l < "$out/failed.txt") runs failed, see $out/failed.txt (rerun the script to retry)"
    else
      touch "$out/.complete"
    fi
  done
  rm -f "$NS3_DIR/results"
fi

# --- 6. compare with the reference --------------------------------------------------------
step "6. comparing with the reference"
names=(); for s in "${SETS[@]}"; do names+=("${s%%|*}"); done
python3 -I "$REPO/tools/compare_reference.py" check "$RES" "$REF" "${names[@]}" | tee "$WORK/comparison.txt"
status=${PIPESTATUS[0]}

# --- 7. pack ---------------------------------------------------------------------------------
step "7. packing the results"
PACK="$WORK/pack/repro-results"
rm -rf "$WORK/pack"; mkdir -p "$PACK"
for f in environment.txt tas.txt smoke.log schedule_test.log check_sweep.log configure.log comparison.txt; do
  [[ -f "$WORK/$f" ]] && cp "$WORK/$f" "$PACK/"
done
[[ -f "$WORK/build.log" ]] && tail -n 200 "$WORK/build.log" > "$PACK/build-tail.log"
{
  printf '%-15s %-10s %7s %5s %6s %6s\n' set state runs logs failed pcaps
  for s in "${SETS[@]}"; do
    IFS='|' read -r name envs args <<< "$s"
    src="$RES/$name"; dst="$PACK/$name"
    runs="$(ref_cells "$name" | wc -l)"
    if [[ ! -d "$src" ]]; then printf '%-15s %-10s\n' "$name" "not run"; continue; fi
    mkdir -p "$dst"
    for f in summary.csv failed.txt sweep.log; do [[ -f "$src/$f" ]] && cp -L "$src/$f" "$dst/"; done
    [[ -d "$src/log"  ]] && cp -rL "$src/log"  "$dst/"
    [[ -d "$src/pcap" ]] && cp -rL "$src/pcap" "$dst/"
    if [[ -d "$src/csv" ]]; then
      ( cd "$src/csv" && find -L . -type f -name '*.csv' | LC_ALL=C sort | sed 's|^\./||' | xargs -r sha256sum ) > "$dst/csv-sha256.txt"
    fi
    if [[ "$name" == figs* ]]; then done_n="$(find -L "$src/log" -name '*.log' 2>/dev/null | wc -l)"
    elif [[ -f "$src/summary.csv" ]]; then done_n="$(( $(wc -l < "$src/summary.csv") - 1 ))"
    else done_n=0; fi
    nlog="$(find -L "$src/log" -name '*.log' 2>/dev/null | wc -l)"
    nfail=0; [[ -f "$src/failed.txt" ]] && nfail="$(wc -l < "$src/failed.txt")"
    npcap="$(find -L "$src/pcap" -type f 2>/dev/null | wc -l)"
    state=complete; [[ -f "$src/.complete" && "$done_n" == "$runs" ]] || state=incomplete
    printf '%-15s %-10s %7s %5s %6s %6s\n' "$name" "$state" "$done_n/$runs" "$nlog" "$nfail" "$npcap"
  done
} | tee "$PACK/STATUS.txt"
grep -q -E 'incomplete|not run' "$PACK/STATUS.txt" && status=1
( cd "$WORK/pack" && tar -czf "$WORK/repro-results.tar.gz" repro-results ) || die "packing failed"
rm -rf "$WORK/pack"
echo
echo "archive: $WORK/repro-results.tar.gz ($(du -h "$WORK/repro-results.tar.gz" | cut -f1))"
echo "the per-frame CSVs stay in $RES; the archive holds their checksums"
[[ -f "$WORK/environment.txt" ]] && { echo; cat "$WORK/environment.txt"; }
echo
if [[ $status -eq 0 ]]; then echo "result: every set matches the reference"; else echo "result: see the comparison and status above"; fi
exit $status
