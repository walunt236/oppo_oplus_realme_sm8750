#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

cd "$GITHUB_WORKSPACE/kernel_workspace"
: > /tmp/sync_failed.list

REJ_DIR="${OUT_DIR:-$HOME/share/out}/rej"
mkdir -p "$REJ_DIR"

count_rejs() {
  local label="$1" files hunks safe
  safe="${label//\//_}"
  files=$(find . -name "*.rej" 2>/dev/null | wc -l)
  hunks=$(find . -name "*.rej" -exec awk '/^@@/{n++} END{print n+0}' {} \; 2>/dev/null | awk '{s+=$1} END{print s+0}')
  if [ "$files" -gt 0 ]; then
    find . -name "*.rej" 2>/dev/null | while IFS= read -r f; do
      rel=$(printf '%s' "$f" | sed 's|^\./||')
      cp -f "$f" "$REJ_DIR/$safe-$(printf '%s' "$rel" | tr '/' '_')" 2>/dev/null || true
      printf '%s  失败hunk=%s\n' "$rel" "$(awk '/^@@/{n++} END{print n+0}' "$f")" >> "$REJ_DIR/$safe.summary"
    done
    find . -name "*.rej" -delete 2>/dev/null || true
  fi
  TOTAL_REJ=$((TOTAL_REJ + hunks))
  TOTAL_REJ_FILES=$((TOTAL_REJ_FILES + files))
  info "$label reject: ${files} 文件 / ${hunks} hunk（明细 $REJ_DIR/$safe.summary）"
}

link_ksu_kernel() {
  ln -sf "$(realpath --relative-to=common/drivers "$PWD/$1/kernel")" common/drivers/kernelsu
  grep -q "kernelsu" common/drivers/Makefile || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> common/drivers/Makefile
  grep -q "drivers/kernelsu/Kconfig" common/drivers/Kconfig || sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" common/drivers/Kconfig
}

ksu_commit_count() {
  curl -sI --retry 3 --retry-delay 5 -H "Authorization: token ${GH_TOKEN:-}" "https://api.github.com/repos/$1/commits?sha=$2&per_page=1" | grep -i "link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p' || true
}

# KernelSU
rm -rf common/drivers/kernelsu

if [[ "$KSU_TYPE" == "sukisu" || "$KSU_TYPE" == "resukisu" ]]; then
  info "配置 ReSukiSU..."
  sync_repo "https://github.com/ReSukiSU/ReSukiSU.git" KernelSU main
  link_ksu_kernel KernelSU
  echo 'CONFIG_KSU_FULL_NAME_FORMAT="%TAG_NAME%-%COMMIT_SHA%@walunt236"' >> ./common/arch/arm64/configs/gki_defconfig
  cd ./KernelSU
  KSU_COMMITS=$(ksu_commit_count ReSukiSU/ReSukiSU main)
  KSU_COMMITS=${KSU_COMMITS:-0}
  if [[ "$KSU_COMMITS" == "0" ]]; then
    warn "ReSukiSU 提交数获取失败，版本号降级为基线"
  fi
  KSU_VERSION=$(expr "$KSU_COMMITS" + 30700 2>/dev/null || echo 0)
  if [[ "$KSU_VERSION" == "0" ]]; then
    warn "ReSukiSU 版本号计算失败，版本号降级为 0"
  fi
  echo "KSUVER=$KSU_VERSION" >> "$GITHUB_ENV"
  echo "ksuver=$KSU_VERSION" >> "$GITHUB_OUTPUT"
