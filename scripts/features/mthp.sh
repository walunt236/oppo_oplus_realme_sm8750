#!/usr/bin/env bash
# mTHP compaction_capture backport (OpenCloudOS PR 1218, patch 2/4)
# 默认应用；当前 6.6.143 缺少该优化。
set -euo pipefail

WS=$GITHUB_WORKSPACE
if [ -z "$WS" ]; then
	WD=$(dirname "$0")
	WS=$(cd "$WD/../.." && pwd)
fi
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

cd "$WS/kernel_workspace/common"
PATCH="$WS/other_patch/mm/mthp_compaction_capture.patch"

if grep -q 'capc->cc->migratetype != MIGRATE_MOVABLE' mm/page_alloc.c; then
	info "[mTHP] compaction_capture 修复已存在"
	exit 0
fi

if patch -p1 --forward -F3 < "$PATCH" >/tmp/mthp_compaction_capture.log 2>&1; then
	info "[mTHP] compaction_capture 修复已应用"
else
	warn "[mTHP] compaction_capture 补丁应用失败"
	tail -5 /tmp/mthp_compaction_capture.log || true
fi

if grep -q 'capc->cc->migratetype != MIGRATE_MOVABLE' mm/page_alloc.c; then
	info "[mTHP] compaction_capture 校验通过"
else
	warn "[mTHP] compaction_capture 未生效"
fi
