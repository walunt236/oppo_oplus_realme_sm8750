#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

cd "$GITHUB_WORKSPACE/kernel_workspace"
: > /tmp/sync_failed.list

REJ_DIR="${OUT_DIR:-$HOME/share/out}/rej"
mkdir -p "$REJ_DIR"
export REJ_DIR

# KernelSU（模块化；KSU_TYPE=none 时由子脚本写 KSUVER=none）
bash "$GITHUB_WORKSPACE/scripts/features/kernelsu.sh"
if [ -f /tmp/ksu_state.env ]; then
  . /tmp/ksu_state.env
fi

# 补丁仓并行预取（模块化；缓存目录、SUSFS release 对齐随块搬迁）
bash "$GITHUB_WORKSPACE/scripts/features/prefetch.sh"
if [ -f /tmp/prefetch_state.env ]; then
  . /tmp/prefetch_state.env
fi
export SUSFS_CACHE_DIR ZRAM_CACHE_DIR SUKI_CACHE_DIR WILD_DIR SUSFS_BRANCH

# SUSFS：补丁/隐藏（模块化；预取同步与 release 对齐见 features/prefetch.sh）
bash "$GITHUB_WORKSPACE/scripts/features/susfs.sh"

# lz4/zstd（模块化；lz4accel 拉取与 zstd 过滤随块搬迁）
bash "$GITHUB_WORKSPACE/scripts/features/lz4zstd.sh"

# lz4kd
bash "$GITHUB_WORKSPACE/scripts/features/lz4kd.sh"

# HMBIRD/Polly 内存/IO 补丁（模块化；Overwriter/Defconfig/18 patch/EnablePOLLY/mm_* 随块搬迁）
bash "$GITHUB_WORKSPACE/scripts/features/hmbird.sh"

# 收尾（模块化；Unicode/lz4 CFLAGS/dma-buf/reject 汇总随块搬迁）
bash "$GITHUB_WORKSPACE/scripts/features/finalize.sh"

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
# BORE（默认关闭，BORE_ENABLE=true 才应用）
bash "$GITHUB_WORKSPACE/scripts/features/bore.sh"
