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

对照：未启用 memcomp 的同配置内核在同样压力下 OOM 杀掉 memhog。

## 尚未完成

- 真机刷入/启动验证
- shmem/tmpfs
- writeback
- 异步压缩
- 真机性能 A/B

## 注意

这是实验分支，不要直接当作日常主线。
