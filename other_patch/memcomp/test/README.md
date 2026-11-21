# UFFDIO_MOVE memcomp test

编译：

    aarch64-linux-gnu-gcc -static -O2 uffd_move_test.c -o uffd_move_test

QEMU 6.6.143 + memcomp 结果：

    features=0x14ffe ioctls=0x8000000000000003
    COMPRESSED=256
    MOVE_RET=0 errno=0 moved=1048576
    VERIFY_OK

说明：源范围 256 个 memcomp PTE，UFFDIO_MOVE 成功搬移 1MB，目标数据校验通过。
