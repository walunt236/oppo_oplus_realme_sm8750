#!/usr/bin/env bash
# BORE 调度器：Hipuu 适配版（KABI 保留槽 1 存指针 + kzalloc bore_ctx）
set -u
if [[ "${BORE_ENABLE:-false}" != "true" ]]; then
  echo "[BORE] 未启用，跳过"
  exit 0
fi
WS="${GITHUB_WORKSPACE:-$(pwd)}"
COMMON="$WS/kernel_workspace/common"
PATCH_DIR="$WS/other_patch/bore"
[[ -f "$PATCH_DIR/bore-7.0.0.patch" ]] || { echo "[BORE] 缺少补丁"; exit 1; }
cd "$COMMON" || exit 1
echo "[BORE] 应用 7.0.0 补丁..."
patch -p1 -N -F 3 < "$PATCH_DIR/bore-7.0.0.patch" > /tmp/bore.log 2>&1 || true
if grep -q "FAILED" /tmp/bore.log; then
  echo "[BORE] 有 hunk 失败："
  grep -E "FAILED|Hunk" /tmp/bore.log | head -5
fi
# 安全默认：sched_bore=0，开机不接管
if [ -f kernel/sched/bore.c ] && grep -q "sched_bore.*= 1;" kernel/sched/bore.c; then
  sed -i "s/^\(u8 \+__read_mostly \+sched_bore \+=\) 1;/\1 0;/" kernel/sched/bore.c
  echo "[BORE] sched_bore 默认值改为 0"
fi
echo "[BORE] 完成"
