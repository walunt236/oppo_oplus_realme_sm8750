.. SPDX-License-Identifier: GPL-2.0

================================
memcomp: compressed page backing
================================

memcomp provides experimental in-memory backing for reclaimed anonymous
and shmem pages. It uses the crypto compression API and stock zsmalloc.
It does not route the first store through a swap block device. Optional
writeback can move cold payloads to real swap without replacing the
memcomp tokens held by their mappings.

This document describes the lifetime and VM integration rules. The
administrator guide describes configuration and the existing sysfs ABI.
No particular compression ratio, latency or energy saving is guaranteed.

Tokens and backing states
=========================

A dedicated non-swap entry type distinguishes memcomp tokens from real
swap offsets, migration entries and PTE markers. Enabling memcomp consumes
one of the swap-entry type values. The implementation requires 64-bit
kernels: a token must round-trip through a PTE offset, and the compression
paths must be able to address a whole folio through its local mapping.

An anonymous folio reserves a consecutive token span before reclaim
unmaps it. Each entry records its position and the size of the source
span. An entry can refer to the resident source folio, a compressed
payload, a same-filled value, or swap backing. A token identifies the
entry, not the address of a zsmalloc object or a swap slot.

Entry references include mapping and internal references. Fork acquires a
reference before copying a token PTE. Zap and MADV_FREE drop only the
references represented by the PTEs they remove. Discarding one mapping
must not invalidate another mapping's reference to the same entry.

An entry's owner relationship with a folio is distinct from the reference
that keeps a resident folio faultable. A failed store can release its
owner hold while a token that escaped rollback still refers to the
resident contents. Releasing that resident reference too early would
leave a valid PTE pointing at a freed folio.

Anonymous reclaim and rollback
==============================

Reservation requires a locked, swap-backed anonymous folio outside the
swap cache. KSM folios are excluded. Their reverse-mapping rules are not
the anonymous rules used by memcomp's restore walk; a still-merged folio
must not acquire a token even after its mapcount falls to one.

Reservation pins the anon_vma while the folio still has its mappings.
The normal single-PTE reverse-map walk then installs token PTEs and takes
the corresponding entry references. Reclaim must flush pending unmaps
before reading contents for compression.

Compression, backing allocation or a subsequent ownership check can
fail after some PTEs have changed. That is not an opportunity to overwrite
the reservation with a normal swap entry. The failure path restores
matching PTEs through the pinned anonymous reverse mapping, updates RSS
and reverse-map accounting, and drops the reservation. It re-walks a
maximum of three times while escaped references remain. The initial walk
can be retried even if it restores nothing; a later re-walk that makes no
progress stops the loop.

When every page of a large folio has been mapped back, rollback repairs
the partially-mapped deferred-split accounting. Otherwise a failed store
could leave a fully mapped folio queued as though part of it were absent.
The anonymous reverse-map pin is released on both successful store and
rollback. Entries that escaped restoration retain resident backing until
fault or invalidation resolves them.

Normal swap is a forward-progress fallback before a fresh reservation
owns post-unmap tokens. A failure after unmap restores or retains resident
backing first. An unchanged incompressible folio can take normal swap on
a later reclaim attempt instead of repeating the failed compression.

A dirty anonymous swap-cache folio gives up its swap slot so that its new
contents can be compressed again. The locked-folio check also reads dirty
state still held only in PTEs or PMDs, without clearing or write-protecting
those mappings. Checking a clean mapped folio can require a reverse-map
walk, but its usual swap-backed eviction is unchanged. Writeback or
outstanding swap references leave the folio on the normal swap path.

Compression and allocation
==========================

The allocator is zsmalloc, called directly rather than through a custom
allocator interface. Compressor selection uses the crypto API and does
not require private hints or changes to a codec. Allocation and context
admission must obey the caller's reclaim constraints.

Bounded compression contexts and detached staging buffers limit concurrent
resource occupancy and allow foreground admission to fail. They do not
guarantee bounded reclaim latency: background context acquisition and
asynchronous completion waits have no timeout. The lease
needed for a synchronous store is acquired before unmapping and consumed
by the store on every return. It is released before finishing or rolling
back the folio. Foreground admission failures can stop repeated anonymous
attempts in the current reclaim pass so that file reclaim can proceed.

Same-filled pages store the repeated value without a zsmalloc payload.
A folio whose contents did not compress can carry an incompressible mark
and a content hash in folio->swap while outside the swap cache. The mark
is not a reserved token. Reclaim recomputes the hash and clears a stale
mark when contents change; migration carries the mark with the contents.
A split cannot assume that the original whole-folio hash describes each
new smaller folio.

