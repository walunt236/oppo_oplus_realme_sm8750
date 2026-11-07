#!/usr/bin/env python3
"""BORE KABI 原地变换：只改树里自己的 sched.h，避免整文件覆盖的分支差异。
1) 删除补丁插入 sched_entity 的 BORE 字段块
2) 删除补丁的 sched_burst_cache 定义
3) 在 sched_entity 前插入 8 字节缓存定义 + 32 字节静态断言
4) 只替换 sched_entity 内的 4 个 KABI 保留字段
"""
import re
import sys

P = sys.argv[1] if len(sys.argv) > 1 else "include/linux/sched.h"
s = open(P, encoding="utf-8").read()

if "bore_kabi_block_check" in s:
    print("BORE KABI: already applied")
    sys.exit(0)

# 定位 sched_entity 块（括号计数）
i = s.find("struct sched_entity {")
if i < 0:
    print("BORE KABI: struct sched_entity not found")
    sys.exit(1)
j = s.find("{", i)
depth = 0
k = j
while k < len(s):
    if s[k] == "{":
        depth += 1
    elif s[k] == "}":
        depth -= 1
        if depth == 0:
            break
    k += 1
end = s.find(";", k) + 1
block = s[i:end]

# 1) 删除块内补丁插入的 BORE 字段
pat = re.compile(r"\n#ifdef CONFIG_SCHED_BORE\n(?:(?!\n#endif).)*?burst_time(?:(?!\n#endif).)*?\n#endif[^\n]*\n", re.S)
block2, n1 = pat.subn("\n", block)
print("删除补丁字段块:", n1)

# 2) 替换保留字段
res = "\tANDROID_KABI_RESERVE(1);\n\tANDROID_KABI_RESERVE(2);\n\tANDROID_KABI_RESERVE(3);\n\tANDROID_KABI_RESERVE(4);"
bore = """#ifdef CONFIG_SCHED_BORE
	u64				burst_time;
	u8				prev_burst_penalty;
	u8				curr_burst_penalty;
	u8				burst_penalty;
	u8				burst_score;
	u8				rel_deadline;
	u8				__bore_pad[3];
	struct sched_burst_cache	child_burst;
	struct sched_burst_cache	group_burst;
#else
	ANDROID_KABI_RESERVE(1);
	ANDROID_KABI_RESERVE(2);
	ANDROID_KABI_RESERVE(3);
	ANDROID_KABI_RESERVE(4);
#endif"""
if res not in block2:
    print("BORE KABI: 保留字段未找到（可能已被补丁移动）")
    sys.exit(1)
block2 = block2.replace(res, bore, 1)

# 3) 插回
s = s[:i] + block2 + s[end:]

# 4) 删除补丁的 sched_burst_cache 定义（sched_entity 之前）
s = re.sub(r"#ifdef CONFIG_SCHED_BORE\nstruct sched_burst_cache \{[^}]*\};\n#endif[^\n]*\n\n?", "", s, count=1)

# 5) 插入我们的定义 + 静态断言
defs = """#ifdef CONFIG_SCHED_BORE
struct sched_burst_cache {
	u8	score;
	u16	count;
	u32	timestamp;
};

struct bore_kabi_block_check {
	u64				burst_time;
	struct sched_burst_cache	child_burst;
	struct sched_burst_cache	group_burst;
	u8				flags[5];
	u8				pad[3];
};
_Static_assert(sizeof(struct bore_kabi_block_check) == 32,
	       "BORE KABI block must occupy exactly the 32 reserved bytes");
#endif

"""
s = s.replace("struct sched_entity {", defs + "struct sched_entity {", 1)

open(P, "w", encoding="utf-8").write(s)
print("BORE KABI: applied (%d lines)" % len(s.splitlines()))
