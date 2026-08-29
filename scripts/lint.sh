#!/bin/bash
# lint.sh — 脚本与工作流静态质检
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0

for f in scripts/*.sh; do
  if bash -n "$f" 2>/dev/null; then
    echo "[lint] bash -n: $f OK"
  else
    echo "[lint][ERROR] bash -n: $f 失败"
    fail=1
  fi
done

python3 - << 'PYEOF'
import re, sys, pathlib
bad = 0
for pattern in ('.github/workflows/*.yml', 'scripts/*.sh'):
    for f in sorted(pathlib.Path('.').glob(pattern)):
        lines = f.read_text(encoding='utf-8', errors='replace').splitlines()
        text = "\n".join(lines)
        for t in set(re.findall(r'<<\s*-?\s*["\']?([A-Za-z_][A-Za-z0-9_]*)["\']?', text)):
            if not any(l.rstrip() == t for l in lines):
                print(f"[lint][ERROR] {f}: heredoc 定界符 {t} 无顶格闭合")
                bad = 1
sys.exit(bad)
PYEOF

[ "$fail" -eq 0 ] && echo "[lint] 全部通过"
exit $fail
