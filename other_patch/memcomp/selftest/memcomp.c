// SPDX-License-Identifier: GPL-2.0
/*
 * memcomp PAGEOUT/refault and opt-in guest swapoff tests.
 *
 * Normal execution changes no system policy and never calls swapoff().
 * PAGEOUT is best-effort: without an observed memcomp PTE, coverage is SKIP,
 * not PASS. Redacted pagemap swap types cannot prove memcomp coverage.
 * No debug-statistics ABI or global capacity delta is needed.
 *
 * The destructive test is for a disposable QEMU guest only. Boot it with
 * memcomp_selftest.allow_swapoff=1 and invoke, for example:
 *   /memcomp_selftest --swap-device /dev/vda --allow-swapoff \
 *       --swapon-flags 0
 * Run this last, after other harness stages have restored the selected swap.
 * For nonzero original flags, also pass --swapon-flags FLAGS.
 * For example, 32778 means SWAP_FLAG_PREFER | 10. Use the original swapon
 * flags, including discard policy. The test never creates or formats swap.
 * A separate recovery process restores the selected area's flags/priority
 * on control-pipe EOF, including when the test process is killed. Killing
 * the recovery process itself or losing the guest cannot be recovered here.
 * The harness must serialize swap policy changes and supply the original
 * flags: /proc/swaps exposes priority but not discard policy.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
/* A 32-bit userspace on a 64-bit kernel still needs 64-bit pagemap offsets. */
#define _FILE_OFFSET_BITS 64
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <sched.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/swap.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

#include "../kselftest.h"
#include "vm_util.h"

/* Older libc headers lack the discard-policy flags from include/linux/swap.h. */
#ifndef SWAP_FLAG_DISCARD_ONCE
#define SWAP_FLAG_DISCARD_ONCE 0x20000
#endif
#ifndef SWAP_FLAG_DISCARD_PAGES
#define SWAP_FLAG_DISCARD_PAGES 0x40000
#endif

#define MEMCOMP_SYSFS "/sys/kernel/mm/memcomp"
#define NR_PAGES 256
#define PAGEOUT_TRIES 50
#define PM_FRAME_MASK ((1ULL << 55) - 1)
#define PM_TYPE_MASK 31
/* include/linux/swap.h: 32 - SWP_MEMCOMP_NUM - SWP_PTE_MARKER_NUM. */
#define PM_MEMCOMP_TYPE 30
/* 32 types minus all possible marker, memcomp, device, migration and poison. */
#define PM_ALWAYS_REAL_TYPES (32 - 1 - 1 - 4 - 3 - 1)

struct mapping {
	unsigned char *addr;
	size_t page_size;
	size_t len;
	int pagemap_fd;
	bool show_type;
};

static struct mapping test_mapping = { .pagemap_fd = -1 };

/* Also runs on every setup error handled by a kselftest exit helper. */
static int cleanup_mapping(void)
{
	struct mapping *map = &test_mapping;
	int result = 0;

	if (map->addr && map->addr != MAP_FAILED) {
		if (munmap(map->addr, map->len)) {
			ksft_print_msg("munmap: %s\n", strerror(errno));
			result = -1;
		}
		map->addr = NULL;
	}
	if (map->pagemap_fd >= 0) {
		if (close(map->pagemap_fd)) {
			ksft_print_msg("close pagemap: %s\n", strerror(errno));
			result = -1;
		}
		map->pagemap_fd = -1;
	}
	return result;
}

static void cleanup_on_exit(void)
{
	cleanup_mapping();
}

struct page_state {
	unsigned int present;
	unsigned int swapped;
	unsigned int compressed;
	unsigned int real_swapped;
};

struct swap_area {
	char path[PATH_MAX];
	unsigned long long used;
	int priority;
	int count;
};

struct options {
	const char *swap_path;
	int swapon_flags;
	bool have_flags;
	bool allow_swapoff;
	bool rewrite_only;
};

