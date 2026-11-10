# 一加 13 (SM8750) 6.6 内核构建

基于 [cctv18/oppo_oplus_realme_sm8750](https://github.com/cctv18/oppo_oplus_realme_sm8750) 的改进版。构建逻辑从工作流内嵌 bash 提取为 `scripts/` 独立模块，工作流只保留编排。

**本仓库不含内核源码**：每次构建时从 OnePlusOSS 拉取 6.6 内核，与骁龙上游三方合并后再打补丁。GitHub 只负责下发任务与汇总日志，实际编译在自托管 runner（Hyper-V Ubuntu 虚拟机 `kbuild`）上完成。

## 快速开始

1. 启动 `kbuild` 虚拟机并确认 runner 在线（离线时任务会一直排队，不会失败）
2. Actions → **oneplus13 内核编译** → Run workflow
3. 构建过程打印到 `build_summary.log`，产物见下方「产物」

## 输入参数（15 个分类开关）

同类功能聚在一个下拉里，选中哪个就开启上面列出的那组特性；展开结果会逐行打印在构建日志的「展开分类开关」一节，可直接核对。

| 分类 | 选项 | 开启什么 |
|---|---|---|
| `root` | `none` / `ksu` / `resukisu` / `sukisu` / `ksunext` | 对应的 KernelSU 方案，`none` 完全不集成 |
| `susfs` | `on` / `off` | SUSFS 全套（sus_path、sus_mount、sus_kstat、open_redirect、spoof_uname…），需 `root≠none` |
| `kpm` | `off` / `builtin` / `kpn` | `builtin`：SukiSU、ReSukiSU 内置 KPM；`kpn`：构建后用 KP-N 修补 Image |
| `sched` | `stock` / `tuned` / `tuned_bore` | `tuned`：NEXT_BUDDY + HRTICK + SIS_PROP + CACHE_HOT_BUDDY + LB_MIN；`tuned_bore`：以上全部 + BORE 调度器（开机接管） |
| `io` | `stock` / `adios` / `f2fs` / `adios_f2fs` | `adios`：ADIOS I/O 调度器；`f2fs`：ATGC + GC_MERGE + GC 三项调优（紧急休眠 50ms、拥塞 6ms、fsync 批量 20）；`adios_f2fs`：两者都开 |
| `compression` | `stock` / `lz4zstd` / `lz4kd` / `lz4zstd_lz4kd` | `lz4zstd`：LZ4 1.10 NEON + zstd；`lz4kd`：LZ4KD（zram 多级压缩）；`lz4zstd_lz4kd`：两者都开 |
| `net` | `stock` / `bbr3` | BBRv3 拥塞控制 |
| `mem` | `stock` / `rcu_nocb` | RCU_NOCB_CPU + RCU_LAZY（回调卸载到专属线程） |
| `container` | `off` / `standard` / `extend` | `standard`：命名空间 + SysV IPC + ntsync + netfilter 扩展；`extend`：再加 BT_HCIVHCI、STATIC_USERMODEHELPER 等 |
| `security` | `off` / `baseband` / `rekernel` / `both` | `baseband`：基带保护 LSM；`rekernel`：Re-Kernel |
| `opt` | `stock` / `o3_polly` | `lib`、`crypto` 加 `-O3` + Polly 向量化 |
| `afdo` | `off` / `use` / `generate` | `use`：用已有采样优化；`generate`：产出可采样内核（采完再用 `use` 重建） |
| `mode` | `build` / `clean` / `diagnosis` | `build`：增量；`clean`：删 `out/` 全量重建；`diagnosis`：只跑源码同步+补丁+配置注入并导出 `.config`，不编译不打包 |
| `ccache` | `keep` / `reset` / `debug` | `reset`：先删旧缓存；`debug`：保留并上传调试日志 |
| `suffix` | 字符串 | 内核后缀，留空用 `build.env` 的默认值 |

所有 `stock` / `off` 选项都表示「保持上游行为」，不会注入任何补丁或配置。

## 产物

| 位置 | 内容 | 保留 |
|---|---|---|
| VM `~/share/out/` | `AnyKernel3-<KSU>-<KSUVER>-<版本>-<后缀>-<日期>.zip` | 1 个当前 + `*.prev` |
| VM `~/share/out/history/` | 按 run 号归档 | 最近 5 个 |
| Actions run 页 artifact | 同一个 zip + `build_summary.log` | 7 天 |

zip 里的 `ak3.log` 记录 commit、KSU 版本和全部特性开关，回滚时不用猜。

## 常用组合

| 场景 | 选法 |
|---|---|
| 日常稳定版 | 默认值（`sched=tuned`、`io=adios_f2fs`、`compression=lz4zstd_lz4kd`、`net=bbr3`、`mem=rcu_nocb`） |
| 只验证补丁/配置能否应用 | `mode = diagnosis`（不编译，几分钟） |
| 试 BORE 调度器 | `sched = tuned_bore` |
| 定位「是不是补丁导致的问题」 | 所有分类选 `stock` / `off`，再逐个打开 |
| 改了编译器或 defconfig 后重建 | `mode = clean`，必要时再 `ccache = reset` |
| 采 AutoFDO 样本 | 先 `afdo = generate` 构建并刷入，采样后 `afdo = use` |

## 目录

| 目录 | 职责 |
|---|---|
| `.github/workflows/` | `kernel.yml` 主编排、`lint.yml` 静态检查、两个清理工作流 |
| `scripts/` | 构建阶段脚本，`build.env` 是参数（含工具链版本、仓库地址）的唯一来源 |
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
