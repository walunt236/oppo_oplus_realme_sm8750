#!/usr/bin/env python3
"""调整内核里的 zram 行为（幂等，可重复调用）

1) 开机首次设置的 disksize 下限（默认 6144MB）：
   本机型厂商脚本 init.kernel.post_boot-memory.sh 硬编码 4GB，
   这里在 zram 首次初始化时抬到 6GB；之后用户手动调整不再干预。
2) 自动冷数据重压缩的触发条件改为按绝对占用判断：
   原逻辑用 mem_used/disksize，zram 扩容后阈值被放大，重压缩永不触发。

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
CLAMP_ADD = r'''
	/* 首次初始化强制不低于 zram_boot_min_mb */
	if (!zram_boot_min_applied && zram_boot_min_mb) {
		u64 boot_min = (u64)zram_boot_min_mb << 20;

		if (disksize < boot_min) {
			pr_info("zram: boot disksize %llu MB -> %u MB\n",
				disksize >> 20, zram_boot_min_mb);
			disksize = boot_min;
		}
		zram_boot_min_applied = true;
	}'''

DEF_ANCHOR = "#define ZRAM_AUTO_RECOMP_INTERVAL_SHORT\t(15 * HZ)"
DEF_ADD = r'''#define ZRAM_AUTO_RECOMP_MIN_BYTES	(512ULL << 20)
#define ZRAM_AUTO_RECOMP_MID_BYTES	(1536ULL << 20)
#define ZRAM_AUTO_RECOMP_PSI_LOW	500
#define ZRAM_AUTO_RECOMP_INTERVAL_SHORT	(15 * HZ)'''

THR_OLD = "\tif (usage < ZRAM_AUTO_RECOMP_USAGE_MID &&\n\t    psi_some < ZRAM_AUTO_RECOMP_PSI_HIGH) {"
THR_NEW = ("\t/* 按绝对占用判断（与 zram 容量解耦）：低于 512MB 且无压力则跳过 */\n"
           "\tif (mem_used < ZRAM_AUTO_RECOMP_MIN_BYTES &&\n"
           "\t    psi_some < ZRAM_AUTO_RECOMP_PSI_LOW) {")

HIGH_OLD = "\t} else if (usage >= ZRAM_AUTO_RECOMP_USAGE_HIGH ||\n\t\t   psi_some >= ZRAM_AUTO_RECOMP_PSI_HIGH) {"
HIGH_NEW = "\t} else if (mem_used >= ZRAM_AUTO_RECOMP_MID_BYTES ||\n\t\t   psi_some >= ZRAM_AUTO_RECOMP_PSI_HIGH) {"


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
        s = s.replace(CLAMP_ANCHOR, CLAMP_ADD + "\n" + CLAMP_ANCHOR, 1)
        n += 1
    if DEF_ANCHOR in s:
        s = s.replace(DEF_ANCHOR, DEF_ADD, 1)
        n += 1
    if THR_OLD in s:
        s = s.replace(THR_OLD, THR_NEW, 1)
        n += 1
    if HIGH_OLD in s:
        s = s.replace(HIGH_OLD, HIGH_NEW, 1)
        n += 1
    if n < 4:
        print("[WARN] zram 源码仅匹配到 %d 处，可能上游版本变化" % n)
    open(path, "w", encoding="utf-8").write(s)
    print("[INFO] zram 源码调整完成（%d 处）：开机下限 %dMB + 重压缩按绝对占用" % (n, MIN_MB))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("用法: zram_src_tune.py <zram_drv.c>")
    sys.exit(patch(sys.argv[1]))
