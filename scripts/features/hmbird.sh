#!/usr/bin/env bash
# HMBIRD 模块：Overwriter / Hmbird Defconfig / 16 个内存与 IO 补丁 / EnablePOLLY / zsmalloc copy_page
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

# zsmalloc 压缩迁移用 copy_page 代替 memcpy：补丁已固化到 other_patch/mm/，不再依赖网络。
# brokestar233 的另外三个补丁经复核后移除：
#   mm_kvmalloc  —— 把 __GFP_NORETRY 换成清 __GFP_DIRECT_RECLAIM，会改变大块分配的失败率，
#                    且 vendor 已有 adjust_kvmalloc_flags / use_vmalloc hook；
#   mm_slab      —— 给所有 kmalloc cache 加 SLAB_HWCACHE_ALIGN，显著增加内存占用，与 memcomp 目标冲突；
#   mm_vmpressure—— 只删注释，无行为变化。
ZSC_PATCH="$GITHUB_WORKSPACE/other_patch/mm/zsmalloc_copy_page.patch"
if [ -f "$ZSC_PATCH" ]; then
  if patch -p1 --forward -f < "$ZSC_PATCH" >/dev/null 2>&1; then
    info "[HMBIRD] zsmalloc copy_page 已应用"
  else
    warn "[HMBIRD] zsmalloc copy_page 未应用（可能已存在）"
  fi
  if grep -q 'copy_page(d_addr, s_addr)' mm/zsmalloc.c; then
    info "[HMBIRD] zsmalloc copy_page 校验通过"
  else
    warn "[HMBIRD] zsmalloc copy_page 未生效"
  fi
else
  warn "[HMBIRD] 缺少 other_patch/mm/zsmalloc_copy_page.patch，跳过"
fi
# ---- 原块结束 ----
