#!/usr/bin/env bash
# Baseband-guard 模块：基带保护 LSM
# 来源：scripts/apply_patches.sh 原第 367-384 行（原样搬迁）
# 开关：BASEBAND_GUARD（沿用原变量，仅 true 时启用）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [[ "${BASEBAND_GUARD:-false}" != "true" ]]; then
  info "[BASEBAND] 未启用，跳过"
  exit 0
fi

# ---- 原块开始（原第 367-384 行，原样搬迁，勿改） ----
# Baseband-guard
if [[ "$BASEBAND_GUARD" == "true" ]]; then
  info "启用基带保护..."
  cd "$GITHUB_WORKSPACE/kernel_workspace"
  echo "CONFIG_BBG=y" >> ./common/arch/arm64/configs/gki_defconfig
  cd common
  curl -fSL --retry 3 --retry-delay 5 --retry-all-errors -o /tmp/baseband_setup.sh \
    "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" || {
    error "Baseband-guard 脚本下载失败"
    exit 1
  }
  bash /tmp/baseband_setup.sh || {
    error "Baseband-guard 安装失败"
    exit 1
  }
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
  grep -q 'baseband_guard' security/Kconfig || { error "BBG LSM 注入失败（security/Kconfig 无 baseband_guard），中止构建"; exit 1; }
fi

# ---- 原块结束 ----
