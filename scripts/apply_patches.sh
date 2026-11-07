#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

cd "$GITHUB_WORKSPACE/kernel_workspace"
: > /tmp/sync_failed.list

REJ_DIR="${OUT_DIR:-$HOME/share/out}/rej"
mkdir -p "$REJ_DIR"

count_rejs() {
  local label="$1" files hunks safe
  safe="${label//\//_}"
  files=$(find . -name "*.rej" 2>/dev/null | wc -l)
  hunks=$(find . -name "*.rej" -exec awk '/^@@/{n++} END{print n+0}' {} \; 2>/dev/null | awk '{s+=$1} END{print s+0}')
  if [ "$files" -gt 0 ]; then
    find . -name "*.rej" 2>/dev/null | while IFS= read -r f; do
      rel=$(printf '%s' "$f" | sed 's|^\./||')
      cp -f "$f" "$REJ_DIR/$safe-$(printf '%s' "$rel" | tr '/' '_')" 2>/dev/null || true
      printf '%s  失败hunk=%s\n' "$rel" "$(awk '/^@@/{n++} END{print n+0}' "$f")" >> "$REJ_DIR/$safe.summary"
    done
    find . -name "*.rej" -delete 2>/dev/null || true
  fi
  TOTAL_REJ=$((TOTAL_REJ + hunks))
  TOTAL_REJ_FILES=$((TOTAL_REJ_FILES + files))
  info "$label reject: ${files} 文件 / ${hunks} hunk（明细 $REJ_DIR/$safe.summary）"
}

# KernelSU（模块化；KSU_TYPE=none 时由子脚本写 KSUVER=none）
bash "$GITHUB_WORKSPACE/scripts/features/kernelsu.sh"
if [ -f /tmp/ksu_state.env ]; then
  . /tmp/ksu_state.env
fi

# 补丁仓并行预取
SUSFS_CACHE_DIR="$HOME/.cache_patches/susfs4ksu"
ZRAM_CACHE_DIR="$HOME/.cache_patches/zram_patches"
SUKI_CACHE_DIR="$HOME/.cache_patches/sukisu_patches"
WILD_DIR="$HOME/.cache_patches/wild_patches"
mkdir -p "$HOME/.cache_patches"
export SUSFS_CACHE_DIR ZRAM_CACHE_DIR SUKI_CACHE_DIR WILD_DIR

if [[ "$SUSFS_ENABLE" == "true" && "$KSU_TYPE" != "none" ]]; then
  SUSFS_BRANCH="${SUSFS_BRANCH:-gki-${QCOM_SERIES:-android15-6.6}}"
  export SUSFS_BRANCH
  sync_repo "https://github.com/ShirkNeko/susfs4ksu.git" "$SUSFS_CACHE_DIR" "$SUSFS_BRANCH" || true &
fi
sync_repo "https://github.com/mrcxlinux/kernel_patches.git" "$ZRAM_CACHE_DIR" || true &
if [[ "$LZ4KD_ENABLE" == "true" ]]; then
  sync_repo "https://github.com/ShirkNeko/SukiSU_patch.git" "$SUKI_CACHE_DIR" || true &
fi
sync_repo "https://github.com/WildKernels/kernel_patches.git" "$WILD_DIR" || true &
wait

