# 架构说明

## 1. 定位

本仓库**不含内核源码**，只负责构建编排：内核在每次构建时从 `OnePlusOSS` 拉取，再与骁龙上游做三方合并。
GitHub Actions 只做任务下发、日志汇总与产物归档；实际编译发生在自托管 runner（`kbuild`，Hyper-V 上的 Ubuntu 虚拟机）。

```
GitHub（调度/日志/artifact）
   └── self-hosted runner: kbuild  ←── 真正的编译与打包都在这里
         ├── ~/.toolchains         Clang 19（ZyCromerZ）+ Android build-tools
         ├── ~/.cache_patches      补丁仓、build_state、afdo、ak3tools
         ├── ~/share/out           产物与历史包
         └── kernel_workspace/     内核源码树（含 out/，增量构建复用）
```

## 2. 执行环境与持久化

| 路径 | 内容 | 跨运行保留 |
|---|---|---|
| `~/.toolchains/Clang-*` | 交叉编译器 | 是（`[秒过]` 的来源） |
| `~/.toolchains/build-tools-main` | bison/flex 等宿主工具 | 是 |
| `~/.cache_patches/` | susfs4ksu / zram_patches / SukiSU_patch / wild_patches 补丁仓、`build_state`、`afdo/` | 是 |
| `~/.ccache` | ccache 缓存（上限 20G） | 是 |
| `~/share/out` | AK3 安装包、`history/`（保留 5 个）、`rej/`、`qcom_conflicts/` | 是 |
| `kernel_workspace/` | 内核树 + `out/` + `vendor_modules/` + `AnyKernel3/` | 是 |
| `/tmp/*_state.env` | 子脚本回传变量 | **是**（self-hosted 不清 `/tmp`，各脚本开头需自行重置） |

工具链身份（版本、目录名、下载地址）与外部仓库地址统一在 `scripts/build.env` 定义，换编译器只改 `CLANG_RELEASE` 一行。

## 3. 分类开关（category switch）

派发表单按**领域**分成 15 个下拉，每个下拉内部再分档；一个分类一次选择，不再逐个布尔勾选。

```
workflow_dispatch：root / susfs / kpm / sched / io / compression / net /
                   mem / container / security / opt / afdo / mode / ccache / suffix
   └── 步骤「展开分类开关」：case 分支把分类值翻译成脚本实际读取的变量
         e.g. sched=tuned_bore → SCHED_ENABLE=true + BORE_ENABLE=true
              io=adios_f2fs   → ADIOS_ENABLE=true + F2FS_ENABLE=true
              mode=diagnosis  → DIAGNOSIS=true（CLEAN_BUILD=false）
   └── 写入 $GITHUB_ENV，下游脚本无需感知「分类」这一层
```

设计要点：

- **只加一层翻译，不加新的配置源**：脚本仍然只认 `SUSFS_ENABLE`、`ADIOS_ENABLE` 这类变量，分类映射全部集中在工作流的「展开分类开关」步骤里
- **展开结果逐行打印**（`emit` 会同时写 `$GITHUB_ENV` 和日志），所以「这次到底开了什么」在日志第一屏就能核对
- 每个 `case` 都有 `*) die` 兜底：新增选项却忘了加分支时会立刻报错，而不是静默用默认值
- 所有 `stock`/`off` 选项都是显式关闭，不注入补丁也不写配置

## 4. 流水线

| # | step | 脚本 | 关键动作 | 失败即中止 |
|---|---|---|---|---|
| 1 | 同步仓库代码 | 内联 | 从 GitHub 浅拉当前分支并 `reset --hard` | 是 |
| 2 | 展开分类开关 | 内联 | 15 个分类 → `*_ENABLE` 变量写入 `GITHUB_ENV` | 是 |
| 3 | 代码静态检查 | `lint.sh` | `bash -n`、CRLF、heredoc、配置片段、YAML、shellcheck | 是 |
| 4 | 环境初始化 | `init_env.sh` | 磁盘预检 → 克隆内核与 vendor_modules → 骁龙上游合并 → 工具链 | 是 |
| 5 | ccache 配置 | `ccache_setup.sh` | 设置 ccache 环境与上限 | 是 |
| 6 | 清除旧 ccache | 内联 | 仅 `ccache=reset` | 否 |
| 7 | 应用补丁 | `apply_patches.sh` | 顺序调用 18 个功能模块 | 视补丁严格度 |
| 8 | 注入配置 | `config_inject.sh` | 17 个配置片段 + cmdline + LOCALVERSION | 是 |
| 9 | 准备 AutoFDO | 内联 | 选 profile、校验符号表一致性 | 是 |
| 10 | 编译内核 | `build_kernel.sh` | defconfig → 校验 → `make Image` → IKCFG 校验 | 是 |
| 11 | 上传诊断配置 | — | 仅 `mode=diagnosis` | 否 |
| 12 | 汇总日志 | 内联 | 打印 `build_summary.log` | 否（`always()`） |
| 13 | 打包发布 | `package.sh` | KPM 修补 → AnyKernel3 → zip → 存档 | 是 |
| 14 | 上传安装包 | — | zip + 日志上传 artifact（7 天） | 否 |
| 15 | 上传 ccache 日志 | — | 仅 `ccache=debug` | 否 |

## 5. 状态传递

三条通道，各有边界：

- **`$GITHUB_ENV`**：跨 step 传递（分类展开出的全部开关、`KERNEL_VERSION_FULL`、`CCACHE_REAL_KEY`、`BT_DIR_NAME` 等）
- **`$GITHUB_OUTPUT`**：step 输出（`ak3name` → artifact 上传）
- **`/tmp/*_state.env`**：子脚本 → 主脚本回传（子进程改不了父进程环境），目前有 `ksu_state.env`、`prefetch_state.env`

