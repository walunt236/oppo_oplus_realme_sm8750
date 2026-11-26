#!/system/bin/sh
# memcomp 无 swap 版采样脚本（Android 设备，需 root）
#
# 用法（建议放 KSU 模块或 /data/local/tmp）：
#   su -c 'sh /data/local/tmp/memcomp_sample.sh [输出文件] [间隔秒]'
#
# 输出一行一条 CSV，用于回答三个问题：
#   1) 池子有没有到上限（over/limit_hits）  2) lmkd 该不该提前动手（psi_some10）
#   3) 后台内存是否被压缩掉（memfree/cached/swapfree 对比）
#
# 内核没开 memcomp 时脚本会直接退出，不会写入垃圾数据。

OUT="${1:-/data/local/tmp/memcomp.csv}"
IV="${2:-60}"
ST=/sys/kernel/mm/memcomp/status

[ -r "$ST" ] || { echo "memcomp 未启用（$ST 不存在）" >&2; exit 1; }

[ -f "$OUT" ] || echo "ts,limit_bytes,used_bytes,over,limit_hits,compact_runs,compact_freed,stored_bytes,compressed_bytes,memfree_kb,memavail_kb,cached_kb,swapfree_kb,psi_some10,psi_full10,loadavg" > "$OUT"

getkv() { sed -n "s/^$1 //p" "$ST"; }

while :; do
  ts=$(date +%s)
  limit=$(getkv limit_bytes)
  used=$(getkv used_bytes)
  over=$(getkv over)
  hits=$(getkv limit_hits)
  cruns=$(getkv compact_runs)
  cfreed=$(getkv compact_freed_pages)
  stored=$(getkv stored_bytes)
  comp=$(getkv compressed_bytes)

  mi=$(cat /proc/meminfo)
  memfree=$(echo "$mi" | awk '/^MemFree:/{print $2}')
  memavail=$(echo "$mi" | awk '/^MemAvailable:/{print $2}')
  cached=$(echo "$mi" | awk '/^Cached:/{print $2}')
  swapfree=$(echo "$mi" | awk '/^SwapFree:/{print $2}')
  [ -n "$swapfree" ] || swapfree=0

  psi=$(cat /proc/pressure/memory 2>/dev/null)
  some10=$(echo "$psi" | sed -n 's/^some .*avg10=\([0-9.]*\).*/\1/p')
  full10=$(echo "$psi" | sed -n 's/^full .*avg10=\([0-9.]*\).*/\1/p')
  load=$(cut -d' ' -f1 /proc/loadavg)

  echo "$ts,$limit,$used,$over,$hits,$cruns,$cfreed,$stored,$comp,$memfree,$memavail,$cached,$swapfree,$some10,$full10,$load" >> "$OUT"
  sleep "$IV"
done
