#!/usr/bin/env bash
# 补丁仓预取模块：susfs4ksu / zram_patches / SukiSU_patch / wild_patches 并行同步 + SUSFS release 对齐
# 来源：scripts/apply_patches.sh 原第 35-76 行（原样搬迁）
# 开关：无（同步任务按 SUSFS_ENABLE / LZ4KD_ENABLE 条件启动）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

# release 对齐依赖 KernelSU 子脚本回传的 KSU_TAG_DATE；主脚本已 source，独立运行时自行读取
if [ -f /tmp/ksu_state.env ]; then
  . /tmp/ksu_state.env
fi

# 原块在 set -u 下依赖工作流环境；独立运行时使用与主流程一致的默认值
SUSFS_ENABLE="${SUSFS_ENABLE:-false}"
LZ4KD_ENABLE="${LZ4KD_ENABLE:-false}"
KSU_TYPE="${KSU_TYPE:-none}"

# ---- 原块开始（apply_patches.sh 原第 35-76 行，原样搬迁，勿改） ----
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
# ---- 原块结束 ----

# 子进程变量回传：主脚本后续 susfs/lz4zstd/lz4kd/hmbird 需要这些缓存路径
printf 'SUSFS_CACHE_DIR=%q\nZRAM_CACHE_DIR=%q\nSUKI_CACHE_DIR=%q\nWILD_DIR=%q\nSUSFS_BRANCH=%q\n' \
  "$SUSFS_CACHE_DIR" "$ZRAM_CACHE_DIR" "$SUKI_CACHE_DIR" "$WILD_DIR" "${SUSFS_BRANCH:-}" > /tmp/prefetch_state.env
