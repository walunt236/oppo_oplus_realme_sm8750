#!/usr/bin/env bash
# libbpf 模块：新 glibc 下 strchr() const 兼容修正
# 来源：scripts/apply_patches.sh 原第 562-578 行（原样搬迁）
# 开关：LIBBPF_ENABLE=true（原块无开关，本次新增；默认 true，保持原行为）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [[ "${LIBBPF_ENABLE:-true}" != "true" ]]; then
  info "[LIBBPF] 未启用，跳过"
  exit 0
fi

cd "$WS/kernel_workspace/common"

# ---- 原块开始（apply_patches.sh 第 562-578 行，原样搬迁，勿改） ----

# 新 glibc（如 26.04 的 2.42）下 strchr() 对 const 参数返回 const char*，
# 会与内核自带 -Werror 冲突，导致 resolve_btfids 编译失败。
LIBBPF="$GITHUB_WORKSPACE/kernel_workspace/common/tools/lib/bpf/libbpf.c"
# 自愈：旧版补丁在 6.6.14x 上会产生 const const
if grep -qE 'const const char \*next_path;' "$LIBBPF" 2>/dev/null; then
  sed -i 's/const const char \*next_path;/const char *next_path;/' "$LIBBPF"
  info "libbpf const 重复声明已修正"
fi
if grep -qE '^[[:space:]]*char \*next_path;' "$LIBBPF" 2>/dev/null; then
  sed -i 's/^[[:space:]]*char \*next_path;/const char *next_path;/' "$LIBBPF"
  info "libbpf const 补丁已应用（新 glibc 兼容）"
elif grep -qE '^[[:space:]]*const char \*next_path;' "$LIBBPF" 2>/dev/null; then
  info "libbpf 已是 const 声明（上游已修），跳过该补丁"
else
  warn "libbpf next_path 声明未找到，跳过"
fi

# ---- 原块结束 ----
