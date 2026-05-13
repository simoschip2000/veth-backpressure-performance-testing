#!/bin/bash
set -euo pipefail

# Repo root is the parent dir of this script's location
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Use sudo for privileged commands when not running as root
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo env PATH=$PATH"

#MQ=yes
MQ=no

# recreate namespaces
$SUDO ip netns del server || true
$SUDO ip netns del client || true
$SUDO ip netns del router || true
$SUDO ip netns add server
$SUDO ip netns add client
$SUDO ip netns add router

# setup routing between netns namespaces
if [[ "${MQ}" == "yes" ]]; then
  $SUDO ip -netns client link add dev to-router type veth peer name client-link netns router numtxqueues 8 numrxqueues 8
  $SUDO ip -netns server link add dev in-router type veth peer name server-link netns router numtxqueues 8 numrxqueues 8
else
  $SUDO ip -netns client link add dev to-router type veth peer name client-link netns router
  $SUDO ip -netns server link add dev in-router type veth peer name server-link netns router
fi

# bring up devices and assign IPs
#
for n in client router server; do
        $SUDO ip -n $n link set lo up
done
#
# client:
$SUDO ip -netns client link set dev to-router up
$SUDO ip -netns client addr add dev to-router 198.18.0.2/24
$SUDO ip -netns client route add default via 198.18.0.1
#
# server:
$SUDO ip -netns server link set dev in-router up
$SUDO ip -netns server addr add dev in-router 192.168.20.2/24
$SUDO ip -netns server route add default via 192.168.20.1
#
# router:
$SUDO ip -netns router link set dev client-link up
$SUDO ip -netns router addr add dev client-link 198.18.0.1/24
$SUDO ip -netns router link set dev server-link up
$SUDO ip -netns router addr add dev server-link 192.168.20.1/24
$SUDO ip netns exec router sysctl -w net.ipv4.ip_forward=1


# force qdisc to requeue gso_skb
$SUDO ip netns exec router ethtool -K server-link tso off

# Enable NAPI
$SUDO ip netns exec server ethtool -K in-router gro on
# enable threaded-NAPI
$SUDO ip netns exec server bash -c "echo 1 > /sys/class/net/in-router/threaded"


# needed for bbperf udp client
# ip netns exec client ip link set dev lo up

# Making NAPI thread slower via many iptables rules
$SUDO ip netns exec server bash -c '
iptables-restore < <(
echo "*filter"
for n in `seq 1 5000`; do
  echo "-I INPUT -d 192.168.20.2"
done
echo "COMMIT"
)
'

# install bbperf (shared venv at repo root; selftests may use it too)
[ ! -d "${REPO_ROOT}/venv" ] && virtualenv "${REPO_ROOT}/venv"
source "${REPO_ROOT}/venv/bin/activate"
pip3 install --upgrade bbperf
