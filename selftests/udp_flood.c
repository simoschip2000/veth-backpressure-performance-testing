// SPDX-License-Identifier: GPL-2.0
/*
 * UDP flood generator with per-packet timestamps for latency measurement.
 * Used by veth_bql_test.sh to stress-test BQL under sustained load.
 *
 * Usage: udp_flood <ip> <pkt_size> <port> <duration> [max_pkt_size] [label] [burst_pkts:pause_us]
 */
#include <arpa/inet.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static volatile int running = 1;

static void stop(int sig) { running = 0; }

struct pkt_hdr {
	struct timespec ts;
	unsigned long seq;
};

int main(int argc, char **argv)
{
	struct sockaddr_in dst;
	struct pkt_hdr hdr;
	unsigned long count = 0;
	char buf[1500];
	int sndbuf = 1048576;
	int pkt_size, max_pkt_size;
	int cur_size;
	int duration;
	int burst_pkts = 0;   /* 0 = continuous (no burst) */
	int burst_pause_us = 0;
	int fd;

	const char *label = "flood";

	if (argc < 5) {
		fprintf(stderr, "Usage: %s <ip> <pkt_size> <port> <duration> [max_pkt_size] [label] [burst_pkts:pause_us]\n",
			argv[0]);
		return 1;
	}

	pkt_size = atoi(argv[2]);
	if (pkt_size < (int)sizeof(struct pkt_hdr))
		pkt_size = sizeof(struct pkt_hdr);
	if (pkt_size > (int)sizeof(buf))
		pkt_size = sizeof(buf);
	max_pkt_size = (argc > 5 && argv[5][0] != '\0') ? atoi(argv[5]) : pkt_size;
	if (max_pkt_size < pkt_size)
		max_pkt_size = pkt_size;
	if (max_pkt_size > (int)sizeof(buf))
		max_pkt_size = sizeof(buf);
	duration = atoi(argv[4]);
	if (argc > 6)
		label = argv[6];
	if (argc > 7) {
		char *colon = strchr(argv[7], ':');
		if (colon) {
			burst_pkts = atoi(argv[7]);
			burst_pause_us = atoi(colon + 1);
			fprintf(stderr, "  %s: burst mode %d pkts, %d us pause\n",
				label, burst_pkts, burst_pause_us);
		}
	}

	memset(&dst, 0, sizeof(dst));
	dst.sin_family = AF_INET;
	dst.sin_port = htons(atoi(argv[3]));
	inet_pton(AF_INET, argv[1], &dst.sin_addr);

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		perror("socket");
		return 1;
	}

	/* Raise send buffer so sk_wmem_alloc limit doesn't cap
	 * in-flight packets before the ptr_ring (256 entries) fills.
	 * Default wmem_default ~208K only allows ~93 packets.
	 */
	setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

	memset(buf, 0xAA, sizeof(buf));
	signal(SIGINT, stop);
	signal(SIGTERM, stop);
	signal(SIGALRM, stop);
	alarm(duration);

	while (running) {
		if (max_pkt_size > pkt_size)
			cur_size = pkt_size + (rand() % (max_pkt_size - pkt_size + 1));
		else
			cur_size = pkt_size;
		clock_gettime(CLOCK_MONOTONIC, &hdr.ts);
		hdr.seq = count;
		memcpy(buf, &hdr, sizeof(hdr));
		sendto(fd, buf, cur_size, MSG_DONTWAIT,
		       (struct sockaddr *)&dst, sizeof(dst));
		count++;
		if (!(count % 10000000))
			fprintf(stderr, "  %s: %lu M packets\n",
				label, count / 1000000);

		/* Burst mode: send burst_pkts, then pause */
		if (burst_pkts > 0 && (count % burst_pkts) == 0)
			usleep(burst_pause_us);
	}

	fprintf(stderr, "  %s: total %lu packets (%.1f M)\n",
		label, count, (double)count / 1e6);
	close(fd);
	return 0;
}
