#!/usr/bin/env bash
#
# verify_paper2.sh -- rebuild the simulation stack from scratch, rerun every
# fault experiment of the second paper ("Recovery bursts decide"), and check the
# results against tools/reference/paper2/.
#
# Separate from tools/verify_reproducibility.sh (the first paper); the two can
# share a --work folder's ns-3 build but keep their results apart.
#
# What it does, in order:
#   1. static checks, before anything is built: the registered predictions
#      tools/validation/v1_cells.csv still have the hash they were registered
#      with, and tools/fault_sweep.sh lists exactly the reference cells of the
#      chosen sets;
#   2. clones ns-3 at a fixed tag and installs the DenKrysos TAS module in
#      contrib/tsn at a fixed commit (or from a clone you name);
#   3. copies this repository into the ns-3 tree, configures and builds;
#   4. runs the scenario checks: tools/adversary_check.sh (30 PBFT checks) and
#      tools/protocol_check.sh (17 HotStuff checks);
#   5. runs the sweep, tools/fault_sweep.sh, over the chosen sets (211 cells for
#      the full paper, about 3 h on one core; -j N runs N cells at a time);
#   6. assembles every table and figure with tools/assemble_results.py;
#   7. compares with the reference (tools/compare_paper2.py): control isolation
#      and safety in every cell, each cell's outcome and recovery-rule
#      prediction, every value of every cell, and every table of the paper;
#   8. packs the results into WORK/paper2-repro-results.tar.gz (a few MB).
#
# The reference was produced with the defaults below: ns-3.49, TAS module commit
# 3d00954. The model is deterministic, so a matching build reproduces it
# exactly.
#
# Usage:
#   tools/verify_paper2.sh [options]
#
#   --repo DIR        this repository (default: the directory above this script)
#   --work DIR        where everything is built and run (default ./paper2-work,
#                     or beside the repository if that would put it inside it)
#   --ns3-tag TAG     ns-3 release tag (default ns-3.49)
#   --tas-commit SHA  TAS module commit to check out (default 3d00954)
#   --tas-src DIR     use an existing TAS clone instead of cloning one
#   --profile P       ns-3 build profile (default: ns-3's own default)
#   -j N              cells run in parallel by the sweep (default 1)
#   --sets "S ..."    run only these sets (default: f1 f2 f3 f4 f5 p1 p2 v1);
#                     a partial run checks cells only, not the tables
#   --quick           the same as --sets "f1 p1 v1": 70 cells, about 1 h serially
#   --skip-checks     skip step 4 (the scenario checks, about 15 min)
#   --check-only      skip steps 2-5: assemble, compare and pack what is
#                     already in --work
#   --python PATH     the Python interpreter for every Python step, e.g. a
#                     virtual environment's bin/python3 (default: python3 on
#                     the PATH); no need to activate the environment
#   --figures         require matplotlib and stop at step 1 without it. By
#                     default the figures are optional: without matplotlib the
#                     tables are still built and checked, the figures are not
#                     drawn. They are not needed to verify the results, since
#                     the comparison covers every number they are drawn from.
#                     To draw them: pip install -r tools/requirements-paper2.txt
#
# Rerunning the script resumes: the build is reused and finished cells are
# skipped (fault_sweep.sh marks each with log/<cell>.done).
#
# Exit status: 0 if every cell ran and everything matches the reference, 1 if a
# check failed or a cell is missing or differs, 2 on a setup error.

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
JOBS=1
ALL_SETS="f1 f2 f3 f4 f5 p1 p2 v1"
SETS_ARG="$ALL_SETS"
SKIP_CHECKS=0
CHECK_ONLY=0
PY=python3
FIGURES=0
# The registered predictions of v1 (after the Raft drop)
V1_SHA256="97c20de3318c24b366a84a430cf6649438f19532e8ebb5996bfc93bc351f0da4"
ADV_EXPECT=30
PROTO_EXPECT=17

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
    -j)             JOBS="$2"; shift 2 ;;
    --sets)         SETS_ARG="$2"; shift 2 ;;
    --quick)        SETS_ARG="f1 p1 v1"; shift ;;
    --skip-checks)  SKIP_CHECKS=1; shift ;;
    --check-only)   CHECK_ONLY=1; shift ;;
    --python)       PY="$2"; shift 2 ;;
    --figures)      FIGURES=1; shift ;;
    -h|--help)      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

