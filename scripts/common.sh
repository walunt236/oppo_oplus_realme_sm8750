#!/bin/bash
# common.sh — 公共库：日志/网络回退/重试/补丁拉取
set -euo pipefail

LOG_FILE="${LOG_FILE:-$GITHUB_WORKSPACE/build_summary.log}"

info() { echo "[INFO] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[WARN] $*" | tee -a "$LOG_FILE"; }
error() { echo "[ERROR] $*" | tee -a "$LOG_FILE"; }
die() { error "$*"; exit 1; }

glr() {
  git -c http.version=HTTP/1.1 "$@" 2>/dev/null ||
    git -c http.proxy=http://127.0.0.1:7897 -c https.proxy=http://127.0.0.1:7897 -c http.version=HTTP/1.1 "$@"
}

detect_proxy() {
  if curl -s -o /dev/null --connect-timeout 2 --max-time 3 --proxy http://127.0.0.1:7897 https://api.github.com 2>/dev/null; then
    echo "http_proxy=http://127.0.0.1:7897" >> "$GITHUB_ENV"
    echo "https_proxy=http://127.0.0.1:7897" >> "$GITHUB_ENV"
    info "检测到本地代理 127.0.0.1:7897，网络操作走代理"
  else
    info "未检测到代理，纯直连模式（api/codeload/SSH443 直连可用，AOSP 走 glr 回退）"
  fi
}

retry() {
  local label="$1" n="$2" delay="${3:-5}"
  shift 3
  local i=1
  until "$@"; do
    [ "$i" -lt "$n" ] || return 1
    warn "$label 失败(第${i}次)，${delay} 秒后重试..."
    sleep "$delay"
    i=$((i + 1))
  done
}

fetch_gh_file() {
  local repo="$1" path="$2" ref="$3" out="$4"
  curl -fsSL --retry 3 --retry-delay 5 -H "Authorization: token ${GH_TOKEN:-}" \
    "https://api.github.com/repos/$repo/contents/$path?ref=$ref" |
    python3 -c "import sys,json,base64;open('$out','wb').write(base64.b64decode(json.load(sys.stdin)['content']))"
}

fetch_repo_file() { fetch_gh_file "$GITHUB_REPOSITORY" "$1" "$GITHUB_REF_NAME" "$2"; }

find_latest() {
  find "$1" -type f -name "$2" 2>/dev/null | sort | tail -n 1 || true
}

apply_repo_patch() {
  local repo_path="$1" out="$2" mode="$3" label="$4"
  fetch_repo_file "$repo_path" "$out"
  if ( cd ./common && patch -p1 -F 3 < "$out" ); then
    info "$label 应用成功"
  elif [[ "$mode" == "strict" ]]; then
    die "$label 应用失败，中止构建"
  else
    warn "$label 应用失败，继续..."
  fi
}