elif [[ "$KSU_TYPE" == "ksunext" ]]; then
  info "配置 KernelSU Next..."
  sync_repo "https://github.com/pershoot/KernelSU-Next.git" KernelSU-Next dev-susfs
  link_ksu_kernel KernelSU-Next
  cd KernelSU-Next
  KSU_COMMITS=$(ksu_commit_count pershoot/KernelSU-Next dev-susfs)
  KSU_COMMITS=${KSU_COMMITS:-0}
  if [[ "$KSU_COMMITS" == "0" ]]; then
    warn "KernelSU-Next 提交数获取失败，版本号降级为基线"
  fi
  KSU_VERSION=$(expr "$KSU_COMMITS" + 30000)
  echo "KSUVER=$KSU_VERSION" >> "$GITHUB_ENV"
  echo "ksuver=$KSU_VERSION" >> "$GITHUB_OUTPUT"
  sed -i "s/KSU_VERSION_FALLBACK := 1/KSU_VERSION_FALLBACK := $KSU_VERSION/g" kernel/Kbuild
  grep -q "KSU_VERSION_FALLBACK := $KSU_VERSION" kernel/Kbuild || warn "KSU_VERSION_FALLBACK 锚点未命中（上游 Kbuild 已变动）"
  KSU_GIT_TAG=$(curl -sL --retry 3 --retry-delay 5 --retry-all-errors "https://api.github.com/repos/KernelSU-Next/KernelSU-Next/tags" 2>/dev/null | grep -o '"name": *"[^"]*"' | head -n 1 | sed 's/"name": "//;s/"//' || true)
  if [[ -n "$KSU_GIT_TAG" ]]; then
    sed -i "s/KSU_VERSION_TAG_FALLBACK := v0.0.1/KSU_VERSION_TAG_FALLBACK := $KSU_GIT_TAG/g" kernel/Kbuild
    grep -q "KSU_VERSION_TAG_FALLBACK := $KSU_GIT_TAG" kernel/Kbuild || warn "KSU_VERSION_TAG_FALLBACK 锚点未命中（上游 Kbuild 已变动）"
  fi
  # drivers/kernelsu 是指向 KernelSU-Next/kernel 的符号链接，patch 不会跟随，
  # 所以进到链接目录内部用 -p3 应用（剥掉 a/drivers/kernelsu/ 三段）。
  cd ../common/drivers/kernelsu
  patch -p3 -N -F 3 < "$GITHUB_WORKSPACE/other_patch/apk_sign.patch" > /tmp/apk_sign.log 2>&1 || true
  if grep -q 'pershoot Manager' manager/apk_sign.c 2>/dev/null; then
    info "多管理器签名支持已生效（pershoot / Wild_KSU）"
  else
    warn "apk_sign 补丁未生效（明细 /tmp/apk_sign.log）"
  fi
elif [[ "$KSU_TYPE" == "ksu" ]]; then
  info "配置原版 KernelSU..."
  sync_repo "https://github.com/tiann/KernelSU.git" KernelSU main
  link_ksu_kernel KernelSU
  cd ./KernelSU
  # 默认对齐官方 release：内核 KSU 版本号要与官方 APK 一致，
  # 且内核编译期写死的管理器签名哈希(c371061b...)是 release 签名。
  # 开发版(main)APK 由 CI 用临时密钥签名，内核永远认不出。
  # 默认 main：SUSFS 集成补丁是针对 main 写的，release tag(v3.3.1) 上会大面积 reject。
  # 若上游 SUSFS 补丁支持了 release 版本，可用 KSU_CHANNEL=release 切换。
  KSU_CHANNEL="${KSU_CHANNEL:-main}"
  KSU_REL_TAG=""
  if [ "$KSU_CHANNEL" = "release" ]; then
    KSU_REL_TAG=$(curl -sL --retry 3 --retry-delay 5 --retry-all-errors --max-time 20       "https://api.github.com/repos/tiann/KernelSU/releases/latest" 2>/dev/null       | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)
    if [ -n "${KSU_REL_TAG:-}" ] && \
       git -c http.proxy= fetch -q --depth=1 origin "refs/tags/${KSU_REL_TAG}:refs/tags/${KSU_REL_TAG}" 2>/dev/null && \
       git checkout -q "refs/tags/${KSU_REL_TAG}" 2>/dev/null; then
      info "KernelSU 已对齐官方 release: ${KSU_REL_TAG}"
    else
      warn "KernelSU release tag 检出失败，回退 main（管理器需自编译同密钥版本）"
      KSU_REL_TAG=""
    fi
  fi
  KSU_COMMITS=$(ksu_commit_count tiann/KernelSU "${KSU_REL_TAG:-main}")
  KSU_COMMITS=${KSU_COMMITS:-0}
  if [[ "$KSU_COMMITS" == "0" ]]; then
    warn "KernelSU 提交数获取失败，版本号降级为基线"
  fi
  KSU_VERSION=$(expr "$KSU_COMMITS" + 30000)
  echo "KSUVER=$KSU_VERSION" >> "$GITHUB_ENV"
  echo "ksuver=$KSU_VERSION" >> "$GITHUB_OUTPUT"
  sed -i "s/DKSU_VERSION=16/DKSU_VERSION=${KSU_VERSION}/" kernel/Kbuild
  grep -q "DKSU_VERSION=${KSU_VERSION}" kernel/Kbuild || warn "DKSU_VERSION 锚点未命中（上游 Kbuild 已变动）"
