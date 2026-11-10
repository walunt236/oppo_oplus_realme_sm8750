#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0

# 1) bash 语法
for f in scripts/*.sh scripts/features/*.sh; do
  if bash -n "$f" 2>/dev/null; then
    echo "[lint] bash -n: $f OK"
  else
    echo "[lint][ERROR] bash -n: $f 失败"
    bash -n "$f" || true
    fail=1
  fi
done

# 2) CRLF：在 Windows 上编辑过的脚本，到 Linux runner 上会以
#    "bash: $'\r': command not found" 直接失败，且报错行号会偏移
for f in scripts/*.sh scripts/features/*.sh .github/workflows/*.yml configs/features/*.config; do
  if grep -q $'\r' "$f" 2>/dev/null; then
    echo "[lint][ERROR] $f 含 CRLF 行尾"
    fail=1
  fi
done

# 3) heredoc 定界符必须顶格闭合
if ! python3 - << 'PYEOF'
import pathlib, re, sys

bad = 0
for pattern in ('.github/workflows/*.yml', 'scripts/*.sh scripts/features/*.sh'):
    for f in sorted(pathlib.Path('.').glob(pattern)):
        lines = f.read_text(encoding='utf-8', errors='replace').splitlines()
        text = "\n".join(lines)
        for t in set(re.findall(r'<<\s*-?\s*["\']?([A-Za-z_][A-Za-z0-9_]*)["\']?', text)):
            if not any(l.rstrip() == t for l in lines):
                print(f"[lint][ERROR] {f}: heredoc 定界符 {t} 无顶格闭合")
                bad = 1
sys.exit(bad)
PYEOF
then
  fail=1
fi

# 4) 配置片段：格式 / CRLF / 同键冲突
if ! python3 scripts/check_configs.py; then
  fail=1
fi

# 5) 工作流 YAML 解析 + 内联 run: 块的 bash 语法
if python3 -c 'import yaml' 2>/dev/null; then
  if ! python3 - << 'PYEOF'
import glob, os, subprocess, sys, tempfile, yaml

bad = 0
for f in sorted(glob.glob('.github/workflows/*.yml')):
    try:
        doc = yaml.safe_load(open(f, encoding='utf-8'))
        print(f"[lint] YAML OK: {f}")
    except Exception as e:
        print(f"[lint][ERROR] YAML 解析失败: {f}: {e}")
        bad = 1
        continue

    # 内联 run: 是 bash，但 bash -n 不会扫到 YAML 里，单独抽出来检查
    for jname, job in (doc.get('jobs') or {}).items():
        for step in (job.get('steps') or []):
            run = step.get('run')
            if not isinstance(run, str):
                continue
            with tempfile.NamedTemporaryFile('w', suffix='.sh', delete=False,
                                             encoding='utf-8', newline='\n') as tmp:
                tmp.write(run)
                path = tmp.name
            r = subprocess.run(['bash', '-n', path], capture_output=True, text=True)
            if r.returncode != 0:
                print(f"[lint][ERROR] {f} :: {jname} :: {step.get('name')}: run 块语法错误")
                print(r.stderr.strip())
                bad = 1
            os.unlink(path)
sys.exit(bad)
PYEOF
  then
    fail=1
  fi
else
  echo "[lint][SKIP] 未安装 PyYAML，跳过工作流 YAML 与 run 块校验"
fi

[ "$fail" -eq 0 ] && echo "[lint] 全部通过"
exit $fail
