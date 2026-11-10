# 一加 13 (SM8750) 6.6 内核构建

基于 [cctv18/oppo_oplus_realme_sm8750](https://github.com/cctv18/oppo_oplus_realme_sm8750) 的改进版。构建逻辑从工作流内嵌 bash 提取为 `scripts/` 独立模块，工作流只保留编排。

**本仓库不含内核源码**：每次构建时从 OnePlusOSS 拉取 6.6 内核，与骁龙上游三方合并后再打补丁。GitHub 只负责下发任务与汇总日志，实际编译在自托管 runner（Hyper-V Ubuntu 虚拟机 `kbuild`）上完成。

## 快速开始

1. 启动 `kbuild` 虚拟机并确认 runner 在线（离线时任务会一直排队，不会失败）
2. Actions → **oneplus13 内核编译** → Run workflow，按需改输入后运行
3. 构建过程打印到 `build_summary.log`，产物见下方「产物」

## 输入参数

派发表单只有 7 项：**这次要做什么**。**这个内核是什么**（14 个特性开关）在 `configs/profiles/` 里，跟着 commit 走。

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `profile` | choice | `stable` | 特性配置档：`stable` / `minimal` / `custom`，见下节 |
| `ksu_type` | choice | `ksu` | `resukisu` / `sukisu` / `ksunext` / `ksu` / `none` |
| `afdo_mode` | choice | `use` | `off` / `use`（用已有采样）/ `generate`（出可采样内核） |
| `ccache_mode` | choice | `keep` | `keep` / `reset`（先清缓存）/ `debug`（保留并上传日志） |
| `kernel_suffix` | string | 空 | 自定义内核后缀，空则用 `build.env` 的默认值 |
| `diagnosis` | bool | `false` | 跑完源码同步+补丁+配置注入后导出 `.config`，不编译不打包 |
| `clean_build` | bool | `false` | 删 `out/` 全量重建 |

## 特性配置档

| 档位 | 用途 |
|---|---|
| `stable` | 当前基线，与历史默认值逐项一致 |
| `minimal` | 关掉所有可选特性，用来二分定位「问题是我加的补丁引入的，还是上游本来就有」 |
| `custom` | 临时试验：改 `configs/profiles/custom.env` 后提交，派发时选 `custom` |

配置档内容（`configs/profiles/*.env`）：

```bash
SUSFS_ENABLE=true          # KernelSU + SUSFS
KPM_ENABLE=false           # false / builtin（仅 sukisu、resukisu）/ kpn
LZ4KD_ENABLE=true          # LZ4KD 压缩补丁
DROIDSPACES_ENABLE=false   # false / standard / extend
REKERNEL_ENABLE=false
BASEBAND_GUARD=false
ADIOS_ENABLE=true
BBR3_ENABLE=true
SCHED_ENABLE=true          # NEXT_BUDDY / HRTICK / SIS_PROP 等
LZ4ZSTD_ENABLE=true        # LZ4 1.10 NEON + zstd
F2FS_ENABLE=true           # ATGC/GC_MERGE + GC 调优
BORE_ENABLE=false          # 实验，开机即接管
RCU_NOCB_ENABLE=true
O3_SELECTIVE=true          # lib、crypto 加 -O3 + Polly
```

改特性 = 改一个文件 + 提交。`scripts/check_profiles.py` 会在 lint 时校验键名、取值和完整性（缺键会静默退回脚本各自的默认值，而各脚本默认值并不一致）。

## 产物

| 位置 | 内容 | 保留 |
|---|---|---|
| VM `~/share/out/` | `AnyKernel3-<KSU>-<KSUVER>-<版本>-<后缀>-<日期>.zip` | 1 个当前 + `*.prev` |
| VM `~/share/out/history/` | 按 run 号归档 | 最近 5 个 |
| Actions run 页 artifact | 同一个 zip + `build_summary.log` | 7 天 |

zip 里的 `ak3.log` 记录了 Profile、commit、KSU 版本与全部特性开关，回滚时不用猜。

## 常用组合

| 场景 | 参数 |
|---|---|
| 日常稳定版 | 全部默认（`profile=stable`） |
| 只验证补丁/配置能否应用 | `diagnosis = true`（不编译，几分钟） |
| 定位「是不是补丁导致的问题」 | `profile = minimal` |
| 试新特性 | 改 `custom.env` → `profile = custom` |
| 改了编译器或 defconfig 后重建 | `clean_build = true`，必要时再 `ccache_mode = reset` |
| 采 AutoFDO 样本 | 先 `afdo_mode = generate` 构建并刷入，采样后 `afdo_mode = use` |

## 目录

| 目录 | 职责 |
|---|---|
| `.github/workflows/` | `kernel.yml` 主编排、`lint.yml` 静态检查、两个清理工作流 |
| `scripts/` | 构建阶段脚本，`build.env` 是参数（含工具链版本、仓库地址）的唯一来源 |
| `scripts/features/` | 18 个功能模块，顺序固定，见 [功能模块清单](scripts/features/README.md) |
| `configs/features/` | 17 个 defconfig 配置片段 |
| `configs/profiles/` | 3 个特性配置档（stable / minimal / custom） |
| `other_patch/` | 随仓库版本化的补丁（外部的在构建时拉取） |
| `ak3_overlay/` | AnyKernel3 覆盖层与打包工具 |
| `lib/ccache-x86-64` | ccache 二进制，VM 首次安装用 |
| `docs/` | [架构说明](docs/ARCHITECTURE.md)、[AutoFDO 指南](docs/AUTOFDO.md) |

## 本地检查

改动脚本后先跑（需要 `python3`，装了 `pyyaml` 会额外校验工作流）：

```bash
bash scripts/lint.sh
```

同样的检查在 push / PR 时会由 `.github/workflows/lint.yml` 自动执行，约 30 秒。

## 鸣谢

- 原始脚本：[cctv18/oppo_oplus_realme_sm8750](https://github.com/cctv18/oppo_oplus_realme_sm8750)
- ReSukiSU：[ReSukiSU/ReSukiSU](https://github.com/ReSukiSU/ReSukiSU)
- KernelSU：[tiann/KernelSU](https://github.com/tiann/KernelSU)
- KernelSU Next：[pershoot/KernelSU-Next](https://github.com/pershoot/KernelSU-Next)
- susfs4ksu：[ShirkNeko/susfs4ksu](https://github.com/ShirkNeko/susfs4ksu)
- SukiSU 补丁：[SukiSU-Ultra/SukiSU_patch](https://github.com/SukiSU-Ultra/SukiSU_patch)
- 基带保护：[vc-teahouse/Baseband-guard](https://github.com/vc-teahouse/Baseband-guard)
- LZ4 NEON ASM：[ferstar](https://github.com/ferstar) / [Xiaomichael](https://github.com/Xiaomichael) / [cctv18](https://github.com/cctv18)
- ADIOS：[firelzrd/adios](https://github.com/firelzrd/adios)
- wild kernels [https://github.com/WildKernels/OnePlus_KernelSU_SUSFS]
- 编译工具链：[ZyCromerZ/Clang](https://github.com/ZyCromerZ/Clang)
- 打包：[osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3)、[topjohnwu/Magisk](https://github.com/topjohnwu/Magisk)

## 许可证

本项目以 [GPL-2.0](LICENSE) 发布。仓库内补丁遵循 Linux 内核 GPL-2.0；打包环节使用的工具（AnyKernel3、Magisk 提取的 busybox/magiskboot 等）来自各自上游项目，遵循其原始许可证。
