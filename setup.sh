#!/bin/bash
set -euo pipefail

# recreate namespaces
ip netns del server || true
ip netns del client || true
ip netns add server
ip netns add client

# set up veth pair
ip netns exec client ip link add dev to-server type veth peer name in-server netns server

# force qdisc to requeue gso_skb
ip netns exec client ethtool -K to-server tso off

# Enable NAPI
ip netns exec server ethtool -K in-server gro on

# bring up devices and assign ips
ip netns exec client ip link set dev to-server up
ip -netns server link set dev in-server up
ip netns exec client ip addr add dev to-server 192.168.20.1/24
ip -netns server addr add dev in-server 192.168.20.2/24

ip netns exec server bash -c "echo 1 > /sys/class/net/in-server/threaded"

# needed for bbperf udp client
ip netns exec client ip link set dev lo up

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