else
  info "跳过 KernelSU 配置"
  echo "KSUVER=none" >> "$GITHUB_ENV"
  echo "ksuver=none" >> "$GITHUB_OUTPUT"
fi

# 补丁仓并行预取
SUSFS_CACHE_DIR="$HOME/.cache_patches/susfs4ksu"
ZRAM_CACHE_DIR="$HOME/.cache_patches/zram_patches"
SUKI_CACHE_DIR="$HOME/.cache_patches/sukisu_patches"
WILD_DIR="$HOME/.cache_patches/wild_patches"
mkdir -p "$HOME/.cache_patches"

if [[ "$SUSFS_ENABLE" == "true" && "$KSU_TYPE" != "none" ]]; then
  SUSFS_BRANCH="gki-${QCOM_SERIES:-android15-6.6}"
  sync_repo "https://github.com/ShirkNeko/susfs4ksu.git" "$SUSFS_CACHE_DIR" "$SUSFS_BRANCH" || true &
fi
sync_repo "https://github.com/mrcxlinux/kernel_patches.git" "$ZRAM_CACHE_DIR" || true &
if [[ "$LZ4KD_ENABLE" == "true" ]]; then
  sync_repo "https://github.com/ShirkNeko/SukiSU_patch.git" "$SUKI_CACHE_DIR" || true &
fi
sync_repo "https://github.com/WildKernels/kernel_patches.git" "$WILD_DIR" || true &
wait
[ -d "$ZRAM_CACHE_DIR/.git" ] || die "zram_patches 预取失败（克隆失败且无本地缓存）"
[ -d "$WILD_DIR/.git" ] || die "wild_patches 预取失败（克隆失败且无本地缓存）"
if [[ "$SUSFS_ENABLE" == "true" && "$KSU_TYPE" != "none" ]] && [ ! -d "$SUSFS_CACHE_DIR/.git" ]; then
  die "susfs4ksu 预取失败（克隆失败且无本地缓存）"
fi
if [[ "$LZ4KD_ENABLE" == "true" ]] && [ ! -d "$SUKI_CACHE_DIR/.git" ]; then
  die "SukiSU_patch 预取失败（克隆失败且无本地缓存）"
fi
info "补丁仓并行预取完成"

