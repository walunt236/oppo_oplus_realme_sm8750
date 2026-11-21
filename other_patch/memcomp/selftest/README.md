# memcomp selftest

QEMU 6.6.143 + memcomp 结果：

    ok 1 PAGEOUT: 256 memcomp PTEs, 0 present
    ok 2 PAGEOUT/refault data integrity (all bytes)
    ok 3 refault pagemap: all pages present, not swapped
    # Totals: pass:3 fail:0 skip:5

swap 相关 4-8 因无 active swap 跳过。
