#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
export AFDO_PROFILE="${AFDO_PROFILE:-}"

# AutoFDO 模式判定（GitHub 注入的 AFDO_GENERATE 是 true/false 字符串）
AFDO_GEN_ONLY=0
case "${AFDO_GENERATE:-}" in
  true|1) AFDO_GEN_ONLY=1 ;;
esac
AFDO_PROFILE_VALID=0
if [ "${AFDO_ENABLE:-false}" = "true" ] && [ "$AFDO_GEN_ONLY" -eq 0 ] \
   && [ -n "${AFDO_PROFILE:-}" ] && [ -s "${AFDO_PROFILE:-}" ]; then
  AFDO_PROFILE_VALID=1
fi
info "AutoFDO 状态: ENABLE=${AFDO_ENABLE:-false} GENERATE=${AFDO_GENERATE:-false} GEN_ONLY=$AFDO_GEN_ONLY PROFILE=${AFDO_PROFILE:-} 有效=$AFDO_PROFILE_VALID"

# 增量编译 mtime 钳制
cd "$GITHUB_WORKSPACE/kernel_workspace/common"
# 指纹必须包含文件内容：git status 只给路径，改同一批文件的内容会被漏掉，
# 导致增量构建复用旧 .o（实测：zram 调优改动未进内核）
PATCH_HASH=$( { echo "clang=${CLANG_VERSION:-19}"; echo "cc=${CLANG_DIR_NAME:-}"; git status --porcelain 2>/dev/null; git diff 2>/dev/null; } | md5sum | cut -d' ' -f1 || true )
echo "PATCH_HASH=$PATCH_HASH" >> "$GITHUB_ENV"
STORED=$(cut -d'|' -f1 "$HOME/.cache_patches/build_state" 2>/dev/null || true)
if [[ "$STORED" == "$PATCH_HASH" ]]; then
  info "增量编译：源码指纹与上次成功构建一致，钳制全部跟踪源文件 mtime..."
  git ls-files | xargs -r -P 16 touch -d @1500000000 2>/dev/null || true
  git update-index --refresh 2>/dev/null || true
  info "mtime 钳制完成，make 将只重编被补丁改动的文件"
else
  info "全量模式：源码指纹变化/首次构建/上次构建未成功"
fi

# 构建内核配置
cd "$GITHUB_WORKSPACE/kernel_workspace/common"

CLANG_DIR_NAME="${CLANG_DIR_NAME:-Clang-19.0.0git-20240723}"

load_toolchain_env() {
  export PATH="$HOME/.toolchains/${BT_DIR_NAME:?}/build-tools/bin:$PATH"
  export PATH="$HOME/.toolchains/${CLANG_DIR_NAME}/bin:$PATH"
  export PATH="/usr/lib/ccache:$PATH"
}

assert_config() {
  local sym="$1" desc="${2:-$1}"
  grep -q "^${sym}=y" out/.config || die "配置未生效: ${sym}，中止构建"
  info "${desc} 配置生效"
}

load_toolchain_env

if [[ "$CLEAN_BUILD" == "true" ]]; then
  info "clean_build 开启，删除 out/ 执行全量重建..."
  rm -rf out
fi

make_defconfig() {
  make -j${BUILD_JOBS} LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC="ccache clang" LD="ld.lld" HOSTLD=ld.lld O=out gki_defconfig
  # KSU 的 preinit 依赖 out/usr/include/linux/unistd.h（Kbuild 用 wildcard 检测）。
  # 显式安装一次 UAPI 头，保证 KSU 的 Kbuild 解析时它已存在。
  make -j${BUILD_JOBS} LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    CC="ccache clang" LD="ld.lld" HOSTLD=ld.lld O=out headers_install \
    >/dev/null 2>&1 || die "headers_install 失败"
  [ -f out/usr/include/linux/unistd.h ] || die "out/usr/include 未生成，KSU preinit 将不可用"

  # 性能项是否真的落到最终 .config（defconfig 里的 "# ... is not set" 可能被 select）
  for _c in INIT_ON_ALLOC_DEFAULT_ON SHUFFLE_PAGE_ALLOCATOR; do
    if grep -q "^CONFIG_$_c=y" out/.config; then
      warn "$_c 仍为 y：性能优化未生效"
    else
      info "$_c 已关闭"
    fi
  done
}

