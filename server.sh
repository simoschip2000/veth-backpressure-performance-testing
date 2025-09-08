#!/bin/bash

source ./venv/bin/activate
ip netns exec server bbperf -s -B 192.168.20.2
