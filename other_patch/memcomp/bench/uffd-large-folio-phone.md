# 真机 UFFDIO_MOVE large folio 现象

内核：6.6.143-oneplus13-4k-aosp16-ge1b346b6b4f4 #5 (CI)

## 4K / NOHUGEPAGE

    1MB MADV_PAGEOUT 后 256 个 memcomp token
    UFFDIO_MOVE 整段 1MB
    MOVE_RET=0 moved=1048576
    VERIFY_OK

逐页搬移：

    PAGES_OK=256 PAGES_FAIL=0
    VERIFY_OK

## 64KB THP

MADV_HUGEPAGE 后按 64KB 对齐搬移：

    前 15 个 64KB chunk 成功
    最后 64KB chunk 第一次 EAGAIN moved=49152
    重试剩余 12KB/32KB 时 EEXIST
    单独只搬最后一个 64KB chunk 仍复现
    读取目标失败页会阻塞在 userfault

结论：4K 路径正常；large folio/最后 64KB 的 UFFDIO_MOVE 仍有未解决边界，需在 mm/userfaultfd.c 的 memcomp large folio 路径中定位。