make_defconfig

CFG_HASH=$(md5sum out/.config | cut -d' ' -f1 || true)
echo "CFG_HASH=$CFG_HASH" >> "$GITHUB_ENV"
STORED_CFG=$(cut -d'|' -f2 "$HOME/.cache_patches/build_state" 2>/dev/null || true)
if [[ "$STORED_CFG" != "$CFG_HASH" ]]; then
  info ".config 与上次成功构建不一致，强制全量重建（避免增量配置陈旧）..."
  rm -rf out
  make_defconfig
  CFG_HASH=$(md5sum out/.config | cut -d' ' -f1 || true)
  echo "CFG_HASH=$CFG_HASH" >> "$GITHUB_ENV"
fi

if [ -f out/.config ]; then
  if grep -q '^CONFIG_ZRAM_DEF_COMP="lz4"' out/.config && grep -q '^CONFIG_ZRAM_DEF_COMP_LZ4=y' out/.config; then
    info "zram 主算法 lz4（次级 lz4hc 冷数据重压缩）"
  else
    die "zram 主算法未配置为 lz4（当前: $(grep '^CONFIG_ZRAM_DEF_COMP=' out/.config 2>/dev/null || echo 无)）"
  fi
fi

if [ -f out/.config ]; then
  if grep -q '^CONFIG_ZRAM_MEMORY_TRACKING=y' out/.config && grep -q '^CONFIG_ZRAM_TRACK_ENTRY_ACTIME=y' out/.config; then
    info "ZRAM_MEMORY_TRACKING 配置生效 (idle 页重压缩可用)"
  else
    die "ZRAM_MEMORY_TRACKING 配置未生效，中止构建"
  fi
fi

if [ "$AFDO_PROFILE_VALID" -eq 1 ]; then assert_config CONFIG_AUTOFDO_CLANG "AutoFDO (AUTOFDO_CLANG)"; fi
case "${AFDO_GENERATE:-}" in true|1) assert_config CONFIG_AUTOFDO_CLANG "AutoFDO 生成模式" ;; esac
assert_config CONFIG_SECTION_MISMATCH_WARN_ONLY "SECTION_MISMATCH_WARN_ONLY (modpost mismatch 降级警告)"
assert_config CONFIG_LTO_CLANG_THIN "ThinLTO"
assert_config CONFIG_HZ_300 "HZ=300"
assert_config CONFIG_IP_SET "网络功能扩展 (IP_SET)"
assert_config CONFIG_MQ_IOSCHED_ADIOS "ADIOS"
assert_config CONFIG_TCP_CONG_BBR3 "BBRv3"
assert_config CONFIG_PER_VMA_LOCK_STATS "per-VMA lock 统计"
assert_config CONFIG_IOMMU_DEFAULT_DMA_STRICT "IOMMU 严格模式"


# ABI 保护：task_struct 字段相关选项任何模式都不许关
grep -q '^CONFIG_TASK_IO_ACCOUNTING=y' out/.config || die "ABI 保护：CONFIG_TASK_IO_ACCOUNTING 被关闭，会破坏 task_struct 布局"
grep -q '^CONFIG_TASK_XACCT=y' out/.config || die "ABI 保护：CONFIG_TASK_XACCT 被关闭，会破坏 task_struct 布局"

if grep -q '^CONFIG_LLVM_POLLY=y' out/.config; then
  info "LLVM POLLY 配置生效"
else
  warn "LLVM_POLLY 未在 .config 中出现（补丁可能未完全生效），跳过校验继续"
fi

if [[ "$DIAGNOSIS" == "true" ]]; then
  info "诊断模式开启，已导出 build_config.txt"
  cp out/.config out/build_config.txt
fi

# 选择性 -O3
if [[ "$O3_SELECTIVE" == "true" ]]; then
  cd "$GITHUB_WORKSPACE/kernel_workspace/common"
  for TARGET_DIR in lib crypto; do
    if [ -d "$TARGET_DIR" ] && ! grep -q 'polly-vectorizer=stripmine' "$TARGET_DIR/Makefile"; then
      echo 'subdir-ccflags-y += -O3 -mllvm -polly -mllvm -polly-vectorizer=stripmine' >> $TARGET_DIR/Makefile
    fi
  done
  info "选择性O3与Polly配置完成"