# SUSFS
if [[ "$SUSFS_ENABLE" == "true" ]]; then
  if [[ "$KSU_TYPE" != "none" ]]; then
    cd "$GITHUB_WORKSPACE/kernel_workspace"
    info "添加 susfs 补丁..."

    rm -rf susfs4ksu
    cp -r "$SUSFS_CACHE_DIR" susfs4ksu

    cp "$GITHUB_WORKSPACE/other_patch/69_hide_stuff.patch" ./common/69_hide_stuff.patch

    cp ./susfs4ksu/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH}.patch ./common/
    cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
    cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/

    cd ./common

    sed -i -e '/int ret = 0, copied = 0;/a \    unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;' -e '/int ret = 0, copied = 0;/a \    pagemap_entry_t *res = NULL;' ./fs/proc/task_mmu.c || true

    patch -p1 < 50_add_susfs_in_${SUSFS_BRANCH}.patch || {
      sed -i '/^    unsigned int nr_subpages = __PAGE_SIZE \/ PAGE_SIZE;$/d; /^    pagemap_entry_t \*res = NULL;$/d' ./fs/proc/task_mmu.c || true
      error "SUSFS 核心补丁应用失败"
      exit 1
    }

    sed -i '/^    unsigned int nr_subpages = __PAGE_SIZE \/ PAGE_SIZE;$/d; /^    pagemap_entry_t \*res = NULL;$/d' ./fs/proc/task_mmu.c || true

    patch -p1 -N -F 3 < 69_hide_stuff.patch > /tmp/hide.log 2>&1 || true
    if grep -q 'show_vma_header_prefix_fake' ./fs/proc/task_mmu.c 2>/dev/null; then
      info "隐藏 VMA 功能已生效"
    else
      warn "69_hide_stuff 补丁未生效（明细 /tmp/hide.log）"
    fi
    cd ..
  else
    info "跳过 susfs 配置（未选择 KernelSU）"
  fi

  if [[ "$KSU_TYPE" == "ksu" ]]; then
    info "为原版 KernelSU 添加补丁..."
    cp ./susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./KernelSU/ || warn "susfs-ksu 补丁文件缺失，跳过补丁应用"
    cd ./KernelSU
    patch -p1 < 10_enable_susfs_for_ksu.patch > /tmp/susfs_ksu.log 2>&1 || true
    # 该补丁是针对上游 main 写的；在 release tag(v3.3.1) 上会有 hunk 失败。
    # 只要有 reject 就必须整体回滚：半应用会让源码引用不存在的符号，编译直接失败。
    if find . -name "*.rej" | grep -q .; then
      REJ_N=$(find . -name "*.rej" | wc -l)
      # 不能回滚：内核侧 fs/susfs.c 的 CONFIG_KSU_SUSFS_* 由本补丁的 Kconfig 提供，
      # 回滚会让内核侧 SUSFS 条件编译失效并编译失败。半残状态必须显式中止。
      error "susfs-ksu 集成补丁与当前 KernelSU 版本不兼容（${REJ_N} 个 reject），中止构建"
      find . -name "*.rej" | head -6
      exit 1
    else
      info "SUSFS ↔ KernelSU 集成已生效"
    fi
  fi
fi

# lz4/zstd
cd "$GITHUB_WORKSPACE/kernel_workspace/common"

# 001-lz4.patch 已固化为 other_patch/lz4_1.10_neon.patch，不再从上游拉取
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
LZ4_NEON_PATCH="$GITHUB_WORKSPACE/other_patch/lz4_1.10_neon.patch"
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

# lz4kd
if [[ "$LZ4KD_ENABLE" == "true" ]]; then
  cd "$GITHUB_WORKSPACE/kernel_workspace/common"

  cp -r "$SUKI_CACHE_DIR/other/zram/lz4k/include/linux/"* ./include/linux/
  cp -r "$SUKI_CACHE_DIR/other/zram/lz4k/lib/"* ./lib/
  cp -r "$SUKI_CACHE_DIR/other/zram/lz4k/crypto/"* ./crypto/
  cp "$SUKI_CACHE_DIR/other/zram/zram_patch/6.6/lz4kd.patch" ./
  patch -p1 -F 3 < lz4kd.patch || true

  if [ -f crypto/lz4kd.c ] && [ -f lib/lz4kd/lz4kd_decode.c ] && grep -q 'lz4kd' crypto/Makefile && grep -q 'lz4kd' lib/Makefile; then
    info "LZ4KD 补丁生效 (crypto/lz4kd.c + lib/lz4kd/ 已就位)"
  else
    error "LZ4KD 补丁未生效，中止构建"
    exit 1
  fi
fi

# 风驰引擎已移除：它本质是对 sched_ext 的魔改替换（删掉标准 struct_ops 换成 hmbird），
# 改为启用内核标准 sched_ext，用社区 BPF 调度器（scx_lavd / scx_bpfland 等）替代。
cd "$GITHUB_WORKSPACE/kernel_workspace"
cd common

info "注入 Overwriter 补丁..."
OVERWRITER_PATCH=$(find_latest "$WILD_DIR/oneplus/hmbird/" "overwriter.patch")
if [ -z "$OVERWRITER_PATCH" ]; then
  warn "oneplus/hmbird 未找到 overwriter.patch，开始全仓搜索..."
  OVERWRITER_PATCH=$(find_latest "$WILD_DIR" "overwriter.patch")
