#!/bin/bash
# apply_patches.sh — 源码修改域：KSU/SUSFS/lz4/风驰/Droidspaces/ADIOS/BBG/BBRv3/调度
set -euo pipefail
source "$(dirname "$0")/common.sh"

cd "$GITHUB_WORKSPACE/kernel_workspace"

sync_repo() {
  local url="$1" dir="$2" branch="${3:-main}"
  if [ -d "$dir/.git" ]; then
    if glr fetch -C "$dir" --depth=1 origin "$branch"; then
      git -C "$dir" reset --hard FETCH_HEAD
      info "[动态] $dir 已同步 $branch 最新"
    else
      warn "$dir fetch 失败，使用本地已有版本"
    fi
  else
    rm -rf "$dir"
    glr clone --depth=1 "$url" "$dir" -b "$branch" || { error "补丁仓克隆失败: $url ($branch)"; exit 1; }
  fi
}

# ============ KernelSU ============
rm -rf common/drivers/kernelsu

if [[ "$KSU_TYPE" == "sukisu" || "$KSU_TYPE" == "resukisu" ]]; then
  info "配置 ReSukiSU..."
  if [ -d KernelSU/.git ]; then
    info "[秒过] ReSukiSU 仓库已存在，增量同步..."
    if glr fetch -C KernelSU origin main 2>/dev/null; then
      git -C KernelSU reset --hard FETCH_HEAD
    else
      warn "KernelSU 增量拉取失败，使用本地已有版本"
    fi
  else
    rm -rf KernelSU
    glr clone -b main https://github.com/ReSukiSU/ReSukiSU.git KernelSU
  fi
  ln -sf "$(realpath --relative-to=common/drivers "$PWD/KernelSU/kernel")" common/drivers/kernelsu
  grep -q "kernelsu" common/drivers/Makefile || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> common/drivers/Makefile
  grep -q "drivers/kernelsu/Kconfig" common/drivers/Kconfig || sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" common/drivers/Kconfig
  echo 'CONFIG_KSU_FULL_NAME_FORMAT="%TAG_NAME%-%COMMIT_SHA%@walunt236"' >> ./common/arch/arm64/configs/gki_defconfig
  cd ./KernelSU
  KSU_VERSION=$(expr $(git rev-list --count main) + 30700 2>/dev/null || echo 0)
  if [[ "$KSU_VERSION" == "0" ]]; then
    warn "ReSukiSU 提交数获取失败，版本号降级为 0"
  fi
  echo "KSUVER=$KSU_VERSION" >> "$GITHUB_ENV"
  echo "ksuver=$KSU_VERSION" >> "$GITHUB_OUTPUT"
