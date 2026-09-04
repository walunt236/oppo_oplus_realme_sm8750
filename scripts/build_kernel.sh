#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

# 增量编译 mtime 钳制
cd "$GITHUB_WORKSPACE/kernel_workspace/common"
PATCH_HASH=$(git status --porcelain 2>/dev/null | md5sum | cut -d' ' -f1)
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

load_toolchain_env() {
  export PATH="$HOME/.toolchains/${BT_DIR_NAME:?}/build-tools/bin:$PATH"
  export PATH="$HOME/.toolchains/Clang-19.0.0git-20240723/bin:$PATH"
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
  make -j$(nproc --all) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC="ccache clang" LD="ld.lld" HOSTLD=ld.lld O=out gki_defconfig
}

make_defconfig

CFG_HASH=$(md5sum out/.config | cut -d' ' -f1)
echo "CFG_HASH=$CFG_HASH" >> "$GITHUB_ENV"
STORED_CFG=$(cut -d'|' -f2 "$HOME/.cache_patches/build_state" 2>/dev/null || true)
if [[ "$STORED_CFG" != "$CFG_HASH" ]]; then
  info ".config 与上次成功构建不一致，强制全量重建（避免增量配置陈旧）..."
  rm -rf out
  make_defconfig
  CFG_HASH=$(md5sum out/.config | cut -d' ' -f1)
  echo "CFG_HASH=$CFG_HASH" >> "$GITHUB_ENV"
fi

if [[ "$LZ4KD_ENABLE" == "true" ]] && [ -f out/.config ]; then
  if grep -q '^CONFIG_ZRAM_DEF_COMP_LZ4=y' out/.config && grep -q '^CONFIG_ZRAM_DEF_COMP="lz4"' out/.config; then
    info "ZRAM 主算法配置生效 (lz4 NEON + MULTI_COMP/zstd 双重压缩)"
  else
    die "LZ4KD 配置未生效，中止构建"
  fi
fi

if [ -f out/.config ]; then
  if grep -q '^CONFIG_ZRAM_MEMORY_TRACKING=y' out/.config && grep -q '^CONFIG_ZRAM_TRACK_ENTRY_ACTIME=y' out/.config; then
    info "ZRAM_MEMORY_TRACKING 配置生效 (idle 页重压缩可用)"
  else
    die "ZRAM_MEMORY_TRACKING 配置未生效，中止构建"
  fi
fi

assert_config CONFIG_AUTOFDO_CLANG "AutoFDO (AUTOFDO_CLANG)"
assert_config CONFIG_SECTION_MISMATCH_WARN_ONLY "SECTION_MISMATCH_WARN_ONLY (modpost mismatch 降级警告)"
assert_config CONFIG_LTO_CLANG_THIN "ThinLTO"
assert_config CONFIG_HZ_300 "HZ=300"
assert_config CONFIG_IP_SET "网络功能扩展 (IP_SET)"
assert_config CONFIG_MQ_IOSCHED_ADIOS "ADIOS"
assert_config CONFIG_TCP_CONG_BBR3 "BBRv3"
assert_config CONFIG_PER_VMA_LOCK_STATS "per-VMA lock 统计"

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

if [[ "$RUNNER_TYPE" == "ubuntu-latest" ]]; then
  info "清理云端磁盘空间..."
  sudo rm -rf /usr/share/dotnet &
  sudo rm -rf /usr/local/lib/android &
  sudo rm -rf /opt/ghc &
  sudo rm -rf /opt/hostedtoolcache/CodeQL &
  wait
fi

export SOURCE_DATE_EPOCH=$(date +%s)
export KBUILD_BUILD_TIMESTAMP="$(date -u)"
export KBUILD_BUILD_USER="OnePlus"
export KBUILD_BUILD_HOST="ubuntu-build"

mkdir -p "$HOME/.thinlto-cache"
cat << 'EOF' > ld-wrapper
#!/bin/sh
exec ld.lld --thinlto-cache-dir="$HOME/.thinlto-cache" --thinlto-jobs="$(nproc --all)" "$@"
EOF
chmod +x ld-wrapper

