#!/bin/bash

# Use sudo for privileged commands when not running as root
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo env PATH=$PATH"

$SUDO ip netns exec client ping -i 0.2 192.168.20.2 | stdbuf -oL awk -F'time=' '{sub(/ ms/,"",$2); print $2}' | ttyplot