fi
if [ -z "$OVERWRITER_PATCH" ]; then
  error "Overwriter 补丁未找到"
  exit 1
fi
sed -i 's/\r$//' "$OVERWRITER_PATCH"
patch -p1 -F 3 -f < "$OVERWRITER_PATCH" || {
  error "Overwriter 补丁应用失败"
  exit 1
}

if [ -f "./drivers/of/overwriter/overwrite_configs/convert_configs.sh" ]; then
  chmod +x ./drivers/of/overwriter/overwrite_configs/convert_configs.sh
fi

info "固化 Hmbird Defconfig..."
HMBIRD_CFG=$(find_latest "$WILD_DIR/oneplus/hmbird/" "hmbird_config.patch")
if [ -z "$HMBIRD_CFG" ]; then
  warn "oneplus/hmbird 未找到 hmbird_config.patch，开始全仓搜索..."
  HMBIRD_CFG=$(find_latest "$WILD_DIR" "hmbird_config.patch")
fi
if [ -z "$HMBIRD_CFG" ]; then
  error "Hmbird Defconfig 补丁未找到"
  exit 1
fi
sed -i 's/\r$//' "$HMBIRD_CFG"
patch -p1 -F 3 -f < "$HMBIRD_CFG" || {
  error "Hmbird Defconfig 补丁应用失败"
  exit 1
}

for p in optimized_mem_operations file_struct_8bytes_align reduce_cache_pressure mem_opt_prefetch optimise_memcmp f2fs_reduce_congestion f2fs_enlarge_min_fsync_blocks increase_ext4_default_commit_age int_sqrt reduce_gc_thread_sleep_time increase_sk_mem_packets disable_cache_hot_buddy force_tcp_nodelay minimise_wakeup_time reduce_freeze_timeout silence_irq_cpu_logspam silence_system_logspam; do
  patch -p1 --forward -f < "$WILD_DIR/common/$p.patch" || warn "$p.patch 应用失败，继续..."
done
if [ -f "$HOME/.cache_patches/zram_patches/common/EnablePOLLY.patch" ]; then
  patch -p1 --forward -f < "$HOME/.cache_patches/zram_patches/common/EnablePOLLY.patch" || warn "EnablePOLLY.patch 应用失败，继续..."
else
  fetch_gh_file "mrcxlinux/kernel_patches" "common/EnablePOLLY.patch" "main" "/tmp/EnablePOLLY.patch" || warn "EnablePOLLY.patch 下载失败，继续..."
  patch -p1 --forward -f < /tmp/EnablePOLLY.patch || warn "EnablePOLLY.patch 应用失败，继续..."
fi
curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 -o /tmp/mm_zsmalloc.patch "https://github.com/brokestar233/android_kernel_common_oneplus_sm8750/commit/d831954.patch" || { warn "mm_zsmalloc 下载失败，跳过..."; rm -f /tmp/mm_zsmalloc.patch; }
patch -p1 --forward -f < /tmp/mm_zsmalloc.patch || warn "mm_zsmalloc 应用失败，继续..."
curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 -o /tmp/mm_kvmalloc.patch "https://github.com/brokestar233/android_kernel_common_oneplus_sm8750/commit/a8093f3.patch" || { warn "mm_kvmalloc 下载失败，跳过..."; rm -f /tmp/mm_kvmalloc.patch; }
patch -p1 --forward -f < /tmp/mm_kvmalloc.patch || warn "mm_kvmalloc 应用失败，继续..."
curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 -o /tmp/mm_slab.patch "https://github.com/brokestar233/android_kernel_common_oneplus_sm8750/commit/936de3f.patch" || { warn "mm_slab 下载失败，跳过..."; rm -f /tmp/mm_slab.patch; }
patch -p1 --forward -f < /tmp/mm_slab.patch || warn "mm_slab 应用失败，继续..."
curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 -o /tmp/mm_vmpressure.patch "https://github.com/brokestar233/android_kernel_common_oneplus_sm8750/commit/99b920c.patch" || { warn "mm_vmpressure 下载失败，跳过..."; rm -f /tmp/mm_vmpressure.patch; }
patch -p1 --forward -f < /tmp/mm_vmpressure.patch || warn "mm_vmpressure 应用失败，继续..."

