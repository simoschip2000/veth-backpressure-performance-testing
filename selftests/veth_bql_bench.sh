#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# A/B benchmark wrapper for veth_bql_test.sh.
# Runs the given command line N times with BQL enabled and N times with
# --bql-disable, then reports average throughput (pps) and ping RTT.
#
# Usage: ./veth_bql_bench.sh [--runs N] -- [veth_bql_test.sh args...]
# Example: ./veth_bql_bench.sh --runs 5 -- --pktgen --pktgen-threads 2 --duration 10

SCRIPTDIR="$(cd "$(dirname -- "$0")" && pwd)"
source "$SCRIPTDIR/bench_helpers.sh"

RUNS=10

usage() {
    echo "Usage: $0 [--runs N] -- [veth_bql_test.sh options...]"
    echo "  --runs N   number of iterations per variant (default: $RUNS)"
    echo ""
    echo "Example:"
    echo "  $0 --runs 5 -- --pktgen --duration 10"
    exit 1
}

# Parse our options (before the --)
while [ $# -gt 0 ]; do
    case "$1" in
    --runs)  RUNS="$2"; shift 2 ;;
    --help|-h) usage ;;
    --)      shift; break ;;
    *)       break ;;  # assume everything else is for veth_bql_test.sh
    esac
done

TEST_ARGS=("$@")

echo "=== veth BQL A/B benchmark ==="
echo "Runs per variant: $RUNS"
echo "Test args: ${TEST_ARGS[*]}"
echo ""

echo "--- BQL enabled ---"
read -r bql_pps bql_rtt <<< "$(run_n_times "bql-on" )"

echo ""
echo "--- BQL disabled ---"
read -r nobql_pps nobql_rtt <<< "$(run_n_times "bql-off" --bql-disable)"

echo ""
echo "========================================"
echo "Results (average over $RUNS runs):"
echo "========================================"
printf "%-20s %12s %12s\n" "" "BQL on" "BQL off"
printf "%-20s %12s %12s\n" "---" "------" "-------"
printf "%-20s %12d %12d\n" "Throughput (pps)" "$bql_pps" "$nobql_pps"
printf "%-20s %12s %12s\n" "Ping RTT avg (ms)" "$bql_rtt" "$nobql_rtt"

# Differences
if [ "$nobql_pps" -gt 0 ]; then
    pps_diff=$(awk "BEGIN {printf \"%.1f\", 100.0*($bql_pps - $nobql_pps)/$nobql_pps}")
    printf "%-20s %12s\n" "Throughput diff" "${pps_diff}%"
fi
if [ "$(echo "$nobql_rtt > 0" | bc -l)" -eq 1 ]; then
    rtt_diff=$(awk "BEGIN {printf \"%.1f\", 100.0*($bql_rtt - $nobql_rtt)/$nobql_rtt}")
    printf "%-20s %12s\n" "RTT diff" "${rtt_diff}%"
fi
echo "========================================"