Payload thresholds depend on the allocator's actual class geometry.
Logical compressed length and allocator footprint are different costs.
The implementation must not assume that a threshold measured with a
modified allocator also applies to stock zsmalloc.

Asynchronous foreground batches
================================

A crypto implementation with an asynchronous form can compress a bounded
batch of already-unmapped folios in the reclaiming task's path. The
reclaimer flushes their pending TLB invalidations, submits requests,
waits for completion and then publishes the resulting payloads. Small
batches can use the synchronous path instead.

A batch does not hold the limited store leases while waiting for the
compressor. Failure to acquire a lease when publishing a completed folio
fails that store and invokes the same rollback rules. No private crypto
execution hints or independent background compression worker are needed.

Fault, migration and userfaultfd
================================

A token fault resolves the entry and its backing, prepares a folio, and
revalidates the PTE before publishing a present mapping. A concurrent zap,
move or invalidation can require retry rather than installation of stale
contents. Fault results use vm_fault_t rather than negative errno values.

A resident token must be restored where the source folio's reverse mapping
expects it. UFFDIO_MOVE first faults that token back at the source address
and retries through the present-PTE path. A nonresident exclusive token
can move like a swap entry. A stable entry reference spans the lookup and
PTE revalidation; entry locks must not be acquired while the temporary
PTE mapping keeps an RCU read-side section active.

For a present PTE, UFFDIO_MOVE checks exclusivity on the actual source
page, not the first page of its folio. Reclaim can clear exclusivity one
page at a time. A genuinely shared page remains rejected, while an
exclusive tail page is not rejected just because the head differs.

Migration transfers the resident/owner relationship together with the
contents and restores that relationship if the VM mapping transfer fails.
Splitting a folio with a live reservation is refused; rollback must first
resolve that reservation and repair deferred-split state.

Shmem and memory cgroups
========================

Shmem keeps memcomp tokens in its page-cache exceptional entries rather
than installing the anonymous reservation protocol on an inode mapping.
The writepage handoff and the swapin path balance the mapping's entry
reference separately from an anonymous folio-owner reference. Truncate,
fault races and allocation failures must undo the associated inode and
entry accounting.

Compressed storage is charged to the source folio's object cgroup, not
the task that happens to execute reclaim. Metadata and allocated payload
bytes have distinct lifetimes. A pending charge must be refunded if
allocation, publication or a competing operation prevents its transfer
to the entry. Same-filled payloads still require entry metadata.

Dropping a mapping does not necessarily destroy the backing entry. The
payload charge is refunded when allocated backing is freed, including
conversion to swap backing. The metadata charge and object-cgroup reference
remain until the RCU-delayed entry free. This is compressed-storage
accounting, not a separate per-cgroup admission controller or swap budget.
Normal VM charging is still required for folios allocated on refault.

Swap writeback
==============

Cold allocated payloads can move from the pool to real swap. Packed slots
share a swap page between multiple payloads; the hybrid representation can
also use an unpacked slot when packing does not fit. Slot ownership,
packed-member lifetime and read-cache references are balanced independently
of the mapping's token reference.

Writeback selection and its drain budget are bounded. The policy derives
its limits from total RAM rather than a device-specific memory size.
The level controller observes zsmalloc's physical pool footprint. It must
not close its feedback loop on total stored logical bytes: moving a
payload to swap leaves those bytes represented by the entry, so that
quantity does not measure memory released by writeback.

Writeback pressure scopes exclude inappropriate reclaim contexts and
avoid doing packed I/O in direct reclaim. Swapoff resolves entries backed
by the disappearing swap device into RAM, balances failures and lost
races, and does not report a failed conversion as successful. Allocation
and I/O must not recurse into reclaim under an entry lock. Conservative
packed-slot defragmentation remains separate from active pool draining.

Observability and limitations
=============================

The stable stat file reports logical stored bytes, compressed bytes and
allocator pool bytes, in that order. These are not interchangeable gauges.
Debug event counters can count repeated attempts for the same page; their
deltas are not counts of unique pages. See the ABI descriptions for each
field's units and accounting point.

The current implementation is mutually exclusive with zram and zswap,
supports only 64-bit configurations, and reserves one swap-entry type.
Its multivalue sysfs files and large implementation are RFC limitations,
not the intended final upstream interface or source layout.

Runtime validation of hibernation, memory hot-remove, DAMON and all
khugepaged interactions remains incomplete. A successful build or a test
in one VM topology does not establish coverage of those interactions.
