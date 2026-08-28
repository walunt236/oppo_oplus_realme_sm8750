#!/bin/bash
# common.sh — 公共库：日志/网络回退/补丁拉取
set -euo pipefail

LOG_FILE="${LOG_FILE:-$GITHUB_WORKSPACE/build_summary.log}"

info() { echo "[INFO] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[WARN] $*" | tee -a "$LOG_FILE"; }
error() { echo "[ERROR] $*" | tee -a "$LOG_FILE"; }

# git 包装：直连失败自动走 Clash 代理
glr() {
  git -c http.version=HTTP/1.1 "$@" 2>/dev/null ||
    git -c http.proxy=http://127.0.0.1:7897 -c https.proxy=http://127.0.0.1:7897 -c http.version=HTTP/1.1 "$@"
}

# 本地代理探测，命中则写入 GITHUB_ENV
detect_proxy() {
  if curl -s -o /dev/null --connect-timeout 2 --max-time 3 --proxy http://127.0.0.1:7897 https://api.github.com 2>/dev/null; then
    echo "http_proxy=http://127.0.0.1:7897" >> "$GITHUB_ENV"
    echo "https_proxy=http://127.0.0.1:7897" >> "$GITHUB_ENV"
    info "检测到本地代理 127.0.0.1:7897，网络操作走代理"
  else
    info "未检测到代理，纯直连模式（api/codeload/SSH443 直连可用，AOSP 走 glr 回退）"
  fi
}

# 从本仓库 api.github.com contents 拉取文件（base64）
fetch_repo_file() {
  local path="$1" out="$2"
  curl -fsSL --retry 3 --retry-delay 5 -H "Authorization: token ${GH_TOKEN:-}" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/contents/$path?ref=$GITHUB_REF_NAME" |
    python3 -c "import sys,json,base64;open('$out','wb').write(base64.b64decode(json.load(sys.stdin)['content']))"
}

# 补丁仓缓存化：已有则增量，否则克隆
ensure_patch_repo() {
  local url="$1" dir="$2" branch="${3:-main}"
  mkdir -p "$HOME/.cache_patches"
  if [ -d "$dir/.git" ]; then
    info "[秒过] 本地补丁仓 $dir 增量同步..."
    git -C "$dir" fetch --depth=1 origin "$branch" || true
    git -C "$dir" reset --hard FETCH_HEAD || true
  else
    info "首次克隆 $url ..."
    git clone --depth=1 "$url" "$dir" -b "$branch"
  fi
}