static void usage(const char *prog)
{
	printf("Usage: %s [--rewrite-only |\n", prog);
	printf("       --swap-device PATH --allow-swapoff --swapon-flags FLAGS]\n");
	printf("No arguments: PAGEOUT/refault and swap-cache checks; no swapoff.\n"
	       "--rewrite-only runs only the swap-cache checks, without swapoff.\n"
	       "Swapoff requires root, QEMU, and the guest boot argument\n"
	       "memcomp_selftest.allow_swapoff=1. FLAGS are the original\n"
	       "numeric swapon(2) flags (priority and discard policy).\n"
	       "FLAGS is required for exact restoration; use 0 when the original\n"
	       "swapon call used no flags. Run last with swap already active.\n");
}

static void parse_options(int argc, char **argv, struct options *opts)
{
	static const struct option long_opts[] = {
		{ "allow-swapoff", no_argument, NULL, 'a' },
		{ "allow-guest-swapoff", no_argument, NULL, 'a' },
		{ "swap-device", required_argument, NULL, 's' },
		{ "swapoff", required_argument, NULL, 's' },
		{ "swapon-flags", required_argument, NULL, 'f' },
		{ "rewrite-only", no_argument, NULL, 'r' },
		{ "help", no_argument, NULL, 'h' },
		{ }
	};
	unsigned long flags;
	char *end;
	int c;

	while ((c = getopt_long(argc, argv, "", long_opts, NULL)) != -1) {
		switch (c) {
		case 'a':
			opts->allow_swapoff = true;
			break;
		case 's':
			opts->swap_path = optarg;
			break;
		case 'f':
			errno = 0;
			flags = strtoul(optarg, &end, 0);
			if (errno || !*optarg || *end || flags > INT_MAX ||
			    flags & ~(SWAP_FLAG_PREFER | SWAP_FLAG_PRIO_MASK |
				      SWAP_FLAG_DISCARD | SWAP_FLAG_DISCARD_ONCE |
				      SWAP_FLAG_DISCARD_PAGES))
				ksft_exit_fail_msg("Invalid swapon flags\n");
			opts->swapon_flags = flags;
			opts->have_flags = true;
			break;
		case 'r':
			opts->rewrite_only = true;
			break;
		case 'h':
			usage(argv[0]);
			exit(KSFT_PASS);
		default:
			ksft_exit_fail_msg("Invalid option; use --help\n");
		}
	}
	if (optind != argc ||
	    (opts->rewrite_only &&
	     (opts->swap_path || opts->allow_swapoff || opts->have_flags)) ||
	    ((opts->swap_path || opts->allow_swapoff || opts->have_flags) &&
	     !(opts->swap_path && opts->allow_swapoff && opts->have_flags)))
		ksft_exit_fail_msg("Swapoff needs --swap-device --allow-swapoff --swapon-flags\n");
}

static unsigned char pattern(size_t page, size_t offset)
{
	/* Repeating but neither all-zero nor same-filled; vary every page. */
	return (page * 37 + (page >> 8) * 17 + (offset % 64) * 13 + 1) & 255;
}

static void fill_mapping(struct mapping *map)
{
	size_t page, offset;

	for (page = 0; page < NR_PAGES; page++)
		for (offset = 0; offset < map->page_size; offset++)
			map->addr[page * map->page_size + offset] =
				pattern(page, offset);
}

static bool check_data(struct mapping *map)
{
	unsigned char *addr = map->addr;
	size_t page, offset;

	for (page = 0; page < NR_PAGES; page++) {
		for (offset = 0; offset < map->page_size; offset++) {
			if (addr[page * map->page_size + offset] !=
			    pattern(page, offset)) {
				ksft_print_msg("Data mismatch: page %zu byte %zu\n",
					       page, offset);
				return false;
			}
		}
	}
	return true;
}

static int read_entry(struct mapping *map, size_t page, uint64_t *entry)
{
	uint64_t index;
	ssize_t ret;

	/* Keep malformed/incomplete setup from reaching the pagemap offset math. */
	if (!map->page_size) {
		errno = EINVAL;
		return -1;
	}
	index = (uintptr_t)map->addr / map->page_size + page;

	do {
		ret = pread(map->pagemap_fd, entry, sizeof(*entry),
			    index * sizeof(*entry));
	} while (ret < 0 && errno == EINTR);
	if (ret == sizeof(*entry))
		return 0;
	if (ret >= 0)
		errno = EIO;
	return -1;
}

