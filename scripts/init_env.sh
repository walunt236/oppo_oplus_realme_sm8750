#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

export GIT_TERMINAL_PROMPT=0

echo "=== 内核构建关键状态日志汇总 ===" > "$LOG_FILE"
info "清理可能残留的后台进程"
pkill -9 -f "kernel_workspace" || true
sleep 1
info "修复Git大小写敏感"
git config core.ignorecase false || true
info "仓库：$GITHUB_REPOSITORY"
info "分支：$GITHUB_REF_NAME"
cd "$GITHUB_WORKSPACE"
mkdir -p kernel_workspace
cd kernel_workspace

info "检查构建依赖..."
MISSING_PKGS=""
for pkg in build-essential bc bison flex libssl-dev libelf-dev libncurses-dev \
           python3 python-is-python3 dwarves git curl wget aria2 zip unzip \
           zstd xz-utils ca-certificates cpio rsync kmod; do
  dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS $pkg"
done
if [ -n "$MISSING_PKGS" ]; then
  info "安装缺失依赖:$MISSING_PKGS"
  sudo apt-get update -q
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends $MISSING_PKGS || {
    error "构建依赖安装失败"
    exit 1
  }
else
  info "构建依赖齐全"
fi

if ! command -v ccache >/dev/null 2>&1; then
  info "ccache 未安装，正在下载..."
  wget -q --timeout=30 "https://github.com/$GITHUB_REPOSITORY/raw/refs/heads/$GITHUB_REF_NAME/lib/ccache-x86-64" -O ccache || die "ccache 下载失败"
  sudo cp -f ./ccache /usr/bin/ccache
  sudo chmod +x /usr/bin/ccache
  rm -f ./ccache
  info "ccache 已安装到 /usr/bin/ccache"
else
  info "ccache 已存在: $(ccache --version | head -1)"
fi

OEM_BRANCH="oneplus/sm8750_b_16.0.0_oneplus_13"

mkdir -p "$HOME/.cache_patches"

if [ -d "common/.git" ]; then
  info "common 源码已存在，reset到OEM"
  cd common
  retry "OEM fetch" 3 5 glr fetch --depth=1 origin "$OEM_BRANCH" || die "OEM fetch 3 次均失败，中止构建"
  git reset --hard FETCH_HEAD
  git clean -fd -e /out/
  cd ..
else
  rm -rf common
  info "首次克隆 OEM 内核源码仓库..."
  retry "OEM 克隆" 3 5 glr clone --depth=1 \
    https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8750.git \
    -b "$OEM_BRANCH" \
    common || die "OEM 克隆 3 次均失败，中止构建"
fi

if [ -d "vendor_modules/.git" ]; then
  info "vendor_modules 已存在，仅更新（后台并行）..."
  ( cd vendor_modules && {
      retry "vendor_modules fetch" 3 5 glr fetch --depth=1 origin "$OEM_BRANCH" || exit 1
      git reset --hard FETCH_HEAD
      git clean -fd -e /out/
    }
  ) &
  VENDOR_PID=$!
else
  rm -rf vendor_modules
  info "首次克隆设备树与私有驱动仓库（后台并行）..."
  ( retry "vendor_modules 克隆" 3 5 glr clone --depth=1 \
      https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750.git \
      -b "$OEM_BRANCH" \
      vendor_modules || exit 1
  ) &
  VENDOR_PID=$!
fi

cd common
git config user.email "github-actions[bot]@users.noreply.github.com"
git config user.name "github-actions[bot]"

wait $VENDOR_PID || { error "vendor_modules 拉取失败，中止构建"; exit 1; }

# 骁龙(QCOM)上游合并：以 OnePlus BSP 基线 tag 为基点，三方合并到最新骁龙 tag
UPSTREAM_SUBLEVEL=""
if [[ "${QCOM_MERGE:-true}" != "true" ]]; then
  info "QCOM_MERGE=false，跳过骁龙上游合并"
