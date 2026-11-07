#!/usr/bin/env bash
# 收尾模块：Unicode 防检测 / lz4 CFLAGS / dma-buf 回滚 / reject 汇总
# 来源：scripts/apply_patches.sh 原第 11-27、154-187 行（reject 助手与收尾块；原样搬迁）
# 开关：无（收尾始终执行）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

# 预取阶段由主脚本完成；独立运行时使用与主脚本一致的默认值
WILD_DIR="${WILD_DIR:-$HOME/.cache_patches/wild_patches}"

# 主脚本已在开头创建；独立运行时使用与主脚本一致的默认值
REJ_DIR="${REJ_DIR:-${OUT_DIR:-$HOME/share/out}/rej}"
mkdir -p "$REJ_DIR"

# ---- 原块开始（apply_patches.sh 原第 11-27 行，原样搬迁，勿改） ----
count_rejs() {
  local label="$1" files hunks safe
  safe="${label//\//_}"
  files=$(find . -name "*.rej" 2>/dev/null | wc -l)
  hunks=$(find . -name "*.rej" -exec awk '/^@@/{n++} END{print n+0}' {} \; 2>/dev/null | awk '{s+=$1} END{print s+0}')
  if [ "$files" -gt 0 ]; then
    find . -name "*.rej" 2>/dev/null | while IFS= read -r f; do
      rel=$(printf '%s' "$f" | sed 's|^\./||')
      cp -f "$f" "$REJ_DIR/$safe-$(printf '%s' "$rel" | tr '/' '_')" 2>/dev/null || true
      printf '%s  失败hunk=%s\n' "$rel" "$(awk '/^@@/{n++} END{print n+0}' "$f")" >> "$REJ_DIR/$safe.summary"
    done
    find . -name "*.rej" -delete 2>/dev/null || true
  fi
  TOTAL_REJ=$((TOTAL_REJ + hunks))
  TOTAL_REJ_FILES=$((TOTAL_REJ_FILES + files))
  info "$label reject: ${files} 文件 / ${hunks} hunk（明细 $REJ_DIR/$safe.summary）"
}
# ---- 原块结束 ----

cd "$WS/kernel_workspace/common"

# ---- 原块开始（apply_patches.sh 原第 154-187 行，原样搬迁，勿改） ----
TOTAL_REJ=0
TOTAL_REJ_FILES=0
count_rejs "基础补丁"

# AOSP 直连补丁已移除：11 个 commit 的改动已 100% 包含在 6.6.143 上游，
# 且 aosp-mirror 仓库已停止更新（最后推送 2025-11），保留只会产生无效 reject。

# palazik 补丁已停用（try_to_steal_block 与 6.6.143 的 fallback 流程不兼容，收益小）

UNICODE_PATCH=$(find_latest "$WILD_DIR/" "*unicode*6.1+*.patch")
if [ -z "$UNICODE_PATCH" ]; then
  UNICODE_PATCH=$(find_latest "$WILD_DIR/" "*unicode*.patch")
fi
if [ -n "$UNICODE_PATCH" ]; then
  info "匹配到 Unicode 防检测路径补丁: $UNICODE_PATCH"
  sed -i 's/\r$//' "$UNICODE_PATCH"
  patch -p1 --forward -f < "$UNICODE_PATCH" || warn "Unicode 补丁应用失败，继续..."
fi

if [ -f "lib/Makefile" ]; then
  grep -q '^CFLAGS_lz4.o += -O3' lib/Makefile || echo 'CFLAGS_lz4.o += -O3' >> lib/Makefile
  grep -q '^CFLAGS_lz4hc.o += -O3' lib/Makefile || echo 'CFLAGS_lz4hc.o += -O3' >> lib/Makefile
fi

git -C "$GITHUB_WORKSPACE/kernel_workspace/common" checkout -- drivers/dma-buf/dma-buf.c 2>/dev/null || true

count_rejs "Unicode/收尾"

if [ "$TOTAL_REJ" -gt 0 ]; then
  warn "补丁失败 hunk 总计 $TOTAL_REJ（涉及 $TOTAL_REJ_FILES 个文件），部分功能可能未生效"
  warn "明细已保存到 $REJ_DIR/*.summary 与同名 .rej"
else
  info "所有补丁干净应用（0 reject）"
fi
# ---- 原块结束 ----