static int scan_mapping(struct mapping *map, struct page_state *state)
{
	uint64_t entry;
	size_t page;

	memset(state, 0, sizeof(*state));
	for (page = 0; page < NR_PAGES; page++) {
		if (read_entry(map, page, &entry))
			return -1;
		/* Every page was written: neither holes nor dual states are valid. */
		if (!!(entry & PM_PRESENT) == !!(entry & PM_SWAP)) {
			ksft_print_msg("Invalid pagemap state on page %zu\n", page);
			errno = EINVAL;
			return -1;
		}
		if (entry & PM_PRESENT) {
			state->present++;
		} else {
			state->swapped++;
			if (map->show_type &&
			    (entry & PM_TYPE_MASK) == PM_MEMCOMP_TYPE)
				state->compressed++;
			else if (map->show_type &&
				 (entry & PM_TYPE_MASK) < PM_ALWAYS_REAL_TYPES)
				state->real_swapped++;
		}
	}
	return 0;
}

static bool same_swap_area(const char *wanted, const char *listed)
{
	struct stat wanted_stat, listed_stat;

	if (!wanted || stat(wanted, &wanted_stat) || stat(listed, &listed_stat))
		return false;
	if (S_ISBLK(wanted_stat.st_mode) && S_ISBLK(listed_stat.st_mode))
		return wanted_stat.st_rdev == listed_stat.st_rdev;
	if (S_ISREG(wanted_stat.st_mode) && S_ISREG(listed_stat.st_mode))
		return wanted_stat.st_dev == listed_stat.st_dev &&
			wanted_stat.st_ino == listed_stat.st_ino;
	return false;
}

/* Return 1 if found, 0 if absent, -1 on an unreadable/malformed swap list. */
static int find_swap(const char *path, struct swap_area *area)
{
	char name[PATH_MAX], type[32];
	unsigned long long size, used;
	char *line = NULL;
	size_t len = 0;
	FILE *file;
	int priority, found = 0;

	memset(area, 0, sizeof(*area));
	file = fopen("/proc/swaps", "re");
	if (!file)
		return -1;
	if (getline(&line, &len, file) < 0 ||
	    sscanf(line, "%4095s %31s", name, type) != 2 ||
	    strcmp(name, "Filename") || strcmp(type, "Type")) {
		found = -1;
		goto out;
	}
	while (getline(&line, &len, file) >= 0) {
		if (sscanf(line, "%4095s %31s %llu %llu %d",
			   name, type, &size, &used, &priority) != 5) {
			found = -1;
			break;
		}
		area->count++;
		if (path && same_swap_area(path, name)) {
			strcpy(area->path, name);
			area->used = used;
			area->priority = priority;
			found = 1;
		}
	}
	if (ferror(file))
		found = -1;
out:
	free(line);
	fclose(file);
	if (found < 0)
		errno = EIO;
	return found;
}

static int pageout_mapping(struct mapping *map, struct page_state *state)
{
	unsigned int attempt;

	/* Migration entries also have PM_SWAP; absence of disk swap is no proof. */
	if (!map->show_type) {
		memset(state, 0, sizeof(*state));
		return 0;
	}
	for (attempt = 0; attempt < PAGEOUT_TRIES; attempt++) {
		if (madvise(map->addr, map->len, MADV_PAGEOUT)) {
			if (errno == EINVAL || errno == ENOSYS || errno == EOPNOTSUPP) {
				ksft_print_msg("MADV_PAGEOUT unavailable: %s\n",
					       strerror(errno));
				return 0;
			}
			return -1;
		}
		if (scan_mapping(map, state))
			return -1;
		if (state->compressed)
			return 1;
		usleep(20000);
	}
	return 0;
}

/* Keep the same mapping across swap-in and rewrite: this is not a fresh VMA. */
static bool random_mapping(struct mapping *map, bool verify)
{
	uint64_t seed = 0x7a1d93ef2468bc05ULL;
	size_t offset;

	for (offset = 0; offset < map->len; offset += sizeof(seed)) {
		uint64_t word;

		seed ^= seed >> 12;
		seed ^= seed << 25;
		seed ^= seed >> 27;
		word = seed * 0x2545f4914f6cdd1dULL;
		if (verify) {
			if (memcmp(map->addr + offset, &word, sizeof(word)))
				return false;
		} else {
			memcpy(map->addr + offset, &word, sizeof(word));
		}
	}
	return true;
}

