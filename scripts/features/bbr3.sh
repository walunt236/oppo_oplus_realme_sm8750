#!/usr/bin/env bash
# BBRv3 模块：BBRv3 TCP 拥塞控制回移与默认项
# 来源：scripts/apply_patches.sh 原第 386-401 行（原样搬迁）
# 开关：BBR3_ENABLE（原块无开关，默认 true 保持原行为）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [[ "${BBR3_ENABLE:-true}" != "true" ]]; then
  info "[BBRV3] 未启用，跳过"
  exit 0
fi

# ---- 原块开始（原第 386-401 行，原样搬迁，勿改） ----
# BBRv3
info "应用 BBRv3 补丁..."
cd "$GITHUB_WORKSPACE/kernel_workspace/common"
fetch_gh_file "WildKernels/kernel_patches" "common/bbrv3/0001-net-tcp-backport-BBRv3-to-android15-6.6.patch" "main" /tmp/bbrv3.patch

if git apply -p1 < /tmp/bbrv3.patch 2>/dev/null; then
  info "BBRv3 git apply 成功"
elif patch -p1 -F 3 < /tmp/bbrv3.patch 2>/dev/null; then
  info "BBRv3 patch 成功"
else
  error "BBRv3 补丁失败，中止构建"
  exit 1
fi

echo "CONFIG_TCP_CONG_BBR3=y" >> ./arch/arm64/configs/gki_defconfig
echo "CONFIG_DEFAULT_BBR3=y" >> ./arch/arm64/configs/gki_defconfig

# ---- 原块结束 ----
