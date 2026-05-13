#!/bin/bash
source ./venv/bin/activate
set -euo pipefail

TIME=60

DEV=server-link
NS=router
# Delay the ping test until elefant flow ramps up
DELAY=5
PING_TIME=$((TIME - DELAY - 1))

run_test() {
  output=$1
  echo -e "\n=== $output === (runs for $TIME sec)"
  # start ping process in background
  (sleep $DELAY && echo "ping: started in background (runs for $PING_TIME sec)" && \
   ip netns exec client ping -w $PING_TIME -q -i 0.1 192.168.20.2)&
  graph=$(ip netns exec client bbperf -t $TIME -u -c 192.168.20.2 -B 198.18.0.2 -g -J $output.json | grep "created graph" | awk '{print $3}')
  mv $graph ./bbperf-graph-$output.png
  # wait for background ping to complete
  wait
  # Qdisc output: Look for requeues
  ip netns exec ${NS} tc -s qdisc ls dev ${DEV}
  # Interface stats: Look for TX dropped
  ip -netns ${NS} -s link ls dev ${DEV}
}

ip netns exec ${NS} tc qdisc del dev ${DEV} root 2>/dev/null || true
run_test "no_qdisc"

ip netns exec ${NS} tc qdisc replace dev ${DEV} root fq_codel
run_test "fq_codel"

ip netns exec ${NS} tc qdisc replace dev ${DEV} root codel
run_test "codel"

ip netns exec ${NS} tc qdisc replace dev ${DEV} root sfq
run_test "sfq"

# For MQ tests add some more queues to the veth device
# - this will make ping test results unreliable as a drop indicator
MQs=2
ip netns exec client ethtool --set-channels to-router   rx $MQs tx $MQs
ip netns exec router ethtool --set-channels client-link rx $MQs tx $MQs
ip netns exec router ethtool --set-channels server-link rx $MQs tx $MQs
ip netns exec server ethtool --set-channels in-router   rx $MQs tx $MQs

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