static int pageout_all(struct mapping *map, struct page_state *state,
		       bool compressed)
{
	unsigned int attempt;

	for (attempt = 0; attempt < PAGEOUT_TRIES; attempt++) {
		if (madvise(map->addr, map->len, MADV_PAGEOUT) ||
		    scan_mapping(map, state))
			return -1;
		if (compressed ? state->compressed == NR_PAGES :
		    state->real_swapped == NR_PAGES)
			return 1;
		usleep(20000);
	}
	return 0;
}

static void skip_rewrite(const char *reason)
{
	ksft_test_result_skip("clean swap-cache eviction: %s\n", reason);
	ksft_test_result_skip("dirty swap-cache rewrite: %s\n", reason);
	ksft_test_result_skip("dirty swap-cache rewrite integrity: %s\n", reason);
}

static void test_dirty_swapcache_rewrite(struct mapping *map)
{
	struct page_state state = {};
	struct swap_area area;
	int result;

	if (!map->show_type) {
		skip_rewrite("pagemap swap types are unavailable");
		return;
	}
	if (find_swap(NULL, &area) < 0) {
		ksft_test_result_fail("swap-cache setup: read /proc/swaps\n");
		goto skip_tail;
	}
	if (!area.count) {
		skip_rewrite("no active swap; not applicable");
		return;
	}
	if (madvise(map->addr, map->len, MADV_DONTNEED)) {
		ksft_test_result_fail("swap-cache reset: %s\n", strerror(errno));
		goto skip_tail;
	}
	random_mapping(map, false);
	result = pageout_all(map, &state, false);
	if (result != 1 || !random_mapping(map, true)) {
		ksft_test_result_fail("real-swap setup: rc=%d real=%u memcomp=%u present=%u\n",
				      result,
				      state.real_swapped, state.compressed,
				      state.present);
		goto skip_tail;
	}
	/* A read-only refault must not turn a clean cached copy into memcomp. */
	result = pageout_all(map, &state, false);
	ksft_test_result(result == 1 && random_mapping(map, true),
			 "clean swap-cache eviction retains normal swap: rc=%d real=%u memcomp=%u\n",
			 result, state.real_swapped,
			 state.compressed);
	if (result != 1)
		goto skip_tail;
	/* The read fault retains its swap-cache slot; dirty the same folios. */
	fill_mapping(map);
	result = pageout_all(map, &state, true);
	ksft_test_result(result == 1,
			 "dirty swap-cache rewrite enters memcomp: rc=%d memcomp=%u real=%u present=%u\n",
			 result,
			 state.compressed, state.real_swapped, state.present);
	ksft_test_result(check_data(map),
			 "dirty swap-cache rewrite integrity (all bytes)\n");
	return;
skip_tail:
	ksft_test_result_skip("dirty swap-cache rewrite: setup failed\n");
	ksft_test_result_skip("rewrite integrity: setup failed\n");
}

static bool file_has(const char *path, const char *text)
{
	char buffer[8192];
	ssize_t len;
	int fd;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return false;
	do {
		len = read(fd, buffer, sizeof(buffer));
	} while (len < 0 && errno == EINTR);
	close(fd);
	if (len <= 0)
		return false;
	/* Device-tree compatible is a NUL-separated string list. */
	return !!memmem(buffer, len, text, strlen(text));
}

static bool guest_authorized(void)
{
	struct utsname uts;
	char buffer[8192], *token, *save;
	bool authorized = false;
	ssize_t len;
	int fd;

	/* WSL is a host for this purpose, despite running under a hypervisor. */
	if (uname(&uts) || strcasestr(uts.release, "microsoft"))
		return false;
	fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return false;
	do {
		len = read(fd, buffer, sizeof(buffer) - 1);
	} while (len < 0 && errno == EINTR);
	close(fd);
	if (len <= 0 || len == sizeof(buffer) - 1)
		return false;
	buffer[len] = 0;
	for (token = strtok_r(buffer, "\n ", &save); token;
	     token = strtok_r(NULL, "\n ", &save))
		if (!strcmp(token, "memcomp_selftest.allow_swapoff=1"))
			authorized = true;
	return authorized &&
		(file_has("/sys/class/dmi/id/sys_vendor", "QEMU") ||
		 file_has("/sys/class/dmi/id/product_name", "QEMU") ||
		 file_has("/sys/class/dmi/id/product_name", "KVM") ||
		 file_has("/proc/device-tree/model", "QEMU") ||
		 file_has("/proc/device-tree/compatible", "linux,dummy-virt") ||
		 file_has("/proc/device-tree/compatible", "riscv-virtio"));
}

