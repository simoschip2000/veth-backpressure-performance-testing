#!/bin/bash

ip netns exec client ping -i 0.2 -I 192.168.20.1 192.168.20.2 | stdbuf -oL awk -F'time=' '{sub(/ ms/,"",$2); print $2}' | ttyplot
