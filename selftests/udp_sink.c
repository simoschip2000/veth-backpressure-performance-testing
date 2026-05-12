// SPDX-License-Identifier: GPL-2.0
/*
 * UDP sink with per-packet latency measurement and drop/reorder tracking.
 * Used by veth_bql_test.sh to measure latency under load.
 *
 * Usage: udp_sink <port> [label]
 */
#include <arpa/inet.h>
#include <math.h>
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

static const char *label = "sink";

static void print_periodic(unsigned long count, unsigned long delta_count,
			   double delta_sec, unsigned long drops,
			   unsigned long reorders,
			   double lat_min, double lat_sum,
			   double lat_max)
{
	unsigned long pps;

	if (!count)
		return;
	pps = delta_sec > 0 ? (unsigned long)(delta_count / delta_sec) : 0;
	fprintf(stderr, "  %s: %lu pkts (%lu pps)  drops=%lu  reorders=%lu"
		"  latency min/avg/max = %.3f/%.3f/%.3f ms\n",
		label, count, pps, drops, reorders,
		lat_min * 1e3, (lat_sum / count) * 1e3,
		lat_max * 1e3);
}

static void print_final(unsigned long count, double elapsed_sec,
			unsigned long drops, unsigned long reorders,
			double lat_min, double lat_sum,
			double lat_sum_sq, double lat_max)
{
	unsigned long pps;
	double avg, stddev;

	if (!count)
		return;
	pps = elapsed_sec > 0 ? (unsigned long)(count / elapsed_sec) : 0;
	avg = lat_sum / count;
	stddev = sqrt(lat_sum_sq / count - avg * avg);
	fprintf(stderr, "  %s: %lu pkts (%lu avg pps)  drops=%lu  reorders=%lu"
		"  latency min/avg/max/stddev = %.3f/%.3f/%.3f/%.3f ms\n",
		label, count, pps, drops, reorders,
		lat_min * 1e3, avg * 1e3,
		lat_max * 1e3, stddev * 1e3);
}

int main(int argc, char **argv)
{
	unsigned long next_seq = 0, drops = 0, reorders = 0;
	double lat_min = 1e9, lat_max = 0, lat_sum = 0, lat_sum_sq = 0;
	unsigned long count = 0, last_count = 0;
	struct sockaddr_in addr;
	char buf[2048];
	int fd, one = 1;

	if (argc < 2) {
		fprintf(stderr, "Usage: %s <port> [label]\n", argv[0]);
		return 1;
	}
	if (argc >= 3)
		label = argv[2];

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		perror("socket");
		return 1;
	}
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

	/* Timeout so recv() unblocks periodically to check 'running' flag.
	 * Needed because glibc signal() sets SA_RESTART, so SIGTERM
	 * does not interrupt recv().
	 */
	struct timeval tv = { .tv_sec = 1 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(atoi(argv[1]));
	addr.sin_addr.s_addr = INADDR_ANY;
	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("bind");
		return 1;
	}

	signal(SIGINT, stop);
	signal(SIGTERM, stop);

	struct timespec t_start, t_last_print;

	clock_gettime(CLOCK_MONOTONIC, &t_start);
	t_last_print = t_start;

	while (running) {
		struct pkt_hdr hdr;
		struct timespec now;
		ssize_t n;
		double lat;

		n = recv(fd, buf, sizeof(buf), 0);
		if (n < (ssize_t)sizeof(struct pkt_hdr))
			continue;

		clock_gettime(CLOCK_MONOTONIC, &now);
		memcpy(&hdr, buf, sizeof(hdr));

		/* Track drops (gaps) and reorders (late arrivals) */
		if (hdr.seq > next_seq)
			drops += hdr.seq - next_seq;
		if (hdr.seq < next_seq)
			reorders++;
		if (hdr.seq >= next_seq)
			next_seq = hdr.seq + 1;

		lat = (now.tv_sec - hdr.ts.tv_sec) +
		      (now.tv_nsec - hdr.ts.tv_nsec) * 1e-9;

		if (lat < lat_min)
			lat_min = lat;
		if (lat > lat_max)
			lat_max = lat;
		lat_sum += lat;
		lat_sum_sq += lat * lat;
		count++;

		{
			double since_print;

			since_print = (now.tv_sec - t_last_print.tv_sec) +
				      (now.tv_nsec - t_last_print.tv_nsec) * 1e-9;
			if (since_print >= 5.0) {
				print_periodic(count, count - last_count,
					       since_print, drops,
					       reorders, lat_min,
					       lat_sum, lat_max);
				last_count = count;
				t_last_print = now;
			}
		}
	}

	{
		struct timespec t_now;
		double elapsed;

		clock_gettime(CLOCK_MONOTONIC, &t_now);
		elapsed = (t_now.tv_sec - t_start.tv_sec) +
			  (t_now.tv_nsec - t_start.tv_nsec) * 1e-9;
		print_final(count, elapsed, drops, reorders,
			    lat_min, lat_sum, lat_sum_sq, lat_max);
	}
	close(fd);
	return 0;
}
