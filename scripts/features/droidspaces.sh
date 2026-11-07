#!/usr/bin/env bash
# Droidspaces 模块：容器支持补丁（SysV IPC / OPlus BSP / ntsync / evdi）
# 来源：scripts/apply_patches.sh 原第 435-457 行（原样搬迁）
# 开关：DROIDSPACES_ENABLE=false|standard|extend（沿用原变量；默认启用，false 时跳过）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [[ "${DROIDSPACES_ENABLE:-true}" == "false" ]]; then
  info "[DROIDSPACES] 未启用，跳过"
  exit 0
fi

# ---- 原块开始（apply_patches.sh 第 435-457 行，原样搬迁，勿改） ----
# Droidspaces
if [[ "$DROIDSPACES_ENABLE" != "false" ]]; then
  info "启用 Droidspaces 容器支持..."
  cd "$GITHUB_WORKSPACE/kernel_workspace"
  apply_patch_file "other_patch/droidspaces/fix_sysvipc_kabi_6_7_8.patch" /tmp/fix_sysvipc.patch nonstrict "fix_sysvipc_kabi 补丁"
  apply_patch_file "other_patch/droidspaces/fix_oplus_bsp_midas.patch" /tmp/fix_midas.patch nonstrict "fix_oplus_bsp_midas 补丁"
  cp "$GITHUB_WORKSPACE/other_patch/droidspaces/ntsync_base.patch" /tmp/ntsync_base.patch
  if cp "$GITHUB_WORKSPACE/other_patch/droidspaces/ntsync_compat_android15-$KERNEL_VERSION.patch" /tmp/ntsync_compat.patch; then
    ( cd ./common && patch -p1 -F 3 < /tmp/ntsync_base.patch > /tmp/ntsync.log 2>&1 ) || true
    ( cd ./common && patch -p1 -F 3 < /tmp/ntsync_compat.patch >> /tmp/ntsync.log 2>&1 ) || true
    if [ -f ./common/drivers/misc/ntsync.c ]; then
      info "ntsync 已就位（Wine/Proton 同步原语）"
    else
      warn "ntsync 补丁未生效（明细 /tmp/ntsync.log）"
    fi
  else
    warn "ntsync compat 补丁拉取失败，跳过（仅 base 已应用）"
    ( cd ./common && patch -p1 -F 3 < /tmp/ntsync_base.patch ) || true
  fi
  if [[ "$DROIDSPACES_ENABLE" == "extend" ]]; then
    apply_patch_file "other_patch/droidspaces/evdi_drm.patch" /tmp/evdi_drm.patch nonstrict "evdi_drm 补丁"
  fi
fi

# ---- 原块结束 ----
