#!/usr/bin/env python3
"""BORE 运行时门控：把 fair.c 的热路径改动全部挂到 sched_bore 下。
目标：sched_bore=0 时内核行为与原生 EEVDF 完全一致，避免"关掉也卡"。
"""
import re
import sys

P = sys.argv[1] if len(sys.argv) > 1 else "kernel/sched/fair.c"
s = open(P, encoding="utf-8").read()
changes = []

# 1) update_curr：burst 累加只在 sched_bore 时执行
old = "curr->burst_time += delta_exec;\n\tupdate_burst_penalty(curr);"
new = "if (likely(sched_bore)) {\n\t\tcurr->burst_time += delta_exec;\n\t\tupdate_burst_penalty(curr);\n\t}"
if old in s:
    s = s.replace(old, new, 1); changes.append("update_curr")

# 2) dequeue_task_fair：restart_burst 只在 sched_bore 时
old2 = "if (task_sleep) {"
if old2 in s and "restart_burst(se);" in s:
    s = s.replace(old2, "if (likely(sched_bore) && task_sleep) {", 1); changes.append("dequeue_task")

# 3) yield_task_fair：rescale 只在 sched_bore 时
old3 = "restart_burst_rescale_deadline(se);"
if old3 in s:
    s = s.replace(old3, "if (likely(sched_bore))\n\t\trestart_burst_rescale_deadline(se);", 1); changes.append("yield")

# 4) place_entity：rel_deadline 分支挂到 sched_bore
old4 = "if (sched_feat(PLACE_REL_DEADLINE) && se->rel_deadline) {"
if old4 in s:
    s = s.replace(old4, "if (sched_bore && sched_feat(PLACE_REL_DEADLINE) && se->rel_deadline) {", 1); changes.append("place_entity")

# 5) dequeue_entity：rel_deadline 设置挂到 sched_bore
old5 = "if (sched_feat(PLACE_REL_DEADLINE) && !sleep) {"
if old5 in s:
    s = s.replace(old5, "if (sched_bore && sched_feat(PLACE_REL_DEADLINE) && !sleep) {", 1); changes.append("dequeue_entity")

# 6) task_fork_fair：update_burst_score 挂到 sched_bore
old6 = "\tupdate_burst_score(se);"
if old6 in s:
    s = s.replace(old6, "\tif (likely(sched_bore))\n\t\tupdate_burst_score(se);", 1); changes.append("task_fork")

open(P, "w", encoding="utf-8").write(s)
print("BORE gate: " + (", ".join(changes) if changes else "nothing matched"))
