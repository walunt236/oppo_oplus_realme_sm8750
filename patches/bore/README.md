
## 适配状态（2026-11-06 更新）：**未完成，开启会编译失败**

### 阻塞点 1：代码结构不兼容

BORE 的 6.6 分支基于 6.6.6x，而 6.6.143 重构了 fair.c：

- 143 的 update_curr() 拆成了 update_curr_se() 和 update_curr_task()
- 143 的 reweight_entity() 是 static，BORE 需要导出它

机械移植会产生这些错误：

    fair.c:1197: call to undeclared function 'update_curr_se'
    fair.c:1215: static declaration of 'update_curr_task' follows non-static declaration
    fair.c:1240: redefinition of 'update_curr'
    fair.c:3899: static declaration of 'reweight_entity' follows non-static declaration

需要按 6.6.143 的实际结构逐函数改写，不是套补丁能解决的。

### 阻塞点 2：KMI / 厂商模块不兼容

BORE 往 struct sched_entity 里插入 7 个字段（约 64 字节），会让后面字段的偏移全部改变。

而 OPPO 的厂商模块直接读这些字段：

- se->vlag（7 处）—— 在插入点之后，偏移会变
- se->slice（2 处）
- se->parent（1 处，指针）
- se->my_q（1 处，指针）

指针读错位 = 解引用野指针 = 内核崩溃 = 无限重启。
这些模块是预编译的，我们无法重编。

### 结论

BORE 在当前条件下不可用。开关默认关闭，开启会导致编译失败。
要真正启用，需要：
1. 按 6.6.143 的 fair.c 结构重写 BORE 挂钩
2. 解决 sched_entity 布局问题（目前无解，除非能重编厂商模块）

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
