# QEMU A/B: baseline vs memcomp

Both kernels 6.6.143, QEMU virt 2 GiB, 4 vCPU, memhog 1900 MB mode 2.

## baseline (no memcomp, no zram/zswap)

    Out of memory: Killed process (memhog)
    anon-rss: 1663812 kB
    MemFree after kill: 1897796 kB

## memcomp

    no OOM
    memcomp stat: 314523648 3363921 7651328
    MemFree: 446704 kB
    MemAvailable: 0 kB
    AnonHugePages: 1372160 kB

结论：同等 2 GiB 压力下 baseline 触发 OOM，memcomp 通过压缩避免了 OOM。
