# memcomp 6.6.143 实验分支

实验开关：

    MEMCOMP_ENABLE=true

源码 overlay：

    other_patch/memcomp/memcomp-overlay.tar.gz

## 当前状态

已打通匿名页回收压缩路径，QEMU 压力测试通过：

- CONFIG_MEMCOMP=y
- CONFIG_LRU_GEN=y / ENABLED=y
- CONFIG_ZRAM=n
- CONFIG_ZSWAP=n

测试前：

    0 0 0

压力中：

    373854208 3275060 4444160

无 Bad swap、无 WARNING、无 OOM、无 panic。

## 对照结果

同配置、同压力、同 init：

无 memcomp：

    Out of memory: Killed process (memhog)

有 memcomp：

    memhog touched 1400 MB in 4351.3 ms
    memcomp stat = 373854208 3275060 4444160
    MemFree ~908 MB
    无 OOM/WARNING/panic

说明 memcomp 在压力下能压缩匿名页并避免 OOM。
测试使用了人为高 watermark，且大部分是零页，压缩比不代表真实负载。

## 尚未完成

- 真机刷入/启动验证
- shmem/tmpfs
- writeback
- 异步压缩
- 真机性能 A/B

## 注意

这是实验分支，不要直接当作日常主线。

## shmem 尝试记录

0006 的 shmem 最小接入已尝试，但在 QEMU tmpfs 压力下出现：

    get_swap_device: Bad swap file entry
    Kernel panic

当前已回退 mm/shmem.c，保留已验证的匿名页路径。shmem 需要补齐 load/invalidate 路径后再启用。

## GitHub CI

memcomp 构建已通过：

    run 31 success
    AnyKernel3-none-none-6.6.143-memcomp-ci-20261119.zip

该次使用 ksu_type=none、afdo_mode=off 验证打包链路。
KSU + AutoFDO 完整配置仍需补测。

## CI 产物启动验证

CI artifact Image 已在 QEMU 验证（CPU max，Oryon 指令集）：

    before: 0 0 0
    under:  359686144 3160300 4657152
    after:  427139072 3750559 5406720

无 memcomp 崩溃；末尾 panic 仅为 init 主动退出。

## 完整配置 CI + QEMU 验证

GitHub Actions run 32 success：

    ksu_type=ksu
    susfs_enable=false
    afdo_mode=use
    memcomp_enable=true
    AnyKernel3-KSU-32734-6.6.143-memcomp-ksu-20261119.zip

CI Image 已在 QEMU（-cpu max）启动：

    before: 0 0 0
    under:  270876672 2383140 3682304
    after:  36864 2413 69632

无 memcomp 崩溃；末尾 panic 仅为 init 主动退出。

## 模式数据压力测试

1400MB 可压缩 pattern，min_free=500MB：

无 memcomp：

    touched 1400 MB in 1900.4 ms
    MemFree 544228 kB
    Inactive(anon) 0 kB

有 memcomp：

    touched 1400 MB in 1525.8 ms
    stat 242323456 16505098 17403904
    MemAvailable 16300 kB

单次结果，仅用于功能验证，不作为最终性能结论。

## shmem/tmpfs 接入

补齐了 shmem swapin 的 memcomp load/invalidate 路径。QEMU tmpfs 压力测试：

    before: 0 0 0
    pressure: 422699008 149349 2437120
    after: 138362880 422731 3616768

无 WARNING/Bad swap/OOM。

## shmem 数据一致性验证

QEMU tmpfs 写入 400MB pattern，memhog 1100MB 压力后读回校验：

    VERIFY_OK 400 MB
    pressure stat: 339181568 23607871 28016640

无 WARNING/Bad swap/OOM。

## CI 产物 shmem 数据完整性

CI 构建的 KSU+AFDO+memcomp+shmem Image 在 QEMU 验证：

    shmemtest wrote 400 MB
    VERIFY_OK 400 MB
    MemAvailable: 1672 kB

无 WARNING/Bad swap/OOM；末尾 panic 仅为 init 退出。

## 重复基准

pattern 1400MB，3 次：

memcomp: 1529.1 / 1530.6 / 1513.5 ms
baseline: 1468.1 / 2843.0 / 1460.3 ms

QEMU 噪声大，不能据此宣称速度提升。

## 大页测试

已加入恢复后 large folio 的 deferred split 处理（0010）。QEMU THP 压力下未崩溃，但 memcomp stat 仍为 0，说明大页回收路径尚未真正触发压缩。

## THP 复测

1000MB MADV_HUGEPAGE + 700MB 第二进程，min_free=200MB：

    memcomp stat 仍为 0 0 0
    AnonHugePages 约 1.65GB
    无 WARNING/Bad swap/OOM

large folio 的 memcomp 压缩路径仍未打通。

## 最新 CI

run 34 success：

    AnyKernel3-KSU-32734-6.6.143-memcomp-thp-20261119.zip

包含 shmem + large folio deferred split。

## large folio 上限说明

MEMCOMP_MAX_COMPRESS_PAGES=16，即单次最多 16 页（64KB）。
QEMU 测试使用 2MB PMD 大页（512 页），超出上限，stat=0 属于预期，不是崩溃。
0010 只处理 1..16 页恢复后的 deferred split。

## 回滚说明

- 日常主线 main 未被修改
- 所有实验改动在 memcomp-6.6
- 回滚只需切回 main / 恢复 boot 备份
- 实验内核关闭 ZRAM/ZSWAP，不能直接作为日常启动项

## UFFDIO_MOVE 修复

真机发现 ART MarkCompact 报：

    ioctl_userfaultfd: move failed: Bad address

补入 0001 每页 exclusivity 检查与 0004 memcomp entry move 支持。