static int wait_child(pid_t child)
{
	int status;
	pid_t ret;

	do {
		ret = waitpid(child, &status, 0);
	} while (ret < 0 && errno == EINTR);
	return ret == child && WIFEXITED(status) && !WEXITSTATUS(status) ? 0 : -1;
}

static int restore_swap(struct swap_area *saved, int flags)
{
	struct swap_area current;
	int found, attempt;

	for (attempt = 0; attempt < 3; attempt++) {
		found = find_swap(saved->path, &current);
		if (found == 1)
			return current.priority == saved->priority &&
			current.count == saved->count ? 0 : -1;
		if (!found && !swapon(saved->path, flags))
			continue;
		usleep(100000);
	}
	found = find_swap(saved->path, &current);
	return found == 1 && current.priority == saved->priority &&
		current.count == saved->count ? 0 : -1;
}

/* Recovery is armed before the parent can disable any swap. */
static pid_t start_recovery(struct mapping *map, struct swap_area *saved,
			    int flags, int *control)
{
	int pipefd[2], ready[2];
	char byte;
	ssize_t ret;
	pid_t child;

	if (pipe2(pipefd, O_CLOEXEC))
		return -1;
	if (pipe2(ready, O_CLOEXEC)) {
		close(pipefd[0]);
		close(pipefd[1]);
		return -1;
	}
	fflush(NULL);
	child = fork();
	if (!child) {
		close(pipefd[1]);
		close(ready[0]);
		/* Ignore harness termination, including process-group SIGKILL. */
		if (setsid() < 0 || signal(SIGINT, SIG_IGN) == SIG_ERR ||
		    signal(SIGTERM, SIG_IGN) == SIG_ERR ||
		    signal(SIGHUP, SIG_IGN) == SIG_ERR)
			_exit(1);
		/* Drop inherited memcomp references before allowing swapoff. */
		if (munmap(map->addr, map->len) || close(map->pagemap_fd))
			_exit(1);
		byte = 'R';
		do {
			ret = write(ready[1], &byte, 1);
		} while (ret < 0 && errno == EINTR);
		if (ret != 1)
			_exit(1);
		close(ready[1]);
		do {
			ret = read(pipefd[0], &byte, 1);
		} while (ret > 0 || (ret < 0 && errno == EINTR));
		close(pipefd[0]);
		if (restore_swap(saved, flags)) {
			dprintf(STDERR_FILENO, "memcomp: RESTORE FAILED for %s; "
				"run swapon with flags %#x\n", saved->path, flags);
			_exit(1);
		}
		_exit(0);
	}
	close(pipefd[0]);
	close(ready[1]);
	if (child < 0) {
		close(pipefd[1]);
		close(ready[0]);
		return -1;
	}
	do {
		ret = read(ready[0], &byte, 1);
	} while (ret < 0 && errno == EINTR);
	close(ready[0]);
	if (ret != 1 || byte != 'R') {
		close(pipefd[1]);
		wait_child(child);
		return -1;
	}
	*control = pipefd[1];
	return child;
}

static void skip_swapoff(const char *reason)
{
	ksft_test_result_skip("swapoff integrity: %s\n", reason);
	ksft_test_result_skip("swap restoration: %s\n", reason);
}

