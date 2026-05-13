#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/venv/bin/activate"

# Use sudo for privileged commands when not running as root
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo env PATH=$PATH"

TIME=60

DEV=server-link
NS=router
# Delay the ping test until elefant flow ramps up
DELAY=5
PING_TIME=$((TIME - DELAY - 1))

# Results directory: results/reproducer/<timestamp>/ with 'latest' symlink
TIMESTAMP=$(date +%Y-%m-%dT%H-%M-%S)
RESULTS_DIR="${REPO_ROOT}/results/reproducer/${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"
ln -sfn "${TIMESTAMP}" "${REPO_ROOT}/results/reproducer/latest"
echo "Results dir: ${RESULTS_DIR}"

# Tee all output to a log file in the results dir
exec > >(tee "${RESULTS_DIR}/tests.log") 2>&1

# Record command line for easy re-run
printf '%q ' "$0" "$@" > "${RESULTS_DIR}/cmdline.txt"
echo >> "${RESULTS_DIR}/cmdline.txt"

run_test() {
  output=$1
  echo -e "\n=== $output === (runs for $TIME sec)"
  # start ping process in background
  (sleep $DELAY && echo "ping: started in background (runs for $PING_TIME sec)" && \
   $SUDO ip netns exec client ping -w $PING_TIME -q -i 0.1 192.168.20.2)&
  graph=$($SUDO ip netns exec client bbperf -t $TIME -u -c 192.168.20.2 -B 198.18.0.2 \
            -g -J "${RESULTS_DIR}/${output}.json" \
          | grep "created graph" | awk '{print $3}')
  mv "$graph" "${RESULTS_DIR}/bbperf-graph-${output}.png"
  # wait for background ping to complete
  wait
  # Qdisc output: Look for requeues
  $SUDO ip netns exec ${NS} tc -s qdisc ls dev ${DEV}
  # Interface stats: Look for TX dropped
  $SUDO ip -netns ${NS} -s link ls dev ${DEV}
}

$SUDO ip netns exec ${NS} tc qdisc del dev ${DEV} root 2>/dev/null || true
run_test "no_qdisc"

$SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} root fq_codel
run_test "fq_codel"

$SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} root codel
run_test "codel"

$SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} root sfq
run_test "sfq"

# For MQ tests add some more queues to the veth device
# - this will make ping test results unreliable as a drop indicator
MQs=2
$SUDO ip netns exec client ethtool --set-channels to-router   rx $MQs tx $MQs
$SUDO ip netns exec router ethtool --set-channels client-link rx $MQs tx $MQs
$SUDO ip netns exec router ethtool --set-channels server-link rx $MQs tx $MQs
$SUDO ip netns exec server ethtool --set-channels in-router   rx $MQs tx $MQs

$SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} root handle 1: mq
for sq in $($SUDO ip netns exec ${NS} tc -j qdisc show dev ${DEV} | jq -r .[].parent | grep -v null); do
  $SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} parent ${sq} fq_codel
done
run_test "mq_fq_codel_qdisc"

$SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} root handle 1: mq
for sq in $($SUDO ip netns exec ${NS} tc -j qdisc show dev ${DEV} | jq -r .[].parent | grep -v null); do
  $SUDO ip netns exec ${NS} tc qdisc replace dev ${DEV} parent ${sq} sfq
done
run_test "mq_sfq_qdisc"
