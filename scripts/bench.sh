#!/usr/bin/env bash
#
# Large-session performance benches (issue 7.2). Runs the Criterion benches for
# min/max decimation (racestudio-analysis) and lazy channel opening
# (racestudio-decode), and — in `--ci` mode — enforces the wall-clock regression
# ceilings recorded in scripts/bench_thresholds.json.
#
# The ceilings are deliberately generous: they catch algorithmic (e.g. O(n^2))
# regressions without flaking on the run-to-run and machine-to-machine variance
# that makes absolute micro-benchmarks unreliable in shared CI.
#
# Usage:
#   scripts/bench.sh            full Criterion run (both crates), no gate
#   scripts/bench.sh --ci       quick run + enforce max_seconds ceilings (CI gate)
#   scripts/bench.sh --print     print the resolved threshold config and exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT/scripts/bench_thresholds.json"
CRIT_DIR="$ROOT/target/criterion"

# Run only the two harness=false Criterion bench targets (never the empty libtest
# lib-bench harness, which would reject the Criterion CLI flags below).
run_benches() {
  cargo bench --manifest-path "$ROOT/Cargo.toml" -p racestudio-analysis --bench decimation -- "$@"
  cargo bench --manifest-path "$ROOT/Cargo.toml" -p racestudio-decode --bench lazy_open -- "$@"
}

enforce_ceilings() {
  python3 - "$CONFIG" "$CRIT_DIR" <<'PY'
import sys, json, os

config_path, crit_dir = sys.argv[1], sys.argv[2]
with open(config_path) as handle:
    config = json.load(handle)

failed = False
for name, spec in config["benchmarks"].items():
    cid = spec["criterion_id"]
    ceiling_s = float(spec["max_seconds"])
    estimates = os.path.join(crit_dir, cid, "new", "estimates.json")
    if not os.path.exists(estimates):
        print(f"[MISS] {name}: no Criterion estimates at {estimates}", file=sys.stderr)
        failed = True
        continue
    with open(estimates) as handle:
        mean_s = float(json.load(handle)["mean"]["point_estimate"]) / 1e9
    ok = mean_s <= ceiling_s
    failed = failed or not ok
    print(f"[{'OK' if ok else 'FAIL'}] {name}: {mean_s * 1e3:.3f} ms "
          f"(ceiling {ceiling_s * 1e3:.0f} ms)")

if failed:
    print("FAIL: a benchmark exceeded its wall-clock ceiling (see above)", file=sys.stderr)
    sys.exit(1)
print("PASS: all tracked benchmarks are within their wall-clock ceilings")
PY
}

case "${1:-}" in
  --print)
    echo "CONFIG=$CONFIG"
    cat "$CONFIG"
    exit 0
    ;;
  --ci)
    echo "==> [bench] quick run + regression-ceiling gate (CI)"
    # Reduced sampling keeps CI fast; correctness of the numbers is not the point,
    # only that no benchmark blew past its generous ceiling.
    run_benches --warm-up-time 0.5 --measurement-time 1 --sample-size 10
    echo "==> [bench] enforcing ceilings from scripts/bench_thresholds.json"
    enforce_ceilings
    ;;
  "")
    echo "==> [bench] full Criterion run (racestudio-analysis + racestudio-decode)"
    run_benches
    ;;
  *)
    echo "usage: bench.sh [--ci|--print]" >&2
    exit 2
    ;;
esac
