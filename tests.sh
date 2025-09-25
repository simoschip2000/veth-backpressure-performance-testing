#!/bin/bash
source ./venv/bin/activate

TIME=15

DEV=server-link
NS=router

run_test() {
  output=$1
  echo "=== $output ==="
  graph=$(ip netns exec client bbperf -t $TIME -u -c 192.168.20.2 -B 192.168.20.1 -g -J $output.json | grep "created graph" | awk '{print $3}')
  mv $graph ./bbperf-graph-$output.png
  # Qdisc output: Look for requeues
  ip netns exec ${NS} tc -s qdisc ls dev ${DEV}
  # Interface stats: Look for TX dropped
  ip -netns ${NS} -s link ls dev ${DEV}
}

ip netns exec ${NS} tc qdisc del dev ${DEV} root || true
run_test "no_qdisc"

ip netns exec ${NS} tc qdisc replace dev ${DEV} root fq_codel
run_test "fq_codel"

ip netns exec ${NS} tc qdisc replace dev ${DEV} root sfq
run_test "sfq"

ip netns exec ${NS} tc qdisc replace dev ${DEV} root handle 1: mq
for sq in $(ip netns exec ${NS} tc -j qdisc show dev ${DEV} | jq -r .[].parent | grep -v null); do
  ip netns exec ${NS} tc qdisc replace dev ${DEV} parent ${sq} fq_codel
done
run_test "mq_fq_codel_qdisc"

ip netns exec ${NS} tc qdisc replace dev ${DEV} root handle 1: mq
for sq in $(ip netns exec ${NS} tc -j qdisc show dev ${DEV} | jq -r .[].parent | grep -v null); do
  ip netns exec ${NS} tc qdisc replace dev ${DEV} parent ${sq} sfq
done
run_test "mq_sfq_qdisc"
