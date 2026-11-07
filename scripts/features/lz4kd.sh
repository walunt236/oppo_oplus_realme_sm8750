#!/usr/bin/env bash
# LZ4KD 模块：LZ4K 内核压缩补丁
# 来源：scripts/apply_patches.sh 原第 315-331 行（原样搬迁）
# 开关：LZ4KD_ENABLE=true（沿用原变量；未设置/false 时跳过）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [[ "${LZ4KD_ENABLE:-false}" != "true" ]]; then
  info "[LZ4KD] 未启用，跳过"
  exit 0
fi

# 预取阶段由主脚本完成；独立运行时使用与主脚本一致的默认值
SUKI_CACHE_DIR="${SUKI_CACHE_DIR:-$HOME/.cache_patches/sukisu_patches}"

# ---- 原块开始（apply_patches.sh 第 315-331 行，原样搬迁，勿改） ----
# lz4kd
if [[ "$LZ4KD_ENABLE" == "true" ]]; then
  cd "$GITHUB_WORKSPACE/kernel_workspace/common"

  cp -r "$SUKI_CACHE_DIR/other/zram/lz4k/include/linux/"* ./include/linux/
  cp -r "$SUKI_CACHE_DIR/other/zram/lz4k/lib/"* ./lib/
  cp -r "$SUKI_CACHE_DIR/other/zram/lz4k/crypto/"* ./crypto/
  cp "$SUKI_CACHE_DIR/other/zram/zram_patch/6.6/lz4kd.patch" ./
  patch -p1 -F 3 < lz4kd.patch || true

  if [ -f crypto/lz4kd.c ] && [ -f lib/lz4kd/lz4kd_decode.c ] && grep -q 'lz4kd' crypto/Makefile && grep -q 'lz4kd' lib/Makefile; then
    info "LZ4KD 补丁生效 (crypto/lz4kd.c + lib/lz4kd/ 已就位)"
  else
    error "LZ4KD 补丁未生效，中止构建"
    exit 1
  fi
fi

# ---- 原块结束 ----
