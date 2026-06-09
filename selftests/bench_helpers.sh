#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Shared helpers for veth_bql_bench.sh and veth_bql_sweep.sh.

BENCH_SCRIPTDIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Extract delivered pps (goodput) from a result directory.
# Uses rx_packets on the peer veth rather than pktgen's enqueue count,
# because dropping qdiscs (fq_codel) inflate the pktgen number -- CoDel
# drops happen on dequeue, after pktgen already counted the enqueue.
extract_pps() {
    local resultsdir="$1"
    local goodput_file="$resultsdir/goodput_pps"
    if [ -f "$goodput_file" ]; then
        cat "$goodput_file"
        return
    fi
    # Fallback to pktgen.log for older result dirs
    local pktgen_log="$resultsdir/pktgen.log"
    if [ -f "$pktgen_log" ]; then
        grep -oP '\d+(?=pps)' "$pktgen_log" | awk '{sum+=$1} END {print sum+0}'
        return
    fi
    echo 0
}

# Extract average ping RTT (ms) from a result directory, or "nan" on 100% loss.
extract_ping_rtt() {
    local resultsdir="$1"
    local ping_log="$resultsdir/ping.log"
    if [ -f "$ping_log" ]; then
        # rtt min/avg/max/mdev = 0.042/0.062/0.125/0.021 ms
        local avg
        avg=$(grep -oP 'rtt [^=]+= [^/]+/\K[0-9.]+' "$ping_log")
        if [ -n "$avg" ]; then
            echo "$avg"
            return
        fi
    fi
    echo nan
}

# Extract p99 ping RTT (ms) from a result directory.
extract_ping_p99() {
    local resultsdir="$1"
    local ping_log="$resultsdir/ping.log"
    if [ -f "$ping_log" ]; then
        grep -oP 'time=\K[0-9.]+' "$ping_log" | LC_ALL=C sort -n | \
            awk '{a[NR]=$1} END {if(NR>0) {idx=int(NR*0.99); if(idx<1) idx=1; print a[idx]} else print 0}'
        return
    fi
    echo 0
}

# Extract p5/p25/p50/p75/p95 from a bpftrace lhist section.
# Args: <logfile> <section_header_regex>
# Prints "p5 p25 p50 p75 p95" to stdout; "0 0 0 0 0" if missing.
_extract_lhist_percentiles() {
    local log="$1" header="$2"
    if [ ! -f "$log" ]; then
        echo "0 0 0 0 0"
        return
    fi
    awk -v hdr="$header" '
    $0 ~ hdr { capture=1; next }
    capture && /^$/ { capture=0 }
    capture && /^\[/ {
        s = $0
        gsub(/\|.*/, "", s)
        gsub(/[][,)]+/, " ", s)
        split(s, a)
        n++
        lo[n] = a[1]+0; hi[n] = a[2]+0; cnt[n] = a[3]+0
        # Fix overflow bucket: bpftrace prints [max, ...) where "..." parses as 0
        if (hi[n] <= lo[n] && lo[n] > 0) hi[n] = lo[n]
        total += a[3]+0
    }
    END {
        if (total == 0) { print "0 0 0 0 0"; exit }
        split("5 25 50 75 95", pcts)
        cum = 0; pi = 1
        for (i = 1; i <= n; i++) {
            prev = cum
            cum += cnt[i]
            while (pi <= 5 && cum >= total * pcts[pi] / 100) {
                result[pi] = lo[i]
                pi++
            }
        }
        while (pi <= 5) { result[pi] = lo[n]; pi++ }
        printf "%.0f %.0f %.0f %.0f %.0f\n", result[1], result[2], result[3], result[4], result[5]
    }
    ' "$log"
}

