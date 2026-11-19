#!/usr/bin/env bash
set -u

if [[ "${MEMCOMP_ENABLE:-false}" != "true" ]]; then
    echo "[FEATURE] memcomp 未启用，跳过"
    exit 0
fi

WS="${GITHUB_WORKSPACE:-$(pwd)}"
COMMON="$WS/kernel_workspace/common"
OVERLAY="$WS/other_patch/memcomp/memcomp-overlay.tar.gz"

if [[ ! -f "$OVERLAY" ]]; then
    echo "[FEATURE] memcomp overlay 缺失: $OVERLAY" >&2
    exit 1
fi

tar -xzf "$OVERLAY" -C "$COMMON"
echo "[FEATURE] memcomp overlay 已应用"
