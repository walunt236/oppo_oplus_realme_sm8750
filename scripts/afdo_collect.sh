#!/usr/bin/env bash
# 把设备上采集的 perf.data 转换成 AutoFDO profile（kernel.afdo）
#
# 用法:
#   scripts/afdo_collect.sh <perf.data> [vmlinux]
#
# 说明:
#   llvm-profgen 只接受带 LBR 分支记录的样本，arm64 设备普遍没有 LBR，
#   因此这里改用 scripts/perf2afdo.py 直接解析调用栈 + DWARF 行号。
#
# 前提:
#   1. 已用 afdo_mode=generate 构建；vmlinux 自动存到
#      ~/.cache_patches/afdo/vmlinux.latest（必须与刷入的内核同一次构建）
#   2. 设备采样命令（必须带调用栈）:
#      simpleperf record -a -e cpu-cycles -f 500 --call-graph fp --duration 600 -o /sdcard/perf.data
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AFDO_DIR="${AFDO_DIR:-$HOME/.cache_patches/afdo}"
PERF="${1:-}"
VMLINUX="${2:-$AFDO_DIR/vmlinux.latest}"
OUT="$AFDO_DIR/kernel.afdo"

usage() { echo "用法: $0 <perf.data> [vmlinux]"; exit 1; }
[ -n "$PERF" ] || usage
[ -s "$PERF" ] || { echo "[ERROR] 找不到 perf.data: $PERF"; exit 1; }
[ -s "$VMLINUX" ] || { echo "[ERROR] 找不到 vmlinux: $VMLINUX"; echo "        先跑一次 afdo_mode=generate 的构建"; exit 1; }

echo "[INFO] 采样文件: $PERF ($(du -h "$PERF" | cut -f1))"
echo "[INFO] vmlinux:   $VMLINUX ($(du -Lh "$VMLINUX" | cut -f1))"

mkdir -p "$AFDO_DIR"
python3 "$HERE/perf2afdo.py" "$PERF" "$VMLINUX" "$OUT"

[ -s "$OUT" ] || { echo "[ERROR] profile 生成失败"; exit 1; }

HASH=$(md5sum "$OUT" | cut -c1-8)
ln -sf kernel.afdo "$AFDO_DIR/kernel-$HASH.afdo"
echo "[OK] 已安装: $OUT ($(du -h "$OUT" | cut -f1), hash=$HASH)"
echo "[NEXT] 派发构建时选择 afdo_mode=use（会优先使用这份自采样本）"
