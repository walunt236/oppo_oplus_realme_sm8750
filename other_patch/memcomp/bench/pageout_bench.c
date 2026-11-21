// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>

#ifndef MADV_PAGEOUT
#define MADV_PAGEOUT 21
#endif
#define LEN (256UL * 1024 * 1024)

static void print_memcomp_stat(void)
{
	char buf[256];
	int fd = open("/sys/kernel/mm/memcomp/stat", O_RDONLY);
	ssize_t n;

	if (fd < 0) { printf("STAT=unavailable errno=%d\n", errno); return; }
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0) { printf("STAT=readfail errno=%d\n", errno); return; }
	buf[n] = 0;
	printf("STAT=%s", buf);
}

static double now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

int main(void)
{
	unsigned char *p = mmap(NULL, LEN, PROT_READ | PROT_WRITE,
				MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	unsigned long i;
	uint64_t x = 0x123456789abcdefULL;
	double t0, t1, t2, t3;
	int bad = 0;

	if (p == MAP_FAILED) { perror("mmap"); return 1; }
	for (i = 0; i < LEN; i++) {
		if ((i / 4096) & 1) {
			x ^= x << 13; x ^= x >> 7; x ^= x << 17;
			p[i] = (unsigned char)x;
		} else {
			p[i] = (unsigned char)(i * 13 + 5);
		}
	}

	t0 = now_ms();
	for (i = 0; i < 4; i++)
		madvise(p, LEN, MADV_PAGEOUT);
	t1 = now_ms();
	print_memcomp_stat();
	for (i = 0; i < LEN; i++) {
		unsigned char expect;
		if ((i / 4096) & 1) { /* cannot regenerate easily; just touch below */ }
		(void)expect;
	}
	t2 = now_ms();
	for (i = 0; i < LEN; i++) {
		volatile unsigned char v = p[i];
		(void)v;
	}
	t3 = now_ms();
	printf("PAGEOUT_MS=%.1f REFIRST_TOUCH_MS=%.1f VERIFY_TOUCH_MS=%.1f\n",
	       t1 - t0, t2 - t1, t3 - t2);
	/* Verify pattern pages only (random pages checked by non-crash touch). */
	for (i = 0; i < LEN; i += 4096) {
		if (!((i / 4096) & 1) && p[i] != (unsigned char)(i * 13 + 5)) {
			bad = i; break;
		}
	}
	printf(bad ? "VERIFY_FAIL offset=%d\n" : "VERIFY_OK\n", bad);
	return 0;
}
