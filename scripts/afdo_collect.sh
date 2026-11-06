#!/usr/bin/env bash
# 把设备上采集的 perf.data 转换成 AutoFDO profile（kernel.afdo）
#
# 用法:
#   scripts/afdo_collect.sh <perf.data> [vmlinux]
#
# 前提:
#   1. 先用 afdo_mode=generate 构建并刷入内核；vmlinux 会自动存到
#      ~/.cache_patches/afdo/vmlinux.latest（必须与刷入的内核同一次构建）
#   2. 设备采集的 perf.data 必须带分支栈（simpleperf record -b）
set -euo pipefail

AFDO_DIR="${AFDO_DIR:-$HOME/.cache_patches/afdo}"
PERF="${1:-}"
VMLINUX="${2:-$AFDO_DIR/vmlinux.latest}"

usage() { echo "用法: $0 <perf.data> [vmlinux]"; exit 1; }
[ -n "$PERF" ] || usage
[ -s "$PERF" ] || { echo "[ERROR] 找不到 perf.data: $PERF"; exit 1; }
[ -s "$VMLINUX" ] || { echo "[ERROR] 找不到 vmlinux: $VMLINUX"; echo "        先跑一次 afdo_mode=generate 的构建"; exit 1; }

PROFGEN="${LLVM_PROFGEN:-}"
if [ -z "$PROFGEN" ]; then
  for c in "$HOME/.toolchains/Clang-19.0.0git-20240723/bin/llvm-profgen" \
           "$(command -v llvm-profgen 2>/dev/null || true)"; do
    if [ -n "$c" ] && [ -x "$c" ]; then PROFGEN="$c"; break; fi
  done
fi
[ -n "$PROFGEN" ] && [ -x "$PROFGEN" ] || { echo "[ERROR] 找不到 llvm-profgen"; exit 1; }

echo "[INFO] llvm-profgen: $("$PROFGEN" --version 2>/dev/null | head -1)"
echo "[INFO] 采样文件: $PERF ($(du -h "$PERF" | cut -f1))"
echo "[INFO] vmlinux:   $VMLINUX ($(du -Lh "$VMLINUX" | cut -f1))"

mkdir -p "$AFDO_DIR"
OUT="$AFDO_DIR/kernel.afdo.new"
"$PROFGEN" --binary="$VMLINUX" --perfdata="$PERF" --output="$OUT"

if [ ! -s "$OUT" ]; then
  echo "[ERROR] profile 生成失败（确认 perf.data 带分支栈 -b）"
  exit 1
fi

SAMPLES=$(wc -l < "$OUT")
mv -f "$OUT" "$AFDO_DIR/kernel.afdo"
HASH=$(md5sum "$AFDO_DIR/kernel.afdo" | cut -c1-8)
ln -sf kernel.afdo "$AFDO_DIR/kernel-$HASH.afdo"
echo "[OK] 已生成: $AFDO_DIR/kernel.afdo ($(du -h "$AFDO_DIR/kernel.afdo" | cut -f1), $SAMPLES 行, hash=$HASH)"
echo "[NEXT] 派发构建时选择 afdo_mode=use"