TOTAL_REJ=0
TOTAL_REJ_FILES=0
count_rejs "基础补丁"

# AOSP 直连补丁已移除：11 个 commit 的改动已 100% 包含在 6.6.143 上游，
# 且 aosp-mirror 仓库已停止更新（最后推送 2025-11），保留只会产生无效 reject。

# palazik 补丁已停用（try_to_steal_block 与 6.6.143 的 fallback 流程不兼容，收益小）

UNICODE_PATCH=$(find_latest "$WILD_DIR/" "*unicode*6.1+*.patch")
if [ -z "$UNICODE_PATCH" ]; then
  UNICODE_PATCH=$(find_latest "$WILD_DIR/" "*unicode*.patch")
fi
if [ -n "$UNICODE_PATCH" ]; then
  info "匹配到 Unicode 防检测路径补丁: $UNICODE_PATCH"
  sed -i 's/\r$//' "$UNICODE_PATCH"
  patch -p1 --forward -f < "$UNICODE_PATCH" || warn "Unicode 补丁应用失败，继续..."
fi

if [ -f "lib/Makefile" ]; then
  grep -q '^CFLAGS_lz4.o += -O3' lib/Makefile || echo 'CFLAGS_lz4.o += -O3' >> lib/Makefile
  grep -q '^CFLAGS_lz4hc.o += -O3' lib/Makefile || echo 'CFLAGS_lz4hc.o += -O3' >> lib/Makefile
fi

git -C "$GITHUB_WORKSPACE/kernel_workspace/common" checkout -- drivers/dma-buf/dma-buf.c 2>/dev/null || true

count_rejs "Unicode/收尾"

if [ "$TOTAL_REJ" -gt 0 ]; then
  warn "补丁失败 hunk 总计 $TOTAL_REJ（涉及 $TOTAL_REJ_FILES 个文件），部分功能可能未生效"
  warn "明细已保存到 $REJ_DIR/*.summary 与同名 .rej"
else
  info "所有补丁干净应用（0 reject）"
fi


# Droidspaces
if [[ "$DROIDSPACES_ENABLE" != "false" ]]; then
  info "启用 Droidspaces 容器支持..."
  cd "$GITHUB_WORKSPACE/kernel_workspace"
  apply_patch_file "droidspaces_patch/fix_sysvipc_kabi_6_7_8.patch" /tmp/fix_sysvipc.patch nonstrict "fix_sysvipc_kabi 补丁"
  apply_patch_file "droidspaces_patch/fix_oplus_bsp_midas.patch" /tmp/fix_midas.patch nonstrict "fix_oplus_bsp_midas 补丁"
  cp "$GITHUB_WORKSPACE/droidspaces_patch/ntsync_base.patch" /tmp/ntsync_base.patch
  if cp "$GITHUB_WORKSPACE/droidspaces_patch/ntsync_compat_android15-$KERNEL_VERSION.patch" /tmp/ntsync_compat.patch; then
    ( cd ./common && patch -p1 -F 3 < /tmp/ntsync_base.patch > /tmp/ntsync.log 2>&1 ) || true
    ( cd ./common && patch -p1 -F 3 < /tmp/ntsync_compat.patch >> /tmp/ntsync.log 2>&1 ) || true
    if [ -f ./common/drivers/misc/ntsync.c ]; then
      info "ntsync 已就位（Wine/Proton 同步原语）"
    else
      warn "ntsync 补丁未生效（明细 /tmp/ntsync.log）"
    fi
  else
    warn "ntsync compat 补丁拉取失败，跳过（仅 base 已应用）"
    ( cd ./common && patch -p1 -F 3 < /tmp/ntsync_base.patch ) || true
  fi
  if [[ "$DROIDSPACES_ENABLE" == "extend" ]]; then
    apply_patch_file "droidspaces_patch/evdi_drm.patch" /tmp/evdi_drm.patch nonstrict "evdi_drm 补丁"
  fi
fi

# ADIOS
info "启用 ADIOS I/O 调度器..."
cd "$GITHUB_WORKSPACE/kernel_workspace"
apply_patch_file "other_patch/adios/adios_block_only.patch" /tmp/adios.patch strict "ADIOS 补丁"

