#!/bin/bash
# 应用 BORE 调度器（可选步骤，由 bore_enable 开关控制）
set -euo pipefail
source "$(dirname "$0")/common.sh"

PATCH="$GITHUB_WORKSPACE/patches/bore/bore-6.6.143.patch"
[ -f "$PATCH" ] || die "BORE 补丁不存在: $PATCH"

cd "$GITHUB_WORKSPACE/kernel_workspace/common"

if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
  info "BORE 补丁干净应用"
else
  warn "BORE 补丁无法干净应用，改用 fuzzy 模式"
  patch -p1 -F 3 --forward < "$PATCH" || die "BORE 补丁应用失败"
fi

grep -q '^CONFIG_SCHED_BORE=y' arch/arm64/configs/gki_defconfig || \
  echo 'CONFIG_SCHED_BORE=y' >> arch/arm64/configs/gki_defconfig

# 关键闸门：BORE 补丁不得破坏 OPPO 厂商模块依赖的 trace hook
HOOKS=(
  '#include <trace/hooks/sched.h>'
  '#include <trace/hooks/dtask.h>'
  'EXPORT_TRACEPOINT_SYMBOL_GPL(sched_stat_runtime)'
)
for l in "${HOOKS[@]}"; do
  grep -qF "$l" kernel/sched/fair.c || die "BORE 补丁误删 OEM 内容: $l"
done

info "BORE 调度器已注入（OEM trace hook 校验通过）"