# Extract BQL completion interval percentiles (us) from bql_interval.log.
# Merges the ns histogram (0-1000ns, fine-grained) with the us histogram
# ([1000,2000)us onward) to get full resolution across the entire range.
# The ns overflow bucket [1000,...) is skipped since those samples are
# already covered by the us histogram.
extract_interval_percentiles() {
    local log="$1/bql_interval.log"
    if [ ! -f "$log" ]; then
        echo "0 0 0 0 0"
        return
    fi
    awk '
    /interval histogram \(ns/ { section="ns"; next }
    /interval histogram \(us/ { section="us"; next }
    /^---/ { section=""; next }
    section != "" && /^\[/ {
        s = $0
        gsub(/\|.*/, "", s)
        gsub(/[][,)]+/, " ", s)
        split(s, a)
        blo = a[1]+0; bhi = a[2]+0; bcnt = a[3]+0
        # Fix overflow bucket: bpftrace prints [max, ...) where "..." parses as 0
        if (bhi <= blo && blo > 0) bhi = blo
        if (bcnt == 0) next
        if (section == "ns") {
            if (blo >= 1000) next
            ns_n++
            ns_lo[ns_n] = blo; ns_hi[ns_n] = bhi; ns_cnt[ns_n] = bcnt
            ns_total += bcnt
        } else {
            us_n++
            us_lo[us_n] = blo; us_hi[us_n] = bhi; us_cnt[us_n] = bcnt
        }
    }
    END {
        # Build merged bucket array in microseconds:
        #   1) ns regular buckets [0,100)...[900,1000) -> [0, 0.1)...[0.9, 1.0) us
        #   2) gap bucket [1, 100) us = us[0,100) count - ns regular total
        #   3) us buckets [100, 200), [200, 300), ...
        n = 0
        for (i = 1; i <= ns_n; i++) {
            n++
            mlo[n] = ns_lo[i] / 1000
            mhi[n] = ns_hi[i] / 1000
            mcnt[n] = ns_cnt[i]
        }
        us_first = 0
        for (i = 1; i <= us_n; i++) {
            if (us_lo[i] == 0 && us_hi[i] <= 100) {
                us_first = us_cnt[i]
                break
            }
        }
        gap = us_first - ns_total
        if (gap > 0) {
            n++
            mlo[n] = 1.0
            mhi[n] = 100.0
            mcnt[n] = gap
        }
        for (i = 1; i <= us_n; i++) {
            if (us_lo[i] >= 100) {
                n++
                mlo[n] = us_lo[i]
                mhi[n] = us_hi[i]
                mcnt[n] = us_cnt[i]
            }
        }

        total = 0
        for (i = 1; i <= n; i++) total += mcnt[i]
        if (total == 0) { print "0 0 0 0 0"; exit }

        split("5 25 50 75 95", pcts)
        cum = 0; pi = 1
        for (i = 1; i <= n; i++) {
            prev = cum
            cum += mcnt[i]
            while (pi <= 5 && cum >= total * pcts[pi] / 100) {
                result[pi] = mlo[i]
                pi++
            }
        }
        while (pi <= 5) { result[pi] = mlo[n]; pi++ }
        printf "%.3f %.3f %.3f %.3f %.3f\n", result[1], result[2], result[3], result[4], result[5]
    }
    ' "$log"
}

# Extract BQL limit percentiles (packets) from bql_inflight.log.
extract_limit_percentiles() {
    _extract_lhist_percentiles "$1/bql_inflight.log" "BQL limit histogram"
}

# Extract dql_completed count percentiles (pkts per completion) from bql_interval.log.
extract_count_percentiles() {
    _extract_lhist_percentiles "$1/bql_interval.log" "dql_completed count histogram"
}

# Run veth_bql_test.sh $RUNS times with given extra args.
# Expects RUNS and TEST_ARGS to be set by the caller.
# Prints space-separated values to stdout; progress to stderr:
#   avg_pps avg_rtt avg_p99
#   ip5 ip25 ip50 ip75 ip95        (interval percentiles, us)
#   lp5 lp25 lp50 lp75 lp95        (BQL limit percentiles, pkts)
#   cp5 cp25 cp50 cp75 cp95        (completed count percentiles, pkts)
run_n_times() {
    local label="$1"; shift
    local -a extra_args=("$@")
    local pps_values=() rtt_values=() p99_values=()
    local ip5_v=() ip25_v=() ip50_v=() ip75_v=() ip95_v=()
    local lp5_v=() lp25_v=() lp50_v=() lp75_v=() lp95_v=()
    local cp5_v=() cp25_v=() cp50_v=() cp75_v=() cp95_v=()

    for ((i = 1; i <= RUNS; i++)); do
        local attempt=0 pps rtt rc
        while true; do
            attempt=$((attempt + 1))
            if [[ $attempt -gt 1 ]]; then
                echo "  [$label] run $i/$RUNS retry $((attempt - 1)) (previous ping=nan) ..." >&2
            else
                echo "  [$label] run $i/$RUNS ..." >&2
            fi

            local rundir
            rundir=$(mktemp -d "/tmp/veth_bql_bench.${label}.XXXXXX")

            RESULTSDIR="$rundir" "$BENCH_SCRIPTDIR/veth_bql_test.sh" \
                "${TEST_ARGS[@]}" "${extra_args[@]}" > "$rundir/stdout.log" 2>&1
            rc=$?

            pps=$(extract_pps "$rundir")
            rtt=$(extract_ping_rtt "$rundir")

            echo "    pps=$pps  ping_avg=${rtt}ms  exit=$rc" >&2

            [[ "$rtt" != "nan" ]] && break
        done

        local p99
        p99=$(extract_ping_p99 "$rundir")
        pps_values+=("$pps")
        rtt_values+=("$rtt")
        p99_values+=("$p99")

        local ip5 ip25 ip50 ip75 ip95
        read -r ip5 ip25 ip50 ip75 ip95 <<< "$(extract_interval_percentiles "$rundir")"
        ip5_v+=("$ip5"); ip25_v+=("$ip25"); ip50_v+=("$ip50")
        ip75_v+=("$ip75"); ip95_v+=("$ip95")

        local lp5 lp25 lp50 lp75 lp95
        read -r lp5 lp25 lp50 lp75 lp95 <<< "$(extract_limit_percentiles "$rundir")"
        lp5_v+=("$lp5"); lp25_v+=("$lp25"); lp50_v+=("$lp50")
        lp75_v+=("$lp75"); lp95_v+=("$lp95")

        local cp5 cp25 cp50 cp75 cp95
        read -r cp5 cp25 cp50 cp75 cp95 <<< "$(extract_count_percentiles "$rundir")"
        cp5_v+=("$cp5"); cp25_v+=("$cp25"); cp50_v+=("$cp50")
        cp75_v+=("$cp75"); cp95_v+=("$cp95")

        echo "    pps=$pps  ping_avg=${rtt}ms  ping_p99=${p99}ms  interval_p50=${ip50}us  limit_p50=${lp50}  count_p50=${cp50}  exit=$rc" >&2
    done

    _avg() { printf '%s\n' "$@" | awk '{sum+=$1} END {printf "%.0f", sum/NR}'; }
    _avgf() { printf '%s\n' "$@" | awk '{sum+=$1} END {printf "%.3f", sum/NR}'; }

    echo "$(_avg "${pps_values[@]}") $(_avgf "${rtt_values[@]}") $(_avgf "${p99_values[@]}") \
$(_avgf "${ip5_v[@]}") $(_avgf "${ip25_v[@]}") $(_avgf "${ip50_v[@]}") $(_avgf "${ip75_v[@]}") $(_avgf "${ip95_v[@]}") \
$(_avg "${lp5_v[@]}") $(_avg "${lp25_v[@]}") $(_avg "${lp50_v[@]}") $(_avg "${lp75_v[@]}") $(_avg "${lp95_v[@]}") \
$(_avg "${cp5_v[@]}") $(_avg "${cp25_v[@]}") $(_avg "${cp50_v[@]}") $(_avg "${cp75_v[@]}") $(_avg "${cp95_v[@]}")"
}
