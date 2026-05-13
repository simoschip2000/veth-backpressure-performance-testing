#!/bin/bash
# Generate a 5-panel gnuplot graph in the style of bbperf's own output,
# but with ping RTT and ping drops overlaid on the RTT panel.
#
# Panels (top to bottom):
#   1. Throughput (Mbps)   - sender + receiver
#   2. Packets/sec         - receiver_pps
#   3. RTT (ms)            - unloaded + loaded + ping RTT + ping drops
#   4. Buffered bytes      - BDP + excess buffered
#   5. Packet loss (%)     - pkt_loss_percent
#
# Inspired by bbperf's src/bbperf/udp-graph.gp (Apache 2.0, Cloudflare 2024).
#
# Usage: plot_multi.sh <bbperf.json> <ping.log> <output.png> <title>
set -euo pipefail

BBPERF_JSON="$1"
PING_LOG="$2"
OUTPUT_PNG="$3"
TITLE="${4:-bbperf + ping}"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# --- Extract bbperf data into a bbperf-style columnar file ---
# Use bbperf's first VALID sample as t0 so post-calibration data starts at 0.
# Ping data captured during bbperf's calibration phase will appear at
# negative x (preserved here; we don't clip the x-axis in the multi-panel
# view to give full context).
#
# Columns:
#   1: relative_sent_time_sec
#   2: sender_throughput_mbps
#   3: receiver_throughput_mbps
#   4: receiver_pps
#   5: unloaded_rtt_ms
#   6: loaded_rtt_ms
#   7: bdp_bytes
#   8: excess_buffered_bytes
#   9: pkt_loss_percent
python3 << PYEOF > "${TMPDIR}/bbperf.dat"
import json, sys
with open('${BBPERF_JSON}') as f:
    d = json.load(f)
unloaded_rtt = d.get('summary', {}).get('unloaded_rtt_ms', 0) or 0
valid = [e for e in d['entries'] if e.get('is_sample_valid')]
if not valid:
    sys.exit(1)
t0 = valid[0]['sent_time_sec']
with open('${TMPDIR}/t0.txt', 'w') as f:
    f.write(f'{t0:.6f}')
for e in valid:
    print(
        f"{e['sent_time_sec'] - t0:.3f} "
        f"{e['sender_throughput_rate_mbps']:.2f} "
        f"{e['receiver_throughput_rate_mbps']:.2f} "
        f"{e['receiver_pps']} "
        f"{unloaded_rtt:.3f} "
        f"{e['loaded_rtt_ms']:.2f} "
        f"{e['bdp_bytes']} "
        f"{e['excess_buffered_bytes']} "
        f"{e['pkt_loss_percent']:.3f}"
    )
PYEOF

T0=$(cat "${TMPDIR}/t0.txt")

# --- Extract ping data (received + dropped) aligned to bbperf t0 ---
python3 << PYEOF > "${TMPDIR}/ping.dat"
import re, sys
t0 = float('${T0}')

received = []  # (relative_time, rtt_ms, icmp_seq)
for line in open('${PING_LOG}'):
    m = re.match(r'\[(\d+\.\d+)\].*icmp_seq=(\d+).*time=([0-9.]+)\s*ms', line)
    if m:
        received.append((float(m.group(1)), int(m.group(2)), float(m.group(3))))

# Estimate inter-packet interval (median of consecutive deltas)
deltas = []
prev_ts, prev_seq = (received[0][0], received[0][1]) if received else (0, 0)
for ts, seq, _ in received[1:]:
    if seq == prev_seq + 1:
        deltas.append(ts - prev_ts)
    prev_ts, prev_seq = ts, seq
