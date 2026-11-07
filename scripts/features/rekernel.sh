#!/usr/bin/env bash
# Re-Kernel 模块：CONFIG_REKERNEL 默认启用
# 来源：scripts/apply_patches.sh 原第 360-365 行（原样搬迁）
# 开关：REKERNEL_ENABLE（沿用原变量，未设置/false 时跳过）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [[ "${REKERNEL_ENABLE:-false}" != "true" ]]; then
  info "[RE-KERNEL] 未启用，跳过"
  exit 0
fi

# ---- 原块开始（原第 360-365 行，原样搬迁，勿改） ----
# Re-Kernel
if [[ "$REKERNEL_ENABLE" == "true" ]]; then
  info "启用 Re-Kernel 支持..."
  cd "$GITHUB_WORKSPACE/kernel_workspace"
  echo "CONFIG_REKERNEL=y" >> ./common/arch/arm64/configs/gki_defconfig
fi

# ---- 原块结束 ----
