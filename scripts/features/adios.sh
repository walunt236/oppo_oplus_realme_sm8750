#!/usr/bin/env bash
# ADIOS 模块：ADIOS I/O 调度器补丁
# 来源：scripts/apply_patches.sh 原第 350-353 行（原样搬迁）
# 开关：ADIOS_ENABLE（默认 true）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [[ "${ADIOS_ENABLE:-true}" != "true" ]]; then
  info "[ADIOS] 未启用，跳过"
  exit 0
fi

# ---- 原块开始（原第 350-353 行，原样搬迁，勿改） ----
# ADIOS
info "启用 ADIOS I/O 调度器..."
cd "$GITHUB_WORKSPACE/kernel_workspace"
apply_patch_file "other_patch/adios/adios_block_only.patch" /tmp/adios.patch strict "ADIOS 补丁"

# ---- 原块结束 ----
