# 一加 13 (SM8750) 6.6 内核构建

基于 [cctv18/oppo_oplus_realme_sm8750](https://github.com/cctv18/oppo_oplus_realme_sm8750) 的改进版。构建逻辑从工作流内嵌 bash 提取为 `scripts/` 独立模块，工作流只保留编排。

**本仓库不含内核源码**：每次构建时从 OnePlusOSS 拉取 6.6 内核，与骁龙上游三方合并后再打补丁。GitHub 只负责下发任务与汇总日志，实际编译在自托管 runner（Hyper-V Ubuntu 虚拟机 `kbuild`）上完成。

## 快速开始

1. 启动 `kbuild` 虚拟机并确认 runner 在线（离线时任务会一直排队，不会失败）
2. Actions → **oneplus13 内核编译** → Run workflow，按需改输入后运行
3. 构建过程打印到 `build_summary.log`，产物见下方「产物」

## 产物

| 位置 | 内容 | 保留 |
|---|---|---|
| VM `~/share/out/` | `AnyKernel3-<KSU>-<KSUVER>-<版本>-<后缀>-<日期>.zip` | 1 个当前 + `*.prev` |
| VM `~/share/out/history/` | 按 run 号归档 | 最近 5 个 |
| Actions run 页 artifact | 同一个 zip + `build_summary.log` | 7 天 |

## 输入参数

### KernelSU

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `ksu_type` | choice | `ksu` | `resukisu` / `sukisu` / `ksunext` / `ksu` / `none` |
| `susfs_enable` | bool | `true` | 需 `ksu_type != none`；关闭时写 `CONFIG_KSU_SUSFS=n` |
| `kpm_enable` | choice | `false` | `false` / `builtin`（仅 sukisu、resukisu）/ `kpn` |
| `rekernel_enable` | bool | `false` | Re-Kernel 支持 |
| `baseband_guard` | bool | `false` | 基带保护 LSM |

### 内核特性

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `lz4kd_enable` | bool | `true` | LZ4KD 压缩补丁 |
| `lz4zstd_enable` | bool | `true` | LZ4 1.10 + NEON / zstd |
| `f2fs_enable` | bool | `true` | ATGC/GC_MERGE 默认值 + GC 调优 |
| `sched_enable` | bool | `true` | NEXT_BUDDY / HRTICK / SIS_PROP 等 |
| `bbr3_enable` | bool | `true` | BBRv3 拥塞控制 |
| `adios_enable` | bool | `true` | ADIOS I/O 调度器 |
| `bore_enable` | bool | `true` | BORE 调度器 |
| `rcu_nocb_enable` | bool | `true` | RCU_NOCB_CPU + RCU_LAZY |
| `droidspaces_enable` | choice | `false` | `false` / `standard` / `extend`（容器支持） |

### 构建控制

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `afdo_mode` | choice | `use` | `off` / `use`（用已有采样）/ `generate`（出可采样内核） |
| `o3_selective` | bool | `true` | `lib`、`crypto` 加 `-O3` + Polly |
| `clean_build` | bool | `false` | 删 `out/` 全量重建 |
| `diagnosis` | bool | `false` | 跑完源码同步+补丁+配置注入后导出 `.config`，不编译不打包 |
| `ccache_update` | bool | `false` | 先删旧 ccache 缓存 |
| `ccache_debug` | bool | `false` | 上传 ccache 调试日志 |
| `kernel_suffix` | string | 空 | 自定义内核后缀，空则用 `build.env` 的默认值 |

## 常用组合

| 场景 | 参数 |
|---|---|
| 日常稳定版 | 全部默认 |
| 只验证补丁/配置能否应用 | `diagnosis = true`（不编译，几分钟） |
| 改了编译器或 defconfig 后重建 | `clean_build = true`，必要时再加 `ccache_update = true` |
| 采 AutoFDO 样本 | 先 `afdo_mode = generate` 构建并刷入，采样后 `afdo_mode = use` |

## 目录

| 目录 | 职责 |
|---|---|
| `.github/workflows/` | `kernel.yml` 主编排、`lint.yml` 静态检查、两个清理工作流 |
| `scripts/` | 构建阶段脚本，`build.env` 是所有参数（含工具链版本、仓库地址）的唯一来源 |
| `scripts/features/` | 18 个功能模块，顺序固定，见 [功能模块清单](scripts/features/README.md) |
| `configs/features/` | 17 个 defconfig 配置片段 |
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
