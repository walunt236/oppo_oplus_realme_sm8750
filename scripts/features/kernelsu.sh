#!/usr/bin/env bash
# KernelSU 模块：ReSukiSU / KernelSU-Next / 原版 KernelSU 同步与版本号注入
# 来源：scripts/apply_patches.sh 原第 29-37、39-130 行（helper 函数与原块；none 分支移至开关；原样搬迁）
# 开关：KSU_TYPE != none（none 时写 KSUVER=none 后退出）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

# 清理上一次运行的状态（self-hosted runner 的 /tmp 会保留）
: > /tmp/ksu_state.env

# ---- 原块开始（apply_patches.sh 原第 29-37、39-130 行，原样搬迁，勿改） ----
link_ksu_kernel() {
  ln -sf "$(realpath --relative-to=common/drivers "$PWD/$1/kernel")" common/drivers/kernelsu
  grep -q "kernelsu" common/drivers/Makefile || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> common/drivers/Makefile
  grep -q "drivers/kernelsu/Kconfig" common/drivers/Kconfig || sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" common/drivers/Kconfig
}

ksu_commit_count() {
  curl -sI --retry 3 --retry-delay 5 -H "Authorization: token ${GH_TOKEN:-}" "https://api.github.com/repos/$1/commits?sha=$2&per_page=1" | grep -i "link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p' || true
}

cd "$WS/kernel_workspace"

# KernelSU
rm -rf common/drivers/kernelsu

if [[ "${KSU_TYPE:-none}" == "none" ]]; then
  info "跳过 KernelSU 配置"
  echo "KSUVER=none" >> "$GITHUB_ENV"
  echo "ksuver=none" >> "$GITHUB_OUTPUT"
  exit 0
fi

if [[ "$KSU_TYPE" == "sukisu" || "$KSU_TYPE" == "resukisu" ]]; then
  info "配置 ReSukiSU..."
  sync_repo "https://github.com/ReSukiSU/ReSukiSU.git" KernelSU main
  link_ksu_kernel KernelSU
  KSU_OWNER="${GITHUB_REPOSITORY_OWNER:-walunt236}"
  echo "CONFIG_KSU_FULL_NAME_FORMAT=\"%TAG_NAME%-%COMMIT_SHA%@${KSU_OWNER}\"" >> ./common/arch/arm64/configs/gki_defconfig
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
  patch -p3 -N -F 3 < "$GITHUB_WORKSPACE/other_patch/ksu/apk_sign.patch" > /tmp/apk_sign.log 2>&1 || true
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
  # 默认跟 main 最新：有新特性优先。release 对齐模式保留但默认关闭，
  # 因为 SUSFS 补丁需同步对比，release tag 上补丁常失配。
  # 且内核编译期写死的签名哈希(c371061b...)对应 release 密钥；
  # 开发版(main)APK 由 CI 用临时密钥签名，内核永远认不出。
  # SUSFS 补丁另需对齐到发布同期提交（见下方 SUSFS 同步段）。
  KSU_CHANNEL="${KSU_CHANNEL:-main}"
  KSU_REL_TAG=""
  KSU_TAG_DATE=""
  if [ "$KSU_CHANNEL" = "release" ]; then
    REL_JSON=$(curl -sL --retry 3 --retry-delay 5 --retry-all-errors --max-time 20 \
      "https://api.github.com/repos/tiann/KernelSU/releases/latest" 2>/dev/null || true)
    KSU_REL_TAG=$(printf '%s' "$REL_JSON" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    KSU_TAG_DATE=$(printf '%s' "$REL_JSON" | sed -n 's/.*"published_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if [ -n "${KSU_REL_TAG:-}" ] && \
       git -c http.proxy= fetch -q --depth=1 origin "refs/tags/${KSU_REL_TAG}:refs/tags/${KSU_REL_TAG}" 2>/dev/null && \
       git checkout -q "refs/tags/${KSU_REL_TAG}" 2>/dev/null; then
      info "KernelSU 已对齐官方 release: ${KSU_REL_TAG} (${KSU_TAG_DATE%%T*})"
    else
      warn "KernelSU release tag 检出失败，回退 main"
      KSU_REL_TAG=""
      KSU_TAG_DATE=""
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
fi

# 子进程变量回传：主脚本 release 模式 SUSFS 同期对齐需要 KSU_TAG_DATE
printf 'KSU_TAG_DATE=%q\nKSU_CHANNEL=%q\n' "${KSU_TAG_DATE:-}" "${KSU_CHANNEL:-main}" > /tmp/ksu_state.env
