#!/usr/bin/env bash
# 调度器模块：NEXT_BUDDY / HRTICK / SIS_PROP / CACHE_HOT_BUDDY / LB_MIN
# 来源：scripts/apply_patches.sh 原第 403-419 行（原样搬迁）
# 开关：SCHED_ENABLE（原块无开关，默认 true 保持原行为）
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

if [[ "${SCHED_ENABLE:-true}" != "true" ]]; then
  info "[SCHED] 未启用，跳过"
  exit 0
fi

# ---- 原块开始（原第 403-419 行，原样搬迁，勿改） ----
# 调度器优化
cd "$GITHUB_WORKSPACE/kernel_workspace/common"

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

info "调度器优化完成 (PELT 32ms 上游默认 / NEXT_BUDDY / HRTICK / SIS_PROP / CACHE_HOT_BUDDY / LB_MIN)"

# ---- 原块结束 ----