else
  info "查询骁龙上游最新标签..."
  QCOM_RAW_TAGS=$(git -c http.proxy= ls-remote --tags "$QCOM_REPO" 'refs/tags/android15-6.6-*_r*' 2>/dev/null) || QCOM_RAW_TAGS=""
  QCOM_LATEST_TAG=$(printf '%s\n' "$QCOM_RAW_TAGS" | grep -v '\^{}' | awk '{print $2}' | sed 's|refs/tags/||' | sort -V | tail -1) || true
  QCOM_LATEST_TAG=${QCOM_LATEST_TAG:-$QCOM_BASE_TAG}
  QCOM_LATEST_TAG=${QCOM_LATEST_TAG:-$QCOM_BASE_TAG}
  info "骁龙上游: 基线 $QCOM_BASE_TAG -> 目标 $QCOM_LATEST_TAG"
  echo "QCOM_LATEST_TAG=$QCOM_LATEST_TAG" >> "$GITHUB_ENV"

  if [[ "$QCOM_LATEST_TAG" == "$QCOM_BASE_TAG" ]]; then
    info "骁龙上游无新版本，跳过合并"
  else
    git remote remove qcom 2>/dev/null || true
    git remote add qcom "$QCOM_REPO"
    for tag in "$QCOM_BASE_TAG" "$QCOM_LATEST_TAG"; do
      retry "骁龙 $tag 拉取" 3 5 git -c http.proxy= fetch --filter=blob:none --no-tags --depth=1 qcom \
        "refs/tags/$tag:refs/qcom/$tag" || die "骁龙上游标签 $tag 拉取失败"
    done

    info "生成骁龙补丁: $QCOM_BASE_TAG -> $QCOM_LATEST_TAG"
    git diff --binary "refs/qcom/$QCOM_BASE_TAG" "refs/qcom/$QCOM_LATEST_TAG" > /tmp/qcom_upstream.patch 2>/dev/null || true
    info "骁龙补丁规模: $(wc -l < /tmp/qcom_upstream.patch) 行"

    QCOM_CONFLICT_DIR="${OUT_DIR:-$HOME/share/out}/qcom_conflicts"
    mkdir -p "$QCOM_CONFLICT_DIR"
    : > "$QCOM_CONFLICT_DIR/conflicts.txt"

    if git apply -3 /tmp/qcom_upstream.patch > /tmp/qcom_apply.log 2>&1; then
      info "骁龙上游合并完成: $(grep -c '^Applied patch' /tmp/qcom_apply.log) 个文件干净应用"
    else
      grep -oP "Applied patch to '\K[^']+(?=' with conflicts)" /tmp/qcom_apply.log | sort -u > "$QCOM_CONFLICT_DIR/conflicts.txt" || true
      while IFS= read -r f; do
        git checkout HEAD -- "$f" 2>/dev/null || true
      done < "$QCOM_CONFLICT_DIR/conflicts.txt"
      cp -f /tmp/qcom_apply.log "$QCOM_CONFLICT_DIR/apply.log" 2>/dev/null || true
      warn "骁龙上游合并: $(grep -c '^Applied patch' /tmp/qcom_apply.log) 个文件应用，$(wc -l < "$QCOM_CONFLICT_DIR/conflicts.txt") 个冲突已回退本地版本"
    fi

    TARGET_SUBLEVEL=$(git show "refs/qcom/$QCOM_LATEST_TAG:Makefile" 2>/dev/null | sed -n 's/^SUBLEVEL\s*=\s*\([0-9]*\).*/\1/p') || true)
    if [[ -n "$TARGET_SUBLEVEL" ]]; then
      sed -i "s/^SUBLEVEL = .*/SUBLEVEL = $TARGET_SUBLEVEL/" Makefile
      info "内核版本已同步骁龙上游: 6.6.$TARGET_SUBLEVEL"
    fi
  fi
fi
echo "UPSTREAM_SUBLEVEL=$UPSTREAM_SUBLEVEL" >> "$GITHUB_ENV"

