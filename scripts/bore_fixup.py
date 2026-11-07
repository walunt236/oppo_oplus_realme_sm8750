#!/usr/bin/env python3
"""BORE 补丁兜底修正（v2）：CachyOS 6.6 补丁在 OEM fair.c 上会有 3 个 hunk 打不上。
v2 修正：改为检查“定义”而不是“出现”，避免使用处误判。
"""
import re
import sys

p = sys.argv[1] if len(sys.argv) > 1 else "kernel/sched/fair.c"
s = open(p, encoding="utf-8").read()
changed = []

# 1) include
if "#include <linux/sched/bore.h>" not in s:
    anchor = '#include "autogroup.h"'
    if anchor in s:
        s = s.replace(anchor, anchor + "\n\n#include <linux/sched/bore.h>", 1)
        changed.append("include")

# 2) 基础片定义：检查定义（= 号），不是使用
if not re.search(r"nsecs_per_tick\s*=", s):
    old_re = re.compile(
        r"unsigned int sysctl_sched_base_slice\s*=\s*700000ULL;\n"
        r"EXPORT_SYMBOL_GPL\(sysctl_sched_base_slice\);\n"
        r"static unsigned int normalized_sysctl_sched_base_slice\s*=\s*700000ULL;")
    new = (
        "#ifdef CONFIG_SCHED_BORE\n"
        "static const unsigned int nsecs_per_tick       = 1000000000ULL / HZ;\n"
        "unsigned int sysctl_sched_min_base_slice       = 2000000;\n"
        "__read_mostly uint sysctl_sched_base_slice     = nsecs_per_tick;\n"
        "#else\n"
        "unsigned int sysctl_sched_base_slice\t\t\t= 700000ULL;\n"
        "#endif\n"
        "EXPORT_SYMBOL_GPL(sysctl_sched_base_slice);\n"
        "#ifndef CONFIG_SCHED_BORE\n"
        "static unsigned int normalized_sysctl_sched_base_slice\t= 700000ULL;\n"
        "#endif")
    s2, n = old_re.subn(new, s, count=1)
    if n:
        s = s2
        changed.append("base-slice")
    else:
        print("FIXUP: base-slice anchor MISS")

# 3) RUN_TO_PARITY
if not re.search(r"sched_burst_parity_threshold\s*<\s*cfs_rq->nr_running", s):
    old = ("\tif (sched_feat(RUN_TO_PARITY) && curr && curr->vlag == curr->deadline)\n"
           "\t\treturn curr;")
    new = ("\tif (sched_feat(RUN_TO_PARITY) && curr && curr->vlag == curr->deadline)\n"
           "#ifdef CONFIG_SCHED_BORE\n"
           "\t\tif (!(likely(sched_bore) && likely(sched_burst_parity_threshold) &&\n"
           "\t\t\tsched_burst_parity_threshold < cfs_rq->nr_running))\n"
           "#endif\n"
           "\t\treturn curr;")
    if old in s:
        s = s.replace(old, new, 1)
        changed.append("run-to-parity")
    else:
        print("FIXUP: RUN_TO_PARITY anchor MISS")

open(p, "w", encoding="utf-8").write(s)
print("BORE fixup v2: " + (", ".join(changed) if changed else "nothing to do"))
