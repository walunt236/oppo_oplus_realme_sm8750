# 功能模块清单

每个功能一个脚本：scripts/features/<name>.sh
资产目录：other_patch/<name>/
开关：优先沿用原工作流变量；原块无开关的新增 <NAME>_ENABLE（默认 true，保持原行为）

## 当前状态

apply_patches.sh：428 → 217 → 73 行；剩余内容为调用顺序与状态衔接。

### 已抽取（脚本）

| 功能 | 脚本 | 开关 | 备注 |
|---|---|---|---|
| KernelSU | features/kernelsu.sh | KSU_TYPE != none | 版本号写 GITHUB_ENV/GITHUB_OUTPUT；KSU_TAG_DATE 经 /tmp/ksu_state.env 回传主脚本 |
| 补丁仓预取 | features/prefetch.sh | 无（按 SUSFS/LZ4KD 条件启动同步） | 原 35-76；缓存目录/sync_repo 并行 wait/SUSFS release 对齐随块；变量经 /tmp/prefetch_state.env 回传主脚本 |
| SUSFS | features/susfs.sh | SUSFS_ENABLE | 预取/release 对齐见 features/prefetch.sh（共用并行 wait） |
| LZ4KD | features/lz4kd.sh | LZ4KD_ENABLE | 预取见 features/prefetch.sh |
| lz4/zstd | features/lz4zstd.sh | LZ4ZSTD_ENABLE（默认 true） | 原块 178-240；lz4accel 拉取、002-zstd 过滤随块搬迁 |
| Droidspaces | features/droidspaces.sh | DROIDSPACES_ENABLE | false 跳过，standard/extend 生效 |
| ADIOS | features/adios.sh | ADIOS_ENABLE（默认 true） | — |
| KVM NVHE | features/nvhe.sh | 无（始终执行） | AutoFDO .rel.llvm 元数据兼容；补丁幂等，只在 gen-hyprel.c 未打过时生效 |
| Re-Kernel | features/rekernel.sh | REKERNEL_ENABLE | 沿用原变量，默认关闭 |
| Baseband-guard | features/baseband.sh | BASEBAND_GUARD | 沿用原变量，含 LSM 注入校验 |
| BBRv3 | features/bbr3.sh | BBR3_ENABLE（默认 true） | — |
| 调度器 | features/sched.sh | SCHED_ENABLE（默认 true） | NEXT_BUDDY / HRTICK / SIS_PROP / CACHE_HOT_BUDDY / LB_MIN |
| f2fs | features/f2fs.sh | F2FS_ENABLE（默认 true） | ATGC 路径 bug 已修（0aae0936） |
| libbpf | features/libbpf.sh | 无（始终执行） | 新 glibc 下 strchr() const 兼容；关掉只会编译失败，自带 const const 自愈 |
| BORE | features/bore.sh | BORE_ENABLE（默认 true） | 7.0.0 补丁 + 7.0.1r2 审计修复；sched_bore 默认 1（开机即接管） |
| WildKernels 小补丁 | features/wild_extra.sh | WILD_EXTRA_ENABLE（默认 true） | 扫描顺序 / clear_page 16B 对齐 / cpufreq unlikely |
| HMBIRD/Polly | features/hmbird.sh | 无（始终执行） | 原 87-152；Overwriter/Defconfig/18 patch/EnablePOLLY/mm_* 原样搬迁，子脚本内 cd common |
| 收尾 | features/finalize.sh | 无（始终执行） | 原 11-27、154-187；count_rejs 助手随块，Unicode/lz4 CFLAGS/dma-buf 回滚/reject 汇总 |

### 已抽取（配置片段）

configs/features/ 下 17 个片段：adios、bore、droidspaces、droidspaces_extend、hz300、
kernel_tunables、ksu_susfs、lz4kd、misc_toggles、namespaces、netfilter、
perf_toggles、rcu、tmpfs、ubsan_oem、zram、zsmalloc_chain

config_inject.sh：587 → 143 行，配置指令序列与改造前逐行一致。
片段数量与同键冲突由 `scripts/check_configs.py` 在每次 lint 时自动校验并打印实时条数，不再手工维护数字。

### 未抽取（有意保留）

apply_patches.sh 的功能块已全部模块化；以下仅剩 config_inject.sh 的混合配置块。

| 块 | 位置 | 原因 |
|---|---|---|
| 混合配置块（HEADERS_INSTALL sed + AFDO 条件 + SECTION_MISMATCH） | config_inject.sh L43-52 | 拆开风险大 |

## 约定

1. 开关为 false 时直接 exit 0
2. 幂等：已应用则跳过
3. 日志前缀 [FEATURE]
4. 致命失败 die，实验性失败 warn
5. 配置片段放 configs/features/<name>.config
6. 新增脚本后确认 scripts/lint.sh 覆盖（已包含 scripts/features/*.sh）