[[ -n "$REPO" && -f "$REPO/scratch/iiot-consensus-tsn.cc" ]] || die "--repo must point at the iiot-tsn-consensus repository"
[[ -n "$TAS_SRC" && $TAS_COMMIT_SET -eq 1 ]] && die "give --tas-src or --tas-commit, not both"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "-j needs a positive number"
read -r -a SETS <<< "$SETS_ARG"
[[ ${#SETS[@]} -gt 0 ]] || die "--sets is empty"
for s in "${SETS[@]}"; do
  case " $ALL_SETS " in *" $s "*) ;; *) die "unknown set $s (sets are $ALL_SETS)" ;; esac
done
FULL=1
for s in $ALL_SETS; do case " ${SETS[*]} " in *" $s "*) ;; *) FULL=0 ;; esac; done

REPO="$(cd "$REPO" && pwd -P)"
# The work folder must not sit inside the repository: the ns-3 tree is built
# there, and copying the repository into it would copy a folder into itself.
inside_repo() { case "$1/" in "$REPO"/*) return 0 ;; esac; return 1; }
if [[ -z "$WORK" ]]; then
  WORK="$(pwd -P)/paper2-work"
  inside_repo "$WORK" && WORK="$(dirname "$REPO")/paper2-work"
fi
mkdir -p "$WORK" || die "cannot create $WORK"
WORK="$(cd "$WORK" && pwd -P)"
if inside_repo "$WORK"; then
  rmdir "$WORK" 2>/dev/null
  die "--work $WORK is inside the repository; choose a folder outside $REPO"
fi
REF="$REPO/tools/reference/paper2"
[[ -s "$REF/all_cells.csv" ]] || die "no reference results in $REF"
NS3_DIR="$WORK/ns-3"
RES="$WORK/results_fault"       # the sweep's output (OUT)
PAPER="$WORK/results_paper"     # assembled tables and figures
echo "repository  $REPO"
echo "work folder $WORK"
echo "sets        ${SETS[*]}$( [[ $FULL -eq 1 ]] && echo ' (the full paper)' || echo ' (partial: cells only, no tables)')"

# ref_cells : the reference cells of the chosen sets, sorted, one per line
ref_cells() {
  "$PY" -I - "$REF/all_cells.csv" "${SETS[@]}" <<'EOF'
import csv, sys
sets = set(sys.argv[2:])
with open(sys.argv[1], newline="") as f:
    cells = sorted(r["cell"] for r in csv.DictReader(f) if r["set"] in sets)
print("\n".join(cells))
EOF
}

# --- 1. static checks ------------------------------------------------------------
step "1. static checks"
PY_PATH="$(command -v "$PY")" || die "no Python interpreter $PY (see --python)"
# The sweep and the checks call python3 by name: put this interpreter's folder
# first, so a virtual environment given with --python is used throughout.
PATH="$(dirname "$PY_PATH"):$PATH"; export PATH
MPL="$("$PY" -I -c 'import matplotlib; print(matplotlib.__version__)' 2>/dev/null)"
if [[ -n "$MPL" ]]; then
  echo "ok       $PY_PATH ($("$PY" --version 2>&1)), matplotlib $MPL: figures will be drawn"
elif [[ $FIGURES -eq 1 ]]; then
  die "--figures: matplotlib is not available to $PY_PATH (pip install -r tools/requirements-paper2.txt, or --python <venv>/bin/python3)"
else
  echo "note     $PY_PATH has no matplotlib: the tables are built and checked, the figures are not drawn (optional; --figures requires them)"
fi
# Which interpreter assembled the results: written on every run, --check-only
# included, since that is the step that draws the figures.
{
  echo "python      $PY_PATH ($("$PY" --version 2>&1))"
  echo "matplotlib  ${MPL:-not installed (figures not drawn)}"
} > "$WORK/python.txt"
v1="$REPO/tools/validation/v1_cells.csv"
[[ -f "$v1" ]] || die "no registered predictions at $v1"
got="$(sha256sum "$v1" | cut -d' ' -f1)"
[[ "$got" == "$V1_SHA256" ]] || die "tools/validation/v1_cells.csv has changed since registration (SHA-256 $got, registered $V1_SHA256)"
echo "ok       registered predictions unchanged (v1_cells.csv, SHA-256 ${V1_SHA256:0:12}...)"

# The sweep's dry run prints one command per cell; each names its cell in the
# --adversaryCsv path. Run it from a scratch copy of tools/ so nothing is written
# into the repository.
LIST_DIR="$WORK/listcheck"; rm -rf "$LIST_DIR"; mkdir -p "$LIST_DIR/tools/validation"
cp "$REPO/tools/fault_sweep.sh" "$LIST_DIR/tools/" || die "cannot read $REPO/tools/fault_sweep.sh"
cp "$v1" "$LIST_DIR/tools/validation/"
( cd "$LIST_DIR" && OUT="$LIST_DIR/out" tools/fault_sweep.sh --dry-run "${SETS[@]}" 2>/dev/null ) \
  | grep -o 'adversaryCsv=[^ "]*' | sed 's|.*/csv/||; s|-rounds\.csv$||' | LC_ALL=C sort > "$LIST_DIR/cells.txt"
ref_cells | LC_ALL=C sort > "$LIST_DIR/ref.txt"
n_ref="$(wc -l < "$LIST_DIR/ref.txt")"
if cmp -s "$LIST_DIR/cells.txt" "$LIST_DIR/ref.txt"; then
  echo "ok       fault_sweep.sh lists the $n_ref reference cells of these sets"
else
  echo "MISMATCH fault_sweep.sh lists $(wc -l < "$LIST_DIR/cells.txt") cells, the reference has $n_ref:"
  diff "$LIST_DIR/ref.txt" "$LIST_DIR/cells.txt" | sed -n 's/^</  only in reference:/p; s/^>/  only in sweep:    /p' | head -10
  rm -rf "$LIST_DIR"
  die "the sweep does not list the reference cells; nothing was built"
fi
rm -rf "$LIST_DIR"

status=0
if [[ $CHECK_ONLY -eq 0 ]]; then
  # --- 2. ns-3 and the TAS module ---------------------------------------------------
  step "2. ns-3 $NS3_TAG and the TAS module"
  for t in git cmake g++ make; do command -v "$t" >/dev/null || die "$t is not installed"; done
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
    # The module is the directory whose model/ defines TasQueueDisc.
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
  [[ -f "$WORK/tas.txt" ]] && cat "$WORK/tas.txt"

  # --- 3. install, configure, build ------------------------------------------------
  step "3. install and build"
  # Copy files only, plus tools/validation/ (the registered predictions v1 and
  # v1s read); anything else found in the repository (a work folder, results,
  # the reference) stays out.
  rm -rf "$NS3_DIR/tools" "$NS3_DIR/tests"
  for d in scratch tools tests tools/validation; do
    mkdir -p "$NS3_DIR/$d"
    for f in "$REPO/$d"/*; do
      [[ -f "$f" ]] || continue
      cp "$f" "$NS3_DIR/$d/" || die "copying $f into $NS3_DIR/$d failed"
    done
  done
  [[ -x "$NS3_DIR/tools/fault_sweep.sh" ]] || die "tools/fault_sweep.sh did not reach $NS3_DIR"
  [[ -f "$NS3_DIR/tools/validation/v1_cells.csv" ]] || die "tools/validation/v1_cells.csv did not reach $NS3_DIR"
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
    echo "ns-3        $NS3_TAG $(git -C "$NS3_DIR" rev-parse HEAD 2>/dev/null || echo 'commit unknown')"
    echo "profile     ${PROFILE:-ns-3 default}"
    echo "repository  $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo 'not a git checkout') $( [[ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]] && echo '(uncommitted changes)')"
    echo "sets        ${SETS[*]}"
    echo "jobs        $JOBS"
  } > "$WORK/environment.txt"

  # --- 4. scenario checks --------------------------------------------------------------
  step "4. scenario checks"
  if [[ $SKIP_CHECKS -eq 1 ]]; then
    echo "skipped (--skip-checks)"
  else
    # check NAME SCRIPT EXPECTED : run a check script from the ns-3 root
    check() {
      local name="$1" script="$2" want="$3" line pass fail
      ( cd "$NS3_DIR" && OUT="$WORK/$name" "tools/$script" > "$WORK/$name.log" 2>&1 )
      line="$(grep -E '^[0-9]+ passed, [0-9]+ failed' "$WORK/$name.log" | tail -1)"
      pass="$(echo "$line" | awk '{print $1}')"; fail="$(echo "$line" | awk '{print $3}')"
      if [[ "$pass" == "$want" && "$fail" == "0" ]]; then
        printf 'ok       %-20s %s/%s passed\n' "$script" "$pass" "$want"
      else
        printf 'FAIL     %-20s %s passed, %s failed (expected %s/%s); see %s\n' \
          "$script" "${pass:-?}" "${fail:-?}" "$want" "$want" "$WORK/$name.log"
        status=1
      fi
    }
    check adversary_check adversary_check.sh "$ADV_EXPECT"
    check protocol_check  protocol_check.sh  "$PROTO_EXPECT"
  fi

  # --- 5. the sweep -----------------------------------------------------------------------
  step "5. sweep: ${SETS[*]} (-j $JOBS; resumable)"
  mkdir -p "$RES"
  ( cd "$NS3_DIR" && OUT="$RES" tools/fault_sweep.sh -j "$JOBS" "${SETS[@]}" ) 2>&1 | tee -a "$RES/sweep.log" \
    | grep -E '^(==|FAIL)' || true
  echo "sweep log: $RES/sweep.log"
fi

# --- completeness ---------------------------------------------------------------------
step "checking that every cell ran"
[[ -s "$RES/summary.csv" ]] || die "no sweep results in $RES (run without --check-only first)"
missing=()
while read -r c; do
  [[ -f "$RES/log/$c.done" ]] && grep -q "^$c," "$RES/summary.csv" || missing+=("$c")
done < <(ref_cells)
dups="$(tail -n +2 "$RES/summary.csv" | cut -d, -f1 | LC_ALL=C sort | uniq -d | head -5 | tr '\n' ' ')"
if [[ ${#missing[@]} -eq 0 ]]; then
  echo "ok       all $(ref_cells | wc -l) cells finished"
else
  echo "MISSING  ${#missing[@]} cells did not finish, e.g. ${missing[*]:0:5} (rerun the script to retry them)"
  status=1
fi
if [[ -n "$dups" ]]; then
  echo "WARN     summary.csv has repeated rows for: $dups(a cell was run twice; delete the extra rows)"
  status=1
fi

# --- 6. assemble ----------------------------------------------------------------------------
step "6. assembling tables and figures"
rm -rf "$PAPER"
"$PY" -I "$REPO/tools/assemble_results.py" "$RES/summary.csv" --csvdir "$RES/csv" \
  --registered "$REPO/tools/validation/v1_cells.csv" --out "$PAPER" > "$WORK/assemble.log" 2>&1 \
  || die "assemble_results.py failed, see $WORK/assemble.log"
echo "ok       $PAPER ($(ls "$PAPER"/table_*.csv 2>/dev/null | wc -l) tables, $(ls "$PAPER"/fig_*.pdf 2>/dev/null | wc -l) figures)"

# --- 7. compare -------------------------------------------------------------------------------
step "7. comparing with the reference"
cmp_args=(check "$PAPER" "$REF" --csvdir "$RES/csv")
[[ $FULL -eq 1 ]] || cmp_args+=(--sets "${SETS[@]}")
"$PY" -I "$REPO/tools/compare_paper2.py" "${cmp_args[@]}" | tee "$WORK/comparison.txt"
[[ ${PIPESTATUS[0]} -eq 0 ]] || status=1

# --- 8. pack ----------------------------------------------------------------------------------
step "8. packing the results"
PACK="$WORK/pack/paper2-repro-results"
rm -rf "$WORK/pack"; mkdir -p "$PACK"
for f in environment.txt python.txt tas.txt configure.log adversary_check.log protocol_check.log assemble.log comparison.txt; do
  [[ -f "$WORK/$f" ]] && cp "$WORK/$f" "$PACK/"
done
[[ -f "$WORK/build.log" ]] && tail -n 200 "$WORK/build.log" > "$PACK/build-tail.log"
cp "$RES/summary.csv" "$PACK/"
[[ -f "$RES/sweep.log" ]] && cp "$RES/sweep.log" "$PACK/"
[[ -d "$RES/log" ]] && { mkdir -p "$PACK/log"; cp "$RES"/log/*.log "$PACK/log/" 2>/dev/null; }
mkdir -p "$PACK/results_paper"
cp "$PAPER"/*.csv "$PAPER"/*.tex "$PAPER"/README.txt "$PACK/results_paper/" 2>/dev/null
cp "$PAPER"/fig_*.pdf "$PACK/results_paper/" 2>/dev/null
[[ -d "$RES/csv" ]] && ( cd "$RES/csv" && find . -type f -name '*.csv' | LC_ALL=C sort | sed 's|^\./||' | xargs -r sha256sum ) > "$PACK/csv-sha256.txt"
( cd "$WORK/pack" && tar -czf "$WORK/paper2-repro-results.tar.gz" paper2-repro-results ) || die "packing failed"
rm -rf "$WORK/pack"
echo "archive: $WORK/paper2-repro-results.tar.gz ($(du -h "$WORK/paper2-repro-results.tar.gz" | cut -f1))"
echo "the per-round CSVs stay in $RES/csv; the archive holds their checksums"
[[ -f "$WORK/environment.txt" ]] && { echo; cat "$WORK/environment.txt"; }
cat "$WORK/python.txt"
echo
n_fig=$(ls "$PAPER"/fig_*.pdf 2>/dev/null | wc -l)
if [[ $n_fig -gt 0 ]]; then
  echo "figures: $n_fig drawn in $PAPER"
else
  echo "figures: not drawn (optional; the comparison covers the data they are drawn from)"
fi
if [[ $status -eq 0 ]]; then
  echo "result: the second paper's results are reproduced"
else
  echo "result: NOT reproduced; see the checks and the comparison above"
fi
exit $status