static void test_swapoff(struct mapping *map, struct options *opts)
{
	struct swap_area saved, current;
	struct page_state state;
	char path[PATH_MAX];
	struct stat st;
	pid_t recovery;
	int result, control, off_errno = 0;
	bool intact = false, inactive = false;
	const char *p;

	if (!opts->allow_swapoff) {
		skip_swapoff("not explicitly authorized (default is non-destructive)");
		return;
	}
	if (!guest_authorized() || geteuid()) {
		skip_swapoff("requires authorized disposable QEMU guest and root");
		return;
	}
	if (!realpath(opts->swap_path, path) || stat(path, &st) ||
	    !(S_ISBLK(st.st_mode) || S_ISREG(st.st_mode))) {
		ksft_test_result_fail("swapoff: invalid swap path\n");
		ksft_test_result_skip("swap restoration: no swap disabled\n");
		return;
	}
	/* /proc/swaps escapes such paths; reject instead of misidentifying one. */
	for (p = path; *p; p++) {
		if (isspace((unsigned char)*p) || *p == '\\') {
			skip_swapoff("swap path contains unsupported whitespace/escape");
			return;
		}
	}
	result = find_swap(path, &saved);
	if (result <= 0) {
		if (result < 0)
			ksft_test_result_fail("swapoff: cannot read /proc/swaps\n");
		else
			ksft_test_result_skip("swapoff: selected area is not active\n");
		ksft_test_result_skip("swap restoration: no swap disabled\n");
		return;
	}
	if ((opts->swapon_flags & SWAP_FLAG_PREFER) ?
	    saved.priority != (opts->swapon_flags & SWAP_FLAG_PRIO_MASK) :
	    (saved.priority != -2 || saved.count != 1)) {
		/* Removing an automatic-priority area renumbers the other areas. */
		skip_swapoff("original flags/priority cannot be reliably restored");
		return;
	}
	fill_mapping(map);
	result = pageout_mapping(map, &state);
	if (result <= 0) {
		if (result < 0)
			ksft_test_result_fail("swapoff setup PAGEOUT: %s\n", strerror(errno));
		else
			ksft_test_result_skip("swapoff: no memcomp PTE observed\n");
		ksft_test_result_skip("swap restoration: no swap disabled\n");
		return;
	}
	if (find_swap(path, &current) != 1 ||
	    current.priority != saved.priority || current.count != saved.count) {
		ksft_test_result_fail("swapoff setup: selected swap changed\n");
		ksft_test_result_skip("swap restoration: no swap disabled\n");
		return;
	}
	recovery = start_recovery(map, &saved, opts->swapon_flags, &control);
	if (recovery < 0) {
		ksft_test_result_fail("swapoff: cannot arm recovery process\n");
		ksft_test_result_skip("swap restoration: no swap disabled\n");
		return;
	}
	if (swapoff(path)) {
		off_errno = errno;
	} else {
		inactive = find_swap(path, &current) == 0;
		intact = check_data(map);
	}
	/* No exit helper is used between swapoff and closing the recovery pipe. */
	close(control);
	result = wait_child(recovery);
	if (off_errno)
		intact = check_data(map);
	if (!off_errno)
		ksft_test_result(inactive && intact,
				 "swapoff with memcomp PTEs preserves data\n");
	else if (!intact)
		ksft_test_result_fail("failed swapoff corrupted test data\n");
	else if (off_errno == ENOMEM || off_errno == EPERM || off_errno == EACCES ||
		 off_errno == EBUSY)
		ksft_test_result_skip("swapoff: %s\n", strerror(off_errno));
	else
		ksft_test_result_fail("swapoff: %s\n", strerror(off_errno));
	if (result || find_swap(path, &current) != 1 ||
	    current.priority != saved.priority || current.count != saved.count)
		ksft_test_result_fail("restore selected swap and original priority\n");
	else if (off_errno)
		ksft_test_result_skip("swap restoration: swapoff did not disable swap\n");
	else
		ksft_test_result_pass("restore selected swap and original priority\n");
}