# Re-Kernel
if [[ "$REKERNEL_ENABLE" == "true" ]]; then
  info "启用 Re-Kernel 支持..."
  cd "$GITHUB_WORKSPACE/kernel_workspace"
  echo "CONFIG_REKERNEL=y" >> ./common/arch/arm64/configs/gki_defconfig
fi

# Baseband-guard
if [[ "$BASEBAND_GUARD" == "true" ]]; then
  info "启用基带保护..."
  cd "$GITHUB_WORKSPACE/kernel_workspace"
  echo "CONFIG_BBG=y" >> ./common/arch/arm64/configs/gki_defconfig
  cd common
  curl -fSL --retry 3 --retry-delay 5 --retry-all-errors -o /tmp/baseband_setup.sh \
    "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" || {
    error "Baseband-guard 脚本下载失败"
    exit 1
  }
  bash /tmp/baseband_setup.sh || {
    error "Baseband-guard 安装失败"
    exit 1
  }
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
  grep -q 'baseband_guard' security/Kconfig || { error "BBG LSM 注入失败（security/Kconfig 无 baseband_guard），中止构建"; exit 1; }
fi

# BBRv3
info "应用 BBRv3 补丁..."
cd "$GITHUB_WORKSPACE/kernel_workspace/common"
fetch_gh_file "WildKernels/kernel_patches" "common/bbrv3/0001-net-tcp-backport-BBRv3-to-android15-6.6.patch" "main" /tmp/bbrv3.patch

if git apply -p1 < /tmp/bbrv3.patch 2>/dev/null; then
  info "BBRv3 git apply 成功"
elif patch -p1 -F 3 < /tmp/bbrv3.patch 2>/dev/null; then
  info "BBRv3 patch 成功"
else
  error "BBRv3 补丁失败，中止构建"
  exit 1
fi

echo "CONFIG_TCP_CONG_BBR3=y" >> ./arch/arm64/configs/gki_defconfig
echo "CONFIG_DEFAULT_BBR3=y" >> ./arch/arm64/configs/gki_defconfig

# 调度器优化
cd "$GITHUB_WORKSPACE/kernel_workspace/common"

cat > kernel/sched/sched-pelt.h << 'PELTEOF'
/* SPDX-License-Identifier: GPL-2.0 */
/* Generated by Documentation/scheduler/sched-pelt; do not modify. */

static const u32 runnable_avg_yN_inv[] __maybe_unused = {
	0xffffffff,	0xf5257d14,	0xeac0c6e6,	0xe0ccdeeb,	0xd744fcc9,	0xce248c14,
	0xc5672a10,	0xbd08a39e,	0xb504f333,	0xad583ee9,	0xa5fed6a9,	0x9ef5325f,
	0x9837f050,	0x91c3d373,	0x8b95c1e3,	0x85aac367,
};

#define LOAD_AVG_PERIOD 16
#define LOAD_AVG_MAX 24130
PELTEOF

sed -i 's/SCHED_FEAT(NEXT_BUDDY, false)/SCHED_FEAT(NEXT_BUDDY, true)/' kernel/sched/features.h
sed -i 's/SCHED_FEAT(HRTICK, false)/SCHED_FEAT(HRTICK, true)/' kernel/sched/features.h
sed -i 's/SCHED_FEAT(SIS_PROP, false)/SCHED_FEAT(SIS_PROP, true)/' kernel/sched/features.h
# 缓存局部性 + 减少无谓迁移（省电取向）
sed -i 's/SCHED_FEAT(CACHE_HOT_BUDDY, false)/SCHED_FEAT(CACHE_HOT_BUDDY, true)/' kernel/sched/features.h
sed -i 's/SCHED_FEAT(LB_MIN, false)/SCHED_FEAT(LB_MIN, true)/' kernel/sched/features.h
for feat in NEXT_BUDDY HRTICK SIS_PROP CACHE_HOT_BUDDY LB_MIN; do
  grep -q "SCHED_FEAT($feat, true)" kernel/sched/features.h || {
    error "调度优化 $feat 注入失败（上游已改名，需人工核对），中止构建"
    exit 1
  }
