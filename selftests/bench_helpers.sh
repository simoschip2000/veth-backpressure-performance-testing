#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Shared helpers for veth_bql_bench.sh and veth_bql_sweep.sh.

BENCH_SCRIPTDIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Extract total pps from a pktgen result directory.
extract_pps() {
    local resultsdir="$1"
    local pktgen_log="$resultsdir/pktgen.log"
    if [ -f "$pktgen_log" ]; then
        grep -oP '\d+(?=pps)' "$pktgen_log" | awk '{sum+=$1} END {print sum+0}'
        return
    fi
    echo 0
}

# Extract average ping RTT (ms) from a result directory.
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

# Run veth_bql_test.sh $RUNS times with given extra args.
# Expects RUNS and TEST_ARGS to be set by the caller.
# Prints "avg_pps avg_rtt" to stdout; progress to stderr.
run_n_times() {
    local label="$1"; shift
    local -a extra_args=("$@")
    local pps_values=()
    local rtt_values=()

    for ((i = 1; i <= RUNS; i++)); do
        echo "  [$label] run $i/$RUNS ..." >&2

        local rundir
        rundir=$(mktemp -d "/tmp/veth_bql_bench.${label}.XXXXXX")

        RESULTSDIR="$rundir" "$BENCH_SCRIPTDIR/veth_bql_test.sh" \
            "${TEST_ARGS[@]}" "${extra_args[@]}" > "$rundir/stdout.log" 2>&1
        local rc=$?

        local pps rtt
        pps=$(extract_pps "$rundir")
        rtt=$(extract_ping_rtt "$rundir")
        pps_values+=("$pps")
        rtt_values+=("$rtt")

        echo "    pps=$pps  ping_avg=${rtt}ms  exit=$rc" >&2
    done

    local avg_pps avg_rtt
    avg_pps=$(printf '%s\n' "${pps_values[@]}" | awk '{sum+=$1} END {printf "%.0f", sum/NR}')
    avg_rtt=$(printf '%s\n' "${rtt_values[@]}" | awk '{sum+=$1} END {printf "%.3f", sum/NR}')

    echo "$avg_pps $avg_rtt"
}
