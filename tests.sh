#!/bin/bash
source ./venv/bin/activate

TIME=60

DEV=server-link
NS=router

run_test() {
  output=$1
  ip netns exec client bbperf -t $TIME -u -c 192.168.20.2 -B 192.168.20.1 -g -J $output.json | grep "created graph"
  # Qdisc output: Look for requeues
  ip netns exec ${NS} tc -s qdisc ls dev ${DEV}
  # Interface stats: Look for TX dropped
  ip -netns ${NS} -s link ls dev ${DEV}
}

echo "=== NO QDISC ==="
ip netns exec ${NS} tc qdisc del dev ${DEV} root || true
run_test "no_qdisc"

echo "=== QDISC FQ_CODEL  ==="
ip netns exec ${NS} tc qdisc replace dev ${DEV} root fq_codel
run_test "fq_codel"

echo "=== QDISC SFQ ==="
ip netns exec ${NS} tc qdisc replace dev ${DEV} root sfq
run_test "sfq"
