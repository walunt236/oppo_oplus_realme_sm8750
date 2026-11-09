#!/usr/bin/env bash
# BORE 调度器：Hipuu 适配版（KABI 保留槽 1 存指针 + kzalloc bore_ctx）
set -u
if [[ "${BORE_ENABLE:-false}" != "true" ]]; then
  echo "[BORE] 未启用，跳过"
  exit 0
fi
WS="${GITHUB_WORKSPACE:-$(pwd)}"
COMMON="$WS/kernel_workspace/common"
PATCH_DIR="$WS/other_patch/bore"
[[ -f "$PATCH_DIR/bore-7.0.0.patch" ]] || { echo "[BORE] 缺少补丁"; exit 1; }
cd "$COMMON" || exit 1
echo "[BORE] 应用 7.0.0 补丁 + 7.0.1r2 审计修复..."
patch -p1 -N -F 3 < "$PATCH_DIR/bore-7.0.0.patch" > /tmp/bore.log 2>&1 || true
if grep -q "FAILED" /tmp/bore.log; then
  echo "[BORE] 有 hunk 失败："
  grep -E "FAILED|Hunk" /tmp/bore.log | head -5
fi
# 完全体：sched_bore=1，开机即接管（用户确认此默认可开机）
if [ -f kernel/sched/bore.c ] && grep -q "sched_bore.*= 0;" kernel/sched/bore.c; then
  sed -i "s/^\(u8 \+__read_mostly \+sched_bore \+=\) 0;/\1 1;/" kernel/sched/bore.c
  echo "[BORE] sched_bore 默认值改为 1（完全体）"
fi

# 修复：补丁漏加 include 的文件（core.c / debug.c）
python3 - << 'PYEOF'
import sys
files = ["kernel/sched/core.c", "kernel/sched/debug.c"]
syms = ("effective_prio_bore", "bore_score", "sched_init_bore")
anchors = ['#include "sched.h"', '#include "sched/debug.h"', '#include <linux/sched.h>']
for p in files:
    try:
        s = open(p, encoding="utf-8").read()
    except FileNotFoundError:
        continue
    if "linux/sched/bore.h" in s:
        continue
    if not any(k in s for k in syms):
        continue
    for a in anchors:
        if a in s:
            s = s.replace(a, "#include <linux/sched/bore.h>\n" + a, 1)
            open(p, "w", encoding="utf-8").write(s)
            print("[BORE] %s 已补 include" % p)
            break
    else:
        print("[BORE] %s 未找到 include 锚点" % p)
PYEOF
# BORE 7.0.1r2 审计修复（XiaoZuo1120 issue #84 / PR #83）
# 1) 子进程计数改用 RCU 链表迭代，避免直接读 head->next 的竞态
# 2) fork 时清除继承的 sleep credit
# 3) 唤醒 credit 先换算成虚拟时间，再从 deadline 扣除
# 4) reciprocal LUT[0] 显式置 0，避免未初始化索引
python3 - << 'PYEOF'
import re

def patch_file(path, fn):
    try:
        s = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        print("[BORE][WARN] 缺少 %s，跳过 7.0.1 修复" % path)
        return
    s2 = fn(s)
    if s2 != s:
        open(path, "w", encoding="utf-8").write(s2)
        print("[BORE] 7.0.1 修复已应用到 %s" % path)
    else:
        print("[BORE][WARN] %s 未匹配到 7.0.1 修复点" % path)

new_count = '''static inline u32 count_children_upto2(struct task_struct *p)
{
	struct task_struct *child;
	u32 count = 0;

	list_for_each_entry_rcu(child, &p->children, sibling) {
		if (++count >= 2)
			break;
	}
	return count;
}'''

def fix_bore_c(s):
    s = re.sub(r'static inline u32 count_children_upto2\(struct task_struct \*p\) \{.*?\n\}',
               new_count, s, count=1, flags=re.S)
    s = s.replace("\tctx->burst_time    = 0;\n\tctx->stop_update   = false;",
                  "\tctx->burst_time    = 0;\n\tctx->credit_sleep  = 0;\n\tctx->stop_update   = false;", 1)
    s = s.replace("\tfor (int i = 1; i <= BURST_CACHE_SAMPLE_LIMIT; i++)",
                  "\tbore_reciprocal_lut[0] = 0;\n\tfor (int i = 1; i <= BURST_CACHE_SAMPLE_LIMIT; i++)", 1)
    return s

def fix_fair_c(s):
    old = "if (credit && se->deadline > credit)\n\t\t\tse->deadline -= credit;"
    new = ("if (credit) {\n"
           "\t\t\tu64 vcredit = calc_delta_fair(credit, se);\n\n"
           "\t\t\tif (se->deadline > vcredit)\n"
           "\t\t\t\tse->deadline -= vcredit;\n"
           "\t\t}")
    return s.replace(old, new, 1)

def fix_version(s):
    return s.replace('#define SCHED_BORE_VERSION  "7.0.0"',
                     '#define SCHED_BORE_VERSION  "7.0.1"', 1)

patch_file("kernel/sched/bore.c", fix_bore_c)
patch_file("kernel/sched/fair.c", fix_fair_c)
patch_file("include/linux/sched/bore.h", fix_version)
PYEOF
echo "[BORE] 完成"