fi

# DMA-BUF 页池扩容
cd "$GITHUB_WORKSPACE/kernel_workspace"
SYS_HEAP=$(find common drivers -name "system_heap.c" 2>/dev/null | head -n 1 || true)
if [ -n "$SYS_HEAP" ] && [ -f "$SYS_HEAP" ]; then
  sed -i 's/static u32 max_pool_size = .*/static u32 max_pool_size = 65536;/g' "$SYS_HEAP" 2>/dev/null || true
  info "DMA-BUF 页池扩容完成"
fi

# 编译完整内核镜像
if [[ "$DIAGNOSIS" == "true" ]]; then
  info "诊断模式：跳过内核编译"
  exit 0
fi

cd "$GITHUB_WORKSPACE"

load_toolchain_env

cd kernel_workspace/common


SOURCE_DATE_EPOCH=$(date +%s)
export SOURCE_DATE_EPOCH
KBUILD_BUILD_TIMESTAMP="$(date -u)"
export KBUILD_BUILD_TIMESTAMP
export KBUILD_BUILD_USER="OnePlus"
export KBUILD_BUILD_HOST="ubuntu-build"

mkdir -p "$HOME/.thinlto-cache"
cat << 'EOF' > ld-wrapper
#!/bin/sh
ORDER=""
OUT=""
prev=""
for a in "$@"; do
  if [ "$prev" = "o" ]; then OUT="$a"; prev=""; continue; fi
  case "$a" in
    -o) prev=o;;
    -r|--relocatable) ORDER="";;
  esac
done
# 只给最终 vmlinux 链接套排序表；ThinLTO 分区链接/模块链接各自只含
# 部分符号，套完整排序表会对每个分区重复报 "no such symbol"
case "$OUT" in
  */vmlinux|vmlinux) ;;
  *) ORDER="";;
esac
if [ -z "$ORDER" ] && [ -n "${HOTFILE:-}" ] && [ -s "${HOTFILE:-}" ]; then
  ORDER="--symbol-ordering-file=$HOTFILE"
fi
exec ld.lld --thinlto-cache-dir="$HOME/.thinlto-cache" --thinlto-cache-policy=cache_size_bytes=4g --thinlto-jobs="$(nproc --all)" $ORDER "$@"
EOF
chmod +x ld-wrapper

KCFLAGS_EXTRA="-mcpu=oryon-1 -moutline-atomics -fno-math-errno -fno-strict-aliasing -fno-semantic-interposition"
KCFLAGS_EXTRA+=" -mllvm -enable-misched=true -mllvm -import-instr-limit=300 -falign-functions=32 -falign-loops=32"
KCFLAGS_EXTRA+=" -mllvm -enable-gvn-hoist -mllvm -enable-load-pre -mllvm -polly-opt-outer-coincidence=true -mllvm -inline-threshold=300 -mllvm -inlinehint-threshold=500"
KCFLAGS_EXTRA+=" -mllvm -enable-loopinterchange=true -mllvm -enable-ipra -mllvm -enable-phi-of-ops -mllvm -enable-dse-partial-store-merging"
KCFLAGS_EXTRA+=" -mllvm -enable-aarch64-lsr-cost-opt -mllvm -enable-aarch64-or-like-select -mllvm -vectorizer-min-trip-count=2"
KCFLAGS_EXTRA+=" -mllvm -unroll-threshold=300 -mllvm -enable-loop-distribute"
# Oryon 特调外挂（对应 LLVM #172422，2025-12-31）：
# 调度模型里 LoopMicroOpBufferSize=0 会让 getUnrollingPreferences() 提前 return，
# 导致运行时 trip count 的循环永不展开。命令行传入 PartialUnrollingThreshold 会走
# 第一个分支、以相同数值 16 绕过该判断，等价于上游把模型值改成 16。
KCFLAGS_EXTRA+=" -mllvm -partial-unrolling-threshold=16"
# 编译期实验批（能力检测，不支持则跳过）
for FLAG in "-mllvm -enable-dfa-jump-thread" "-mllvm -misched-postra=true" "-mllvm -align-all-nofallthru-blocks=5" "-mllvm -enable-constraint-elimination"; do
  if echo 'int f(int x){return x+1;}' | clang -x c - $FLAG -c -o /dev/null >/dev/null 2>&1; then
    KCFLAGS_EXTRA+=" $FLAG"
    info "编译期：启用 $FLAG"
  else
    warn "clang 不支持 $FLAG，跳过"
  fi
