#!/usr/bin/env bash
# WildKernels 额外小补丁：调度扫描顺序 / clear_page 对齐 / cpufreq unlikely
# 开关：WILD_EXTRA_ENABLE（默认 true）
set -euo pipefail
WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [ "${WILD_EXTRA_ENABLE:-false}" != "true" ]; then
  info "[WILD_EXTRA] 未启用，跳过"
  exit 0
fi

WILD_DIR="${WILD_DIR:-$HOME/.cache_patches/wild_patches}"
COMMON="$WS/kernel_workspace/common"
[ -d "$COMMON" ] || { warn "[WILD_EXTRA] 内核目录不存在"; exit 0; }
cd "$COMMON"

for p in adjust_cpu_scan_order clear_page_16bytes_align use_unlikely_wrap_cpufreq; do
  f="$WILD_DIR/common/$p.patch"
  if [ ! -f "$f" ]; then
    warn "[WILD_EXTRA] 缺少 $p.patch，跳过"
    continue
  fi
  sed -i "s/\r$//" "$f" 2>/dev/null || true
  if patch -p1 --forward -F 3 < "$f" >/dev/null 2>&1; then
    info "[WILD_EXTRA] 已应用 $p"
  else
    warn "[WILD_EXTRA] $p 应用失败或已存在，跳过"
  fi
done
exit 0