elif [[ "$KSU_TYPE" == "ksunext" ]]; then
  info "配置 KernelSU Next..."
  if [ -d KernelSU-Next/.git ]; then
    info "[秒过] KernelSU-Next 仓库已存在，增量同步..."
    if glr fetch -C KernelSU-Next origin dev-susfs 2>/dev/null; then
      git -C KernelSU-Next reset --hard FETCH_HEAD
    else
      warn "KernelSU-Next 增量拉取失败，使用本地已有版本"
    fi
  else
    rm -rf KernelSU-Next
    glr clone -b dev-susfs https://github.com/pershoot/KernelSU-Next.git KernelSU-Next
  fi
  ln -sf "$(realpath --relative-to=common/drivers "$PWD/KernelSU-Next/kernel")" common/drivers/kernelsu
  grep -q "kernelsu" common/drivers/Makefile || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> common/drivers/Makefile
  grep -q "drivers/kernelsu/Kconfig" common/drivers/Kconfig || sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" common/drivers/Kconfig
  cd KernelSU-Next
  KSU_COMMITS=$(curl -sI --retry 3 --retry-delay 5 "https://api.github.com/repos/pershoot/KernelSU-Next/commits?sha=dev&per_page=1" | grep -i "link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p' || true)
  KSU_COMMITS=${KSU_COMMITS:-0}
  if [[ "$KSU_COMMITS" == "0" ]]; then
    warn "KernelSU-Next 提交数获取失败，版本号降级为基线"
  fi
  KSU_VERSION=$(expr "$KSU_COMMITS" + 30000)
  echo "KSUVER=$KSU_VERSION" >> "$GITHUB_ENV"
  echo "ksuver=$KSU_VERSION" >> "$GITHUB_OUTPUT"
  sed -i "s/KSU_VERSION_FALLBACK := 1/KSU_VERSION_FALLBACK := $KSU_VERSION/g" kernel/Kbuild
  KSU_GIT_TAG=$(curl -sL --retry 3 --retry-delay 5 --retry-all-errors "https://api.github.com/repos/KernelSU-Next/KernelSU-Next/tags" | grep -o '"name": *"[^"]*"' | head -n 1 | sed 's/"name": "//;s/"//')
  sed -i "s/KSU_VERSION_TAG_FALLBACK := v0.0.1/KSU_VERSION_TAG_FALLBACK := $KSU_GIT_TAG/g" kernel/Kbuild
  cd ../common/drivers/kernelsu
  curl -fSL --retry 3 --retry-delay 5 --retry-all-errors -o apk_sign.patch "https://github.com/$GITHUB_REPOSITORY/raw/refs/heads/$GITHUB_REF_NAME/other_patch/apk_sign.patch"
  patch -p2 -N -F 3 < apk_sign.patch || true
elif [[ "$KSU_TYPE" == "ksu" ]]; then
  info "配置原版 KernelSU..."
  if [ -d KernelSU/.git ]; then
    info "[秒过] KernelSU 仓库已存在，增量同步..."
    if glr fetch -C KernelSU origin main 2>/dev/null; then
      git -C KernelSU reset --hard FETCH_HEAD
    else
      warn "KernelSU 增量拉取失败，使用本地已有版本"
    fi
  else
    rm -rf KernelSU
    glr clone -b main https://github.com/tiann/KernelSU.git KernelSU
  fi
  ln -sf "$(realpath --relative-to=common/drivers "$PWD/KernelSU/kernel")" common/drivers/kernelsu
  grep -q "kernelsu" common/drivers/Makefile || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> common/drivers/Makefile
  grep -q "drivers/kernelsu/Kconfig" common/drivers/Kconfig || sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" common/drivers/Kconfig
  cd ./KernelSU
  KSU_COMMITS=$(curl -sI --retry 3 --retry-delay 5 "https://api.github.com/repos/tiann/KernelSU/commits?sha=main&per_page=1" | grep -i "link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p' || true)
  KSU_COMMITS=${KSU_COMMITS:-0}
  if [[ "$KSU_COMMITS" == "0" ]]; then
    warn "KernelSU 提交数获取失败，版本号降级为基线"
  fi
  KSU_VERSION=$(expr "$KSU_COMMITS" + 30000)
  echo "KSUVER=$KSU_VERSION" >> "$GITHUB_ENV"
  echo "ksuver=$KSU_VERSION" >> "$GITHUB_OUTPUT"
  sed -i "s/DKSU_VERSION=16/DKSU_VERSION=${KSU_VERSION}/" kernel/Kbuild
else
  info "跳过 KernelSU 配置"
  echo "KSUVER=none" >> "$GITHUB_ENV"
  echo "ksuver=none" >> "$GITHUB_OUTPUT"
fi

# ===== SUSFS（官方源 ShirkNeko/susfs4ksu，GKI android15-6.6 分支） =====
if [[ "$SUSFS_ENABLE" == "true" ]]; then
  if [[ "$KSU_TYPE" != "none" ]]; then
    cd "$GITHUB_WORKSPACE/kernel_workspace"
    info "添加 susfs 补丁..."
    SUSFS_CACHE_DIR="$HOME/.cache_patches/susfs4ksu"
    mkdir -p "$HOME/.cache_patches"
    sync_repo "https://github.com/ShirkNeko/susfs4ksu.git" "$SUSFS_CACHE_DIR" "gki-android15-6.6"

    rm -rf susfs4ksu
    cp -r "$SUSFS_CACHE_DIR" susfs4ksu

    # 69_hide_stuff.patch 缓存化
    HIDE_PATCH="$HOME/.cache_patches/69_hide_stuff.patch"
    if [ ! -f "$HIDE_PATCH" ]; then
      fetch_repo_file "other_patch/69_hide_stuff.patch" "$HIDE_PATCH"
    fi
    cp "$HIDE_PATCH" ./common/69_hide_stuff.patch

    cp ./susfs4ksu/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch ./common/
    cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
    cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/

    cd ./common

    # 预处理 task_mmu.c 防止补丁偏移报错
    sed -i -e '/int ret = 0, copied = 0;/a \    unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;' -e '/int ret = 0, copied = 0;/a \    pagemap_entry_t *res = NULL;' ./fs/proc/task_mmu.c || true

    patch -p1 < 50_add_susfs_in_gki-android15-6.6.patch || {
      error "SUSFS 核心补丁应用失败"
      exit 1
    }

    # 删除预处理插入的声明（4 空格缩进）——补丁自带 tab 缩进声明，锚定区分防重复
    sed -i '/^    unsigned int nr_subpages = __PAGE_SIZE \/ PAGE_SIZE;$/d; /^    pagemap_entry_t \*res = NULL;$/d' ./fs/proc/task_mmu.c || true

    patch -p1 -N -F 3 < 69_hide_stuff.patch || true
    cd ..
  else
    info "跳过 susfs 配置（未选择 KernelSU）"
  fi

  if [[ "$KSU_TYPE" == "ksu" ]]; then
    info "为原版 KernelSU 添加补丁..."
    cp ./susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./KernelSU/
    cd ./KernelSU
    patch -p1 < 10_enable_susfs_for_ksu.patch || true
  fi
fi

# ===== lz4/zstd =====
cd "$GITHUB_WORKSPACE/kernel_workspace/common"
CACHE_DIR="$HOME/.cache_patches/zram_patches"
mkdir -p "$HOME/.cache_patches"
sync_repo "https://github.com/mrcxlinux/kernel_patches.git" "$CACHE_DIR"

cp "$CACHE_DIR/zram/001-lz4.patch" . || exit 1
cp "$CACHE_DIR/zram/002-zstd.patch" . || exit 1

mkdir -p lib/lz4/lz4armv8
cp "$CACHE_DIR/zram/lz4armv8.S" lib/lz4/lz4armv8/lz4armv8.S || true

ACCEL_DIR="$HOME/.cache_patches/lz4accel"
mkdir -p "$ACCEL_DIR"
# 固定 6.6.142 分支（与 AOSP merge 基线一致，防 API 漂移）
PALAZIK_BRANCH="6.6.142_oneplus13_coloros16"
info "lz4accel 上游分支: $PALAZIK_BRANCH"
curl -fsSL --retry 3 --retry-delay 5 -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/palazik/android_kernel_common_oneplus_sm8750/contents/fs/f2fs/lz4armv8/lz4accel.c?ref=$PALAZIK_BRANCH" | \
  python3 -c "import sys,json,base64;open('$ACCEL_DIR/lz4accel.c','wb').write(base64.b64decode(json.load(sys.stdin)['content']))" || warn "lz4accel.c 拉取失败，保留缓存/继续..."
curl -fsSL --retry 3 --retry-delay 5 -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/palazik/android_kernel_common_oneplus_sm8750/contents/fs/f2fs/lz4armv8/lz4accel.h?ref=$PALAZIK_BRANCH" | \
  python3 -c "import sys,json,base64;open('$ACCEL_DIR/lz4accel.h','wb').write(base64.b64decode(json.load(sys.stdin)['content']))" || warn "lz4accel.h 拉取失败，保留缓存/继续..."
mkdir -p fs/f2fs/lz4armv8
cp "$ACCEL_DIR/lz4accel.c" fs/f2fs/lz4armv8/
cp "$ACCEL_DIR/lz4accel.h" fs/f2fs/lz4armv8/

git apply --reject --whitespace=nowarn 001-lz4.patch || true
patch -p1 -t -F 3 < 002-zstd.patch || true

# 校验：lz4armv8.S（NEON 解压）+ zstd 补丁就位（001-lz4.patch 为 IDEA 格式 binary 段，git apply 无法应用，lz4 用内核原版）
if [ -f lib/lz4/lz4armv8/lz4armv8.S ] && [ -f lib/zstd/zstd_common_module.c ]; then
  info "lz4 NEON 解压 + zstd 就位"
else
  error "lz4/zstd 补丁未生效（lz4armv8.S/zstd 缺失），中止构建"
  exit 1
fi

# ===== lz4kd =====
if [[ "$LZ4KD_ENABLE" == "true" ]]; then
  cd "$GITHUB_WORKSPACE/kernel_workspace/common"
  CACHE_DIR="$HOME/.cache_patches/sukisu_patches"
  mkdir -p "$HOME/.cache_patches"
  sync_repo "https://github.com/ShirkNeko/SukiSU_patch.git" "$CACHE_DIR"

  cp -r "$CACHE_DIR/other/zram/lz4k/include/linux/"* ./include/linux/
  cp -r "$CACHE_DIR/other/zram/lz4k/lib/"* ./lib/
  cp -r "$CACHE_DIR/other/zram/lz4k/crypto/"* ./crypto/
  cp "$CACHE_DIR/other/zram/zram_patch/6.6/lz4kd.patch" ./
  patch -p1 -F 3 < lz4kd.patch || true

  if [ -f crypto/lz4kd.c ] && [ -f lib/lz4kd/lz4kd_decode.c ] && grep -q 'lz4kd' crypto/Makefile && grep -q 'lz4kd' lib/Makefile; then
    info "LZ4KD 补丁生效 (crypto/lz4kd.c + lib/lz4kd/ 已就位)"
  else
    error "LZ4KD 补丁未生效，中止构建"
    exit 1
  fi
fi

# ===== 风驰引擎及优化补丁批 =====
cd "$GITHUB_WORKSPACE/kernel_workspace"

info "获取 Wild 补丁仓..."
WILD_DIR="$HOME/.cache_patches/wild_patches"
mkdir -p "$HOME/.cache_patches"
sync_repo "https://github.com/WildKernels/kernel_patches.git" "$WILD_DIR"

# 优先 oneplus/hmbird，未命中全仓搜索（上游目录可能变动）
PATCH_FILE=$(find "$WILD_DIR/oneplus/hmbird/" -maxdepth 1 -name "fengchi_OP13_*.patch" 2>/dev/null | sort | tail -n 1 || true)
if [ -z "$PATCH_FILE" ]; then
  warn "oneplus/hmbird 目录未找到风驰补丁，开始全仓搜索..."
  PATCH_FILE=$(find "$WILD_DIR" -type f -name "fengchi_OP13_*.patch" 2>/dev/null | sort | tail -n 1 || true)
fi
if [ -z "$PATCH_FILE" ]; then
  error "未匹配到一加13风驰补丁"
  exit 1
fi

info "匹配风驰补丁: $PATCH_FILE"
sed -i 's/\r$//' "$PATCH_FILE"

cd common

info "注入风驰引擎补丁..."
patch -p1 -F 3 -f < "$PATCH_FILE" || true
REJ_COUNT=$(find . -name "*.rej" 2>/dev/null | wc -l)
if [ "$REJ_COUNT" -gt 0 ]; then
  warn "风驰补丁有 $REJ_COUNT 个 reject:"
  find . -name "*.rej" 2>/dev/null | while read f; do
    echo "  --- $(basename "$f") ---" | tee -a "$LOG_FILE"
    head -20 "$f" | tee -a "$LOG_FILE"
  done
fi
if [ "$REJ_COUNT" -le 3 ]; then
  warn "风驰补丁 reject ≤3（上游合并导致偏移），继续编译"
else
  error "风驰核心补丁应用失败（$REJ_COUNT 个 reject）"
  exit 1
fi
find . -name "*.rej" -delete 2>/dev/null

info "注入 Overwriter 补丁..."
OVERWRITER_PATCH=$(find "$WILD_DIR/oneplus/hmbird/" -maxdepth 1 -name "overwriter.patch" 2>/dev/null | sort | tail -n 1 || true)
if [ -z "$OVERWRITER_PATCH" ]; then
  warn "oneplus/hmbird 未找到 overwriter.patch，开始全仓搜索..."
  OVERWRITER_PATCH=$(find "$WILD_DIR" -type f -name "overwriter.patch" 2>/dev/null | sort | tail -n 1 || true)
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
HMBIRD_CFG=$(find "$WILD_DIR/oneplus/hmbird/" -maxdepth 1 -name "hmbird_config.patch" 2>/dev/null | sort | tail -n 1 || true)
if [ -z "$HMBIRD_CFG" ]; then
  warn "oneplus/hmbird 未找到 hmbird_config.patch，开始全仓搜索..."
  HMBIRD_CFG=$(find "$WILD_DIR" -type f -name "hmbird_config.patch" 2>/dev/null | sort | tail -n 1 || true)
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

patch -p1 --forward -f < "$WILD_DIR/common/optimized_mem_operations.patch" || warn "optimized_mem_operations.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/file_struct_8bytes_align.patch" || warn "file_struct_8bytes_align.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/reduce_cache_pressure.patch" || warn "reduce_cache_pressure.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/mem_opt_prefetch.patch" || warn "mem_opt_prefetch.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/optimise_memcmp.patch" || warn "optimise_memcmp.patch 应用失败，继续..."

patch -p1 --forward -f < "$WILD_DIR/common/f2fs_reduce_congestion.patch" || warn "f2fs_reduce_congestion.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/f2fs_enlarge_min_fsync_blocks.patch" || warn "f2fs_enlarge_min_fsync_blocks.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/increase_ext4_default_commit_age.patch" || warn "increase_ext4_default_commit_age.patch 应用失败，继续..."

patch -p1 --forward -f < "$WILD_DIR/common/int_sqrt.patch" || warn "int_sqrt.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/reduce_gc_thread_sleep_time.patch" || warn "reduce_gc_thread_sleep_time.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/increase_sk_mem_packets.patch" || warn "increase_sk_mem_packets.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/disable_cache_hot_buddy.patch" || warn "disable_cache_hot_buddy.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/force_tcp_nodelay.patch" || warn "force_tcp_nodelay.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/minimise_wakeup_time.patch" || warn "minimise_wakeup_time.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/reduce_freeze_timeout.patch" || warn "reduce_freeze_timeout.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/silence_irq_cpu_logspam.patch" || warn "silence_irq_cpu_logspam.patch 应用失败，继续..."
patch -p1 --forward -f < "$WILD_DIR/common/silence_system_logspam.patch" || warn "silence_system_logspam.patch 应用失败，继续..."
if [ -f "$HOME/.cache_patches/zram_patches/common/EnablePOLLY.patch" ]; then
  patch -p1 --forward -f < "$HOME/.cache_patches/zram_patches/common/EnablePOLLY.patch" || warn "EnablePOLLY.patch 应用失败，继续..."
else
  curl -fsSL --retry 3 --retry-delay 5 -H "Authorization: token ${GH_TOKEN:-}" \
    "https://api.github.com/repos/mrcxlinux/kernel_patches/contents/common/EnablePOLLY.patch?ref=main" | \
    python3 -c "import sys,json,base64;open('/tmp/EnablePOLLY.patch','wb').write(base64.b64decode(json.load(sys.stdin)['content']))" || warn "EnablePOLLY.patch 下载失败，继续..."
  patch -p1 --forward -f < /tmp/EnablePOLLY.patch || warn "EnablePOLLY.patch 应用失败，继续..."
fi
curl -fSL --retry 3 --retry-delay 5 --retry-all-errors -o /tmp/mm_zsmalloc.patch "https://github.com/brokestar233/android_kernel_common_oneplus_sm8750/commit/d831954.patch"
patch -p1 --forward -f < /tmp/mm_zsmalloc.patch || warn "mm_zsmalloc 应用失败，继续..."
curl -fSL --retry 3 --retry-delay 5 --retry-all-errors -o /tmp/mm_kvmalloc.patch "https://github.com/brokestar233/android_kernel_common_oneplus_sm8750/commit/a8093f3.patch"
patch -p1 --forward -f < /tmp/mm_kvmalloc.patch || warn "mm_kvmalloc 应用失败，继续..."
curl -fSL --retry 3 --retry-delay 5 --retry-all-errors -o /tmp/mm_slab.patch "https://github.com/brokestar233/android_kernel_common_oneplus_sm8750/commit/936de3f.patch"
patch -p1 --forward -f < /tmp/mm_slab.patch || warn "mm_slab 应用失败，继续..."
curl -fSL --retry 3 --retry-delay 5 --retry-all-errors -o /tmp/mm_vmpressure.patch "https://github.com/brokestar233/android_kernel_common_oneplus_sm8750/commit/99b920c.patch"
patch -p1 --forward -f < /tmp/mm_vmpressure.patch || warn "mm_vmpressure 应用失败，继续..."

TOTAL_REJ=0
BATCH_REJ=$(find . -name "*.rej" 2>/dev/null | wc -l)
TOTAL_REJ=$((TOTAL_REJ + BATCH_REJ))
info "风驰批补丁 reject: $BATCH_REJ"
find . -name "*.rej" -delete 2>/dev/null

# AOSP 上游补丁批（aosp-mirror commit.patch，纯直连通道；本地缓存化）
mkdir -p "$HOME/.cache_patches/aosp"
for hash in 47f80469849a 5fddd8e6a0a7 0a9eef42768c 71bd6942e33f ef0123e95425 7abe312b37cf 6a42fccfc2bc d43ee181a478 5c8ecdcfbfb0 c5d6863c9aba 9eecad532ad3 c7a8aea27b87; do
  if [ ! -s "$HOME/.cache_patches/aosp/$hash.patch" ]; then
    curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 10 --max-time 30 \
      -o "$HOME/.cache_patches/aosp/$hash.patch" "https://github.com/aosp-mirror/kernel_common/commit/$hash.patch" 2>/dev/null || rm -f "$HOME/.cache_patches/aosp/$hash.patch"
  fi
done
for hash in 47f80469849a 5fddd8e6a0a7 0a9eef42768c 71bd6942e33f ef0123e95425 7abe312b37cf 6a42fccfc2bc d43ee181a478 5c8ecdcfbfb0 c5d6863c9aba 9eecad532ad3 c7a8aea27b87; do
  patch -p1 --forward -F 3 < "$HOME/.cache_patches/aosp/$hash.patch" 2>/dev/null || warn "aosp/$hash.patch 应用失败，继续..."
done
BATCH_REJ=$(find . -name "*.rej" 2>/dev/null | wc -l)
TOTAL_REJ=$((TOTAL_REJ + BATCH_REJ))
info "AOSP 补丁 reject: $BATCH_REJ"
find . -name "*.rej" -delete 2>/dev/null

# palazik 补丁批（本地缓存化）
mkdir -p "$HOME/.cache_patches/palazik"
for hash in e8400a0 a09e19e; do
  if [ ! -s "$HOME/.cache_patches/palazik/$hash.patch" ]; then
    curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 -o "$HOME/.cache_patches/palazik/$hash.patch" "https://github.com/palazik/android_kernel_common_oneplus_sm8750/commit/$hash.patch" 2>/dev/null || rm -f "$HOME/.cache_patches/palazik/$hash.patch"
  fi
done
for hash in e8400a0 a09e19e; do
  if [ -s "$HOME/.cache_patches/palazik/$hash.patch" ]; then
    patch -p1 --forward -F 3 < "$HOME/.cache_patches/palazik/$hash.patch" 2>/dev/null || warn "palazik/$hash.patch 应用失败，继续..."
  else
    warn "palazik/$hash.patch 缺失或为空，跳过"
  fi
done
BATCH_REJ=$(find . -name "*.rej" 2>/dev/null | wc -l)
TOTAL_REJ=$((TOTAL_REJ + BATCH_REJ))
info "Palazik 补丁 reject: $BATCH_REJ"
find . -name "*.rej" -delete 2>/dev/null

UNICODE_PATCH=$(find "$WILD_DIR/" -name "*unicode*.patch" | sort | tail -n 1 || true)
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

BATCH_REJ=$(find . -name "*.rej" 2>/dev/null | wc -l)
TOTAL_REJ=$((TOTAL_REJ + BATCH_REJ))
find . -name "*.rej" -delete 2>/dev/null
info "Unicode/收尾补丁 reject: $BATCH_REJ"

if [ "$TOTAL_REJ" -gt 15 ]; then
  error "风驰+优化补丁总计 $TOTAL_REJ 个 reject（>15），请检查补丁兼容性"
  exit 1
elif [ "$TOTAL_REJ" -gt 10 ]; then
  warn "风驰+优化补丁总计 $TOTAL_REJ 个 reject，部分优化可能未生效"
else
  info "风驰+优化补丁 reject 总计 $TOTAL_REJ 个，正常"
fi

info "风驰引擎补丁注入完成"

# ============ Droidspaces ============
if [[ "$DROIDSPACES_ENABLE" != "false" ]]; then
  info "启用 Droidspaces 容器支持..."
  cd "$GITHUB_WORKSPACE/kernel_workspace/common"
  fetch_repo_file "droidspaces_patch/fix_sysvipc_kabi_6_7_8.patch" fix_sysvipc_kabi_6_7_8.patch
  patch -p1 -F 3 < fix_sysvipc_kabi_6_7_8.patch || true
  fetch_repo_file "droidspaces_patch/fix_oplus_bsp_midas.patch" fix_oplus_bsp_midas.patch
  patch -p1 -F 3 < fix_oplus_bsp_midas.patch || true
  fetch_repo_file "droidspaces_patch/ntsync_base.patch" ntsync_base.patch
  if fetch_repo_file "droidspaces_patch/ntsync_compat_android15-$KERNEL_VERSION.patch" ntsync_compat.patch; then
    patch -p1 -F 3 < ntsync_base.patch || true
    patch -p1 -F 3 < ntsync_compat.patch || true
  else
    warn "ntsync compat 补丁拉取失败，跳过（仅 base 已应用）"
    patch -p1 -F 3 < ntsync_base.patch || true
  fi
  if [[ "$DROIDSPACES_ENABLE" == "extend" ]]; then
    fetch_repo_file "droidspaces_patch/evdi_drm.patch" evdi_drm.patch
    patch -p1 -F 3 < evdi_drm.patch || true
  fi
fi

# ===== ADIOS =====
info "启用 ADIOS I/O 调度器..."
cd "$GITHUB_WORKSPACE/kernel_workspace"
# block 4 文件：Kconfig.iosched/Makefile/adios.c/elevator.c（6.6 兼容已验证）
fetch_repo_file "other_patch/adios/adios_block_only.patch" /tmp/adios.patch
if ( cd ./common && patch -p1 -F 3 < /tmp/adios.patch ); then
  info "ADIOS 补丁应用成功"
else
  error "ADIOS 补丁应用失败，中止构建"
  exit 1
fi

# ===== Re-Kernel =====
if [[ "$REKERNEL_ENABLE" == "true" ]]; then
  info "启用 Re-Kernel 支持..."
  cd "$GITHUB_WORKSPACE/kernel_workspace"
  echo "CONFIG_REKERNEL=y" >> ./common/arch/arm64/configs/gki_defconfig
fi

# ===== Baseband-guard（官方源 vc-teahouse） =====
if [[ "$BASEBAND_GUARD" == "true" ]]; then
  info "启用基带保护..."
  cd "$GITHUB_WORKSPACE/kernel_workspace"
  echo "CONFIG_BBG=y" >> ./common/arch/arm64/configs/gki_defconfig
  cd common
  # 两步执行（下载到文件再执行，非管道）
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
fi

# ===== BBRv3 =====
info "应用 BBRv3 补丁..."
cd "$GITHUB_WORKSPACE/kernel_workspace/common"
curl -fsSL --retry 3 --retry-delay 5 -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/WildKernels/kernel_patches/contents/common/bbrv3/0001-net-tcp-backport-BBRv3-to-android15-6.6.patch?ref=main" | \
  python3 -c "import sys,json,base64;open('bbrv3.patch','wb').write(base64.b64decode(json.load(sys.stdin)['content']))"

if git apply -p1 < bbrv3.patch 2>/dev/null; then
  info "BBRv3 git apply 成功"
elif patch -p1 -F 3 < bbrv3.patch 2>/dev/null; then
  info "BBRv3 patch 成功"
else
  error "BBRv3 补丁失败，中止构建"
  exit 1
fi

echo "CONFIG_TCP_CONG_BBR3=y" >> ./arch/arm64/configs/gki_defconfig
echo "CONFIG_DEFAULT_BBR3=y" >> ./arch/arm64/configs/gki_defconfig

# ===== 调度器优化（16ms PELT / NEXT_BUDDY / HRTICK / SIS_PROP） =====
cd "$GITHUB_WORKSPACE/kernel_workspace/common"

# PELT 半衰期 32ms -> 16ms
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
for feat in NEXT_BUDDY HRTICK SIS_PROP; do
  grep -q "SCHED_FEAT($feat, true)" kernel/sched/features.h || {
    error "调度优化 $feat 注入失败（上游已改名，需人工核对），中止构建"
    exit 1
  }
done

info "调度器优化完成 (16ms PELT / NEXT_BUDDY / HRTICK / SIS_PROP)"