done

# 基于 AFDO 画像的机器块布局（ext-TSP），把热块排到一起
KCFLAGS_EXTRA+=" -mllvm -enable-ext-tsp-block-placement=1"

# KSU_NO_PREINIT 兜底已移除：headers_install 后 preinit 会被编译，
# 其符号真实存在，SUSFS 的 exec.c 钩子可以直接链接。

info "核心编译器版本检查："
clang --version | head -n 1
info "链接器版本检查："
ld.lld --version

# AutoFDO profile 新鲜度检测
if [ "$AFDO_PROFILE_VALID" -eq 1 ] && [ -n "${AFDO_VMLINUX:-}" ] && [ -f "$AFDO_VMLINUX" ]; then
  PROFDATA="$HOME/.toolchains/${CLANG_DIR_NAME}/bin/llvm-profdata"
  NM="$HOME/.toolchains/${CLANG_DIR_NAME}/bin/llvm-nm"
  # 去掉 ThinLTO/Clang 内部后缀（.llvm.<hash>），否则与 vmlinux 符号表对不上
  "$PROFDATA" show -sample "$AFDO_PROFILE" 2>/dev/null | grep '^Function: ' | awk '{print $2}' | sed -E 's/:.*$//; s/\.llvm\.[0-9]+$//' | LC_ALL=C sort -u > /tmp/afdo_funcs.txt || true
  "$NM" --defined-only "$AFDO_VMLINUX" 2>/dev/null | awk '$2 ~ /^[tT]$/ {print $3}' | LC_ALL=C sort -u > /tmp/vmlinux_funcs.txt || true
  MATCH=$(LC_ALL=C comm -12 /tmp/afdo_funcs.txt /tmp/vmlinux_funcs.txt | wc -l || true)
  TOTAL=$(wc -l < /tmp/afdo_funcs.txt)
  if [ "$TOTAL" -gt 0 ]; then
    RATE=$(awk -v m="$MATCH" -v t="$TOTAL" 'BEGIN{printf "%.1f", m*100/t}')
    info "AutoFDO profile 符号匹配率: $RATE% ($MATCH/$TOTAL)"
    if awk -v r="$RATE" 'BEGIN{exit !(r < 50)}'; then
      warn "profile 匹配率 <50%——内核已演进，建议重新采样重建 profile"
    fi
  fi
elif [ "$AFDO_PROFILE_VALID" -eq 1 ]; then
  warn "AutoFDO 新鲜度防线未启用（AFDO_VMLINUX 未配置或文件不存在）"
fi