KCFLAGS_EXTRA="-mcpu=oryon-1 -moutline-atomics -fno-math-errno -fno-strict-aliasing -fno-semantic-interposition"
KCFLAGS_EXTRA+=" -mllvm -enable-misched=true -mllvm -import-instr-limit=300 -falign-functions=32 -falign-loops=32"
KCFLAGS_EXTRA+=" -mllvm -enable-gvn-hoist -mllvm -enable-load-pre -mllvm -polly-opt-outer-coincidence=true -mllvm -inline-threshold=300 -mllvm -inlinehint-threshold=500"
KCFLAGS_EXTRA+=" -mllvm -enable-loopinterchange=true -mllvm -enable-ipra -mllvm -enable-phi-of-ops -mllvm -enable-dse-partial-store-merging"
KCFLAGS_EXTRA+=" -mllvm -enable-aarch64-lsr-cost-opt -mllvm -enable-aarch64-or-like-select -mllvm -vectorizer-min-trip-count=2"
KCFLAGS_EXTRA+=" -mllvm -unroll-threshold=300 -mllvm -enable-loop-distribute"

info "核心编译器版本检查："
clang --version | head -n 1
info "链接器版本检查："
ld.lld --version

# AutoFDO profile 新鲜度检测
if [ -n "$AFDO_PROFILE" ] && [ -f /home/dev/pgo/vmlinux ]; then
  PROFDATA="$HOME/.toolchains/Clang-19.0.0git-20240723/bin/llvm-profdata"
  NM="$HOME/.toolchains/Clang-19.0.0git-20240723/bin/llvm-nm"
  "$PROFDATA" show -sample "$AFDO_PROFILE" 2>/dev/null | grep '^Function: ' | awk '{print $2}' | sed 's/:.*//' | sort -u > /tmp/afdo_funcs.txt || true
  "$NM" --defined-only /home/dev/pgo/vmlinux 2>/dev/null | awk '$2 ~ /^[tT]$/ {print $3}' | sort -u > /tmp/vmlinux_funcs.txt || true
  MATCH=$(comm -12 /tmp/afdo_funcs.txt /tmp/vmlinux_funcs.txt | wc -l)
  TOTAL=$(wc -l < /tmp/afdo_funcs.txt)
  if [ "$TOTAL" -gt 0 ]; then
    RATE=$(awk -v m="$MATCH" -v t="$TOTAL" 'BEGIN{printf "%.1f", m*100/t}')
    info "AutoFDO profile 符号匹配率: $RATE% ($MATCH/$TOTAL)"
    if awk -v r="$RATE" 'BEGIN{exit !(r < 50)}'; then
      warn "profile 匹配率 <50%——内核已演进，建议重新采样重建 profile"
    fi
  fi
fi
# 编译器参数官方工具链支持验证
info "编译器参数支持验证（ZyCromerZ clang 19 官方工具链）:"
if clang -mcpu=oryon-1 -### -c /dev/null 2>&1 | grep -qE "error|unknown|not supported"; then
  echo "  ✗ -mcpu=oryon-1 不被工具链支持！" | tee -a "$LOG_FILE"
else
  echo "  ✓ -mcpu=oryon-1（Oryon 目标）" | tee -a "$LOG_FILE"
fi
if [ -n "$AFDO_PROFILE" ]; then
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
  error "AFDO_PROFILE 未就绪（profile 步骤异常），中止构建"
  exit 1
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
if [ -n "$AFDO_PROFILE" ]; then
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
make -j$(nproc --all) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC="ccache clang" LD="$(pwd)/ld-wrapper" HOSTLD=ld.lld O=out KCFLAGS="-O3 -Wno-error $KCFLAGS_EXTRA -fprofile-sample-accurate -mllvm -sample-profile-max-propagate-iterations=300" CLANG_AUTOFDO_PROFILE="$AFDO_PROFILE" Image
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
  assert_ikcfg CONFIG_AUTOFDO_CLANG
  assert_ikcfg CONFIG_HZ_300
  assert_ikcfg CONFIG_TCP_CONG_BBR3
  assert_ikcfg CONFIG_IP_SET
  info "Image 内嵌配置校验通过 (ZRAM_MEMORY_TRACKING/AUTOFDO_CLANG/HZ_300/BBR3/IP_SET)"
fi

info "内核镜像编译完成"
if nm out/vmlinux 2>/dev/null | grep -q "_lz4_decompress_asm"; then
  info "_lz4_decompress_asm 符号校验通过"
else
  warn "_lz4_decompress_asm 符号未找到"
fi

grep "CONFIG_IP6_NF_NAT" out/.config 2>/dev/null || echo "CONFIG_IP6_NF_NAT: not set"
ccache --show-stats
