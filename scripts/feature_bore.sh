#!/usr/bin/env bash
# BORE 调度器：独立功能脚本（工作流通过 BORE_ENABLE 开关引用）
# 资产目录：other_patch/bore/
set -u

if [[ "${BORE_ENABLE:-false}" != "true" ]]; then
  echo "[BORE] 未启用，跳过"
  exit 0
fi

WS="${GITHUB_WORKSPACE:-$(pwd)}"
COMMON="$WS/kernel_workspace/common"
BORE_DIR="$WS/other_patch/bore"
[[ -d "$COMMON" ]] || { echo "[BORE] 找不到内核树"; exit 1; }
[[ -f "$BORE_DIR/bore-6.6-cachy.patch" ]] || { echo "[BORE] 缺少补丁文件"; exit 1; }

cd "$COMMON" || exit 1
echo "[BORE] 应用上游补丁..."
patch -p1 -N -F 3 < "$BORE_DIR/bore-6.6-cachy.patch" > /tmp/bore.log 2>&1 || true
grep -q "previously applied" /tmp/bore.log && echo "[BORE] 补丁已存在（视为已应用）"

echo "[BORE] fair.c 兜底修正..."
python3 "$WS/scripts/bore_fixup.py" kernel/sched/fair.c || echo "[BORE] fixup 失败"

echo "[BORE] sched.h KABI 原地变换..."
python3 "$WS/scripts/bore_kabi.py" include/linux/sched.h || echo "[BORE] KABI 变换失败"

[ -f "$BORE_DIR/files/bore.c" ] && cp -f "$BORE_DIR/files/bore.c" kernel/sched/bore.c
[ -f "$BORE_DIR/files/bore.h" ] && cp -f "$BORE_DIR/files/bore.h" include/linux/sched/bore.h
echo "[BORE] 完成（补丁 + fixup + KABI）"