# AFDO 热函数排序表（链接期函数布局，类似 BOLT，仅改布局不改代码）
if [ "$AFDO_PROFILE_VALID" -eq 1 ]; then
  PROFDATA_HOT="$HOME/.toolchains/${CLANG_DIR_NAME}/bin/llvm-profdata"
  HOT_TMP=/tmp/hot_symbols.txt
  HOT_RANKED=/tmp/hot_symbols.ranked
  if [ -x "$PROFDATA_HOT" ]; then
    # 1) 去掉 .llvm.<hash> 后缀；2) 同一基础符号的多个克隆按计数求和；
    # 3) 按热度排序后只保留合法符号名
    "$PROFDATA_HOT" show -sample "$AFDO_PROFILE" 2>/dev/null | awk '
      /^Function: / {
        name=$2; sub(/:.*$/, "", name);
        sub(/\.llvm\.[0-9]+$/, "", name);
        cnt=$3; sub(/,.*$/, "", cnt);
        if (name != "" && cnt+0 > 0) sum[name]+=cnt;
      }
      END { for (n in sum) print sum[n], n }' \
      | LC_ALL=C sort -nr | awk '{print $2}' \
      | grep -E '^[A-Za-z_][A-Za-z0-9_.$]*$' > "$HOT_RANKED" || true
  fi
  if [ ! -s "$HOT_RANKED" ]; then
    grep -E '^[A-Za-z_][A-Za-z0-9_.$]*:[0-9]+$' "$AFDO_PROFILE" 2>/dev/null \
      | LC_ALL=C sort -t: -k2 -nr | cut -d: -f1 \
      | sed -E 's/\.llvm\.[0-9]+$//' | awk '!seen[$0]++' > "$HOT_RANKED" || true
  fi
  # 若已有 vmlinux 符号表，过滤掉被内联/消除的符号，减少
  # "symbol ordering file: no such symbol" 警告并提高排序命中率
  if [ -s "$HOT_RANKED" ] && [ -s /tmp/vmlinux_funcs.txt ]; then
    head -6000 "$HOT_RANKED" | LC_ALL=C grep -F -x -f /tmp/vmlinux_funcs.txt | head -3000 > "$HOT_TMP" || true
  elif [ -s "$HOT_RANKED" ]; then
    head -3000 "$HOT_RANKED" > "$HOT_TMP"
  fi
  if [ -s "$HOT_TMP" ]; then
    export HOTFILE="$HOT_TMP"
    info "AFDO 热函数排序表: $(wc -l < "$HOTFILE") 个符号（链接期排序，已剥离 .llvm 后缀）"
  else
    warn "AFDO 排序表生成失败（profile 文本格式不识别），跳过链接期排序"
  fi
fi
# 编译器参数官方工具链支持验证
info "编译器参数支持验证（$CLANG_DIR_NAME）:"
if clang --target=aarch64-linux-gnu -mcpu=oryon-1 -### -c /dev/null 2>&1 | grep -qE "error|unknown|not supported"; then
  echo "  ✗ -mcpu=oryon-1 不被工具链支持！" | tee -a "$LOG_FILE"
  exit 1
else
  echo "  ✓ -mcpu=oryon-1（Oryon 目标）" | tee -a "$LOG_FILE"
fi
if [ "$AFDO_PROFILE_VALID" -eq 1 ]; then
  if clang -fprofile-sample-use="$AFDO_PROFILE" -fprofile-sample-accurate -fdebug-info-for-profiling -mllvm -enable-fs-discriminator=true -mllvm -sample-profile-max-propagate-iterations=300 -### -c /dev/null 2>&1 | grep -qE "error|unknown|not supported"; then
    echo "  ✗ AutoFDO 参数不被工具链支持！" | tee -a "$LOG_FILE"
    exit 1
  else
    echo "  ✓ AutoFDO 全套（-fprofile-sample-use / -fprofile-sample-accurate / -fdebug-info-for-profiling / fs-discriminator / propagate-iterations=300）" | tee -a "$LOG_FILE"
  fi
  if ld.lld -m aarch64elf --lto-sample-profile="$AFDO_PROFILE" -r -o /dev/null /dev/null 2>&1 | grep -qE "error|unknown|not supported"; then
    echo "  ✗ --lto-sample-profile 不被链接器支持！" | tee -a "$LOG_FILE"
    exit 1
  else
    echo "  ✓ --lto-sample-profile（ThinLTO 链接期二次应用）" | tee -a "$LOG_FILE"
  fi
else
  warn "未提供 AutoFDO profile，本次跳过 AutoFDO 相关优化"
fi
for flag in "-O3" "-falign-functions=32" "-falign-loops=32" "-moutline-atomics" "-fno-semantic-interposition" "-fno-math-errno" "-mllvm -polly"; do
  if clang $flag -### -c /dev/null 2>&1 | grep -qE "error|unknown|not supported"; then
    echo "  ✗ $flag 不被工具链支持！" | tee -a "$LOG_FILE"
  else
    echo "  ✓ $flag" | tee -a "$LOG_FILE"
  fi
