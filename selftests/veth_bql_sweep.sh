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
echo "tx_usecs,nrules,avg_pps,avg_rtt_ms,avg_p99_ms,interval_p5_us,interval_p25_us,interval_p50_us,interval_p75_us,interval_p95_us,limit_p5,limit_p25,limit_p50,limit_p75,limit_p95,count_p5,count_p25,count_p50,count_p75,count_p95" >> "$CSV"

# Count total combos for progress
read -ra _tu_arr <<< "$TX_USECS_LIST"
read -ra _nr_arr <<< "$NRULES_LIST"
TOTAL=$(( ${#_tu_arr[@]} * ${#_nr_arr[@]} ))
CURRENT=0

# Collect results into arrays for the summary table
declare -a ALL_TX ALL_NR ALL_PPS ALL_RTT ALL_P99 ALL_IP50 ALL_LP50 ALL_CP50

for tx_usecs in $TX_USECS_LIST; do
    for nrules in $NRULES_LIST; do
        CURRENT=$((CURRENT + 1))
        label="tu${tx_usecs}_nr${nrules}"
        echo "--- [$CURRENT/$TOTAL] tx-usecs=$tx_usecs nrules=$nrules ---"

        read -r avg_pps avg_rtt avg_p99 ip5 ip25 ip50 ip75 ip95 lp5 lp25 lp50 lp75 lp95 cp5 cp25 cp50 cp75 cp95 <<< \
            "$(run_n_times "$label" --tx-usecs "$tx_usecs" --nrules "$nrules")"

        echo "$tx_usecs,$nrules,$avg_pps,$avg_rtt,$avg_p99,$ip5,$ip25,$ip50,$ip75,$ip95,$lp5,$lp25,$lp50,$lp75,$lp95,$cp5,$cp25,$cp50,$cp75,$cp95" >> "$CSV"

        ALL_TX+=("$tx_usecs")
        ALL_NR+=("$nrules")
        ALL_PPS+=("$avg_pps")
        ALL_RTT+=("$avg_rtt")
        ALL_P99+=("$avg_p99")
        ALL_IP50+=("$ip50")
        ALL_LP50+=("$lp50")
        ALL_CP50+=("$cp50")

        echo "  => avg pps=$avg_pps  rtt=${avg_rtt}ms  p99=${avg_p99}ms  interval_p50=${ip50}us  limit_p50=${lp50}  count_p50=${cp50}"
        echo ""
    done
done

# --- Summary table ---
echo "========================================"
echo "Sweep results (average over $RUNS runs)"
echo "========================================"
printf "%-12s %-10s %12s %14s %14s %16s %12s %12s\n" "tx-usecs" "nrules" "pps" "rtt (ms)" "p99 (ms)" "interval p50 (us)" "limit p50" "count p50"
printf "%-12s %-10s %12s %14s %14s %16s %12s %12s\n" "--------" "------" "---" "--------" "--------" "-----------------" "---------" "---------"
for ((i = 0; i < ${#ALL_TX[@]}; i++)); do
    printf "%-12s %-10s %12s %14s %14s %16s %12s %12s\n" \
        "${ALL_TX[$i]}" "${ALL_NR[$i]}" "${ALL_PPS[$i]}" "${ALL_RTT[$i]}" "${ALL_P99[$i]}" "${ALL_IP50[$i]}" "${ALL_LP50[$i]}" "${ALL_CP50[$i]}"
done
echo "========================================"
echo ""
echo "CSV saved to: $CSV"
echo "Full logs in: $OUTDIR"
