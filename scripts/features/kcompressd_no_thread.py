#!/usr/bin/env python3
# 诊断：把 kcompressd 的 kthread 创建替换为空（用于定位卡开机）
import re
import sys

p = "mm/vmscan.c"
s = open(p, encoding="utf-8").read()
pat = re.compile(
    r"\t\tpgdat->kcompressd = kthread_create_on_node\(.*?\n\t\t\} else \{\n\t\t\twake_up_process\(pgdat->kcompressd\);\n\t\t\}",
    re.S,
)
s2, n = pat.subn("\t\tpgdat->kcompressd = NULL;", s)
if n:
    open(p, "w", encoding="utf-8").write(s2)
    print("patched", n)
else:
    print("pattern-not-found")
sys.exit(0)
