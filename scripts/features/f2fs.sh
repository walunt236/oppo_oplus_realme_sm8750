#!/usr/bin/env bash
# f2fs 模块：ATGC/GC_MERGE 默认值 + GC 三项调优
# 来源：scripts/apply_patches.sh 原第 530-561 行（原样搬迁）
# 开关：F2FS_ENABLE=true（原块无开关，本次新增；默认 true，保持原行为）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [[ "${F2FS_ENABLE:-true}" != "true" ]]; then
  info "[F2FS] 未启用，跳过"
  exit 0
fi

cd "$WS/kernel_workspace/common"

# ---- 原块开始（apply_patches.sh 第 530-561 行，原样搬迁，勿改） ----
# f2fs：默认启用 ATGC（年龄阈值 GC）与 GC_MERGE（GC 写合并）
# 两者在 6.6.143 里已存在，但只能通过挂载参数开启；而挂载参数由 ROM 的 fstab 决定。
# 这里在 default_options() 之后、解析挂载参数之前打开，ROM 显式传 nogc_merge 仍可覆盖。
F2FS_ATGC_PATCH="$GITHUB_WORKSPACE/other_patch/f2fs/f2fs_default_atgc_gcmerge.patch"
if [ -f "$F2FS_ATGC_PATCH" ]; then
  if patch -p1 --forward -F 3 < "$F2FS_ATGC_PATCH" >/dev/null 2>&1; then
    info "f2fs ATGC / GC_MERGE 默认值已启用"
  else
    warn "f2fs ATGC / GC_MERGE 补丁应用失败（继续构建）"
  fi
fi
if grep -q 'set_opt(sbi, ATGC);' fs/f2fs/super.c 2>/dev/null && \
   grep -q 'set_opt(sbi, GC_MERGE);' fs/f2fs/super.c 2>/dev/null; then
  info "f2fs ATGC / GC_MERGE 校验通过"
else
  warn "f2fs ATGC / GC_MERGE 未生效，GC 行为与上游一致"
fi

# f2fs GC 三项调优：紧急休眠 500→50ms、拥塞超时 20→6ms、fsync 批量 8→20
# 来源 WildKernels/kernel_patches，均已验证适用于 6.6.143
F2FS_GC_TUNING="$GITHUB_WORKSPACE/other_patch/f2fs/f2fs_gc_tuning.patch"
if [ -f "$F2FS_GC_TUNING" ]; then
  patch -p1 --forward -F 3 < "$F2FS_GC_TUNING" > /tmp/f2fs_gc_tuning.log 2>&1 || true
fi
if grep -q 'DEF_GC_THREAD_URGENT_SLEEP_TIME.50' fs/f2fs/gc.h 2>/dev/null && \
   grep -q 'msecs_to_jiffies(6)' fs/f2fs/f2fs.h 2>/dev/null && \
   grep -q 'DEF_MIN_FSYNC_BLOCKS.20' fs/f2fs/segment.h 2>/dev/null; then
  info "f2fs GC 调优已生效（紧急休眠 50ms / 拥塞 6ms / fsync 批量 20）"
else
  warn "f2fs GC 调优未完全生效"
  grep -E 'FAILED|rej' /tmp/f2fs_gc_tuning.log 2>/dev/null | head -3 || true
fi

# ---- 原块结束 ----
