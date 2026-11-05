# BORE 调度器移植（未验证，未接入构建）

本目录保存把 BORE（Burst-Oriented Response Enhancer）移植到 6.6.143 基线的工作快照。

## 状态

- 代码已移植完成，但从未成功编译验证（一次构建在配置检查阶段失败，原因是测试脚本误重置了工作区，不是代码问题）
- 未接入任何构建流程：scripts/ 里没有任何地方引用它，默认构建不受影响
- 保留它只是避免丢失移植成果

## 移植内容

- kernel/sched/bore.c —— 新增（443 行，BORE 核心）
- include/linux/sched/bore.h —— 新增（40 行，接口声明）
- include/linux/sched.h —— struct sched_burst_cache + sched_entity 的 7 个字段
- kernel/sched/fair.c —— 21 处 BORE 挂钩（sysctl、update_curr、place_entity 等）
- kernel/sched/core.c —— include + sched_bore_init()
- kernel/sched/sched.h —— 2 处 extern 替换
- kernel/sched/Makefile —— obj-$(CONFIG_SCHED_BORE) += bore.o
- kernel/fork.c —— include + sched_clone_bore()
- init/Kconfig —— config SCHED_BORE（default n）
- arch/arm64/configs/gki_defconfig —— CONFIG_SCHED_BORE=y

## 重要：OEM 兼容性

自动生成的 diff 会误删 OPPO 的三行内容，移植时已手工恢复：

    #include <trace/hooks/sched.h>
    #include <trace/hooks/dtask.h>
    EXPORT_TRACEPOINT_SYMBOL_GPL(sched_stat_runtime);

重新生成补丁时务必确认这三行还在，否则会破坏 OPPO 厂商模块的 trace hook。

## 启用方式（验证通过后再做）

1. git apply patches/bore/bore-6.6.143.patch
2. 确认 CONFIG_SCHED_BORE=y
3. 编译 + 真机验证

## 上游

https://github.com/firelzrd/bore-scheduler （6.6-bore 分支）