注意第 3 条：因为 runner 不清 `/tmp`，`kernelsu.sh` 每次开头会 `: > /tmp/ksu_state.env` 重置；新增 state 文件必须遵守同样约定，否则会读到上一次构建的值。

## 6. 增量构建

`build_kernel.sh` 用两段哈希判断能否增量：

| 指纹 | 组成 | 作用 |
|---|---|---|
| `PATCH_HASH` | `git status --porcelain` + `git diff` 的 md5 | 源码内容是否变化（只用路径会漏掉内容改动，实际踩过坑） |
| `CFG_HASH` | `out/.config` 的 md5 | 配置是否变化；变化则强制全量 |

命中时执行 `git ls-files | xargs touch -d @1500000000` 钳制 mtime，让 `make` 只重编被补丁改动的文件。
ccache key = `ccache-ecsv3-<内核主版本>-<SUBLEVEL>-<Droidspaces 开关>`，按内容寻址，跨构建复用。

## 7. 校验关卡

| 关卡 | 位置 | 拦什么 |
|---|---|---|
| 静态检查 | `lint.sh` + `.github/workflows/lint.yml` | 语法、CRLF、heredoc、配置片段冲突、YAML、shellcheck（push/PR 即跑，约 30 秒） |
| 分类值兜底 | 工作流「展开分类开关」 | 未知选项（`case *)` 直接失败，不会静默用默认值） |
| 磁盘预检 | `common.sh: need_disk` | 空间不足（全量 30G / 增量 6G） |
| `assert_config` | `build_kernel.sh` | 关键配置未落进 `.config`；ADIOS/BBRv3 跟随分类开关 |
| ABI 保护 | 同上 | `TASK_IO_ACCOUNTING`/`TASK_XACCT` 被关（会破坏 `task_struct` 布局） |
| IKCFG 内嵌校验 | 同上 | 产物里的配置与实际 `.config` 不一致（配置陈旧） |
| zram 标记 | 同上 | 调优代码没编进去（增量复用了旧 `.o`） |
| AutoFDO 匹配率 | 同上 | profile 与 vmlinux 符号表对不上 |
| `.rej` 汇总 | `finalize.sh` | 补丁静默失败 |

## 8. 补丁体系

两类来源：

- **仓库内**（`other_patch/`）：自维护补丁，随仓库版本化，15 个文件
- **运行时拉取**：`susfs4ksu`、`mrcxlinux/kernel_patches`、`ShirkNeko/SukiSU_patch`、`WildKernels/kernel_patches`，缓存进 `~/.cache_patches`

应用策略分 `strict`（失败即 `die`）与 `nonstrict`（打 `.rej` 后继续），由 `apply_patch_file` 的 `mode` 决定。
SUSFS 在 `KSU_CHANNEL=release` 时会回退到 KernelSU 发布同期的提交，避免大面积 reject。

骁龙上游合并是「冲突文件取上游版本 + 调度子系统整体对齐上游」的策略：本地定制依赖后续补丁重新打上去，若某补丁在新基线上失配，会退化成上游行为（靠 `.rej` 汇总兜底）。

## 9. 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| 派发后一直「等待中」 | `kbuild` runner 离线 | 启动 Hyper-V 虚拟机与 runner 服务 |
| `未知 sched: xxx` | 表单加了新选项但没加 case 分支 | 补「展开分类开关」里的分支 |
| `磁盘预检` 报错 | 剩余空间不足 | 清 `kernel_workspace/common/out` 或 `ccache -C` |
| 某个补丁 `FAILED` | 上游基线变了 | 看 `$OUT_DIR/rej/`，重新生成补丁 |
| `配置未生效: CONFIG_xxx` | defconfig 里被 select 或片段被覆盖 | 检查 `configs/features/` 与 `check_configs.py` 输出 |
| AutoFDO 匹配率 <50% | profile 与 vmlinux 不是同一次构建 | 用 `afdo=generate` 的内核重新采样 |
| 构建很慢 | `PATCH_HASH` 变化触发全量 | 正常；若仅改注释仍全量，检查 `git status` 是否被无关文件污染 |

## 10. 新增一个功能模块

1. 复制 `scripts/features/_template.sh` 为 `scripts/features/<name>.sh`，实现开关判断与幂等逻辑
2. 配置项放 `configs/features/<name>.config`（不要直接往 `config_inject.sh` 里塞 `echo`）
3. 在 `apply_patches.sh` 里按顺序加一行调用
4. 新补丁放 `other_patch/<name>/`，用 `apply_patch_file` 的 `strict`/`nonstrict`
5. 在 `kernel.yml` 里做两件事：给所属分类加一个选项（或新建分类），并在「展开分类开关」里加对应的 `case` 分支写 `*_ENABLE`
6. 更新 `scripts/features/README.md` 状态表与 `README.md` 的分类表，跑 `bash scripts/lint.sh`

## 11. 设计约束（有意不做）

- **按领域聚合成分类开关**：同类特性放进一个下拉（如 `io` 里 adios / f2fs / 两者），避免 20+ 个布尔勾选，也不引入"档位"这种把全部特性绑死的东西
- **不引入配置文件档位**：曾经用过 `configs/profiles/*.env`，但改特性要动仓库、且档位粒度太粗，已改回表单
- **不加 `ubuntu-latest` 构建兜底**：脚本依赖 `~/.toolchains` 缓存与 sudo apt 环境，托管 runner 上大概率超时
- **不拆 `build_kernel.sh`**：它是构建关键路径，拆分收益是"好看"，风险是"炸构建"
- **不引入 PR 流程**：单人维护，`push` 级 lint 已足够
