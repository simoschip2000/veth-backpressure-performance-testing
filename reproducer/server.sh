#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../venv/bin/activate"

# Use sudo for privileged commands when not running as root
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo env PATH=$PATH"

$SUDO ip netns exec server bbperf -s -B 192.168.20.2
