#!/usr/bin/env bash
# HMBIRD 模块：Overwriter / Hmbird Defconfig / 16 个内存与 IO 补丁 / EnablePOLLY / mm 依赖补丁
# 来源：scripts/apply_patches.sh 原第 87-152 行（原样搬迁）
# 开关：无（原块始终执行）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

# 预取阶段由主脚本完成；独立运行时使用与主脚本一致的默认值
WILD_DIR="${WILD_DIR:-$HOME/.cache_patches/wild_patches}"

# ---- 原块开始（apply_patches.sh 原第 87-152 行，原样搬迁，勿改） ----
# 风驰引擎已移除（它是对 sched_ext 的魔改替换；而 sched_ext 在 6.6 QCOM 树上不可用：
# ext.o 已从 Makefile 移除且 task_struct 缺 sched_ext_entity）。以下为 HMBIRD 的内存/IO 调优补丁。
cd "$GITHUB_WORKSPACE/kernel_workspace"
cd common

info "注入 Overwriter 补丁..."
OVERWRITER_PATCH=$(find_latest "$WILD_DIR/oneplus/hmbird/" "overwriter.patch")
if [ -z "$OVERWRITER_PATCH" ]; then
  warn "oneplus/hmbird 未找到 overwriter.patch，开始全仓搜索..."
  OVERWRITER_PATCH=$(find_latest "$WILD_DIR" "overwriter.patch")
fi
if [ -z "$OVERWRITER_PATCH" ]; then
  error "Overwriter 补丁未找到"
  exit 1
fi
sed -i 's/\r$//' "$OVERWRITER_PATCH"
patch -p1 -F 3 -f < "$OVERWRITER_PATCH" || {
  error "Overwriter 补丁应用失败"
  exit 1
}

if [ -f "./drivers/of/overwriter/overwrite_configs/convert_configs.sh" ]; then
  chmod +x ./drivers/of/overwriter/overwrite_configs/convert_configs.sh
fi

info "固化 Hmbird Defconfig..."
HMBIRD_CFG=$(find_latest "$WILD_DIR/oneplus/hmbird/" "hmbird_config.patch")
if [ -z "$HMBIRD_CFG" ]; then
  warn "oneplus/hmbird 未找到 hmbird_config.patch，开始全仓搜索..."
  HMBIRD_CFG=$(find_latest "$WILD_DIR" "hmbird_config.patch")
fi
if [ -z "$HMBIRD_CFG" ]; then
  error "Hmbird Defconfig 补丁未找到"
  exit 1
fi
sed -i 's/\r$//' "$HMBIRD_CFG"
patch -p1 -F 3 -f < "$HMBIRD_CFG" || {
  error "Hmbird Defconfig 补丁应用失败"
  exit 1
}

# disable_cache_hot_buddy 已移除：vendor 6.6.143 的 CACHE_HOT_BUDDY 默认就是 true，
# 该补丁改成 false 后又会 sched.sh 的 sed 改回 true（净效果 = 无操作），故不再应用。
for p in optimized_mem_operations file_struct_8bytes_align reduce_cache_pressure mem_opt_prefetch optimise_memcmp f2fs_reduce_congestion f2fs_enlarge_min_fsync_blocks increase_ext4_default_commit_age int_sqrt reduce_gc_thread_sleep_time increase_sk_mem_packets force_tcp_nodelay minimise_wakeup_time reduce_freeze_timeout silence_irq_cpu_logspam silence_system_logspam; do
  if patch -p1 --forward -f < "$WILD_DIR/common/$p.patch" >/dev/null 2>&1; then
    info "[HMBIRD] 已应用 $p"
  else
    warn "[HMBIRD] $p 应用失败或已存在，跳过"
  fi
done
# EnablePOLLY：Polly 循环优化（优先用缓存，失败再下载）
if [ -f "$HOME/.cache_patches/zram_patches/common/EnablePOLLY.patch" ]; then
  patch -p1 --forward -f < "$HOME/.cache_patches/zram_patches/common/EnablePOLLY.patch" || warn "EnablePOLLY.patch 应用失败，继续..."
else
  fetch_gh_file "mrcxlinux/kernel_patches" "common/EnablePOLLY.patch" "main" "/tmp/EnablePOLLY.patch" || warn "EnablePOLLY.patch 下载失败，继续..."
  patch -p1 --forward -f < /tmp/EnablePOLLY.patch || warn "EnablePOLLY.patch 应用失败，继续..."
fi

# mm_slab / mm_kvmalloc：2026-11-27 的 #59 构建（移除这两个补丁）在真机上卡开机，
# 回滚后正常。两者暂定为“vendor 树隐性依赖”，在定位清楚前保留（见 other_patch/mm/）。
for p in mm_kvmalloc mm_slab; do
  f_="$GITHUB_WORKSPACE/other_patch/mm/$p.patch"
  if [ -f "$f_" ]; then
    if patch -p1 --forward -f < "$f_" >/dev/null 2>&1; then
      info "[HMBIRD] 已应用 $p（vendor 依赖，暂保留）"
    else
      warn "[HMBIRD] $p 未应用（可能已存在）"
    fi
  else
    warn "[HMBIRD] 缺少 $f_，跳过 $p"
  fi
done
grep -q 'Embrace davem' mm/slab_common.c && info "[HMBIRD] mm_slab 校验通过" || warn "[HMBIRD] mm_slab 未生效"
grep -q '__GFP_DIRECT_RECLAIM' mm/util.c && info "[HMBIRD] mm_kvmalloc 校验通过" || warn "[HMBIRD] mm_kvmalloc 未生效"

# ---- 原块结束 ----
