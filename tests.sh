#!/bin/bash
source ./venv/bin/activate

TIME=60

run_test() {
  output=$1
  ip netns exec client bbperf -t $TIME -u -c 192.168.20.2 -B 192.168.20.1 -g -J $output.json | grep "created graph"
  # Qdisc output: Look for requeues
  ip netns exec client tc -s qdisc ls dev to-server
  # Interface stats: Look for TX dropped
  ip -netns client -s link ls dev to-server
}

echo "=== NO QDISC ==="
ip netns exec client tc qdisc del dev to-server root || true
run_test "no_qdisc"

echo "=== QDISC FQ_CODEL  ==="
ip netns exec client tc qdisc replace dev to-server root fq_codel
run_test "fq_codel"

echo "=== QDISC SFQ ==="
ip netns exec client tc qdisc replace dev to-server root sfq
run_test "sfq"
