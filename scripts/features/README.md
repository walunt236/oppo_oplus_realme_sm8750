# 功能模块清单

每个功能一个脚本：scripts/features/<name>.sh
资产目录：other_patch/<name>/
开关：<NAME>_ENABLE=true|false（工作流输入传入）

## 当前状态（迁移中）

| 功能 | 资产目录 | 脚本状态 |
|---|---|---|
| zram 多级压缩 | other_patch/zram/ | 待抽取（内联中） |
| f2fs GC 调优 | other_patch/f2fs/ | 待抽取 |
| SUSFS | 动态拉取 + other_patch/ksu/ | 待抽取 |
| LZ4KD | 动态拉取 | 待抽取 |
| Droidspaces | other_patch/droidspaces/ | 待抽取 |
| DAMON | other_patch/damon/ | 待抽取 |
| LZ4 NEON | other_patch/lz4/ | 待抽取 |
| KSU 隐藏 | other_patch/ksu/ | 待抽取 |
| KVM nvhe | other_patch/nvhe/ | 待抽取 |
| ADIOS | other_patch/adios/ | 待抽取 |

## 约定

1. 开关为 false 时直接 exit 0
2. 幂等：已应用则跳过
3. 日志前缀 [FEATURE]
4. 致命失败 die，实验性失败 warn
5. 配置片段放 configs/features/<name>.config
