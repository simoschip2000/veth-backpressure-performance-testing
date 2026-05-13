#!/bin/bash
# Generate a combined gnuplot graph showing bbperf throughput + RTT and
# ping RTT on the same time axis.
#
# Usage: plot_combined.sh <bbperf.json> <ping.log> <output.png> <title>
set -euo pipefail

BBPERF_JSON="$1"
PING_LOG="$2"
OUTPUT_PNG="$3"
TITLE="${4:-Backpressure Test}"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# --- Extract ping data, detect drops, and determine shared t0 ---
# Use ping's first packet timestamp as t0. Ping starts before bbperf
# (which has ~8s UDP calibration), so this gives both datasets a
# stable, accurate time origin.
#
# Ping outputs:
#   ping.dat  - received packets: relative_time_sec  rtt_ms  icmp_seq
#   drops.dat - missing packets:  expected_time_sec  (one per dropped seq)
python3 << PYEOF > "${TMPDIR}/ping.dat"
import re, sys

lines = open('${PING_LOG}').readlines()
received = []  # (timestamp, rtt_ms, icmp_seq)
for line in lines:
    m = re.match(r'\[(\d+\.\d+)\].*icmp_seq=(\d+).*time=([0-9.]+)\s*ms', line)
    if m:
        received.append((float(m.group(1)), int(m.group(2)), float(m.group(3))))

if not received:
    sys.exit(0)

t0 = received[0][0]
# Save t0 for ping-drop computation and gnuplot xrange
with open('${TMPDIR}/t0.txt', 'w') as f:
    f.write(f'{t0:.6f}')

# Estimate ping interval from consecutive deltas (median)
deltas = []
prev_ts, prev_seq = received[0][0], received[0][1]
for ts, seq, _ in received[1:]:
    if seq == prev_seq + 1:
        deltas.append(ts - prev_ts)
    prev_ts, prev_seq = ts, seq
interval = sorted(deltas)[len(deltas)//2] if deltas else 0.1

# Detect missing sequence numbers
last_seq = received[-1][1]
got = set(s for _, s, _ in received)
drops = []
for seq in range(received[0][1], last_seq + 1):
    if seq not in got:
        # Expected time for missing seq: t0 + (seq - first_seq) * interval
        expected_t = t0 + (seq - received[0][1]) * interval
        drops.append(expected_t)

with open('${TMPDIR}/drops.dat', 'w') as f:
    for t in drops:
        # x = relative time, y = small value above 0 so dot is visible
        f.write(f'{t - t0:.3f} 0\n')

# Print received ping data: relative_time  rtt_ms
for ts, _, rtt in received:
    print(f'{ts - t0:.3f} {rtt:.3f}')
PYEOF

T0=$(cat "${TMPDIR}/t0.txt" 2>/dev/null || echo "")
DROP_COUNT=$(wc -l < "${TMPDIR}/drops.dat" 2>/dev/null || echo "0")

# --- Extract bbperf data, aligned to ping's t0 ---
# Columns: relative_time_sec  throughput_mbps  loaded_rtt_ms  loss_pct
python3 << PYEOF > "${TMPDIR}/bbperf.dat"
import json, sys

t0 = float('${T0}') if '${T0}' else None
with open('${BBPERF_JSON}') as f:
    d = json.load(f)
if not d['entries']:
    sys.exit(1)
if t0 is None:
    t0 = d['entries'][0]['sent_time_sec']
# Only plot valid samples (ramp-up samples have noisy throughput numbers)
valid = [e for e in d['entries'] if e.get('is_sample_valid')]
for e in valid:
    t = e['sent_time_sec'] - t0
    print(f"{t:.3f} {e['sender_throughput_rate_mbps']:.2f} {e['loaded_rtt_ms']:.2f} {e['pkt_loss_percent']:.2f}")
PYEOF

# Check we have data
if [ ! -s "${TMPDIR}/bbperf.dat" ]; then
    echo "WARNING: no valid bbperf samples, skipping plot" >&2
    exit 0
fi

# --- Compute ping stats for annotation ---
PING_STATS=""
if [ -s "${TMPDIR}/ping.dat" ]; then
    PING_STATS=$(python3 -c "
import sys
rtts = [float(line.split()[1]) for line in open('${TMPDIR}/ping.dat')]
if rtts:
    rtts.sort()
    n = len(rtts)
    p99_idx = int(n * 0.99)
    print(f'avg={sum(rtts)/n:.1f}ms p99={rtts[p99_idx]:.1f}ms max={rtts[-1]:.1f}ms n={n}')
")
fi

# --- Generate gnuplot script ---
# Note: the heredoc is unquoted so $TMPDIR expands but other $vars in
# the gnuplot script are protected by escaping ($ is only special if
# followed by a name; gnuplot syntax uses no shell-style $vars).
cat > "${TMPDIR}/plot.gp" << GNUPLOT_HEADER
set terminal pngcairo size 1200,700 noenhanced font 'Arial,11'
set output OUTPUT_PNG

set title TITLE font 'Arial,14'
set xlabel 'Time (seconds since test start)'

# Two y-axes: left=throughput, right=RTT
set ylabel 'Throughput (Mbps)' textcolor rgb '#0060ad'
set y2label 'RTT (ms)' textcolor rgb '#dd181f'
set ytics nomirror tc rgb '#0060ad'
set y2tics nomirror tc rgb '#dd181f'
set y2range [0:*]
set xrange [0:*]

set grid xtics ytics
set key outside top center horizontal
set style fill transparent solid 0.3

# Layers (drawn bottom-to-top in legend):
#   bbperf throughput  - left axis, blue filled area
#   bbperf RTT         - right axis, red line
#   ping RTT           - right axis, green dots
#   ping drops         - right axis, red X marks at y=0
plot BBPERF_DAT using 1:2 axes x1y1 with filledcurves x1 \\
         lc rgb '#0060ad' title 'bbperf throughput (Mbps)', \\
     BBPERF_DAT using 1:3 axes x1y2 with lines \\
         lw 2 lc rgb '#dd181f' title 'bbperf RTT (ms)', \\
     PING_DAT using 1:2 axes x1y2 with points \\
         pt 7 ps 0.4 lc rgb '#00aa00' title PING_LABEL, \\
     DROPS_DAT using 1:2 axes x1y2 with points \\
         pt 2 ps 1.5 lw 2 lc rgb '#cc0000' title DROPS_LABEL
GNUPLOT_HEADER

# Build labels with stats
PING_LABEL="ping RTT"
if [ -n "$PING_STATS" ]; then
    PING_LABEL="ping RTT (${PING_STATS})"
fi
DROPS_LABEL="ping drops (${DROP_COUNT})"

# Ensure drops.dat exists with at least one off-screen point so gnuplot
# keeps the legend entry visible even when there are no drops.
if [ ! -s "${TMPDIR}/drops.dat" ]; then
    echo "-1 0" > "${TMPDIR}/drops.dat"
fi

# Run gnuplot with variable substitution
gnuplot \
    -e "OUTPUT_PNG='${OUTPUT_PNG}'" \
    -e "TITLE='${TITLE}'" \
    -e "BBPERF_DAT='${TMPDIR}/bbperf.dat'" \
    -e "PING_DAT='${TMPDIR}/ping.dat'" \
    -e "DROPS_DAT='${TMPDIR}/drops.dat'" \
    -e "PING_LABEL='${PING_LABEL}'" \
    -e "DROPS_LABEL='${DROPS_LABEL}'" \
    "${TMPDIR}/plot.gp"

echo "created combined graph: ${OUTPUT_PNG}"
