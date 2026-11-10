#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
cd "$GITHUB_WORKSPACE"

# KPM 修补
if [[ "$KPM_ENABLE" == 'builtin' ]] && ( [[ "$KSU_TYPE" == "sukisu" ]] || [[ "$KSU_TYPE" == "resukisu" ]] ); then
  info "应用 KPM 并修补内核..."
  cd kernel_workspace/common/out/arch/arm64/boot
  curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 60 -o patch_linux "https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest/download/patch_linux" || {
    error "KPM patch_linux 下载失败"
    exit 1
  }
  chmod +x patch_linux
  ./patch_linux
  rm -f Image
  mv oImage Image
fi
if [[ "$KPM_ENABLE" == 'kpn' ]]; then
  info "应用 KP-N 并修补内核..."
  cd kernel_workspace/common/out/arch/arm64/boot
  KPN_OK=0
  # 首选：cctv18 的定期构建（release 比上游新，2026-06 vs 2026-01）
  if curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 60 \
       -o kpn.zip "https://github.com/cctv18/KPatch-Next/releases/latest/download/kpn.zip" 2>/dev/null; then
    rm -rf kpn-ext && mkdir -p kpn-ext
    unzip -q -o kpn.zip -d kpn-ext 2>/dev/null || true
    KPN_T=$(find kpn-ext -type f -name "kptools*" -print -quit)
    KPN_I=$(find kpn-ext -type f -name "kpimg*" -print -quit)
    if [ -n "$KPN_T" ] && [ -n "$KPN_I" ]; then
      cp -f "$KPN_T" kptools-linux && cp -f "$KPN_I" kpimg-linux && KPN_OK=1
      info "KP-N 工具取自 cctv18 定期构建"
    fi
  fi
  # 回退：上游 KernelSU-Next 的独立产物
  if [ "$KPN_OK" -eq 0 ]; then
    warn "cctv18 构建不可用，回退上游 release"
    curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 \
      -o kptools-linux "https://github.com/KernelSU-Next/KPatch-Next/releases/latest/download/kptools-linux" 2>/dev/null || true
    curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 \
      -o kpimg-linux "https://github.com/KernelSU-Next/KPatch-Next/releases/latest/download/kpimg-linux" 2>/dev/null || true
    if [ -s kptools-linux ] && [ -s kpimg-linux ]; then KPN_OK=1; fi
  fi
  if [ "$KPN_OK" -eq 1 ]; then
    chmod +x ./kptools-linux
    if ./kptools-linux -p -i ./Image -k ./kpimg-linux -o ./oImage; then
      rm -f Image && mv oImage Image
    else
      warn "KP-N 修补失败，继续打包原始内核"
    fi
  else
    warn "KPN 工具不可用，跳过 KP-N 修补"
  fi
fi

# AnyKernel3 打包
cd kernel_workspace
if [ -d AnyKernel3/.git ]; then
  info "AnyKernel3 仓库已存在，增量同步..."
  git -C AnyKernel3 remote set-url origin "$AK3_REPO" 2>/dev/null || true
  if glr -C AnyKernel3 fetch --depth=1 origin && git -C AnyKernel3 reset --hard FETCH_HEAD; then
    :
  else
    warn "AnyKernel3 增量拉取失败，使用本地已有版本"
  fi
else
  rm -rf AnyKernel3
  retry "AnyKernel3 克隆" 8 5 glr clone "$AK3_REPO" --depth=1 AnyKernel3 || die "AnyKernel3 克隆失败，终止打包"
fi
cd AnyKernel3
git clean -ffdqx
if [ -d "$GITHUB_WORKSPACE/ak3_overlay" ]; then
  cp -r "$GITHUB_WORKSPACE/ak3_overlay/"* . || { error "ak3_overlay 拷贝失败"; exit 1; }
else
  error "ak3_overlay 目录缺失，中止打包"
  exit 1
fi
TOOL_CACHE="$HOME/.cache_patches/ak3tools"
mkdir -p "$TOOL_CACHE"
MAGISK_TAG=$(curl -fsSL --retry 2 --connect-timeout 10 --max-time 20 -H "Authorization: token ${GH_TOKEN:-}" "https://api.github.com/repos/topjohnwu/Magisk/releases/latest" 2>/dev/null | grep -oE '"tag_name": *"[^"]+"' | head -1 | cut -d'"' -f4 || true)
MAGISK_TAG=${MAGISK_TAG:-v30.7}
if [ ! -s "$TOOL_CACHE/magisk-$MAGISK_TAG.apk" ]; then
  curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 15 --max-time 180 -o "$TOOL_CACHE/magisk-$MAGISK_TAG.apk" "https://github.com/topjohnwu/Magisk/releases/download/$MAGISK_TAG/Magisk-$MAGISK_TAG.apk" 2>/dev/null || warn "Magisk 下载失败，回退内置工具"
fi
if [ -s "$TOOL_CACHE/magisk-$MAGISK_TAG.apk" ]; then
  if (cd "$TOOL_CACHE" && unzip -o -q "magisk-$MAGISK_TAG.apk" "lib/arm64-v8a/libmagiskboot.so" "lib/arm64-v8a/libbusybox.so" -d magisk-ext && \
      install -m 755 magisk-ext/lib/arm64-v8a/libmagiskboot.so "$GITHUB_WORKSPACE/kernel_workspace/AnyKernel3/tools/magiskboot" && \
      install -m 755 magisk-ext/lib/arm64-v8a/libbusybox.so "$GITHUB_WORKSPACE/kernel_workspace/AnyKernel3/tools/busybox"); then
    info "AK3 工具已更新（Magisk $MAGISK_TAG arm64）"
  else
    warn "Magisk 工具提取失败，回退内置版本"
  fi
  rm -rf "$TOOL_CACHE/magisk-ext"
