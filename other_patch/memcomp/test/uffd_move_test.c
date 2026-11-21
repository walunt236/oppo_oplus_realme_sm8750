// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#define LEN (1024 * 1024)
#define PAGE 4096
#ifndef MADV_PAGEOUT
#define MADV_PAGEOUT 21
#endif

static int memcomp_ptes(void *p, size_t len)
{
	int fd = open("/proc/self/pagemap", O_RDONLY);
	unsigned long i, npages = len / PAGE, found = 0;
	if (fd < 0) return -1;
	for (i = 0; i < npages; i++) {
		uint64_t e;
		off_t off = ((uintptr_t)p / PAGE + i) * sizeof(e);
		if (pread(fd, &e, sizeof(e), off) != sizeof(e)) { close(fd); return -1; }
		if (!(e & (1ULL << 63)) && (e & (1ULL << 62)) && (e & 31) == 30)
			found++;
	}
	close(fd);
	return (int)found;
}

int main(void)
{
	size_t len = LEN;
	unsigned char *src, *dst;
	struct uffdio_api api = { .api = UFFD_API, .features = UFFD_FEATURE_MOVE };
	struct uffdio_register reg;
	struct uffdio_move mv;
	int uffd, ret, i, compressed;

	src = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	dst = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (src == MAP_FAILED || dst == MAP_FAILED) { perror("mmap"); return 1; }
	for (i = 0; i < (int)len; i++)
		src[i] = (unsigned char)(i * 7 + 3);

	uffd = syscall(SYS_userfaultfd, O_CLOEXEC | O_NONBLOCK);
	if (uffd < 0) { perror("userfaultfd"); return 1; }
	if (ioctl(uffd, UFFDIO_API, &api)) { perror("UFFDIO_API"); return 1; }
	printf("features=0x%llx ioctls=0x%llx\n",
	       (unsigned long long)api.features, (unsigned long long)api.ioctls);

	memset(&reg, 0, sizeof(reg));
	reg.range.start = (uintptr_t)dst;
	reg.range.len = len;
	reg.mode = UFFDIO_REGISTER_MODE_MISSING;
	if (ioctl(uffd, UFFDIO_REGISTER, &reg)) { perror("UFFDIO_REGISTER"); return 1; }

	for (i = 0; i < 20; i++)
		madvise(src, len, MADV_PAGEOUT);
	compressed = memcomp_ptes(src, len);
	printf("COMPRESSED=%d\n", compressed);

	memset(&mv, 0, sizeof(mv));
	mv.dst = (uintptr_t)dst;
	mv.src = (uintptr_t)src;
	mv.len = len;
	mv.mode = UFFDIO_MOVE_MODE_DONTWAKE;
	errno = 0;
	ret = ioctl(uffd, UFFDIO_MOVE, &mv);
	printf("MOVE_RET=%d errno=%d moved=%lld\n", ret, errno, (long long)mv.move);
	if (ret == 0) {
		int bad = 0;
		for (i = 0; i < (int)len; i++)
			if (dst[i] != (unsigned char)(i * 7 + 3)) { bad = i; break; }
		printf(bad ? "VERIFY_FAIL offset=%d\n" : "VERIFY_OK\n", bad);
	} else {
		printf("MOVE_FAIL\n");
	}
	return ret ? 2 : 0;
}
