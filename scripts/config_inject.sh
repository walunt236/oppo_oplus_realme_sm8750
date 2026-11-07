#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

cd "$GITHUB_WORKSPACE/kernel_workspace"
DCFG="./common/arch/arm64/configs/gki_defconfig"

if [[ "$SUSFS_ENABLE" == "true" && "$KSU_TYPE" != "none" ]]; then
  cat "$GITHUB_WORKSPACE/configs/features/ksu_susfs.config" >> "$DCFG"
else
  echo "CONFIG_KSU_SUSFS=n" >> "$DCFG"
fi

if [[ "$KSU_TYPE" != "none" ]]; then
  echo "CONFIG_KSU=y" >> "$DCFG"
else
  echo "CONFIG_KSU=n" >> "$DCFG"
fi

if [[ "$KPM_ENABLE" == 'builtin' ]] && ( [[ "$KSU_TYPE" == "sukisu" ]] || [[ "$KSU_TYPE" == "resukisu" ]] ); then
  echo "CONFIG_KPM=y" >> "$DCFG"
fi
cat "$GITHUB_WORKSPACE/configs/features/tmpfs.config" >> "$DCFG"

if [[ "$LZ4KD_ENABLE" == "true" ]]; then
  cat "$GITHUB_WORKSPACE/configs/features/lz4kd.config" >> "$DCFG"
fi

cat "$GITHUB_WORKSPACE/configs/features/zram.config" >> "$DCFG"


echo "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y" >> "$DCFG"
# 骁龙 6.6.14x 已从 kernel/sched/Makefile 移除 ext.o，开启该选项会导致
# bpf_sched_ext_ops 未定义，这里强制关闭
# 关闭 sched_ext：6.6 内核无此功能（6.12 才进主线），且高通 BSP 已剥离
# 核心集成（task_struct 缺 sched_ext_entity），开启只会引用不存在的符号
sed -i '/^CONFIG_SCHED_CLASS_EXT/d' "$DCFG"
echo "# CONFIG_SCHED_CLASS_EXT is not set" >> "$DCFG"
# ARM64 cluster 调度：让 EAS 感知多 cluster 拓扑（默认选项，纯拓扑感知）
echo "CONFIG_SCHED_CLUSTER=y" >> "$DCFG"
# （已移除无效的 check_defconfig 删除动作：本流水线不调用 build/build.sh，该校验从未执行）
sed -i '/^CONFIG_HEADERS_INSTALL/d' "$DCFG"
echo "CONFIG_HEADERS_INSTALL=y" >> "$DCFG"
# KSU preinit 需要 out/usr/include（Kbuild 用 wildcard 检测），必须保留
if [ "${AFDO_ENABLE:-false}" = "true" ]; then
  echo "CONFIG_AUTOFDO_CLANG=y" >> "$DCFG"
  info "AutoFDO 构建已启用（CONFIG_AUTOFDO_CLANG=y）"
else
  info "AutoFDO 未启用，跳过 CONFIG_AUTOFDO_CLANG"
fi
echo "CONFIG_SECTION_MISMATCH_WARN_ONLY=y" >> "$DCFG"

cat "$GITHUB_WORKSPACE/configs/features/misc_toggles.config" >> "$DCFG"

cat "$GITHUB_WORKSPACE/configs/features/kernel_tunables.config" >> "$DCFG"

if [[ "$RCU_NOCB_ENABLE" == "true" ]]; then
  info "开启 RCU_NOCB_CPU..."
  cat "$GITHUB_WORKSPACE/configs/features/rcu.config" >> "$DCFG"
  info "RCU_LAZY 默认启用"
fi

cat "$GITHUB_WORKSPACE/configs/features/namespaces.config" >> "$DCFG"

info "注入 Vendor 驱动符号 (UBSAN / KUNIT)..."
grep -q "CFLAGS_configs.o := -D__IKCFG_BUILD" ./common/kernel/Makefile || \
  echo 'CFLAGS_configs.o := -D__IKCFG_BUILD_$(shell date +%s)' >> ./common/kernel/Makefile
grep -q "CFLAGS_REMOVE_configs.o" ./common/kernel/Makefile || \
  echo 'CFLAGS_REMOVE_configs.o := -flto=thin -fsplit-lto-unit' >> ./common/kernel/Makefile

