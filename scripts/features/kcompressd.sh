#!/usr/bin/env bash
# Kcompressd-Unofficial 0.5：把 6.12 补丁回移到 6.6
# 开关：KCOMPRESSD_ENABLE（默认 false）
#
# 6.6 适配要点（详见 other_patch/kcompressd/kcompressd-6.6.patch）：
#   - __swap_writepage() 仍收 struct page *，改用 &folio->page
#   - vendor 6.6.143 已回移 folio->swap，保留 swp_swap_info() 读取 SWP_SYNCHRONOUS_IO
#   - 无 zswap_is_enabled()，用 zswap_never_enabled() 近似
#   - 无 mem_cgroup_zswap_writeback_enabled()，移除该门控
#   - 6.6 kfifo.h 会经 scatterlist.h 反向包含 mm.h，不能放进 mmzone.h，
#     pglist_data 改存 struct kfifo *，由 kswapd_run() 单独分配
set -u

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
# shellcheck source=/dev/null
source "$WS/scripts/common.sh"

if [[ "${KCOMPRESSD_ENABLE:-false}" != "true" ]]; then
  info "[KCOMPRESSD] 未启用，跳过"
  exit 0
fi

COMMON="$WS/kernel_workspace/common"
PATCH="$WS/other_patch/kcompressd/kcompressd-6.6.patch"
LOG="$(mktemp)"
REJ_BEFORE="$(mktemp)"
REJ_AFTER="$(mktemp)"
trap 'rm -f "$LOG" "$REJ_BEFORE" "$REJ_AFTER"' EXIT

[[ -f "$PATCH" ]] || die "[KCOMPRESSD] 缺少补丁: $PATCH"
[[ -d "$COMMON" ]] || die "[KCOMPRESSD] 内核源码目录不存在: $COMMON"
cd "$COMMON" || die "[KCOMPRESSD] 进入内核目录失败: $COMMON"

MARKERS=(
  "include/linux/mmzone.h:kcompress_fifo"
  "include/linux/swap.h:vm_kcompressd"
  "mm/page_io.c:kcompressd_store"
  "mm/vmscan.c:kcompress_fifo"
  "kernel/sysctl.c:vm_kcompressd"
)

missing_markers() {
  local m f s
  for m in "${MARKERS[@]}"; do
    f="${m%%:*}"
    s="${m#*:}"
    if ! grep -qF -- "$s" "$f" 2>/dev/null; then
      printf '%s\n' "$m"
    fi
  done
  return 0
}

if [[ -z "$(missing_markers)" ]]; then
  info "[KCOMPRESSD] 补丁已应用，跳过（幂等）"
  exit 0
fi

info "[KCOMPRESSD] 应用 6.6 回移补丁: $(basename "$PATCH")"
find . -name '*.rej' -type f 2>/dev/null | sort > "$REJ_BEFORE" || true

if patch -p1 -N -F 3 < "$PATCH" > "$LOG" 2>&1; then
  info "[KCOMPRESSD] patch 应用成功"
else
  warn "[KCOMPRESSD] patch 有失败 hunk，打印后继续（构建可能失败）"
  { grep -E '^(patching file|Hunk #[0-9]+|.*FAILED)' "$LOG" || true; } | head -40 | while IFS= read -r line; do
    warn "[KCOMPRESSD] $line"
  done

  find . -name '*.rej' -type f 2>/dev/null | sort > "$REJ_AFTER" || true
  new_rej="$(comm -13 "$REJ_BEFORE" "$REJ_AFTER" 2>/dev/null || true)"
  if [[ -n "$new_rej" ]]; then
    while IFS= read -r rej; do
      [[ -n "$rej" ]] || continue
      warn "[KCOMPRESSD] ---- 失败 hunk: $rej ----"
      sed -n '1,120p' "$rej" | while IFS= read -r line; do
        warn "[KCOMPRESSD] $line"
      done
    done <<< "$new_rej"
  else
    { grep -vE '^(patching file|Hunk #[0-9]+ succeeded)' "$LOG" || true; } | head -40 | while IFS= read -r line; do
      warn "[KCOMPRESSD] $line"
    done
  fi
fi

# 兜底：mmzone.h 字段 hunk 若失败，用 Python 精确补齐（幂等）
if ! grep -qF "kcompress_fifo" include/linux/mmzone.h 2>/dev/null; then
  warn "[KCOMPRESSD] mmzone.h 字段缺失，尝试 Python 兜底插入"
  python3 - <<'PYEOF'
p = "include/linux/mmzone.h"
s = open(p, encoding="utf-8").read()
if "kcompress_fifo" not in s:
    if "struct kfifo;" not in s:
        s = s.replace("#include <asm/page.h>", "#include <asm/page.h>\n\nstruct kfifo;", 1)
    fields = ("\n#define KCOMPRESS_FIFO_SIZE 256\n"
              "\twait_queue_head_t kcompressd_wait;\n"
              "\tstruct task_struct *kcompressd;\n"
              "\tstruct kfifo *kcompress_fifo;\n"
              "\tspinlock_t kcompress_fifo_lock;\n")
    idx = s.rfind("} pg_data_t;")
    if idx > 0:
        s = s[:idx] + fields + s[idx:]
        open(p, "w", encoding="utf-8").write(s)
        print("inserted")
    else:
        print("anchor-not-found")
PYEOF
fi

# 诊断：跳过 kthread 创建（定位卡开机）
if [[ "${KCOMPRESSD_NO_THREAD:-true}" == "true" ]]; then
  warn "[KCOMPRESSD] 诊断模式：禁用 kthread 创建"
  python3 "$WS/scripts/features/kcompressd_no_thread.py" || warn "[KCOMPRESSD] 诊断脚本执行失败"
fi

missing="$(missing_markers)"
if [[ -z "$missing" ]]; then
  info "[KCOMPRESSD] 幂等校验通过：${#MARKERS[@]} 处标识齐全"
else
  warn "[KCOMPRESSD] 幂等校验失败，缺失: $(printf '%s\n' "$missing" | tr '\n' ' ')"
  warn "[KCOMPRESSD] 请检查上面的失败 hunk / .rej 文件"
fi

exit 0
