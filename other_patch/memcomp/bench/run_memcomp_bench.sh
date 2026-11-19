#!/system/bin/sh
# memcomp device benchmark: read-only capture + optional memhog pressure
set -u
OUT=/sdcard/Download/memcomp-bench-$(date +%Y%m%d-%H%M%S).log
MEMHOG=/data/local/tmp/memhog
MB=${MEMHOG_MB:-6144}
MODE=${MEMHOG_MODE:-2}

s() { cat /sys/kernel/mm/memcomp/stat 2>/dev/null || echo unavailable; }
{
  echo "=== memcomp bench $(date) ==="
  uname -a
  getprop ro.boot.slot_suffix
  echo '--- idle stat ---'; sleep 3; s
  echo '--- idle meminfo ---'; grep -E 'MemTotal|MemFree|MemAvailable|SwapTotal|AnonHugePages|Shmem' /proc/meminfo
  echo '--- idle pressure ---'; cat /proc/pressure/memory 2>/dev/null
  if [ -x "$MEMHOG" ]; then
    echo "--- pressure ${MB}MB mode=$MODE ---"
    "$MEMHOG" "$MB" "$MODE" & P=$!
    sleep 10
    s
    kill -9 "$P" 2>/dev/null
    sleep 2
  else
    echo "memhog missing: $MEMHOG"
  fi
  echo '--- after stat ---'; s
  echo '--- after meminfo ---'; grep -E 'MemFree|MemAvailable|AnonHugePages' /proc/meminfo
  echo '--- crash buffer ---'; logcat -b crash -d 2>/dev/null | tail -40
  echo '--- dmesg ---'; dmesg 2>/dev/null | grep -iE 'memcomp|WARNING|BUG:|Bad swap|Out of memory|Killed process' | tail -30
  echo '=== done ==='
} > "$OUT" 2>&1
echo "$OUT"
