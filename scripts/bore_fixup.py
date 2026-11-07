#!/usr/bin/env python3
"""BORE 补丁兜底修正：CachyOS 6.6 补丁在 OEM fair.c 上会有 3 个 hunk 打不上。
本脚本做幂等修正：
  1) 补 include <linux/sched/bore.h>
  2) 补 BORE 基础片定义（nsecs_per_tick / sysctl_sched_min_base_slice）
  3) 补 __pick_eevdf 的 burst parity 判断
"""
import re
import sys

p = sys.argv[1] if len(sys.argv) > 1 else "kernel/sched/fair.c"
s = open(p, encoding="utf-8").read()
changed = []

# 1) include
if "linux/sched/bore.h" not in s:
    anchor = '#include "autogroup.h"'
    if anchor in s:
        s = s.replace(anchor, anchor + "\n\n#include <linux/sched/bore.h>", 1)
        changed.append("include")
    else:
        print("FIXUP: include anchor MISS")

# 2) 基础片定义
if "nsecs_per_tick" not in s:
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
if "sched_burst_parity_threshold" not in s:
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
print("BORE fixup: " + (", ".join(changed) if changed else "nothing to do"))
