#!/usr/bin/env bash
# KVM NVHE 模块：AutoFDO call-graph-profile 元数据兼容
# 来源：scripts/apply_patches.sh 原第 355-358 行（原样搬迁）
# 开关：NVHE_ENABLE（原块无开关，默认 true 保持原行为）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [[ "${NVHE_ENABLE:-true}" != "true" ]]; then
  info "[NVHE] 未启用，跳过"
  exit 0
fi

# 原块依赖调用方的 cwd（原为 ADIOS 块留下的 kernel_workspace）；独立运行时显式进入
cd "$WS/kernel_workspace"

# ---- 原块开始（原第 355-358 行，原样搬迁，勿改） ----
# KVM NVHE：AutoFDO 生成的 .rel.llvm.* 元数据节会被 gen-hyprel 判为致命错误
if [ -f ./common/arch/arm64/tools/gen-hyprel.c ] && ! grep -q 'strncmp(section_name(shdr), "\.rel\.llvm\."' ./common/arch/arm64/tools/gen-hyprel.c; then
  apply_patch_file "other_patch/nvhe/nvhe_skip_cgprofile_rel.patch" /tmp/nvhe_cgprof.patch strict "KVM NVHE call-graph-profile 兼容"
fi

# ---- 原块结束 ----
