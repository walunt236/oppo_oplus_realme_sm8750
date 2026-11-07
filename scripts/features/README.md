# 功能模块清单

每个功能一个脚本：scripts/features/<name>.sh
资产目录：other_patch/<name>/
开关：<NAME>_ENABLE=true|false（由工作流输入传入，未接入的默认 true 保持原行为）

## 当前状态

### 已抽取（脚本）

| 功能 | 脚本 | 开关 | 备注 |
|---|---|---|---|
| SUSFS | features/susfs.sh | SUSFS_ENABLE | 预取/release 对齐仍留在主脚本（共用并行 wait） |
| LZ4KD | features/lz4kd.sh | LZ4KD_ENABLE | 预取留在主脚本 |
| Droidspaces | features/droidspaces.sh | DROIDSPACES_ENABLE | false 跳过，standard/extend 生效 |
| f2fs | features/f2fs.sh | F2FS_ENABLE（默认 true） | ATGC 路径 bug 已修（0aae0936） |
| libbpf | features/libbpf.sh | LIBBPF_ENABLE（默认 true） | — |

### 已抽取（配置片段）

configs/features/ 下 15 个片段：adios、droidspaces、droidspaces_extend、hz300、
kernel_tunables、ksu_susfs、lz4kd、misc_toggles、namespaces、netfilter、
perf_toggles、rcu、tmpfs、ubsan_oem、zram

config_inject.sh：587 → 136 行，配置指令序列与改造前逐行一致（151 条）。

### 未抽取（有意保留）

| 块 | 位置 | 原因 |
|---|---|---|
| KernelSU | apply_patches.sh 39-130 | 写 GITHUB_ENV/GITHUB_OUTPUT，跨 step 依赖 |
| SUSFS 预取/对齐 | apply_patches.sh 132-172 | 与 zram/WILD 共用并行 wait |
| LZ4KD 预取 | apply_patches.sh 144-148 | 同上 |
| lz4/zstd 段 | apply_patches.sh 251-313 | 与 HMBIRD/Polly 交织 |
| ADIOS/nvhe/Re-Kernel/Baseband/BBRv3/调度器 | apply_patches.sh 459-528 | 边界清楚，下一批 |
| 混合配置块（echo+sed+AFDO 交错） | config_inject.sh L43-62 | 拆开风险大 |

## 约定

1. 开关为 false 时直接 exit 0
2. 幂等：已应用则跳过
3. 日志前缀 [FEATURE]
4. 致命失败 die，实验性失败 warn
5. 配置片段放 configs/features/<name>.config
6. 新增脚本后确认 scripts/lint.sh 覆盖（已包含 scripts/features/*.sh）
