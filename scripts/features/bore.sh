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
# 完全体：sched_bore=1，开机即接管（实测运行稳定）
if [ -f kernel/sched/bore.c ] && grep -q "sched_bore.*= 0;" kernel/sched/bore.c; then
  sed -i "s/^\(u8 \+__read_mostly \+sched_bore \+=\) 0;/\1 1;/" kernel/sched/bore.c
  echo "[BORE] sched_bore 默认值改为 1（完全体）"
fi

# 修复：补丁漏加 include 的文件（core.c / debug.c）
python3 - << 'PYEOF'
import sys
files = ["kernel/sched/core.c", "kernel/sched/debug.c"]
syms = ("effective_prio_bore", "bore_score", "sched_init_bore")
anchors = ['#include "sched.h"', '#include "sched/debug.h"', '#include <linux/sched.h>']
for p in files:
    try:
        s = open(p, encoding="utf-8").read()
    except FileNotFoundError:
        continue
    if "linux/sched/bore.h" in s:
        continue
    if not any(k in s for k in syms):
        continue
    for a in anchors:
        if a in s:
            s = s.replace(a, "#include <linux/sched/bore.h>\n" + a, 1)
            open(p, "w", encoding="utf-8").write(s)
            print("[BORE] %s 已补 include" % p)
            break
    else:
        print("[BORE] %s 未找到 include 锚点" % p)
PYEOF
echo "[BORE] 完成"
