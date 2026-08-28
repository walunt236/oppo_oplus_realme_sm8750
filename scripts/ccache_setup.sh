#!/bin/bash
# ccache_setup.sh — ccache 目录/环境/初始化
set -euo pipefail
source "$(dirname "$0")/common.sh"

df -h
if [[ "$DROIDSPACES_ENABLE" != "false" ]]; then
  CCACHE_REAL_KEY="$CCACHE_KEY-$SUB_VERSION-Droidspaces"
else
  CCACHE_REAL_KEY="$CCACHE_KEY-$SUB_VERSION-none"
fi
echo "CCACHE_REAL_KEY=$CCACHE_REAL_KEY" >> "$GITHUB_ENV"

echo "CCACHE_DIR=$HOME/.ccache" >> "$GITHUB_ENV"
echo "CCACHE_MAXSIZE=40G" >> "$GITHUB_ENV"
echo "CCACHE_BASEDIR=$GITHUB_WORKSPACE" >> "$GITHUB_ENV"
echo "CCACHE_COMPILERCHECK=content" >> "$GITHUB_ENV"
echo "CCACHE_NOHASHDIR=true" >> "$GITHUB_ENV"
echo "CCACHE_NOHARDLINK=true" >> "$GITHUB_ENV"
echo "CCACHE_DIRECT=true" >> "$GITHUB_ENV"
echo "CCACHE_FILECLONE=true" >> "$GITHUB_ENV"
echo "CCACHE_INODECACHE=true" >> "$GITHUB_ENV"
echo "CCACHE_COMPRESSION=true" >> "$GITHUB_ENV"
echo "CCACHE_COMPRESSIONLEVEL=1" >> "$GITHUB_ENV"
echo "CCACHE_UMASK=002" >> "$GITHUB_ENV"
echo "CCACHE_IGNOREOPTIONS=--sysroot*" >> "$GITHUB_ENV"
echo "CCACHE_SLOPPINESS=file_macro,time_macros,include_file_mtime,include_file_ctime,pch_defines,system_headers,locale" >> "$GITHUB_ENV"
# 日志仅在 ccache_debug 开启时写入，避免 9.6GB 级别的无上限增长与写日志 I/O 开销
if [[ "$CCACHE_DEBUG_INPUT" == "true" ]]; then
  echo "CCACHE_LOGFILE=$GITHUB_WORKSPACE/kernel_workspace/ccache.log" >> "$GITHUB_ENV"
fi
if ccache --help 2>&1 | grep -q 'depend_mode'; then
  echo "CCACHE_DEPEND=true" >> "$GITHUB_ENV"
fi

mkdir -p "$HOME/.ccache"
ccache -M "40G"
ccache -o compression=true
if ! grep -q '^sloppiness' "$HOME/.ccache/ccache.conf" 2>/dev/null; then
  echo "sloppiness = file_macro,time_macros,include_file_mtime,include_file_ctime,pch_defines,system_headers,locale" >> "$HOME/.ccache/ccache.conf"
fi

info "ccache 状态:"
ccache -s