int main(int argc, char **argv)
{
	struct mapping *map = &test_mapping;
	struct options opts = { };
	struct page_state state;
	struct stat st;
	uint64_t entry;
	long page_size;
	size_t page;
	int cpu, result;
	bool intact;
	cpu_set_t mask;

	ksft_print_header();
	/* MADV_PAGEOUT only drains the current CPU's LRU batch. */
	cpu = sched_getcpu();
	if (cpu < 0) {
		ksft_print_msg("cannot get current CPU: %s\n", strerror(errno));
	} else if (cpu >= CPU_SETSIZE) {
		ksft_print_msg("current CPU exceeds affinity mask capacity\n");
	} else {
		CPU_ZERO(&mask);
		CPU_SET(cpu, &mask);
		if (sched_setaffinity(0, sizeof(mask), &mask))
			ksft_print_msg("cannot pin current CPU: %s\n",
				       strerror(errno));
	}
	parse_options(argc, argv, &opts);
	if (atexit(cleanup_on_exit))
		ksft_exit_fail_msg("cannot register cleanup\n");
	if (stat(MEMCOMP_SYSFS, &st)) {
		if (errno == ENOENT || errno == ENOTDIR)
			ksft_exit_skip(MEMCOMP_SYSFS " is absent\n");
		ksft_exit_fail_msg("stat memcomp sysfs: %s\n", strerror(errno));
	}
	if (!S_ISDIR(st.st_mode))
		ksft_exit_fail_msg("memcomp sysfs is not a directory\n");
	map->pagemap_fd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
	if (map->pagemap_fd < 0) {
		if (errno == EACCES || errno == EPERM || errno == ENOENT)
			ksft_exit_skip("pagemap is unavailable: %s\n", strerror(errno));
		ksft_exit_fail_msg("open pagemap: %s\n", strerror(errno));
	}
	page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0 || (size_t)page_size > SIZE_MAX / NR_PAGES)
		ksft_exit_fail_msg("Invalid page size\n");
	map->page_size = page_size;
	map->len = NR_PAGES * map->page_size;
	map->addr = mmap(NULL, map->len, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (map->addr == MAP_FAILED)
		ksft_exit_fail_msg("mmap: %s\n", strerror(errno));
	/* Isolate base-page behavior; THP=n kernels may reject this advice. */
	if (madvise(map->addr, map->len, MADV_NOHUGEPAGE) && errno != EINVAL)
		ksft_exit_fail_msg("MADV_NOHUGEPAGE: %s\n", strerror(errno));
	fill_mapping(map);
	for (page = 0; page < NR_PAGES; page++) {
		if (read_entry(map, page, &entry))
			ksft_exit_fail_msg("read pagemap: %s\n", strerror(errno));
		if ((entry & PM_PRESENT) && (entry & PM_FRAME_MASK))
			map->show_type = true;
	}
	ksft_set_plan(opts.rewrite_only ? 3 : 8);
	if (opts.rewrite_only) {
		test_dirty_swapcache_rewrite(map);
		goto out;
	}
	result = pageout_mapping(map, &state);
	if (result < 0) {
		ksft_test_result_fail("PAGEOUT/pagemap: %s\n", strerror(errno));
	} else if (!result) {
		ksft_test_result_skip("PAGEOUT: no memcomp PTE observed; "
				      "pressure/admission or redacted swap type\n");
	} else {
		ksft_test_result_pass("PAGEOUT: %u memcomp PTEs, %u present\n",
				      state.compressed, state.present);
	}
	intact = check_data(map);
	if (!intact)
		ksft_test_result_fail("PAGEOUT/refault data integrity\n");
	else if (result <= 0)
		ksft_test_result_skip("refault integrity: memcomp not exercised\n");
	else
		ksft_test_result_pass("PAGEOUT/refault data integrity (all bytes)\n");
	if (scan_mapping(map, &state))
		ksft_test_result_fail("refault pagemap: %s\n", strerror(errno));
	else if (result <= 0 || !intact)
		ksft_test_result_skip("refault pagemap: no successful memcomp refault\n");
	else if (state.present != NR_PAGES)
		ksft_test_result_skip("refault pagemap: pages reclaimed again under pressure\n");
	else
		ksft_test_result_pass("refault pagemap: all pages present, not swapped\n");
	test_dirty_swapcache_rewrite(map);
	if (ksft_get_fail_cnt())
		skip_swapoff("core test failed; no swapoff attempted");
	else
		test_swapoff(map, &opts);
out:
	if (cleanup_mapping())
		ksft_exit_fail();
	if (ksft_get_fail_cnt())
		ksft_exit_fail();
	if (!ksft_get_pass_cnt()) {
		ksft_print_cnts();
		return KSFT_SKIP;
	}
	ksft_finished();
}