done

info "调度器优化完成 (16ms PELT / NEXT_BUDDY / HRTICK / SIS_PROP / CACHE_HOT_BUDDY / LB_MIN)"

# f2fs：默认启用 ATGC（年龄阈值 GC）与 GC_MERGE（GC 写合并）
# 两者在 6.6.143 里已存在，但只能通过挂载参数开启；而挂载参数由 ROM 的 fstab 决定。
# 这里在 default_options() 之后、解析挂载参数之前打开，ROM 显式传 nogc_merge 仍可覆盖。
F2FS_ATGC_PATCH='" + D + "GITHUB_WORKSPACE/other_patch/f2fs_default_atgc_gcmerge.patch'
if [ -f "$F2FS_ATGC_PATCH" ]; then
  if patch -p1 --forward -F 3 < "$F2FS_ATGC_PATCH" >/dev/null 2>&1; then
    info "f2fs ATGC / GC_MERGE 默认值已启用"
  else
    warn "f2fs ATGC / GC_MERGE 补丁应用失败（继续构建）"
  fi
fi
if grep -q 'set_opt(sbi, ATGC);' fs/f2fs/super.c 2>/dev/null && \
   grep -q 'set_opt(sbi, GC_MERGE);' fs/f2fs/super.c 2>/dev/null; then
  info "f2fs ATGC / GC_MERGE 校验通过"
else
  warn "f2fs ATGC / GC_MERGE 未生效，GC 行为与上游一致"
fi

# f2fs GC 三项调优：紧急休眠 500→50ms、拥塞超时 20→6ms、fsync 批量 8→20
# 来源 WildKernels/kernel_patches，均已验证适用于 6.6.143
F2FS_GC_TUNING="$GITHUB_WORKSPACE/other_patch/f2fs_gc_tuning.patch"
if [ -f "$F2FS_GC_TUNING" ]; then
  patch -p1 --forward -F 3 < "$F2FS_GC_TUNING" > /tmp/f2fs_gc_tuning.log 2>&1 || true
fi
if grep -q 'DEF_GC_THREAD_URGENT_SLEEP_TIME.50' fs/f2fs/gc.h 2>/dev/null && \
   grep -q 'msecs_to_jiffies(6)' fs/f2fs/f2fs.h 2>/dev/null && \
   grep -q 'DEF_MIN_FSYNC_BLOCKS.20' fs/f2fs/segment.h 2>/dev/null; then
  info "f2fs GC 调优已生效（紧急休眠 50ms / 拥塞 6ms / fsync 批量 20）"
else
  warn "f2fs GC 调优未完全生效"
  grep -E 'FAILED|rej' /tmp/f2fs_gc_tuning.log 2>/dev/null | head -3 || true
fi

# 新 glibc（如 26.04 的 2.42）下 strchr() 对 const 参数返回 const char*，
# 会与内核自带 -Werror 冲突，导致 resolve_btfids 编译失败。
LIBBPF="$GITHUB_WORKSPACE/kernel_workspace/common/tools/lib/bpf/libbpf.c"
# 自愈：旧版补丁在 6.6.14x 上会产生 const const
if grep -qE 'const const char \*next_path;' "$LIBBPF" 2>/dev/null; then
  sed -i 's/const const char \*next_path;/const char *next_path;/' "$LIBBPF"
  info "libbpf const 重复声明已修正"
fi
if grep -qE '^[[:space:]]*char \*next_path;' "$LIBBPF" 2>/dev/null; then
  sed -i 's/^[[:space:]]*char \*next_path;/const char *next_path;/' "$LIBBPF"
  info "libbpf const 补丁已应用（新 glibc 兼容）"
elif grep -qE '^[[:space:]]*const char \*next_path;' "$LIBBPF" 2>/dev/null; then
  info "libbpf 已是 const 声明（上游已修），跳过该补丁"
else
  warn "libbpf next_path 声明未找到，跳过"
fi

touch /tmp/sync_failed.list "$PENDING_SYNC"
sort -u "$PENDING_SYNC" /tmp/sync_failed.list -o "$PENDING_SYNC"
