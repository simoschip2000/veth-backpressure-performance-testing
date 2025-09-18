#!/bin/bash
set -euo pipefail

# recreate namespaces
ip netns del server || true
ip netns del client || true
ip netns del router || true
ip netns add server
ip netns add client
ip netns add router

# setup routing between netns namespaces
ip -netns client link add dev to-router type veth peer name client-link netns router
ip -netns server link add dev in-router type veth peer name server-link netns router

# bring up devices and assign IPs
#
for n in client router server; do
        ip -n $n link set lo up
done
#
# client:
ip -netns client link set dev to-router up
ip -netns client addr add dev to-router 198.18.0.2/24
ip -netns client route add default via 198.18.0.1
#
# server:
ip -netns server link set dev in-router up
ip -netns server addr add dev in-router 192.168.20.2/24
ip -netns server route add default via 192.168.20.1
#
# router:
ip -netns router link set dev client-link up
ip -netns router addr add dev client-link 198.18.0.1/24
ip -netns router link set dev server-link up
ip -netns router addr add dev server-link 192.168.20.1/24
ip netns exec router sysctl -w net.ipv4.ip_forward=1


# force qdisc to requeue gso_skb
ip netns exec router ethtool -K server-link tso off

# Enable NAPI
ip netns exec server ethtool -K in-router gro on
# enable threaded-NAPI
ip netns exec server bash -c "echo 1 > /sys/class/net/in-router/threaded"


# needed for bbperf udp client
# ip netns exec client ip link set dev lo up

# Making NAPI thread slower via many iptables rules
ip netns exec server bash -c '
iptables-restore < <(
echo "*filter"
for n in `seq 1 5000`; do
  echo "-I INPUT -d 192.168.20.2"
done
echo "COMMIT"
)
'

# install bbperf
[ ! -d venv ] && virtualenv venv
source ./venv/bin/activate
pip3 install --upgrade bbperf
