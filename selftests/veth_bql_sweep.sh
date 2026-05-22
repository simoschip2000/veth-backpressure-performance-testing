#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Parameter sweep benchmark for veth_bql_test.sh.
# Sweeps over tx-usecs (BQL coalescing delay) and nrules (iptables load),
# running each (tx-usecs, nrules) combination N times and collecting
# average throughput (pps) and ping RTT.
#
# Usage:
#   ./veth_bql_sweep.sh [OPTIONS] -- [veth_bql_test.sh args...]
#
# Example:
#   ./veth_bql_sweep.sh --runs 5 --tx-usecs-list "0 250 500 1000 2000" \
#       --nrules-list "0 1000 3500" -- --pktgen --duration 10

SCRIPTDIR="$(cd "$(dirname -- "$0")" && pwd)"
source "$SCRIPTDIR/bench_helpers.sh"

# Defaults
RUNS=10
TX_USECS_LIST="0 100 250 500 750 1000 1500 2000"
NRULES_LIST="0 1000 3500 10000"
OUTDIR=""

usage() {
    echo "Usage: $0 [OPTIONS] -- [veth_bql_test.sh options...]"
    echo ""
    echo "Options:"
    echo "  --runs N              iterations per (tx-usecs, nrules) combo (default: $RUNS)"
    echo "  --tx-usecs-list LIST  space-separated tx-usecs values in us (default: $TX_USECS_LIST)"
    echo "  --nrules-list LIST    space-separated nrules values (default: $NRULES_LIST)"
    echo "  --outdir DIR          output directory for CSV results (default: auto)"
    echo ""
    echo "Example:"
    echo "  $0 --runs 3 --tx-usecs-list '0 500 1000 2000' \\"
    echo "     --nrules-list '0 1000 3500' -- --pktgen --duration 10"
    exit 1
}

# Parse our options (before the --)
while [ $# -gt 0 ]; do
    case "$1" in
    --runs)           RUNS="$2"; shift 2 ;;
    --tx-usecs-list)  TX_USECS_LIST="$2"; shift 2 ;;
    --nrules-list)    NRULES_LIST="$2"; shift 2 ;;
    --outdir)         OUTDIR="$2"; shift 2 ;;
    --help|-h)        usage ;;
    --)               shift; break ;;
    *)                break ;;
    esac
done

TEST_ARGS=("$@")

# Setup output directory
if [ -z "$OUTDIR" ]; then
    REPO_ROOT="$(dirname "$SCRIPTDIR")"
    OUTDIR="$REPO_ROOT/results/sweep/$(date +%Y-%m-%dT%H-%M-%S)"
fi
mkdir -p "$OUTDIR"

CSV="$OUTDIR/sweep.csv"

# --- Main ---

echo "=== veth BQL parameter sweep ==="
echo "Runs per combo: $RUNS"
echo "tx-usecs values: $TX_USECS_LIST"
echo "nrules values:   $NRULES_LIST"
echo "Test args:       ${TEST_ARGS[*]}"
echo "Output:          $OUTDIR"
echo ""

# Record command line for reproducibility
CMDLINE="$0 $*"
echo "$CMDLINE" > "$OUTDIR/cmdline.sh"

# CSV header — first line is a comment with the command line
echo "# $CMDLINE" > "$CSV"
echo "tx_usecs,nrules,avg_pps,avg_rtt_ms" >> "$CSV"

# Count total combos for progress
read -ra _tu_arr <<< "$TX_USECS_LIST"
read -ra _nr_arr <<< "$NRULES_LIST"
TOTAL=$(( ${#_tu_arr[@]} * ${#_nr_arr[@]} ))
CURRENT=0

# Collect results into arrays for the summary table
declare -a ALL_TX ALL_NR ALL_PPS ALL_RTT

for tx_usecs in $TX_USECS_LIST; do
    for nrules in $NRULES_LIST; do
        CURRENT=$((CURRENT + 1))
        label="tu${tx_usecs}_nr${nrules}"
        echo "--- [$CURRENT/$TOTAL] tx-usecs=$tx_usecs nrules=$nrules ---"

        read -r avg_pps avg_rtt <<< "$(run_n_times "$label" \
            --tx-usecs "$tx_usecs" --nrules "$nrules")"

        echo "$tx_usecs,$nrules,$avg_pps,$avg_rtt" >> "$CSV"

        ALL_TX+=("$tx_usecs")
        ALL_NR+=("$nrules")
        ALL_PPS+=("$avg_pps")
        ALL_RTT+=("$avg_rtt")

        echo "  => avg pps=$avg_pps  rtt=${avg_rtt}ms"
        echo ""
    done
done

# --- Summary table ---
echo "========================================"
echo "Sweep results (average over $RUNS runs)"
echo "========================================"
printf "%-12s %-10s %12s %14s\n" "tx-usecs" "nrules" "pps" "rtt (ms)"
printf "%-12s %-10s %12s %14s\n" "--------" "------" "---" "--------"
for ((i = 0; i < ${#ALL_TX[@]}; i++)); do
    printf "%-12s %-10s %12s %14s\n" \
        "${ALL_TX[$i]}" "${ALL_NR[$i]}" "${ALL_PPS[$i]}" "${ALL_RTT[$i]}"
done
echo "========================================"
echo ""
echo "CSV saved to: $CSV"
echo "Full logs in: $OUTDIR"
