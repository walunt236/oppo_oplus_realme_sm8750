#!/usr/bin/env bash
# lz4/zstd 模块：LZ4 1.10 + ARMv8 NEON / zstd 补丁与校验
# 来源：scripts/apply_patches.sh 原第 178-240 行（原样搬迁）
# 开关：LZ4ZSTD_ENABLE（原块无开关，默认 true 保持原行为）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [[ "${LZ4ZSTD_ENABLE:-true}" != "true" ]]; then
  info "[LZ4ZSTD] 未启用，跳过"
  exit 0
fi

# 预取阶段由主脚本完成；独立运行时使用与主脚本一致的默认值
ZRAM_CACHE_DIR="${ZRAM_CACHE_DIR:-$HOME/.cache_patches/zram_patches}"

# ---- 原块开始（原第 178-240 行，原样搬迁，勿改） ----
# lz4/zstd
cd "$GITHUB_WORKSPACE/kernel_workspace/common"

# 001-lz4.patch 已固化为 other_patch/lz4/lz4_1.10_neon.patch，不再从上游拉取
cp "$ZRAM_CACHE_DIR/zram/002-zstd.patch" . || exit 1

mkdir -p lib/lz4/lz4armv8
cp "$ZRAM_CACHE_DIR/zram/lz4armv8.S" lib/lz4/lz4armv8/lz4armv8.S || true

ACCEL_DIR="$HOME/.cache_patches/lz4accel"
mkdir -p "$ACCEL_DIR"
PALAZIK_BRANCH="6.6.142_oneplus13_coloros16"
info "lz4accel 上游分支: $PALAZIK_BRANCH"
[ -s "$ACCEL_DIR/lz4accel.c" ] && [ -s "$ACCEL_DIR/lz4accel.h" ] ||
  { fetch_gh_file "palazik/android_kernel_common_oneplus_sm8750" "fs/f2fs/lz4armv8/lz4accel.c" "$PALAZIK_BRANCH" "$ACCEL_DIR/lz4accel.c" || warn "lz4accel.c 拉取失败，保留缓存/继续..."
    fetch_gh_file "palazik/android_kernel_common_oneplus_sm8750" "fs/f2fs/lz4armv8/lz4accel.h" "$PALAZIK_BRANCH" "$ACCEL_DIR/lz4accel.h" || warn "lz4accel.h 拉取失败，保留缓存/继续..."; }
mkdir -p fs/f2fs/lz4armv8
cp "$ACCEL_DIR/lz4accel.c" fs/f2fs/lz4armv8/
cp "$ACCEL_DIR/lz4accel.h" fs/f2fs/lz4armv8/

# 001-lz4.patch 的 IDEA 导出有两个不可修复的段：
#   1) lz4armv8.S 的二进制段在 11283 行被截断（corrupt binary patch）
#   2) lz4hc_compress.c 的删除段因上下文不符而失败
# 已剔除这两段并固化为标准 git 补丁，可严格应用；.S 由下面单独拷贝，旧文件单独删除。
LZ4_NEON_PATCH="$GITHUB_WORKSPACE/other_patch/lz4/lz4_1.10_neon.patch"
[ -f "$LZ4_NEON_PATCH" ] || die "缺少 lz4 1.10/NEON 补丁: $LZ4_NEON_PATCH"
git apply --whitespace=nowarn "$LZ4_NEON_PATCH" > /tmp/lz4_patch.log 2>&1 || die "lz4 1.10/NEON 补丁应用失败（详见 /tmp/lz4_patch.log）"
rm -f lib/lz4/lz4hc_compress.c
# 002-zstd.patch 里针对 lib/zstd/common/portability_macros.h 的 hunk 是上游 1.5.7 的
# Apple/i386 移植性改动，而本树 zstd 已更新（__GNUC__ >= 11），套用等于降级，故剔除该段。
python3 - "$PWD/002-zstd.patch" <<'PYZSTD' > /tmp/002-zstd-filtered.patch
import re, sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
parts = re.split(r"(?m)^diff --git ", src)
out = [parts[0]]
for p in parts[1:]:
    if p.startswith("a/lib/zstd/common/portability_macros.h"):
        sys.stderr.write("[INFO] 跳过 zstd portability_macros.h（上游旧版本，本树已更新）\n")
        continue
    out.append("diff --git " + p)
sys.stdout.write("".join(out))
PYZSTD
patch -p1 -t -F 3 < /tmp/002-zstd-filtered.patch >> /tmp/lz4_patch.log 2>&1 || true

# 001-lz4.patch 是 IDEA 格式的 378KB 大补丁，包含 LZ4 1.10 升级 + NEON 加速接线。
# 它必然部分失败，但加速接线是关键；这里显式检查是否真的接上了。
LZ4_REJ=$(find lib -name "*.rej" 2>/dev/null | wc -l)
if grep -rqs "lz4_decompress_asm" lib/lz4/; then
  info "lz4 ARMv8 解压加速已接线（补丁残留 ${LZ4_REJ} 个 reject）"
else
  warn "lz4 加速未接线：001-lz4.patch 的关键改动没有落上"
fi
if [ "$LZ4_REJ" -gt 0 ]; then
  warn "lz4/zstd 补丁有 ${LZ4_REJ} 个 hunk 未应用，明细见 /tmp/lz4_patch.log"
  grep -aE "error:|FAILED" /tmp/lz4_patch.log 2>/dev/null | head -3 || true
fi

if [ -f lib/lz4/lz4armv8/lz4armv8.S ] && [ -f lib/zstd/zstd_common_module.c ] && [ -s lib/lz4/lz4armv8/lz4accel.c ] && [ -s lib/lz4/lz4armv8/lz4accel.h ]; then
  info "lz4 NEON 解压 + zstd 就位"
else
  error "lz4/zstd 补丁未生效（lz4armv8.S/zstd 缺失），中止构建"
  exit 1
fi

# ---- 原块结束 ----
