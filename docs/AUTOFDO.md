# AutoFDO 指南

本仓库支持基于设备实测采样的 AutoFDO（Sample PGO）构建。

## 三种模式

| `afdo_mode` | 作用 | 产物 |
|---|---|---|
| `off`（默认） | 不启用 | — |
| `generate` | 构建**可采样内核**：加 `-fdebug-info-for-profiling`，产出带调试信息的 vmlinux | `~/.cache_patches/afdo/vmlinux-<时间戳>` |
| `use` | 用 profile 做优化构建 | 内核镜像 |

`use` 模式下 profile 的选取优先级：

1. `~/.cache_patches/afdo/kernel.afdo`（自采样本）
2. 内核源码树自带的 Google GKI profile（`android/gki/aarch64/afdo/kernel.afdo`）

## 为什么不用 llvm-profgen

`llvm-profgen` 的 `checkPerfScriptType()` **只接受带 LBR 分支记录的样本**（x86 常见，arm64 几乎没有）：

```
simpleperf record -b → branch stack sampling is not supported on this device
simpleperf record -e cs-etm → etm devices are not available（bootloader 未开启）
```

因此本仓库改用 `scripts/perf2afdo.py`：直接解析 perf.data 的样本 IP、
用 vmlinux 符号表 + DWARF 行号聚合计数，生成 LLVM sample profile 文本。

支持两种采样格式：

| 采样命令 | sample_type | 处理方式 |
|---|---|---|
| `simpleperf record -a --duration N` | 纯 IP | 直接用样本 IP |
| `simpleperf record -a --call-graph fp --duration N` | IP + 调用栈 | 取调用栈叶子 |

## 完整流程

### 1. 构建可采样内核

派发工作流，`afdo_mode = generate`。构建日志末尾会输出：

```
[INFO] AutoFDO 生成模式 配置生效
[INFO] 可采样 vmlinux 已保存: ~/.cache_patches/afdo/vmlinux-20261106-1711 (482M)
[INFO] vmlinux 指纹: ddf3681e3aeb53da
```

刷入这个内核。**采样必须在这个内核上做**（见下方“常见错误”）。

### 2. 设备采样

```bash
# 通用场景（推荐 30 分钟）
simpleperf record -a -o /data/local/tmp/perf_daily.data --duration 1800

# 游戏场景（推荐 15 分钟）
simpleperf record -a -o /data/local/tmp/perf_game.data --duration 900
```

采样期间正常使用手机，覆盖：滑动、冷启动应用、相机、视频、游戏、文件拷贝、网页、待机。

### 3. 转换与合并

```bash
# 单份
scripts/afdo_collect.sh perf_daily.data

# 多份（按样本量加权合并）
scripts/afdo_collect.sh perf_daily.data perf_game.data
```

权重规则：合并时计数相加，权重 ∝ 时长 × 采样率。想放大某一份就把它的文件名多写几次：

```bash
# 日用:游戏 = 1:1（游戏权重翻倍）
scripts/afdo_collect.sh perf_daily.data perf_game.data perf_game.data
```

输出示例：

```
[INFO] 总样本=9856722 内核叶子=5059621 唯一地址=76270 运行时基址=0xffffffdd5a010000
[INFO] 函数=4307 行条目=28260 未映射地址=15817 内核样本覆盖率=91.8%
[OK] 已安装: ~/.cache_patches/afdo/kernel.afdo (352K, 4307 个函数, hash=91d5d8fc)
[INFO] 已记录校验信息 (符号表 hash=4de5fbf632921814)
```

### 4. 优化构建

派发工作流，`afdo_mode = use`。日志确认：

```
[INFO] AutoFDO 使用自采样本
[INFO] AutoFDO 状态: ENABLE=true GENERATE=false GEN_ONLY=0 PROFILE=... 有效=1
[INFO] profile 与 vmlinux 符号表一致（4de5fbf632921814）
[INFO] AutoFDO profile 符号匹配率: 99.7% (4293/4307)
```

## 常见错误

### 在 AFDO 内核上采样

**错误**。AFDO 内核的代码布局已被优化，在它上面采样会形成反馈回路：

- 布局改变导致行级计数漂移
- 内联决策改变导致函数边界不同
- 结果自我强化，profile 越来越偏

而且此时 `vmlinux.latest` 仍指向 generate 构建，地址映射会**静默出错**。

正确做法：采样前刷回 `generate` 内核。

### 采样后重新构建 generate

如果转换完 profile 又跑了一次 `generate` 构建，`vmlinux.latest` 会被新内核覆盖，
旧 profile 就与新 vmlinux 不对应了。

`afdo_collect.sh` 会记录 vmlinux 符号表 hash，`use` 模式构建时会自动比对，
不一致直接报错：

```
[ERROR] 自采 profile 与当前 vmlinux 符号表不一致（采样后内核已变过）
```

### 匹配率异常偏低

`AutoFDO profile 符号匹配率` 正常应在 95% 以上。如果只有 50% 左右，先检查：

1. 是否用了错误的 vmlinux（采样内核与 `vmlinux.latest` 不一致）
2. 内核源码是否有大幅变动

> 历史问题：早期版本 `sort`/`comm` 未加 `LC_ALL=C`，区域排序会导致误报 53%，已修复。

## 技术细节

### KASLR 处理

perf.data 里带 `[kernel.kallsyms]_stext` 的 mmap 事件，记录了内核运行时基址。
`perf2afdo.py` 用它把样本 IP 换算成 vmlinux 链接地址：

```
链接地址 = 运行地址 - 运行时基址 + vmlinux._stext
```

因此**每次重启都不影响采样**，但采样内核必须与 vmlinux 来自同一次构建。

### 符号与行号

```
llvm-nm --defined-only -S vmlinux   → 函数地址表（二分查找定位）
llvm-symbolizer --obj=vmlinux       → 地址 → 源码行号
```

### 覆盖率

- 内核态叶子样本：只统计落在 vmlinux 文本区间内的样本
- 用户态样本、vendor 模块样本：自动丢弃（无法优化，也无源码）
- 典型覆盖率 91%～94%（剩余部分多为汇编无符号区域）

## 与 GKI profile 的对比

| 指标 | GKI profile | 自采（15 分钟游戏） |
|---|---|---|
| 函数数 | 8,631 | 4,307 |
| 来源 | 千万设备平均 | 单设备真实使用 |
| 优势 | 覆盖广 | 贴合个人使用 |
| 劣势 | 不含设备特有路径 | 冷门函数覆盖少 |

两者热点函数高度一致（我们 82.6% 的函数在 GKI 中也有），因此自采样本足以支撑优化。
