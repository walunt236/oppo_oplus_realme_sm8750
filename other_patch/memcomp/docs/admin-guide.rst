.. SPDX-License-Identifier: GPL-2.0

======================
memcomp administration
======================

memcomp is an experimental compressed backing store for anonymous and
shmem/tmpfs pages. It keeps compressed payloads in RAM before using block
I/O and can write cold payloads to real swap. It is not a block device and
does not require a zram device or a swap file as its initial storage layer.

Configuration
=============

Enable ``CONFIG_MEMCOMP`` in a 64-bit kernel with MMU, crypto and swap
support. ``CONFIG_SWAP=y`` is required even when no swap device is active.
The option selects stock zsmalloc, the crypto compression interface and
xxhash; it does not require modified allocator or codec code.

``CONFIG_ZRAM`` must be ``n``, not ``m``. ``CONFIG_ZSWAP`` must also be
``n``. Coexistence is not supported in this version. Enabling memcomp
reserves one swap-entry type, reducing the available swap-device types.

``CONFIG_MEMCOMP_DEFAULT_COMPRESSOR`` names the default crypto compressor
and defaults to ``zstd``. Build the desired compressor into the kernel or
make it available during initialization. For zstd this includes
``CONFIG_CRYPTO_ZSTD``. The exact registered crypto name matters.

``CONFIG_MEMCOMP_DEBUG_STATS`` adds diagnostic counters and hot-path
accounting. Enable it for validation and controlled measurement; disclose
its setting when comparing results. It is not required for the two
core read-only attributes.

The ``memcomp.compressor=<name>`` command-line option overrides the
configured default. Initialization waits up to ten seconds for a late
algorithm registration, falls back to zstd if selection or setup fails,
and leaves memcomp disabled if the fallback also fails. Check the kernel
log and the reported compressor instead of assuming the request worked.
There is no ``memcomp.fast=`` option in this implementation.

Inspecting the pool
===================

After successful initialization, inspect::

    cat /sys/kernel/mm/memcomp/stat
    cat /sys/kernel/mm/memcomp/compressor

``stat`` returns three decimal byte counts: logical stored bytes,
compressed bytes and allocator pool bytes, in that order. ``compressor``
reports the selected crypto algorithm. The implementation uses zsmalloc directly;
there is no allocator-selection attribute.

Logical bytes are not physical RAM usage. Same-filled entries, metadata,
allocator fragmentation and swap-backed entries have different costs.
Do not interpret a single ratio or the pool byte count as a complete
measurement of memory saved. In particular, writing a payload to swap
does not remove the logical data represented by its token. The first two
stat values retain swap-backed entries and are not resident-RAM gauges.
Pending reservations are not committed compressed capacity.

Additional nodes exist only with debug statistics enabled. Their fields
are documented in
``Documentation/ABI/testing/sysfs-kernel-mm-memcomp``. Take snapshots
around the measured workload and subtract counters with matching units.
Counters can include repeated attempts on the same page; they do not
necessarily count distinct pages. Gauges and high-water marks are not
cumulative event counters.

Swap and memory pressure
========================

Real swap is optional for in-memory stores. If it is available, normal VM
swap can provide fallback before token ownership, and memcomp can write
cold payloads back using packed or unpacked swap slots. Writeback limits
are derived from total RAM, not from a fixed device-specific capacity.
The pool is not a preallocated reservation of that fraction of RAM.

Storage can fail because data is incompressible, memory-cgroup charging
fails, an execution resource is unavailable, allocation fails, or a VM
race changes the source mapping. A failure after unmap restores matching
PTEs or retains resident backing before releasing ownership. It does not
immediately overwrite the token span with normal swap entries.

Unchanged incompressible contents are marked to avoid repeatedly paying
compression cost. Modified contents can be retried. Same-filled contents
need entry metadata but no allocated compressed payload. KSM-merged
folios are excluded from anonymous memcomp reservation.

``swapoff`` must resolve memcomp entries backed by the removed swap area.
This can require RAM and can fail; a successful swapoff is not a promise
that the compressed pool became empty. Do not use swapoff as an eviction
or reset interface for memcomp.

Memory cgroups
==============

Entry metadata and compressed payload storage are charged to the source
folio's object cgroup rather than to the task doing reclaim. This is not
a separate memcomp quota, target or per-cgroup writeback controller.
Refaulted folios still follow the VM's ordinary memory-cgroup charging.
Observe the normal cgroup memory interfaces as well as memcomp statistics
when applying memory limits.

Validation
==========

Run destructive pressure and swapoff tests in a disposable VM. Building a
kernel or running KUnit does not validate every reclaim topology or
workload. Keep the source revision, effective configuration, command and
complete log with each result.

The dedicated KUnit configuration is
``mm/memcomp/tests/.kunitconfig``. For example::

    python3 tools/testing/kunit/kunit.py run --arch=x86_64 \
        --kunitconfig=mm/memcomp/tests/.kunitconfig \
        --build_dir=<kunit-output> --jobs=<jobs> 'memcomp*'

Tests that call madvise are registered only when
``CONFIG_ADVISE_SYSCALLS=y``. A configuration that omits the syscall does
not exercise those MADV_FREE cases; do not report the full configuration's
case count for that build. KSM flag rejection in KUnit does not replace a
real merge/pageout regression test.

The MM selftest is built separately from the kernel::

    selftest_out="$(pwd)/selftest-out"
    mkdir -p "$selftest_out"
    make -C tools/testing/selftests/mm OUTPUT="$selftest_out" \
        "$selftest_out/memcomp_selftest"

The accompanying harness covers pageout/refault, ownership churn,
userfaultfd moves, shmem and swapoff. Match its requested features and
resources to the guest configuration. A skipped feature is not proof of
runtime coverage on a kernel that enables that feature.

Known limitations
=================

This is an RFC implementation based on Linux 6.12. The swap-entry encoding,
64-bit restriction, mutual exclusion with zram/zswap, multivalue sysfs ABI
and source layout need further work before an upstream submission.

Runtime coverage of hibernation, memory hot-remove, DAMON and all
khugepaged interactions remains incomplete. VM correctness tests and
relative VM measurements do not establish real-device latency, energy or
compatibility. Device validation must use the intended release image and
be reported separately from development-tree results.
