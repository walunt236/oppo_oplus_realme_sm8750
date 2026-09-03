#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

export GIT_TERMINAL_PROMPT=0
detect_proxy

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

if [[ "$RUNNER_TYPE" == "ubuntu-latest" ]]; then
  info "检测到 GitHub 云端环境，执行系统依赖安装及预置优化..."
  sudo apt-mark hold firefox || true
  sudo apt-mark hold libc-bin || true
  sudo apt purge -y man-db || true
  sudo rm -rf /var/lib/man-db/auto-update
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    binutils python-is-python3 libssl-dev libelf-dev aria2
else
  info "检测到 本地 self-hosted (WSL2) 环境，跳过危险修改..."
  for pkg in binutils python3 libssl-dev libelf-dev aria2 wget zip zstd libxml2-dev unzip; do
    if ! dpkg -l "$pkg" >/dev/null 2>&1 && ! command -v "$pkg" >/dev/null 2>&1; then
      warn "缺少依赖: $pkg，尝试安装..."
      sudo apt-get install -y --no-install-recommends "$pkg" || {
        error "依赖 $pkg 安装失败，请手动安装"
        exit 1
      }
    fi
  done
fi

if ! command -v ccache >/dev/null 2>&1; then
  info "ccache 未安装，正在下载..."
  wget -q "https://github.com/$GITHUB_REPOSITORY/raw/refs/heads/$GITHUB_REF_NAME/lib/ccache-x86-64" -O ccache
  sudo cp -f ./ccache /usr/bin/ccache
  sudo chmod +x /usr/bin/ccache
  rm -f ./ccache
  info "ccache 已安装到 /usr/bin/ccache"
else
  info "ccache 已存在: $(ccache --version | head -1)"
fi

OEM_BRANCH="oneplus/sm8750_b_16.0.0_oneplus_13"

mkdir -p "$HOME/.cache_patches"
info "后台预查询 AOSP 最新标签..."
( gproxy ls-remote --tags --sort=-v:refname https://android.googlesource.com/kernel/common 'refs/tags/android15-6.6.*_r00' | head -1 | awk '{print $2}' | sed 's|refs/tags/||' > "$HOME/.cache_patches/latest_aosp_tag" ) &
AOSP_TAG_PID=$!

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

# AOSP 上游合并
info "拉取 Google AOSP android15-6.6 ..."
wait $AOSP_TAG_PID 2>/dev/null || true
LATEST_AOSP_TAG=$(cat "$HOME/.cache_patches/latest_aosp_tag" 2>/dev/null)
LATEST_AOSP_TAG=${LATEST_AOSP_TAG:-android15-6.6}
info "AOSP 最新发布标签: $LATEST_AOSP_TAG"
FETCH_OK=0
for i in 1 2 3; do
  if gproxy fetch --depth=1 --no-tags https://android.googlesource.com/kernel/common "$LATEST_AOSP_TAG"; then
    FETCH_OK=1
    break
  fi
  warn "AOSP fetch 失败(第${i}次)，5 秒后重试..."
  sleep 5
done
if [[ "$FETCH_OK" -eq 1 ]]; then
  UPSTREAM_SUBLEVEL=$(git show FETCH_HEAD:Makefile | sed -n 's/^SUBLEVEL\s*=\s*\([0-9]*\).*/\1/p')
  UPSTREAM_SUBLEVEL=${UPSTREAM_SUBLEVEL:-0}
  echo "UPSTREAM_SUBLEVEL=$UPSTREAM_SUBLEVEL" >> "$GITHUB_ENV"
  if git merge FETCH_HEAD --no-edit -X ours --allow-unrelated-histories; then
    info "AOSP上游合并成功"
  else
    warn "存在冲突，自动保留 OEM 版本..."
    git diff --name-only --diff-filter=U | xargs -r git checkout --ours --
    git add -A
    git commit -m "Merge AOSP $LATEST_AOSP_TAG, keep OEM" || {
      error "AOSP 合并提交失败，中止构建"
      exit 1
    }
  fi
else
  error "AOSP fetch 失败（直连+代理 3 次均不可达），上游合并为必需项，中止构建"
  exit 1
fi

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
  aria2c -s16 -x16 -k1M "$CLANG_URL" -o clang19.tar.gz
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
    -o build-tools.tar.gz
  tar -xzf build-tools.tar.gz -C "$BT_DIR/build-tools" && rm -f build-tools.tar.gz
else
  info "[秒过] build-tools 工具链已存在本地缓存，直接复用！"
fi
echo "BT_DIR_NAME=build-tools-main" >> "$GITHUB_ENV"
rm -f "$BT_DIR/build-tools/bin/bison"


if [[ "$RUNNER_TYPE" == "ubuntu-latest" ]]; then
  if ! dpkg -l binutils python3 libssl-dev libelf-dev >/dev/null 2>&1; then
    warn "云端依赖安装异常，正在重试..."
    sudo apt-get install -y --no-install-recommends \
      binutils python-is-python3 libssl-dev libelf-dev || {
      error "云端依赖安装失败"
      exit 1
    }
  fi
fi
rm -f common/android/abi_gki_protected_exports_* || true
sed -i 's/protected_modules = \[.*\]/protected_modules = []/' common/modules.bzl || true
sed -i 's/ -dirty//g' common/scripts/setlocalversion
sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' common/scripts/setlocalversion
info "源码及工具链初始化完成"
