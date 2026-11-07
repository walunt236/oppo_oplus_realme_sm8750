#!/usr/bin/env bash
# SUSFS 集成模块：补丁应用 + 隐藏 VMA + KernelSU 集成
# 来源：scripts/apply_patches.sh 原第 173-249 行（原样搬迁）
# 开关：SUSFS_ENABLE=true（沿用原变量；未设置/false 时跳过）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [[ "${SUSFS_ENABLE:-false}" != "true" ]]; then
  info "[SUSFS] 未启用，跳过"
  exit 0
fi

# 预取阶段由主脚本完成；独立运行时使用与主脚本一致的默认值
SUSFS_CACHE_DIR="${SUSFS_CACHE_DIR:-$HOME/.cache_patches/susfs4ksu}"
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-${QCOM_SERIES:-android15-6.6}}"

# ---- 原块开始（apply_patches.sh 第 173-249 行，原样搬迁，勿改） ----
# SUSFS
if [[ "$SUSFS_ENABLE" == "true" ]]; then
  if [[ "$KSU_TYPE" != "none" ]]; then
    cd "$GITHUB_WORKSPACE/kernel_workspace"
    info "添加 susfs 补丁..."

    rm -rf susfs4ksu
    cp -r "$SUSFS_CACHE_DIR" susfs4ksu

    cp "$GITHUB_WORKSPACE/other_patch/ksu/69_hide_stuff.patch" ./common/69_hide_stuff.patch

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
    REJ_N=$(find . -name "*.rej" 2>/dev/null | wc -l)
    if grep -rqs 'susfs' kernel/Kconfig 2>/dev/null; then
      if [ "$REJ_N" -eq 0 ]; then
        info "SUSFS ↔ KernelSU 集成已生效"
      else
        # 上游补丁常滞后于 KernelSU main；实测带少量 reject 仍可正常编译。
        warn "SUSFS ↔ KernelSU 集成已生效，但有 ${REJ_N} 个 hunk 未应用（上游补丁滞后于 main）"
      fi
    else
      warn "susfs-ksu 集成补丁未生效（明细 /tmp/susfs_ksu.log）"
    fi

    # 上游补丁按旧版 reset_avc_cache(u32) 写的上下文，在 main 上该 hunk 必然 reject，
    # 结果 apply_kernelsu_rules() 里缺少 susfs_set_batch_sid() 调用。
    # 后果：susfs_zygote_sid 恒为 0 -> is_zygote() 恒假 -> 管理器的 ksu fd 装不上
    # -> 管理器显示"未安装"（但 su 走 execveat 钩子，正常可用）。
    RULES_FILE=./kernel/selinux/rules.c
    if [ -f "$RULES_FILE" ] && \
       grep -rqs "void susfs_set_batch_sid" ./kernel/selinux/selinux.c 2>/dev/null && \
       ! grep -q "susfs_set_batch_sid" "$RULES_FILE"; then
      if ! grep -qs "susfs_set_batch_sid" ./kernel/selinux/selinux.h 2>/dev/null; then
        sed -i "1i extern void susfs_set_batch_sid(void);" "$RULES_FILE"
      fi
      sed -i "0,/reset_avc_cache(pol->latest_granting);/s//&\n    susfs_set_batch_sid();/" "$RULES_FILE"
      if grep -q "susfs_set_batch_sid" "$RULES_FILE"; then
        info "已补上 susfs_set_batch_sid()：SID 初始化恢复（修复管理器未识别）"
      else
        warn "susfs_set_batch_sid() 补写失败，管理器可能仍显示未安装"
      fi
    else
      info "susfs_set_batch_sid() 已存在，无需补写"
    fi
  fi
fi

# ---- 原块结束 ----
