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

extract_pps() {
    local resultsdir="$1"
    local pktgen_log="$resultsdir/pktgen.log"
    if [ -f "$pktgen_log" ]; then
        grep -oP '\d+(?=pps)' "$pktgen_log" | awk '{sum+=$1} END {print sum+0}'
        return
    fi
    echo 0
}

extract_ping_rtt() {
    local resultsdir="$1"
    local ping_log="$resultsdir/ping.log"
    if [ -f "$ping_log" ]; then
        # rtt min/avg/max/mdev = 0.042/0.062/0.125/0.021 ms
        grep -oP 'rtt [^=]+= [^/]+/\K[0-9.]+' "$ping_log" || echo 0
        return
    fi
    echo 0
}

run_variant() {
    local label="$1"; shift
    local -a extra_args=("$@")
    local pps_values=()
    local rtt_values=()

    for ((i = 1; i <= RUNS; i++)); do
        echo "  [$label] run $i/$RUNS ..." >&2

        # Create a dedicated results dir for this run
        local rundir
        rundir=$(mktemp -d "/tmp/veth_bql_bench.${label}.XXXXXX")

        RESULTSDIR="$rundir" "$SCRIPTDIR/veth_bql_test.sh" \
            "${TEST_ARGS[@]}" "${extra_args[@]}" > "$rundir/stdout.log" 2>&1

        local pps rtt
        pps=$(extract_pps "$rundir")
        rtt=$(extract_ping_rtt "$rundir")
        pps_values+=("$pps")
        rtt_values+=("$rtt")

        echo "    pps=$pps  ping_avg=${rtt}ms" >&2
    done

    # Compute averages
    local avg_pps avg_rtt
    avg_pps=$(printf '%s\n' "${pps_values[@]}" | awk '{sum+=$1} END {printf "%.0f", sum/NR}')
    avg_rtt=$(printf '%s\n' "${rtt_values[@]}" | awk '{sum+=$1} END {printf "%.3f", sum/NR}')

    echo "$avg_pps $avg_rtt"
}

echo "=== veth BQL A/B benchmark ==="
echo "Runs per variant: $RUNS"
echo "Test args: ${TEST_ARGS[*]}"
echo ""

echo "--- BQL enabled ---"
read -r bql_pps bql_rtt <<< "$(run_variant "bql-on" )"

echo ""
echo "--- BQL disabled ---"
read -r nobql_pps nobql_rtt <<< "$(run_variant "bql-off" --bql-disable)"

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
