#!/bin/bash
set -euo pipefail

# 参数集中定义（唯一来源）；用 BASH_SOURCE 保证被 source 时路径正确
. "$(dirname "${BASH_SOURCE[0]}")/build.env"

LOG_FILE="${LOG_FILE:-$GITHUB_WORKSPACE/build_summary.log}"

info() { echo "[INFO] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[WARN] $*" | tee -a "$LOG_FILE"; }
error() { echo "[ERROR] $*" | tee -a "$LOG_FILE"; }
die() { error "$*"; exit 1; }

glr() {
  local out
  if out=$(git -c http.proxy= -c https.proxy= -c http.version=HTTP/1.1 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 "$@" 2>&1); then
    printf '%s\n' "$out" >&2
    return 0
  fi
  if [ -n "${PROXY_URL:-}" ]; then
    warn "glr 直连失败，改用代理 $PROXY_URL 重试"
    git -c http.proxy="$PROXY_URL" -c https.proxy="$PROXY_URL" -c http.version=HTTP/1.1 \
        -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 "$@"
  else
    warn "glr 直连失败（未配置 PROXY_URL，不再重试）: $(printf '%s\n' "$out" | grep -iE 'fatal|error|timed out|Could not' | tail -1)"
    return 1
  fi
}

gproxy() {
  if [ -n "${PROXY_URL:-}" ]; then
    git -c http.proxy="$PROXY_URL" -c https.proxy="$PROXY_URL" -c http.version=HTTP/1.1 \
        -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 "$@"
  else
    git "$@"
  fi
}

PENDING_SYNC="$HOME/.cache_patches/pending_sync"
export PENDING_SYNC  # 由 apply_patches.sh 读取

sync_repo() {
  local url="$1" dir="$2" branch="${3:-main}"
  if [ -d "$dir/.git" ]; then
    if glr -C "$dir" fetch --depth=1 origin "$branch"; then
      git -C "$dir" reset --hard FETCH_HEAD
      info "[动态] $dir 已同步 $branch 最新"
    else
      warn "$dir fetch 失败，使用本地已有版本"
      echo "$url|$dir|$branch" >> /tmp/sync_failed.list
      return 1
    fi
  else
    rm -rf "$dir"
    glr clone --depth=1 "$url" "$dir" -b "$branch" || { error "补丁仓克隆失败: $url ($branch)"; exit 1; }
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
  curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 10 --max-time 60 -H "Authorization: token ${GH_TOKEN:-}" \
    "https://api.github.com/repos/$repo/contents/$path?ref=$ref" |
    python3 -c "import sys,json,base64; c=json.load(sys.stdin); open('$out','wb').write(base64.b64decode(c['content']))"
}

find_latest() {
  find "$1" -type f -name "$2" 2>/dev/null | sort | tail -n 1 || true
}

apply_patch_file() {
  local src="$1" out="$2" mode="$3" label="$4"
  local log
  cp "$GITHUB_WORKSPACE/$src" "$out" || { warn "$label 源文件缺失，跳过"; return 0; }
  log=$(mktemp)
  if ( cd ./common && patch -p1 -F 3 < "$out" > "$log" 2>&1 ); then
    info "$label 应用成功"
  elif grep -qE "previously applied|Skipping patch" "$log"; then
    warn "$label 已由上游补丁覆盖，跳过（视为成功）"
  elif [[ "$mode" == "strict" ]]; then
    grep -E "FAILED|Hunk" "$log" | head -5 || true
    die "$label 应用失败，中止构建"
  else
    warn "$label 应用失败，继续..."
  fi
  rm -f "$log"
}
  if ( cd ./common && patch -p1 -F 3 < "$out" ); then
    info "$label 应用成功"
  elif ( cd ./common && patch -p1 -F 3 -R --dry-run < "$out" >/dev/null 2>&1 ); then
    warn "$label 已由上游补丁覆盖（视为已应用）"
  elif [[ "$mode" == "strict" ]]; then
    die "$label 应用失败，中止构建"
  else
    warn "$label 应用失败，继续..."
  fi
}
