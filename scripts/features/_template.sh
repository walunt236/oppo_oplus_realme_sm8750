#!/usr/bin/env bash
# shellcheck disable=SC2034  # 模板占位变量，复制成正式模块后才会被引用
set -u
if [[ "${FEATURE_ENABLE:-false}" != "true" ]]; then
  echo "[FEATURE] 未启用，跳过"
  exit 0
fi
WS="${GITHUB_WORKSPACE:-$(pwd)}"
COMMON="$WS/kernel_workspace/common"
ASSETS="$WS/other_patch/<name>"
echo "[FEATURE] 应用..."
# 1. 补丁: patch -p1 -F 3 < "$ASSETS/xxx.patch"
# 2. 源码调整: python3 "$WS/scripts/xxx.py"
# 3. 配置由 configs/features/<name>.config 负责
echo "[FEATURE] 完成"
