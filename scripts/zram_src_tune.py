#!/usr/bin/env python3
"""调整内核里的 zram 行为（幂等，可重复调用）

1) 开机首次 discs ize 下限（默认 6144MB）
2) 自动冷数据重压缩：次级 lz4hc、PSI 门控、8192 页上限、跳过已重压缩页

同时把自身内容哈希写入内核（"zram-tune:<rev>"）并导出到 GITHUB_ENV，
供 scripts/build_kernel.sh 在构建后校验，防止增量构建复用旧目标文件。
"""
import hashlib
import os
import sys

MIN_MB = 6144

GLOBALS_ANCHOR = "static unsigned int num_devices = 1;"

CLAMP_ANCHOR = "\tdisksize = PAGE_ALIGN(disksize);"

MAXPAGES_OLD = "#define ZRAM_AUTO_RECOMP_MAX_PAGES\t50000"
LOW_OLD = "\tif (usage < ZRAM_AUTO_RECOMP_USAGE_MID &&\n\t    psi_some < ZRAM_AUTO_RECOMP_PSI_HIGH) {"
LOW_NEW = ("\t/* 只有内存压力上来时才做重压缩 */\n"
           "\tif (psi_some < ZRAM_AUTO_RECOMP_PSI_LOW) {")
HIGH_OLD = "\t} else if (usage >= ZRAM_AUTO_RECOMP_USAGE_HIGH ||\n\t\t   psi_some >= ZRAM_AUTO_RECOMP_PSI_HIGH) {"
HIGH_NEW = "\t} else if (psi_some >= ZRAM_AUTO_RECOMP_PSI_HIGH) {"
HUGE_ANCHOR = "\t\t\t/* idle+huge 页统计（不可压缩观测数据） */"
SEC_OLD = 'kstrdup("zstd", GFP_KERNEL)'
SEC_NEW = 'kstrdup("lz4hc", GFP_KERNEL)'


def build_snippets(marker):
    globals_add = r'''

/* 开机首次 disksize 下限（MB）：厂商脚本在本机型硬编码 4GB，
 * 首次初始化时抬到 zram_boot_min_mb；之后用户自行调整不再干预。 */
static unsigned int zram_boot_min_mb = 6144;
module_param(zram_boot_min_mb, uint, 0644);
static bool zram_boot_min_applied;
static const char zram_tune_rev[] = "@@MARKER@@";'''.replace("@@MARKER@@", marker)

    clamp_add = r'''	/* 首次初始化强制不低于 zram_boot_min_mb（同时输出调优版本标记） */
	if (!zram_boot_min_applied && zram_boot_min_mb) {
		u64 boot_min = (u64)zram_boot_min_mb << 20;

		if (disksize < boot_min) {
			pr_info("zram: boot disksize %llu MB -> %u MB [%s]\n",
				disksize >> 20, zram_boot_min_mb, zram_tune_rev);
			disksize = boot_min;
		}
		zram_boot_min_applied = true;
	}
'''
    maxpages_new = ("#define ZRAM_AUTO_RECOMP_MAX_PAGES\t8192\n"
                    "/* 内存压力低于 5% 时不重压缩，避免空转烧 CPU */\n"
                    "#define ZRAM_AUTO_RECOMP_PSI_LOW\t500")
    huge_add = r'''			/* 已用次级算法压缩过，跳过以免每轮重复解压 */
			if (zram_get_priority(zram, index) >= prio)
				goto next;
'''
    return globals_add, clamp_add, maxpages_new, huge_add


def main():
    if len(sys.argv) < 2:
        sys.exit("用法: zram_src_tune.py <zram_drv.c>")
    path = sys.argv[1]

    # 用所有插入内容算出版本标记：脚本一改，标记就变
    probe_globals, probe_clamp, probe_max, probe_huge = build_snippets("REV")
    rev_src = "".join([probe_globals, probe_clamp, probe_max,
                       probe_huge, LOW_NEW, HIGH_NEW, SEC_NEW])
    rev = hashlib.md5(rev_src.encode("utf-8")).hexdigest()[:10]
    marker = "zram-tune:" + rev
    globals_add, clamp_add, maxpages_new, huge_add = build_snippets(marker)

    s = open(path, encoding="utf-8").read()
    if "zram_boot_min_mb" in s:
        print("[INFO] zram 源码已调整，跳过")
        return 0

    n = 0
    if GLOBALS_ANCHOR in s:
        s = s.replace(GLOBALS_ANCHOR, GLOBALS_ANCHOR + globals_add, 1)
        n += 1
    if CLAMP_ANCHOR in s:
        s = s.replace(CLAMP_ANCHOR, clamp_add + CLAMP_ANCHOR, 1)
        n += 1
    if MAXPAGES_OLD in s:
        s = s.replace(MAXPAGES_OLD, maxpages_new, 1)
        n += 1
    if LOW_OLD in s:
        s = s.replace(LOW_OLD, LOW_NEW, 1)
        n += 1
    if HIGH_OLD in s:
        s = s.replace(HIGH_OLD, HIGH_NEW, 1)
        n += 1
    if HUGE_ANCHOR in s:
        s = s.replace(HUGE_ANCHOR, huge_add + HUGE_ANCHOR, 1)
        n += 1
    cnt = s.count(SEC_OLD)
    if cnt:
        s = s.replace(SEC_OLD, SEC_NEW)
        n += cnt
    if n < 8:
        print("[WARN] zram 源码仅匹配到 %d 处（预期 8+），上游可能变化" % n)
    open(path, "w", encoding="utf-8").write(s)

    genv = os.environ.get("GITHUB_ENV")
    if genv:
        with open(genv, "a", encoding="utf-8") as f:
            f.write("ZRAM_TUNE_REV=%s\n" % marker)
    print("[INFO] zram 源码调整完成（%d 处）：开机下限 %dMB + lz4hc 次级 + PSI 门控 + 8192 页上限 [%s]"
          % (n, MIN_MB, marker))
    return 0


if __name__ == "__main__":
    sys.exit(main())
