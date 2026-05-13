#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../venv/bin/activate"

ip netns exec server bbperf -s -B 192.168.20.2