# release 模式下，SUSFS 补丁必须与 KernelSU 发布同期，否则会大面积 reject。
if [[ "$KSU_TYPE" == "ksu" && "${KSU_CHANNEL:-main}" == "release" && -n "${KSU_TAG_DATE:-}" ]]; then
  SUSFS_ERA_SHA=$(curl -sL --retry 3 --retry-delay 5 --retry-all-errors --max-time 20 \
    "https://api.github.com/repos/ShirkNeko/susfs4ksu/commits?sha=${SUSFS_BRANCH}&until=${KSU_TAG_DATE}&per_page=1" 2>/dev/null \
    | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
  if [ -n "$SUSFS_ERA_SHA" ] && \
     glr -C "$SUSFS_CACHE_DIR" fetch -q --depth=1 origin "$SUSFS_ERA_SHA" 2>/dev/null && \
     git -C "$SUSFS_CACHE_DIR" checkout -q FETCH_HEAD 2>/dev/null; then
    info "SUSFS 已对齐 KernelSU 发布同期提交: ${SUSFS_ERA_SHA:0:8} (${KSU_TAG_DATE%%T*})"
  else
    warn "SUSFS 同期提交检出失败，将使用分支最新（可能与 release 不兼容）"
  fi
fi
[ -d "$ZRAM_CACHE_DIR/.git" ] || die "zram_patches 预取失败（克隆失败且无本地缓存）"
[ -d "$WILD_DIR/.git" ] || die "wild_patches 预取失败（克隆失败且无本地缓存）"
if [[ "$SUSFS_ENABLE" == "true" && "$KSU_TYPE" != "none" ]] && [ ! -d "$SUSFS_CACHE_DIR/.git" ]; then
  die "susfs4ksu 预取失败（克隆失败且无本地缓存）"
fi
if [[ "$LZ4KD_ENABLE" == "true" ]] && [ ! -d "$SUKI_CACHE_DIR/.git" ]; then
  die "SukiSU_patch 预取失败（克隆失败且无本地缓存）"
fi
info "补丁仓并行预取完成"

# SUSFS：补丁/隐藏（模块化；预取同步与 release 对齐仍在主脚本）
bash "$GITHUB_WORKSPACE/scripts/features/susfs.sh"

# lz4/zstd（模块化；lz4accel 拉取与 zstd 过滤随块搬迁）
bash "$GITHUB_WORKSPACE/scripts/features/lz4zstd.sh"

# lz4kd
bash "$GITHUB_WORKSPACE/scripts/features/lz4kd.sh"

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

for p in optimized_mem_operations file_struct_8bytes_align reduce_cache_pressure mem_opt_prefetch optimise_memcmp f2fs_reduce_congestion f2fs_enlarge_min_fsync_blocks increase_ext4_default_commit_age int_sqrt reduce_gc_thread_sleep_time increase_sk_mem_packets disable_cache_hot_buddy force_tcp_nodelay minimise_wakeup_time reduce_freeze_timeout silence_irq_cpu_logspam silence_system_logspam; do
  patch -p1 --forward -f < "$WILD_DIR/common/$p.patch" || warn "$p.patch 应用失败，继续..."
done
if [ -f "$HOME/.cache_patches/zram_patches/common/EnablePOLLY.patch" ]; then
  patch -p1 --forward -f < "$HOME/.cache_patches/zram_patches/common/EnablePOLLY.patch" || warn "EnablePOLLY.patch 应用失败，继续..."
else
  fetch_gh_file "mrcxlinux/kernel_patches" "common/EnablePOLLY.patch" "main" "/tmp/EnablePOLLY.patch" || warn "EnablePOLLY.patch 下载失败，继续..."
  patch -p1 --forward -f < /tmp/EnablePOLLY.patch || warn "EnablePOLLY.patch 应用失败，继续..."
fi
curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 -o /tmp/mm_zsmalloc.patch "https://github.com/brokestar233/android_kernel_common_oneplus_sm8750/commit/d831954.patch" || { warn "mm_zsmalloc 下载失败，跳过..."; rm -f /tmp/mm_zsmalloc.patch; }
if [ -f /tmp/mm_zsmalloc.patch ]; then
  patch -p1 --forward -f < /tmp/mm_zsmalloc.patch || warn "mm_zsmalloc 应用失败，继续..."
fi
curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 -o /tmp/mm_kvmalloc.patch "https://github.com/brokestar233/android_kernel_common_oneplus_sm8750/commit/a8093f3.patch" || { warn "mm_kvmalloc 下载失败，跳过..."; rm -f /tmp/mm_kvmalloc.patch; }
if [ -f /tmp/mm_kvmalloc.patch ]; then
  patch -p1 --forward -f < /tmp/mm_kvmalloc.patch || warn "mm_kvmalloc 应用失败，继续..."
fi
curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 -o /tmp/mm_slab.patch "https://github.com/brokestar233/android_kernel_common_oneplus_sm8750/commit/936de3f.patch" || { warn "mm_slab 下载失败，跳过..."; rm -f /tmp/mm_slab.patch; }
if [ -f /tmp/mm_slab.patch ]; then
  patch -p1 --forward -f < /tmp/mm_slab.patch || warn "mm_slab 应用失败，继续..."
fi
curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 -o /tmp/mm_vmpressure.patch "https://github.com/brokestar233/android_kernel_common_oneplus_sm8750/commit/99b920c.patch" || { warn "mm_vmpressure 下载失败，跳过..."; rm -f /tmp/mm_vmpressure.patch; }
if [ -f /tmp/mm_vmpressure.patch ]; then
  patch -p1 --forward -f < /tmp/mm_vmpressure.patch || warn "mm_vmpressure 应用失败，继续..."
fi

TOTAL_REJ=0
TOTAL_REJ_FILES=0
count_rejs "基础补丁"

# AOSP 直连补丁已移除：11 个 commit 的改动已 100% 包含在 6.6.143 上游，
# 且 aosp-mirror 仓库已停止更新（最后推送 2025-11），保留只会产生无效 reject。

# palazik 补丁已停用（try_to_steal_block 与 6.6.143 的 fallback 流程不兼容，收益小）

UNICODE_PATCH=$(find_latest "$WILD_DIR/" "*unicode*6.1+*.patch")
if [ -z "$UNICODE_PATCH" ]; then
  UNICODE_PATCH=$(find_latest "$WILD_DIR/" "*unicode*.patch")
fi
if [ -n "$UNICODE_PATCH" ]; then
  info "匹配到 Unicode 防检测路径补丁: $UNICODE_PATCH"
  sed -i 's/\r$//' "$UNICODE_PATCH"
  patch -p1 --forward -f < "$UNICODE_PATCH" || warn "Unicode 补丁应用失败，继续..."
fi

if [ -f "lib/Makefile" ]; then
  grep -q '^CFLAGS_lz4.o += -O3' lib/Makefile || echo 'CFLAGS_lz4.o += -O3' >> lib/Makefile
  grep -q '^CFLAGS_lz4hc.o += -O3' lib/Makefile || echo 'CFLAGS_lz4hc.o += -O3' >> lib/Makefile
fi

git -C "$GITHUB_WORKSPACE/kernel_workspace/common" checkout -- drivers/dma-buf/dma-buf.c 2>/dev/null || true

count_rejs "Unicode/收尾"

if [ "$TOTAL_REJ" -gt 0 ]; then
  warn "补丁失败 hunk 总计 $TOTAL_REJ（涉及 $TOTAL_REJ_FILES 个文件），部分功能可能未生效"
  warn "明细已保存到 $REJ_DIR/*.summary 与同名 .rej"
else
  info "所有补丁干净应用（0 reject）"
fi

# Droidspaces
bash "$GITHUB_WORKSPACE/scripts/features/droidspaces.sh"

# ADIOS（模块化）
bash "$GITHUB_WORKSPACE/scripts/features/adios.sh"

# KVM NVHE（模块化）
bash "$GITHUB_WORKSPACE/scripts/features/nvhe.sh"

# Re-Kernel（模块化）
bash "$GITHUB_WORKSPACE/scripts/features/rekernel.sh"

# Baseband-guard（模块化）
bash "$GITHUB_WORKSPACE/scripts/features/baseband.sh"

# BBRv3（模块化）
bash "$GITHUB_WORKSPACE/scripts/features/bbr3.sh"

# 调度器优化（模块化）
bash "$GITHUB_WORKSPACE/scripts/features/sched.sh"

# f2fs：ATGC/GC_MERGE 默认值 + GC 三项调优（模块化）
bash "$GITHUB_WORKSPACE/scripts/features/f2fs.sh"

# libbpf：新 glibc 下 strchr() const 兼容修正（模块化）
bash "$GITHUB_WORKSPACE/scripts/features/libbpf.sh"

touch /tmp/sync_failed.list "$PENDING_SYNC"
sort -u "$PENDING_SYNC" /tmp/sync_failed.list -o "$PENDING_SYNC"
