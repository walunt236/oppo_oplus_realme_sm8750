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

OEM_URL="${OEM_REPO}"
OEM_BRANCH=$(git -c http.proxy= ls-remote --symref "$OEM_URL" HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\([^\t]*\).*|\1|p' | sed -n '1p') || true
[ -n "$OEM_BRANCH" ] || die "无法从 $OEM_URL 获取默认分支，中止构建"
info "一加内核默认分支: $OEM_BRANCH"

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
     $OEM_URL \
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
      "$OEM_VENDOR_REPO" \
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
# 基线 tag 不写死：从一加提交信息里的 Based on QCOM release TAG 自动解析
if [[ -z "${QCOM_BASE_TAG:-}" ]]; then
  QCOM_BASE_TAG=$(
    git log -1 --format=%B 2>/dev/null | grep -oE 'android[0-9]+-[0-9][0-9.]*-[0-9]{4}-[0-9]{2}_r[0-9]+' | sed -n '1p'
  ) || QCOM_BASE_TAG=""
  [[ -n "$QCOM_BASE_TAG" ]] && info "从一加提交信息解析出基线 tag: $QCOM_BASE_TAG"
fi
if [[ -z "${QCOM_BASE_TAG:-}" ]]; then
  warn "无法确定骁龙基线 tag，跳过骁龙上游合并"
  QCOM_MERGE=false
fi
UPSTREAM_SUBLEVEL=""
if [[ "${QCOM_MERGE:-true}" != "true" ]]; then
  info "QCOM_MERGE=false，跳过骁龙上游合并"
else
  info "查询骁龙上游最新标签..."
  QCOM_SERIES=$(printf '%s' "$QCOM_BASE_TAG" | sed -n 's/^\(android[0-9]\+-[0-9.]\+\)-[0-9]\{4\}-[0-9]\{2\}_r[0-9]\+$/\1/p')
  QCOM_SERIES=${QCOM_SERIES:-android15-6.6}
  info "骁龙分支系列: $QCOM_SERIES"
  QCOM_RAW_TAGS=$(git -c http.proxy= ls-remote --tags "$QCOM_REPO" "refs/tags/${QCOM_SERIES}-*_r*" 2>/dev/null) || QCOM_RAW_TAGS=""
  QCOM_LATEST_TAG=$(printf '%s\n' "$QCOM_RAW_TAGS" | sed 's|refs/tags/||' | grep -oE "${QCOM_SERIES//./\\.}-202[4-9]-[0-9]{2}_r[0-9]+$" | sort -V | tail -1) || true
  QCOM_LATEST_TAG=${QCOM_LATEST_TAG:-$QCOM_BASE_TAG}
  info "骁龙上游: 基线 $QCOM_BASE_TAG -> 目标 $QCOM_LATEST_TAG"
  echo "QCOM_LATEST_TAG=$QCOM_LATEST_TAG" >> "$GITHUB_ENV"
echo "QCOM_SERIES=$QCOM_SERIES" >> "$GITHUB_ENV"

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
      # 冲突文件采用骁龙版本：它们引用的新符号（如 is_user_task / pgmigration_err）
      # 只存在于新代码里，保留本地旧版会导致新代码找不到声明
      while IFS= read -r f; do
        git checkout "refs/qcom/$QCOM_LATEST_TAG" -- "$f" 2>/dev/null || true
      done < "$QCOM_CONFLICT_DIR/conflicts.txt"
      cp -f /tmp/qcom_apply.log "$QCOM_CONFLICT_DIR/apply.log" 2>/dev/null || true
      warn "骁龙上游合并: $(grep -c '^Applied patch' /tmp/qcom_apply.log) 个文件应用，$(wc -l < "$QCOM_CONFLICT_DIR/conflicts.txt") 个冲突已采用骁龙版本"
    fi


    # git apply 无法处理（does not match index / patch does not apply）的文件：
    # 逐文件做真正的三方合并（base=基线 tag, ours=本地, theirs=目标 tag），
    # 避免出现「头文件留在旧版本、实现跑到新版本」的半代际状态。
    grep -oE "^(error: )?[^:]+(: does not match index|: patch does not apply)" /tmp/qcom_apply.log 2>/dev/null \
      | sed -E 's/^error: //; s/: (does not match index|patch does not apply)$//' | sort -u > /tmp/qcom_3way.list || true
    QCOM_3WAY_OK=0; QCOM_3WAY_NG=0
    while IFS= read -r f; do
      [ -n "$f" ] && [ -f "$f" ] || continue
      git show "refs/qcom/$QCOM_BASE_TAG:$f" > /tmp/q_base 2>/dev/null || continue
      git show "refs/qcom/$QCOM_LATEST_TAG:$f" > /tmp/q_theirs 2>/dev/null || continue
      cp "$f" /tmp/q_ours 2>/dev/null || continue
      if git merge-file -p /tmp/q_ours /tmp/q_base /tmp/q_theirs > /tmp/q_merged 2>/dev/null; then
        cp /tmp/q_merged "$f"
        QCOM_3WAY_OK=$((QCOM_3WAY_OK + 1))
      else
        cp /tmp/q_theirs "$f"
        echo "$f" >> "$QCOM_CONFLICT_DIR/3way_conflicts.txt"
        QCOM_3WAY_NG=$((QCOM_3WAY_NG + 1))
      fi
    done < /tmp/qcom_3way.list
    info "逐文件三方合并: ${QCOM_3WAY_OK} 个成功，${QCOM_3WAY_NG} 个冲突（已采用骁龙版本）"

    # 调度子系统整体对齐上游：三方合并可能产生「新头文件 + 旧实现」的混合体
    # （例如 init_task.c 保留旧 .scx 字段，而 143 的 sched.h 已移除），统一取上游可消除错配
    git checkout "refs/qcom/$QCOM_LATEST_TAG" -- \
      include/linux/sched.h include/linux/sched/ init/init_task.c kernel/sched/ kernel/fork.c \
      2>/dev/null || true
    info "调度子系统已统一为骁龙上游版本"
    TARGET_SUBLEVEL=$(git show "refs/qcom/$QCOM_LATEST_TAG:Makefile" 2>/dev/null | sed -n 's/^SUBLEVEL\s*=\s*\([0-9]*\).*/\1/p' || true)
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
  KERNEL_SUFFIX="${KERNEL_SUFFIX_DEFAULT}"
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

# 工具链身份（目录名/版本/下载地址）统一在 build.env 定义
TC_DIR="$HOME/.toolchains/$CLANG_DIR_NAME"
BT_DIR="$HOME/.toolchains/$BUILD_TOOLS_DIR_NAME"
mkdir -p "$HOME/.toolchains"
CLANG_TGZ="clang-${CLANG_RELEASE}.tar.gz"

if [ ! -d "$TC_DIR/bin" ]; then
  info "检测到工具链未缓存或版本变化（$CLANG_DIR_NAME），开始下载..."
  rm -rf "$TC_DIR"
  mkdir -p "$TC_DIR"
  rm -f clang*.tar.gz*  # 清 aria2c 中断分片（曾累积 4.7G 残留）
  aria2c -s16 -x16 -k1M "$CLANG_URL" -o "$CLANG_TGZ" || die "工具链下载失败（$CLANG_DIR_NAME）"
  tar -xzf "$CLANG_TGZ" -C "$TC_DIR" && rm -f "$CLANG_TGZ"
else
  info "[秒过] 工具链已存在本地缓存（$CLANG_DIR_NAME），直接复用！"
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
echo "BT_DIR_NAME=$BUILD_TOOLS_DIR_NAME" >> "$GITHUB_ENV"
rm -f "$BT_DIR/build-tools/bin/bison"


rm -f common/android/abi_gki_protected_exports_* || true
sed -i 's/protected_modules = \[.*\]/protected_modules = []/' common/modules.bzl || true
sed -i 's/ -dirty//g' common/scripts/setlocalversion
sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' common/scripts/setlocalversion
info "源码及工具链初始化完成"
