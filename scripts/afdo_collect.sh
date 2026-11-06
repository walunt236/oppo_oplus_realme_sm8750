#!/usr/bin/env bash
# 把设备采集的 perf.data 转换成 AutoFDO profile（kernel.afdo），支持多份合并
#
# 用法:
#   scripts/afdo_collect.sh <perf.data> [perf.data2 ...]
#
# 说明:
#   llvm-profgen 只接受带 LBR 的样本，arm64 设备普遍没有，因此改用
#   scripts/perf2afdo.py 直接解析（支持带调用栈的样本，也支持纯 IP 样本）。
#
#   多份输入会按各自样本量加权合并；把同一份传两次即可让它权重翻倍。
#
#   设备采样命令（两者都支持）:
#     simpleperf record -a -o /sdcard/perf.data --duration 900          # 纯 IP
#     simpleperf record -a -e cpu-cycles -f 500 --call-graph fp --duration 600 -o /sdcard/perf.data
#
# 前提:
#   已用 afdo_mode=generate 构建；vmlinux 自动存到
#   ~/.cache_patches/afdo/vmlinux.latest（必须与采样时的内核同一次构建）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AFDO_DIR="${AFDO_DIR:-$HOME/.cache_patches/afdo}"
OUT="$AFDO_DIR/kernel.afdo"
VMLINUX="${AFDO_VMLINUX:-$AFDO_DIR/vmlinux.latest}"

[ $# -ge 1 ] || { echo "用法: $0 <perf.data> [perf.data2 ...]"; exit 1; }
[ -s "$VMLINUX" ] || { echo "[ERROR] 找不到 vmlinux: $VMLINUX"; echo "        先跑一次 afdo_mode=generate 的构建"; exit 1; }

PROFDATA=""
for c in "$HOME"/.toolchains/*/bin/llvm-profdata /opt/toolchains/bin/llvm-profdata; do
  if [ -x "$c" ]; then PROFDATA="$c"; break; fi
done
[ -n "$PROFDATA" ] || { echo "[ERROR] 找不到 llvm-profdata"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

i=0
PARTS=()
for f in "$"; do
  [ -s "$f" ] || { echo "[ERROR] 找不到 perf.data: $f"; exit 1; }
  i=$((i+1))
  echo "[INFO] 转换第 $i 份: $f ($(du -h "$f" | cut -f1))"
  python3 "$HERE/perf2afdo.py" "$f" "$VMLINUX" "$TMP/p$i.afdo"
  PARTS+=("$TMP/p$i.afdo")
done

mkdir -p "$AFDO_DIR"
if [ "$i" -eq 1 ]; then
  cp "$TMP/p1.afdo" "$OUT"
else
  echo "[INFO] 合并 $i 份采样（按样本量加权）"
  "$PROFDATA" merge --sample -o "$OUT" "${PARTS[@]}"
fi

[ -s "$OUT" ] || { echo "[ERROR] profile 生成失败"; exit 1; }
FUNCS=$("$PROFDATA" show -sample "$OUT" 2>/dev/null | grep -c '^Function: ' || echo 0)
HASH=$(md5sum "$OUT" | cut -c1-8)
ln -sf kernel.afdo "$AFDO_DIR/kernel-$HASH.afdo"
echo "[OK] 已安装: $OUT ($(du -h "$OUT" | cut -f1), $FUNCS 个函数, hash=$HASH)"
echo "[NEXT] 派发构建时选择 afdo_mode=use（优先使用这份自采样本）"
