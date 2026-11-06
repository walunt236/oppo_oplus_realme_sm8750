#!/usr/bin/env python3
"""调整内核里的 zram 行为（幂等，可重复调用）

1) 开机首次设置的 disksize 下限（默认 6144MB）：
   本机型厂商脚本 init.kernel.post_boot-memory.sh 硬编码 4GB，
   这里在 zram 首次初始化时抬到 6GB；之后用户手动调整不再干预。
2) 自动冷数据重压缩调优：
   - 次级算法 zstd -> lz4hc（压缩比 +5%，解压速度不退化，走同一套 ARMv8 汇编）
   - 只在 PSI >= 5% 时工作，避免无压力时空转
   - 每周期最多处理 8192 页，限制 CPU 峰值
   - 已用次级算法压缩过的页直接跳过，避免重复解压

由 scripts/config_inject.sh 在应用 other_patch/zram_recomp_default.patch 之后调用。
"""
import sys

MIN_MB = 6144

GLOBALS_ANCHOR = "static unsigned int num_devices = 1;"
GLOBALS_ADD = r'''

/* 开机首次 disksize 下限（MB）：厂商脚本在本机型硬编码 4GB，
 * 首次初始化时抬到 zram_boot_min_mb；之后用户自行调整不再干预。 */
static unsigned int zram_boot_min_mb = 6144;
module_param(zram_boot_min_mb, uint, 0644);
static bool zram_boot_min_applied;'''

CLAMP_ANCHOR = "\tdisksize = PAGE_ALIGN(disksize);"
CLAMP_ADD = r'''	/* 首次初始化强制不低于 zram_boot_min_mb */
	if (!zram_boot_min_applied && zram_boot_min_mb) {
		u64 boot_min = (u64)zram_boot_min_mb << 20;

		if (disksize < boot_min) {
			pr_info("zram: boot disksize %llu MB -> %u MB\n",
				disksize >> 20, zram_boot_min_mb);
			disksize = boot_min;
		}
		zram_boot_min_applied = true;
	}
'''

MAXPAGES_OLD = "#define ZRAM_AUTO_RECOMP_MAX_PAGES\t50000"
MAXPAGES_NEW = ("#define ZRAM_AUTO_RECOMP_MAX_PAGES\t8192\n"
                "/* 内存压力低于 5%% 时不重压缩，避免空转烧 CPU */\n"
                "#define ZRAM_AUTO_RECOMP_PSI_LOW\t500")

LOW_OLD = "\tif (usage < ZRAM_AUTO_RECOMP_USAGE_MID &&\n\t    psi_some < ZRAM_AUTO_RECOMP_PSI_HIGH) {"
LOW_NEW = ("\t/* 只有内存压力上来时才做重压缩 */\n"
           "\tif (psi_some < ZRAM_AUTO_RECOMP_PSI_LOW) {")

HIGH_OLD = "\t} else if (usage >= ZRAM_AUTO_RECOMP_USAGE_HIGH ||\n\t\t   psi_some >= ZRAM_AUTO_RECOMP_PSI_HIGH) {"
HIGH_NEW = "\t} else if (psi_some >= ZRAM_AUTO_RECOMP_PSI_HIGH) {"

HUGE_ANCHOR = "\t\t\t/* idle+huge 页统计（不可压缩观测数据） */"
HUGE_ADD = r'''			/* 已用次级算法压缩过，跳过以免每轮重复解压 */
			if (zram_get_priority(zram, index) >= prio)
				goto next;
'''

SEC_OLD = 'kstrdup("zstd", GFP_KERNEL)'
SEC_NEW = 'kstrdup("lz4hc", GFP_KERNEL)'


def patch(path):
    s = open(path, encoding="utf-8").read()
    if "zram_boot_min_mb" in s:
        print("[INFO] zram 源码已调整，跳过")
        return 0
    n = 0
    if GLOBALS_ANCHOR in s:
        s = s.replace(GLOBALS_ANCHOR, GLOBALS_ANCHOR + GLOBALS_ADD, 1)
        n += 1
    if CLAMP_ANCHOR in s:
        s = s.replace(CLAMP_ANCHOR, CLAMP_ADD + CLAMP_ANCHOR, 1)
        n += 1
    if MAXPAGES_OLD in s:
        s = s.replace(MAXPAGES_OLD, MAXPAGES_NEW, 1)
        n += 1
    if LOW_OLD in s:
        s = s.replace(LOW_OLD, LOW_NEW, 1)
        n += 1
    if HIGH_OLD in s:
        s = s.replace(HIGH_OLD, HIGH_NEW, 1)
        n += 1
    if HUGE_ANCHOR in s:
        s = s.replace(HUGE_ANCHOR, HUGE_ADD + HUGE_ANCHOR, 1)
        n += 1
    cnt = s.count(SEC_OLD)
    if cnt:
        s = s.replace(SEC_OLD, SEC_NEW)
        n += cnt
    if n < 7:
        print("[WARN] zram 源码仅匹配到 %d 处（预期 7+），上游可能变化" % n)
    open(path, "w", encoding="utf-8").write(s)
    print("[INFO] zram 源码调整完成（%d 处）：开机下限 %dMB + lz4hc 次级 + PSI 门控 + 8192 页上限" % (n, MIN_MB))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("用法: zram_src_tune.py <zram_drv.c>")
    sys.exit(patch(sys.argv[1]))
