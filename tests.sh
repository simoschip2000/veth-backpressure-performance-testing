#!/bin/bash
source ./venv/bin/activate

TIME=60

echo "=== NO QDISC ==="
ip netns exec client tc qdisc del dev to-server root || true
ip netns exec client bbperf -t $TIME -u -c 192.168.20.2 -B 192.168.20.1 -g

echo "=== QDISC FQ_CODEL  ==="
ip netns exec client tc qdisc replace dev to-server root fq_codel
ip netns exec client bbperf -t $TIME -u -c 192.168.20.2 -B 192.168.20.1 -g

echo "=== QDISC SFQ ==="
ip netns exec client tc qdisc replace dev to-server root sfq
ip netns exec client bbperf -t $TIME -u -c 192.168.20.2 -B 192.168.20.1 -g