apply_patch_file "other_patch/zram/zram_recomp_default.patch" /tmp/zram_recomp.patch strict "zram 多级压缩补丁"
# zram 源码级调整：开机首次 disksize 不低于 6GB + 重压缩按绝对占用判断
if [ -f ./common/drivers/block/zram/zram_drv.c ]; then
  python3 "$GITHUB_WORKSPACE/scripts/zram_src_tune.py" ./common/drivers/block/zram/zram_drv.c ||     warn "zram 源码调整失败（不影响构建，行为保持上游）"
fi
apply_patch_file "other_patch/damon/damon_reclaim_defaults.patch" /tmp/damon_reclaim.patch strict "DAMON_RECLAIM 默认参数补丁"
cat "$GITHUB_WORKSPACE/configs/features/ubsan_oem.config" >> "$DCFG"

# cmdline 注入
info "对 init/main.c 注入 cmdline..."
cd common
TARGET_MAIN="init/main.c"

if [ ! -f "$TARGET_MAIN" ]; then
  error "无法定位内核入口文件 $TARGET_MAIN"
  exit 1
fi

sed -i '/setup_arch(&command_line);/a \    strlcat(boot_command_line, " schedstats=disable panic=30 page_alloc.shuffle=0 cryptomgr.notests rcutree.blimit=1024 workqueue.power_efficient=1 skew_tick=0 random.trust_cpu=on kfence.sample_interval=0 loglevel=3 transparent_hugepage=madvise kasan=off init_on_alloc=0", sizeof(boot_command_line));' "$TARGET_MAIN"

if grep -q "strlcat.*boot_command_line" "$TARGET_MAIN"; then
  info "cmdline 注入成功"
else
  error "cmdline 注入失败"
  exit 1
fi

# 网络功能增强
cd "$GITHUB_WORKSPACE/kernel_workspace"
cat "$GITHUB_WORKSPACE/configs/features/netfilter.config" >> "$DCFG"

# Droidspaces 配置块
if [[ "$DROIDSPACES_ENABLE" != "false" ]]; then
  cat "$GITHUB_WORKSPACE/configs/features/droidspaces.config" >> "$DCFG"
  if [[ "$DROIDSPACES_ENABLE" == "extend" ]]; then
    cat "$GITHUB_WORKSPACE/configs/features/droidspaces_extend.config" >> "$DCFG"
  fi
fi

# ADIOS 配置块
cd "$GITHUB_WORKSPACE/kernel_workspace"
cat "$GITHUB_WORKSPACE/configs/features/adios.config" >> "$DCFG"

# 版本固化
cd "$GITHUB_WORKSPACE/kernel_workspace"
echo "CONFIG_LOCALVERSION_AUTO=y" >> ./common/arch/arm64/configs/gki_defconfig

LOCALVER="-${KERNEL_SUFFIX}"
if [[ -z "$KERNEL_SUFFIX_INPUT" ]] && [[ -n "$UPSTREAM_SUBLEVEL" ]] && [[ "$UPSTREAM_SUBLEVEL" != "0" ]]; then
  LOCALVER="${LOCALVER}_${UPSTREAM_SUBLEVEL}"
fi
echo "LOCALVER=$LOCALVER" >> "$GITHUB_ENV"

sed -i '/^CONFIG_LOCALVERSION=/d' ./common/arch/arm64/configs/gki_defconfig
echo "CONFIG_LOCALVERSION=\"${LOCALVER}\"" >> ./common/arch/arm64/configs/gki_defconfig

sed -i 's|^echo "\$res"$|echo "'"${LOCALVER}"'"|' ./common/scripts/setlocalversion

# HZ=300
info "启用 HZ=300..."
cd "$GITHUB_WORKSPACE/kernel_workspace"
cat "$GITHUB_WORKSPACE/configs/features/hz300.config" >> "$DCFG"

echo "CONFIG_PER_VMA_LOCK_STATS=y" >> ./common/arch/arm64/configs/gki_defconfig

cat "$GITHUB_WORKSPACE/configs/features/perf_toggles.config" >> "$DCFG"
