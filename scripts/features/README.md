# 功能模块清单

每个功能一个脚本：scripts/features/<name>.sh
资产目录：other_patch/<name>/
开关：优先沿用原工作流变量；原块无开关的新增 <NAME>_ENABLE（默认 true，保持原行为）

## 当前状态

### 已抽取（脚本）

| 功能 | 脚本 | 开关 | 备注 |
|---|---|---|---|
| KernelSU | features/kernelsu.sh | KSU_TYPE != none | 版本号写 GITHUB_ENV/GITHUB_OUTPUT；KSU_TAG_DATE 经 /tmp/ksu_state.env 回传主脚本 |
| SUSFS | features/susfs.sh | SUSFS_ENABLE | 预取/release 对齐仍留在主脚本（共用并行 wait） |
| LZ4KD | features/lz4kd.sh | LZ4KD_ENABLE | 预取留在主脚本 |
| lz4/zstd | features/lz4zstd.sh | LZ4ZSTD_ENABLE（默认 true） | 原块 178-240；lz4accel 拉取、002-zstd 过滤随块搬迁 |
| Droidspaces | features/droidspaces.sh | DROIDSPACES_ENABLE | false 跳过，standard/extend 生效 |
| ADIOS | features/adios.sh | ADIOS_ENABLE（默认 true） | — |
| KVM NVHE | features/nvhe.sh | NVHE_ENABLE（默认 true） | AutoFDO .rel.llvm 元数据兼容 |
| Re-Kernel | features/rekernel.sh | REKERNEL_ENABLE | 沿用原变量，默认关闭 |
| Baseband-guard | features/baseband.sh | BASEBAND_GUARD | 沿用原变量，含 LSM 注入校验 |
| BBRv3 | features/bbr3.sh | BBR3_ENABLE（默认 true） | — |
| 调度器 | features/sched.sh | SCHED_ENABLE（默认 true） | NEXT_BUDDY / HRTICK / SIS_PROP / CACHE_HOT_BUDDY / LB_MIN |
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
| SUSFS 预取/release 对齐 | apply_patches.sh 35-76 | 与 zram/WILD 共用并行 wait；release 对齐依赖 KSU_TAG_DATE |
| LZ4KD 预取 | apply_patches.sh 49-51 | 与 zram/WILD 共用并行 wait |
| HMBIRD/Polly 内存/IO 补丁 | apply_patches.sh 87-152 | 多条 patch 与 cwd/循环变量耦合，本次未拆 |
| 混合配置块（echo+sed+AFDO 交错） | config_inject.sh L43-62 | 拆开风险大 |

## 约定

1. 开关为 false 时直接 exit 0
2. 幂等：已应用则跳过
3. 日志前缀 [FEATURE]
4. 致命失败 die，实验性失败 warn
5. 配置片段放 configs/features/<name>.config
6. 新增脚本后确认 scripts/lint.sh 覆盖（已包含 scripts/features/*.sh）
