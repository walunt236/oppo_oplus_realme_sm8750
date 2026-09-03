#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

# KPM 修补
if [[ "$KPM_ENABLE" == 'builtin' ]] && ( [[ "$KSU_TYPE" == "sukisu" ]] || [[ "$KSU_TYPE" == "resukisu" ]] ); then
  info "应用 KPM 并修补内核..."
  cd kernel_workspace/common/out/arch/arm64/boot
  curl -fSL --retry 3 --retry-delay 5 --retry-all-errors -o patch_linux "https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest/download/patch_linux" || {
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
  curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 -o kptools-linux "https://github.com/KernelSU-Next/KPatch-Next/releases/latest/download/kptools-linux" && KPN_OK=1 || {
    warn "KPN kptools 下载失败，跳过 KPN 修补，继续打包原始内核"
  }
  if [[ "$KPN_OK" -eq 1 ]]; then
    curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 -o kpimg-linux "https://github.com/KernelSU-Next/KPatch-Next/releases/latest/download/kpimg-linux" && KPN_OK=1 || {
      warn "KPN kpimg 下载失败，跳过 KPN 修补，继续打包原始内核"
      KPN_OK=0
    }
  fi
  if [[ "$KPN_OK" -eq 1 ]]; then
    chmod +x ./kptools-linux
    ./kptools-linux -p -i ./Image -k ./kpimg-linux -o ./oImage
    rm -f Image
    mv oImage Image
  fi
fi

# AnyKernel3 打包
cd kernel_workspace
if [ -d AnyKernel3/.git ]; then
  info "AnyKernel3 仓库已存在，增量同步..."
  git -C AnyKernel3 remote set-url origin https://github.com/walunt236/AnyKernel3 2>/dev/null || true
  if glr -C AnyKernel3 fetch --depth=1 origin && git -C AnyKernel3 reset --hard FETCH_HEAD; then
    :
  else
    warn "AnyKernel3 增量拉取失败，使用本地已有版本"
  fi
else
  rm -rf AnyKernel3
  retry "AnyKernel3 克隆" 8 5 glr clone https://github.com/walunt236/AnyKernel3 --depth=1 AnyKernel3 || die "AnyKernel3 克隆失败，终止打包"
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

case "$KSU_TYPE" in
  sukisu)   KSU_TYPENAME="SukiSU" ;;
  resukisu) KSU_TYPENAME="ReSukiSU" ;;
  ksunext)  KSU_TYPENAME="KSUNext" ;;
  ksu)      KSU_TYPENAME="KSU" ;;
  *)        KSU_TYPENAME="none" ;;
esac

if [[ "$KPM_ENABLE" == 'kpn' ]] && [[ "${KPN_OK:-0}" -eq 1 ]]; then
  curl -fSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 30 -o kpn.zip "https://github.com/cctv18/KPatch-Next/releases/latest/download/kpn.zip" || warn "kpn.zip 下载失败，跳过 KPN 模块"
fi

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
echo "ak3name=$AK3_NAME" >> "$GITHUB_OUTPUT"

if [[ "$RUNNER_TYPE" == "self-hosted" ]]; then
  TARGET_DIR="/mnt/d/AK3_DOC"
  mkdir -p "$TARGET_DIR"
  if [ -f "$TARGET_DIR/$AK3_NAME" ]; then
    mv -f "$TARGET_DIR/$AK3_NAME" "$TARGET_DIR/$AK3_NAME.prev"
    info "旧包已备份: $AK3_NAME.prev"
  fi
  cp "../$AK3_NAME" "$TARGET_DIR/"
  info "已成功保存至本地路径: $TARGET_DIR/$AK3_NAME"
fi

# 本地工作区清理
info "清理编译产出和临时文件..."
rm -rf kernel_workspace/vendor_modules/out
rm -f /tmp/*.patch
ccache -c
info "ccache 已裁剪至上限"
for repo in "$HOME/.cache_patches/"*; do
  [ -d "$repo/.git" ] && git -C "$repo" gc --auto 2>/dev/null || true
done
if [[ -n "${PATCH_HASH:-}" ]] && [[ -n "${CFG_HASH:-}" ]]; then
  mkdir -p "$HOME/.cache_patches"
  printf '%s|%s' "$PATCH_HASH" "$CFG_HASH" > "$HOME/.cache_patches/build_state"
  info "增量指纹+配置哈希已记录，下次相同状态将增量编译"
fi

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