OEM_VERSION=$(sed -n 's/^VERSION\s*=\s*\(.*\)/\1/p' Makefile)
OEM_PATCHLEVEL=$(sed -n 's/^PATCHLEVEL\s*=\s*\(.*\)/\1/p' Makefile)
OEM_SUBLEVEL=$(sed -n 's/^SUBLEVEL\s*=\s*\([0-9]*\).*/\1/p' Makefile)
OEM_SUBLEVEL=${OEM_SUBLEVEL:-89}
OEM_EXTRAVERSION=$(sed -n 's/^EXTRAVERSION\s*=\s*\(.*\)/\1/p' Makefile)
OEM_EXTRAVERSION=${OEM_EXTRAVERSION// /}

echo "KERNEL_VERSION=${OEM_VERSION}.${OEM_PATCHLEVEL}" >> "$GITHUB_ENV"
echo "SUB_VERSION=${OEM_SUBLEVEL}${OEM_EXTRAVERSION}" >> "$GITHUB_ENV"
echo "CCACHE_KEY=ccache-ecsv3-${OEM_VERSION}.${OEM_PATCHLEVEL}" >> "$GITHUB_ENV"
OEM_ANDROID_MAJOR=$(echo "$OEM_BRANCH" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
echo "ANDROID_VERSION=android${OEM_ANDROID_MAJOR:-16}" >> "$GITHUB_ENV"

KERNEL_VERSION_FULL="${OEM_VERSION}.${OEM_PATCHLEVEL}.${OEM_SUBLEVEL}${OEM_EXTRAVERSION}"
echo "KERNEL_VERSION_FULL=$KERNEL_VERSION_FULL" >> "$GITHUB_ENV"

if [[ -n "$KERNEL_SUFFIX_INPUT" ]]; then
  KERNEL_SUFFIX="$KERNEL_SUFFIX_INPUT"
else
  KERNEL_SUFFIX="oneplus13-4k-aosp16"
  if [[ -n "$UPSTREAM_SUBLEVEL" ]] && [[ "$UPSTREAM_SUBLEVEL" != "0" ]]; then
    KERNEL_VERSION_FULL="${KERNEL_VERSION_FULL}_${UPSTREAM_SUBLEVEL}"
    echo "KERNEL_VERSION_FULL=$KERNEL_VERSION_FULL" >> "$GITHUB_ENV"
  fi
fi

echo "KERNEL_SUFFIX=$KERNEL_SUFFIX" >> "$GITHUB_ENV"
KERNEL_NAME_VAL="android16-${KERNEL_VERSION_FULL}-${KERNEL_SUFFIX}"
echo "KERNEL_NAME=$KERNEL_NAME_VAL" >> "$GITHUB_ENV"
echo "sub_version=$OEM_SUBLEVEL" >> "$GITHUB_OUTPUT"
echo "kernel_name=$KERNEL_NAME_VAL" >> "$GITHUB_OUTPUT"

cd ..

CLANG_DIR_NAME="Clang-19.0.0git-20240723"
CLANG_URL="https://github.com/ZyCromerZ/Clang/releases/download/19.0.0git-20240723-release/Clang-19.0.0git-20240723.tar.gz"

TC_DIR="$HOME/.toolchains/$CLANG_DIR_NAME"
BT_DIR="$HOME/.toolchains/build-tools-main"
mkdir -p "$HOME/.toolchains"

if [ ! -d "$TC_DIR/bin" ]; then
  info "检测到 Clang 19 未缓存或版本更新，开始下载..."
  rm -rf "$TC_DIR"
  mkdir -p "$TC_DIR"
  rm -f clang19.tar.gz*  # 清 aria2c 中断分片（曾累积 4.7G 残留）
  aria2c -s16 -x16 -k1M "$CLANG_URL" -o clang19.tar.gz || die "Clang 19 下载失败"
  tar -xzf clang19.tar.gz -C "$TC_DIR" && rm -f clang19.tar.gz
else
  info "[秒过] Clang 19 工具链已存在本地缓存，直接复用！"
fi

if [ ! -d "$BT_DIR/build-tools/bin" ]; then
  info "检测到 build-tools 未缓存或布局不符，从 Android 官方源下载..."
  rm -rf "$BT_DIR"
  mkdir -p "$BT_DIR/build-tools"
  rm -f build-tools*.tar.gz*  # 清 aria2c 中断分片（曾累积 18G 残留）
  aria2c -s16 -x16 -k1M \
    "https://android.googlesource.com/platform/prebuilts/build-tools/+archive/refs/heads/main/linux-x86.tar.gz" \
    -o build-tools.tar.gz || die "build-tools 下载失败"
  tar -xzf build-tools.tar.gz -C "$BT_DIR/build-tools" && rm -f build-tools.tar.gz
else
  info "[秒过] build-tools 工具链已存在本地缓存，直接复用！"
fi
echo "BT_DIR_NAME=build-tools-main" >> "$GITHUB_ENV"
rm -f "$BT_DIR/build-tools/bin/bison"


rm -f common/android/abi_gki_protected_exports_* || true
sed -i 's/protected_modules = \[.*\]/protected_modules = []/' common/modules.bzl || true
sed -i 's/ -dirty//g' common/scripts/setlocalversion
sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' common/scripts/setlocalversion
info "源码及工具链初始化完成"
