# veth Backpressure Performance Testing

Tools for testing and measuring veth qdisc backpressure and BQL (Byte
Queue Limits) behavior. This repository contains two independent test suites:

## Backpressure Reproducer (root directory)

The original dark-buffer latency reproducer by Chris Arges. Demonstrates
how veth's 256-entry ptr_ring acts as a "dark buffer" hidden from the
qdisc, causing head-of-line blocking and ping drops under load.

### Install dependencies

```bash
apt install python3-virtualenv gnuplot ttyplot jq ethtool iptables
```

### Run

```bash
./setup.sh              # create netns + veth pair + iptables rules
./server.sh             # in another terminal: start bbperf UDP server
./tests.sh              # run tests: no_qdisc, fq_codel, codel, sfq,
                        #            mq_fq_codel_qdisc, mq_sfq_qdisc
```

Results are written to stdout. Graphs are saved as PNG files in the
current directory.

## BQL Selftest (`selftests/`)

Stress test for the veth BQL patchset. Exercises BQL code paths under
sustained UDP load, measures latency reduction, and detects DQL
accounting bugs.

See [selftests/README.md](selftests/README.md) for full documentation.

### Quick start

```bash
cd /path/to/kernel-tree
/path/to/selftests/veth_bql_test_virtme.sh --qdisc fq_codel --hist
```

## Related

- Upstream patchset: [[PATCH net-next v5 0/5] veth: add Byte Queue Limits (BQL) support](https://lore.kernel.org/all/20260505132159.241305-1-hawk@kernel.org/)

## License

GPL-2.0