done
for m in enable-misched import-instr-limit enable-gvn-hoist enable-load-pre polly-opt-outer-coincidence inline-threshold inlinehint-threshold enable-loopinterchange enable-ipra enable-phi-of-ops enable-dse-partial-store-merging enable-aarch64-lsr-cost-opt enable-aarch64-or-like-select vectorizer-min-trip-count unroll-threshold enable-loop-distribute; do
  if echo 'int f(int x){return x+1;}' | clang -x c - -fsyntax-only -mllvm -$m=1 2>&1 | grep -qE "error|unknown"; then
    echo "  ✗ -mllvm -$m 不被工具链支持！" | tee -a "$LOG_FILE"
  else
    echo "  ✓ -mllvm -$m" | tee -a "$LOG_FILE"
  fi
done
if echo 'int f(int x){return x*2;}' | clang -x c - -fsyntax-only -mllvm -polly -mllvm -polly-vectorizer=stripmine 2>&1 | grep -qE "error|unknown"; then
  echo "  ✗ Polly（-mllvm -polly -polly-vectorizer=stripmine）不被工具链支持！" | tee -a "$LOG_FILE"
else
  echo "  ✓ Polly（-mllvm -polly -polly-vectorizer=stripmine）" | tee -a "$LOG_FILE"
fi
info "优化 pass 实际生效验证（工具链 -Rpass 官方日志）:"
if echo 'static int g(int x){return x*3;} int f(int x){return g(x)+1;}' | clang -x c - -S -o /dev/null -O3 -mllvm -inline-threshold=300 -Rpass=inline 2>&1 | grep -q "inlined into"; then
  echo "  ✓ inline 实际生效（-Rpass=inline: 函数已内联，threshold 参数生效）" | tee -a "$LOG_FILE"
else
  echo "  ✗ inline 未生效！" | tee -a "$LOG_FILE"
fi
if echo 'int f(int *a, int n){int s=0; for(int i=0;i<n;i++) s+=a[i]; return s;}' | clang -x c - -S -o /dev/null -O3 -Rpass=loop-vectorize 2>&1 | grep -q "vectorized loop"; then
  echo "  ✓ 循环向量化实际生效（-Rpass=loop-vectorize: 已向量化）" | tee -a "$LOG_FILE"
else
  echo "  ✗ 循环向量化未生效！" | tee -a "$LOG_FILE"
fi
if [ "$AFDO_PROFILE_VALID" -eq 1 ]; then
  if echo 'static int g(int x){return x*3;} int f(int x){return g(x)+1;}' | clang -x c - -S -o /dev/null -O3 -fprofile-sample-use="$AFDO_PROFILE" -Rpass=inline 2>&1 | grep -q "inlined into"; then
    echo "  ✓ AutoFDO profile 驱动 inline 生效（-Rpass=inline + 自采 profile）" | tee -a "$LOG_FILE"
  else
    echo "  ✗ AutoFDO profile 驱动未生效！" | tee -a "$LOG_FILE"
    exit 1
  fi
fi
if grep -q 'if (min_seq\[!can_swap\] + MIN_NR_GENS < max_seq)' mm/vmscan.c; then
  sed -i '/if (min_seq\[!can_swap\] + MIN_NR_GENS < max_seq)/,+1d' mm/vmscan.c
  info "MGLRU aging threshold relaxed"
else
  warn "MGLRU aging line already modified, skipped"
fi
AFDO_CFLAGS=""
AFDO_MAKE_ARGS=""
if [ "$AFDO_PROFILE_VALID" -eq 1 ]; then
  AFDO_CFLAGS="-fprofile-sample-accurate -mllvm -sample-profile-max-propagate-iterations=300"
  AFDO_MAKE_ARGS="CLANG_AUTOFDO_PROFILE=$AFDO_PROFILE"