interval = sorted(deltas)[len(deltas)//2] if deltas else 0.1

# Detect drops (missing icmp_seq) and write expected timestamps
got = {s for _, s, _ in received}
drops = []
if received:
    first_seq = received[0][1]
    last_seq = received[-1][1]
    ping_t0 = received[0][0]
    for seq in range(first_seq, last_seq + 1):
        if seq not in got:
            expected_t = ping_t0 + (seq - first_seq) * interval
            drops.append(expected_t - t0)

with open('${TMPDIR}/drops.dat', 'w') as f:
    for t in drops:
        f.write(f'{t:.3f} 0\n')

# Print received pings: relative_time  rtt_ms
for ts, _, rtt in received:
    print(f'{ts - t0:.3f} {rtt:.3f}')
PYEOF

DROP_COUNT=$(wc -l < "${TMPDIR}/drops.dat" 2>/dev/null || echo "0")

# Keep gnuplot legend stable when no drops occurred.
# Use a sentinel just outside the plot area; we lock xrange below.
if [ ! -s "${TMPDIR}/drops.dat" ]; then
    echo "-9999 0" > "${TMPDIR}/drops.dat"
fi

# Compute steady-state ping stats (excluding first 10s = bbperf warmup)
PING_STATS=$(python3 -c "
rtts = []
with open('${TMPDIR}/ping.dat') as f:
    for line in f:
        parts = line.split()
        if len(parts) == 2 and float(parts[0]) >= 0:
            rtts.append(float(parts[1]))
if rtts:
    rtts.sort()
    n = len(rtts)
    p99 = rtts[min(int(n*0.99), n-1)]
    print(f'avg={sum(rtts)/n:.1f}ms p99={p99:.1f}ms n={n}')
else:
    print('no overlap')
" 2>/dev/null || echo "")

# Compose title with ping summary
FULL_TITLE="${TITLE}  [ping: ${PING_STATS}, drops: ${DROP_COUNT}]"

# --- Generate gnuplot multi-panel script ---
cat > "${TMPDIR}/plot.gp" << 'GNUPLOT_EOF'
# noenhanced: avoid having to escape underscores in titles/labels
set terminal pngcairo size 1200,1500 noenhanced font 'Arial,11'
set output OUTPUT_PNG

set grid
set key right top box opaque
set style data lines

# Compute x-axis range from bbperf data (column 1 is relative time).
# Include some negative range so ping data captured during bbperf
# calibration (negative x relative to first valid sample) is visible.
stats BBPERF_DAT using 1 nooutput name "XR"
stats PING_DAT using 1 nooutput name "PR"
xmin = (PR_min < 0) ? PR_min - 1 : -1
xmax = XR_max + 1
set xrange [xmin:xmax]

set multiplot title FULL_TITLE layout 5,1
set lmargin 12

# Panel 1: Throughput (Mbps) -----------------------------------------
set ylabel "Mbps"
set xlabel ""
plot BBPERF_DAT using 1:3 title "receiver throughput" lw 2 lc rgb '#0060ad', \
     ""         using 1:2 title "sender throughput"   lw 2 lc rgb '#aa00aa' dt 2

# Panel 2: PPS -------------------------------------------------------
set ylabel "pps"
plot BBPERF_DAT using 1:4 title "receiver pps" lw 2 lc rgb '#0060ad'

# Panel 3: RTT with ping overlay (the headline panel) ----------------
set ylabel "RTT (ms)"
plot BBPERF_DAT using 1:5 title "unloaded RTT" lw 2 lc rgb '#888888' dt 2, \
     BBPERF_DAT using 1:6 title "bbperf loaded RTT" lw 2 lc rgb '#dd181f', \
     PING_DAT   using 1:2 title "ping RTT" with points pt 7 ps 0.5 lc rgb '#00aa00', \
     DROPS_DAT  using 1:2 title DROPS_LABEL with points pt 2 ps 1.5 lw 2 lc rgb '#cc0000'

# Panel 4: Buffered bytes --------------------------------------------
set ylabel "bytes"
plot BBPERF_DAT using 1:7 title "BDP"           lw 2 lc rgb '#888888', \
     BBPERF_DAT using 1:8 title "excess buffered" lw 2 lc rgb '#0060ad'

# Panel 5: Packet loss % ---------------------------------------------
set ylabel "packet loss (%)"
set xlabel "Time (seconds since bbperf valid-sample start)"
plot BBPERF_DAT using 1:9 title "pkt loss %" lw 2 lc rgb '#dd181f'

unset multiplot
GNUPLOT_EOF

DROPS_LABEL="ping drops (${DROP_COUNT})"

gnuplot \
    -e "OUTPUT_PNG='${OUTPUT_PNG}'" \
    -e "FULL_TITLE='${FULL_TITLE}'" \
    -e "BBPERF_DAT='${TMPDIR}/bbperf.dat'" \
    -e "PING_DAT='${TMPDIR}/ping.dat'" \
    -e "DROPS_DAT='${TMPDIR}/drops.dat'" \
    -e "DROPS_LABEL='${DROPS_LABEL}'" \
    "${TMPDIR}/plot.gp"

echo "created multi-panel graph: ${OUTPUT_PNG}"
