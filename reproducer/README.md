# veth Backpressure Reproducer

Chris Arges' dark-buffer latency reproducer. Demonstrates how veth's
256-entry `ptr_ring` acts as a "dark buffer" hidden from the qdisc,
causing head-of-line blocking and ping drops under sustained UDP load.

This is the test that motivated the upstream veth BQL patchset:
[[PATCH net-next v5 0/5] veth: add Byte Queue Limits (BQL) support](https://lore.kernel.org/all/20260505132159.241305-1-hawk@kernel.org/)

## Files

| File         | Description                                                |
|--------------|------------------------------------------------------------|
| `setup.sh`   | Create netns + veth pair + iptables rules + install bbperf |
| `server.sh`  | Run `bbperf` UDP server in the server netns                |
| `tests.sh`   | Run 6 qdisc configurations, save bbperf graphs + JSON      |
| `ping.sh`    | Live ping RTT plot via `ttyplot`                           |

## Topology

```
client (198.18.0.2) <-> router <-> server (192.168.20.2)
                          |
                  qdisc on server-link
                  (where backpressure should land)
```

The server netns has 5000 iptables rules to slow NAPI processing,
creating sustained backpressure on the router's `server-link` txq.

## Prerequisites

```bash
apt install python3-virtualenv gnuplot ttyplot jq ethtool iptables
```

Root is required for `ip netns` operations.

## Run

From the repo root, in two terminals:

```bash
# Terminal 1: create namespaces, install bbperf into ../venv
sudo ./reproducer/setup.sh

# Terminal 2: start bbperf server
sudo ./reproducer/server.sh
```

Then in terminal 1, run the test sweep (~6 min):

```bash
sudo ./reproducer/tests.sh
```

This runs 6 qdisc configurations on the router's egress towards the
server:

- `no_qdisc` -- baseline, no qdisc shaping
- `fq_codel` -- single-queue fq_codel
- `codel`    -- single-queue codel
- `sfq`      -- single-queue sfq
- `mq_fq_codel_qdisc` -- multi-queue (2 channels) with fq_codel per queue
- `mq_sfq_qdisc`      -- multi-queue (2 channels) with sfq per queue

Each test runs for `TIME=60` seconds (set in `tests.sh`) with a
background ping started 5s after the elephant flow ramps up.

## Output

Test runs write results to `../results/reproducer/<timestamp>/` with a
`latest` symlink pointing to the most recent run. Each run directory
contains:

- `tests.log` -- full stdout/stderr of the run
- `cmdline.txt` -- the exact command line used
- `bbperf-graph-<test>.png` -- bbperf throughput/latency graphs
- `<test>.json` -- raw bbperf JSON output

Reference results from earlier runs (host names rather than
timestamps) are committed under `../results/reproducer/` for
comparison.

## Interpreting Results

Look for:

- **Ping drops or high RTT** -- indicates dark-buffer head-of-line blocking
- **`tc -s qdisc` requeues** -- packets bouncing between qdisc and dark buffer
- **Interface TX dropped** -- packets dropped at the veth driver layer

Without BQL, even queue-aware qdiscs like fq_codel cannot prevent
latency spikes because their backlog is empty -- the bytes are stuck
in the invisible `ptr_ring` downstream.