fi
make -j${BUILD_JOBS} LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC="ccache clang" LD="$(pwd)/ld-wrapper" HOSTLD=ld.lld O=out KCFLAGS="-O3 -Wno-error $KCFLAGS_EXTRA $AFDO_CFLAGS" $AFDO_MAKE_ARGS Image
assert_ikcfg() {
  grep -q "^${1}=y" <<< "$IKCFG_TEXT" || die "Image 内嵌配置缺少 ${1}，产物配置陈旧，中止"
}
if [ -f out/arch/arm64/boot/Image ]; then
  IKCFG_TEXT=$(perl -e 'open(F,"<",$ARGV[0]); local $/; $d=<F>; close F; $d =~ /IKCFG_ST(.*?)IKCFG_ED/s; open(G,"|-","gzip -dc 2>/dev/null"); print G $1; close G;' out/arch/arm64/boot/Image 2>/dev/null)
  if [ -z "$IKCFG_TEXT" ]; then
    error "Image 内嵌配置数据缺失（IKCFG 提取失败），产物配置陈旧，中止"
    exit 1
  fi
  assert_ikcfg CONFIG_ZRAM_MEMORY_TRACKING
  if [ "$AFDO_PROFILE_VALID" -eq 1 ]; then assert_ikcfg CONFIG_AUTOFDO_CLANG; fi
  assert_ikcfg CONFIG_HZ_300
  assert_ikcfg CONFIG_TCP_CONG_BBR3
  assert_ikcfg CONFIG_IP_SET
  assert_ikcfg CONFIG_LTO_CLANG_THIN
  assert_ikcfg CONFIG_MQ_IOSCHED_ADIOS
  assert_ikcfg CONFIG_SECTION_MISMATCH_WARN_ONLY
  assert_ikcfg CONFIG_PER_VMA_LOCK_STATS
  grep -qF "CONFIG_LOCALVERSION=\"${LOCALVER:-}\"" <<< "$IKCFG_TEXT" || die "Image 内嵌 LOCALVERSION 与预期不符（期望 ${LOCALVER:-}），产物配置陈旧，中止"
  info "Image 内嵌配置校验通过"
fi

if [ "$AFDO_GEN_ONLY" -eq 1 ]; then
  AFDO_DIR="$HOME/.cache_patches/afdo"
  mkdir -p "$AFDO_DIR"
  SNAP="$AFDO_DIR/vmlinux-$(date +%Y%m%d-%H%M)"
  cp out/vmlinux "$SNAP"
  ln -sf "$(basename "$SNAP")" "$AFDO_DIR/vmlinux.latest"
  info "可采样 vmlinux 已保存: $SNAP ($(du -h "$SNAP" | cut -f1))"
  info "vmlinux 指纹: $(md5sum "$SNAP" | cut -c1-16)"
  info "采样并转换后，用 afdo_mode=use 重建"
fi

info "内核镜像编译完成"
# zram 调优版本标记校验：缺失说明增量构建复用了旧目标文件
if [ -n "${ZRAM_TUNE_REV:-}" ] && [ -f out/vmlinux ]; then
  if grep -aq "$ZRAM_TUNE_REV" out/vmlinux; then
    info "zram 调优标记校验通过（$ZRAM_TUNE_REV）"
  else
    die "zram 调优未编入内核（$ZRAM_TUNE_REV 缺失，疑似增量构建复用了旧目标文件）"
  fi
fi
# KMI 检查：Module.symvers 的 md5（导出符号 CRC 应与基线一致）
if [ -f out/Module.symvers ]; then
  info "Module.symvers: $(wc -l < out/Module.symvers) 行 md5=$(md5sum out/Module.symvers | awk '{print $1}')"
fi
# 结构体布局（若环境有 pahole）
if command -v pahole >/dev/null 2>&1 && [ -f out/vmlinux ]; then
  info "sched_entity: $(pahole -C sched_entity out/vmlinux 2>/dev/null | head -2 | tr '\n' ' ')"
fi
if nm out/vmlinux 2>/dev/null | grep -q "_lz4_decompress_asm"; then
  info "_lz4_decompress_asm 符号校验通过"
else
  warn "_lz4_decompress_asm 符号未找到"
fi

grep "CONFIG_IP6_NF_NAT" out/.config 2>/dev/null || echo "CONFIG_IP6_NF_NAT: not set"
ccache --show-stats

if [[ -n "${PATCH_HASH:-}" ]] && [[ -n "${CFG_HASH:-}" ]]; then
  mkdir -p "$HOME/.cache_patches"
  printf '%s|%s' "$PATCH_HASH" "$CFG_HASH" > "$HOME/.cache_patches/build_state"
  info "增量指纹+配置哈希已记录，下次相同状态将增量编译"
fi
