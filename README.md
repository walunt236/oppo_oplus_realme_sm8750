# 一加 13 (SM8750) 6.6 内核构建

基于 [cctv18/oppo_oplus_realme_sm8750](https://github.com/cctv18/oppo_oplus_realme_sm8750) 的 CI 脚本深度改进版，构建逻辑从单体工作流内嵌 bash 提取为 `scripts/` 独立模块，工作流仅保留编排。

## 仓库结构

```
.github/workflows/6.6.118.yml   工作流编排（inputs 定义 + 步骤调用）
scripts/
  common.sh         公共库（日志/网络回退/补丁拉取）
  init_env.sh       环境依赖 + OEM/vendor 源码 + AOSP merge + 工具链（Clang19 + build-tools 官方源）
  ccache_setup.sh   ccache 配置（40G/依赖模式/日志开关）
  apply_patches.sh  KernelSU/SUSFS/lz4/lz4kd/风驰批/功能开关补丁
  config_inject.sh  defconfig 注入/cmdline/版本固化
  build_kernel.sh   增量钳制/.config 指纹/工具链验证/编译/IKCFG 产物校验
  package.sh        KPM 修补/AnyKernel3 打包/本地保存/清理
other_patch/        本仓库维护的补丁（zram_recomp/damon/adios/apk_sign/69_hide_stuff）
droidspaces_patch/  Droidspaces 容器支持补丁
```

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