fi
cp ../common/out/arch/arm64/boot/Image ./Image
if [[ ! -f ./Image ]]; then
  error "未找到内核镜像文件"
  exit 1
fi
IMG_SIZE=$(stat -c%s ./Image 2>/dev/null || echo 0)
if [ "$IMG_SIZE" -lt 20000000 ]; then
  error "内核镜像异常（$IMG_SIZE 字节，小于 20MB），疑似构建产物损坏"
  exit 1
fi
info "内核镜像大小: $(awk -v s="$IMG_SIZE" 'BEGIN{printf "%.1f MB", s/1048576}')"

case "$KSU_TYPE" in
  sukisu)   KSU_TYPENAME="SukiSU" ;;
  resukisu) KSU_TYPENAME="ReSukiSU" ;;
  ksunext)  KSU_TYPENAME="KSUNext" ;;
  ksu)      KSU_TYPENAME="KSU" ;;
  *)        KSU_TYPENAME="none" ;;
esac


BUILD_DATE="$(TZ=Asia/Shanghai date +%Y%m%d)"
AK3_NAME="AnyKernel3-${KSU_TYPENAME}-${KSUVER}-${KERNEL_VERSION_FULL}-${KERNEL_SUFFIX}-${BUILD_DATE}.zip"
FULL_VERSION="${KERNEL_VERSION_FULL}-${KERNEL_SUFFIX}"
TIME_NOW="$(TZ='Asia/Shanghai' date +'%Y-%m-%d %H:%M:%S')"
cat > ./ak3.log << EOF
Author: $GITHUB_ACTOR
Repo: $GITHUB_REPOSITORY
Branch: $GITHUB_REF_NAME
Run ID: $GITHUB_RUN_ID
Commit: $GITHUB_SHA
Time: $TIME_NOW
Kernel Ver: $FULL_VERSION
KSU Branch: ${KSU_TYPENAME}
KSU Ver: ${KSUVER}
susfs: $SUSFS_ENABLE
KPM: $KPM_ENABLE
LZ4: on
LZ4KD: $LZ4KD_ENABLE
IPset: on
BBRv3: on
Droidspaces: $DROIDSPACES_ENABLE
ADIOS: on
Re-Kernel: $REKERNEL_ENABLE
BBG: $BASEBAND_GUARD
RCU_NOCB: $RCU_NOCB_ENABLE
EOF

rm -f ../AnyKernel3-*.zip
zip -r "../$AK3_NAME" ./*
PKG_SIZE=$(stat -c%s "../$AK3_NAME" 2>/dev/null || echo 0)
info "安装包大小: $(awk -v s="$PKG_SIZE" 'BEGIN{printf "%.1f MB", s/1048576}')"
echo "ak3name=$AK3_NAME" >> "$GITHUB_OUTPUT"

# 产物输出目录：build.env 的 OUT_DIR（默认 $HOME/share/out）
TARGET_DIR="${OUT_DIR:-$HOME/share/out}"
if mkdir -p "$TARGET_DIR" 2>/dev/null; then
  if [ -f "$TARGET_DIR/$AK3_NAME" ]; then
    mv -f "$TARGET_DIR/$AK3_NAME" "$TARGET_DIR/$AK3_NAME.prev"
    info "旧包已备份: $AK3_NAME.prev"
  fi
  cp "../$AK3_NAME" "$TARGET_DIR/" && info "已保存至: $TARGET_DIR/$AK3_NAME"
  # 历史包：按 run 号留档，保留最近 5 个，便于回滚到任意一次可用构建
  HIST_DIR="$TARGET_DIR/history"
  if mkdir -p "$HIST_DIR" 2>/dev/null; then
    HIST_NAME="${AK3_NAME%.zip}-run${GITHUB_RUN_NUMBER:-0}.zip"
    cp -f "../$AK3_NAME" "$HIST_DIR/$HIST_NAME" && info "历史包: history/$HIST_NAME"
    ls -1t "$HIST_DIR"/*.zip 2>/dev/null | tail -n +6 | xargs -r rm -f
  fi
else
  warn "无法写入 $TARGET_DIR，ZIP 保留在工作区"
fi

# 本地工作区清理
info "清理编译产出和临时文件..."
rm -rf "$GITHUB_WORKSPACE/kernel_workspace/vendor_modules/out"
rm -f /tmp/*.patch
ccache -c
info "ccache 已裁剪至上限"
for repo in "$HOME/.cache_patches/"*; do
  [ -d "$repo/.git" ] && git -C "$repo" gc --auto 2>/dev/null || true
done

if [ -s "$PENDING_SYNC" ]; then
  info "构建后补拉同步失败的上游仓库..."
  : > "$PENDING_SYNC.tmp"
  while IFS='|' read -r u d b; do
    [ -z "$d" ] && continue
    if sync_repo "$u" "$d" "$b"; then
      info "补拉成功: $d（下次构建生效）"
    else
      echo "$u|$d|$b" >> "$PENDING_SYNC.tmp"
      error "补拉仍失败: $d（已记录，下次构建继续重试）"
    fi
  done < "$PENDING_SYNC"
  mv "$PENDING_SYNC.tmp" "$PENDING_SYNC"
fi
info "磁盘清理完成"
