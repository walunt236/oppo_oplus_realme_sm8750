# GitHub Actions run 37

- branch memcomp-6.6, head 7a66ed78
- inputs: ksu_type=ksu, memcomp_enable=true, susfs_enable=false
- result: success
- config: CONFIG_MEMCOMP=y, CONFIG_ZRAM unset, CONFIG_ZSWAP unset, CONFIG_KSU=y, no SUSFS

Artifact:
AnyKernel3-KSU-32734-6.6.143-oneplus13-4k-aosp16-20261119.zip

QEMU on the CI image:
- memcomp_selftest: pass:3 fail:0 skip:5
- UFFDIO_MOVE test: 256 compressed PTEs, MOVE_RET=0, moved=1048576, VERIFY_OK

## shmem pressure check on CI image

tmpfs 1500M, memhog 1100MB background, memcomp enabled:

    VERIFY_OK 400 MB
    MemAvailable: 1296 kB

No WARNING/Bad swap/OOM in the run.
