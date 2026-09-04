#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

cd "$GITHUB_WORKSPACE/kernel_workspace"
DCFG="./common/arch/arm64/configs/gki_defconfig"

if [[ "$SUSFS_ENABLE" == "true" ]]; then
  cat >> "$DCFG" << 'SUSFSCFG'
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
SUSFSCFG
else
  echo "CONFIG_KSU_SUSFS=n" >> "$DCFG"
fi

if [[ "$KSU_TYPE" != "none" ]]; then
  echo "CONFIG_KSU=y" >> "$DCFG"
else
  echo "CONFIG_KSU=n" >> "$DCFG"
fi

if [[ "$KPM_ENABLE" == 'builtin' ]] && ( [[ "$KSU_TYPE" == "sukisu" ]] || [[ "$KSU_TYPE" == "resukisu" ]] ); then
  echo "CONFIG_KPM=y" >> "$DCFG"
fi
echo "CONFIG_TMPFS_XATTR=y" >> "$DCFG"
echo "CONFIG_TMPFS_POSIX_ACL=y" >> "$DCFG"

if [[ "$LZ4KD_ENABLE" == "true" ]]; then
  cat >> "$DCFG" << 'LZ4KDCFG'
CONFIG_ZSMALLOC=y
CONFIG_CRYPTO_LZ4K=y
CONFIG_CRYPTO_LZ4KD=y
CONFIG_CRYPTO_842=y
# zram 双重压缩：lz4 主算法 + zstd 冷数据重压缩
# 冷数据：MULTI_COMP recompression 转 zstd
CONFIG_ZRAM_DEF_COMP_LZ4=y
CONFIG_ZRAM_DEF_COMP="lz4"
LZ4KDCFG
fi

echo "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y" >> "$DCFG"
sed -i 's/check_defconfig//' ./common/build.config.gki || true
echo "CONFIG_HEADERS_INSTALL=n" >> "$DCFG"
echo "CONFIG_AUTOFDO_CLANG=y" >> "$DCFG"
echo "CONFIG_SECTION_MISMATCH_WARN_ONLY=y" >> "$DCFG"

echo 'CONFIG_ZRAM=y' >> "$DCFG"
echo 'CONFIG_ZRAM_MEMORY_TRACKING=y' >> "$DCFG"
echo 'CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=y' >> "$DCFG"
echo 'CONFIG_IOMMU_DEFAULT_DMA_STRICT=n' >> "$DCFG"
echo 'CONFIG_IOMMU_DEFAULT_DMA_LAZY=y' >> "$DCFG"

cat >> "$DCFG" << 'TUNECFG'
CONFIG_LTO_CLANG_THIN=y
CONFIG_LLVM_POLLY=y
CONFIG_CRYPTO_LZ4=y
CONFIG_CRYPTO_LZ4HC=y
CONFIG_LZ4_COMPRESS=y
CONFIG_LZ4HC_COMPRESS=y
CONFIG_LZ4_DECOMPRESS=y
CONFIG_CRYPTO_ZSTD=y
CONFIG_CRYPTO_SHA3_ARM64=y
CONFIG_CRYPTO_SM3_ARM64_CE=y
CONFIG_CRYPTO_SM4_ARM64_CE=y
CONFIG_CRYPTO_SM4_ARM64_CE_BLK=y
CONFIG_CRYPTO_SHA256_ARM64_CE=y
CONFIG_CRYPTO_AES_ARM64_CE=y
CONFIG_CRYPTO_AES_ARM64_CE_BLK=y
CONFIG_CRYPTO_AES_ARM64_CE_CCM=y
CONFIG_CRYPTO_CHACHA20_NEON=y
CONFIG_THP_SWAP=y
CONFIG_NET_SCH_ETS=y
CONFIG_ZSTD_COMPRESS=y
CONFIG_ZSTD_DECOMPRESS=y
CONFIG_SLAB_MERGE_DEFAULT=y
CONFIG_F2FS_FS_LZ4=y
CONFIG_F2FS_FS_LZ4HC=y
CONFIG_F2FS_FS_ZSTD=y
CONFIG_EROFS_FS_ZIP_LZMA=y
CONFIG_EROFS_FS_ZIP_DEFLATE=y
CONFIG_ARM64_NEON=y
CONFIG_ARM64_SIMD=y
CONFIG_ARM_SPE_PMU=y
CONFIG_LRU_GEN=y
CONFIG_LRU_GEN_ENABLED=y
CONFIG_DAMON_PADDR=y
CONFIG_DAMON_RECLAIM=y
CONFIG_DAMON_LRU_SORT=y
CONFIG_NET_SCH_CAKE=y
CONFIG_SECURITY_LANDLOCK=y
TUNECFG

if [[ "$RCU_NOCB_ENABLE" == "true" ]]; then
  info "开启 RCU_NOCB_CPU..."
  cat >> "$DCFG" << 'RCUCFG'
CONFIG_RCU_EXPERT=y
CONFIG_RCU_NOCB_CPU=y
CONFIG_RCU_NOCB_CPU_DEFAULT_ALL=y
CONFIG_RCU_LAZY_DEFAULT_OFF=n
CONFIG_RCU_NOCB_CPU_CB_BOOST=y
RCUCFG
  info "RCU_LAZY 默认启用"
fi

cat >> "$DCFG" << 'NSCFG'
CONFIG_UTS_NS=y
CONFIG_USER_NS=y
CONFIG_DEVTMPFS=y
NSCFG

info "注入 Vendor 驱动符号 (UBSAN / KUNIT)..."
grep -q "CFLAGS_configs.o := -D__IKCFG_BUILD" ./common/kernel/Makefile || \
  echo 'CFLAGS_configs.o := -D__IKCFG_BUILD_$(shell date +%s)' >> ./common/kernel/Makefile
grep -q "CFLAGS_REMOVE_configs.o" ./common/kernel/Makefile || \
  echo 'CFLAGS_REMOVE_configs.o := -flto=thin -fsplit-lto-unit' >> ./common/kernel/Makefile

apply_patch_file "other_patch/zram_recomp_default.patch" /tmp/zram_recomp.patch strict "zram 默认 zstd 重压缩算法补丁"
apply_patch_file "other_patch/damon_reclaim_defaults.patch" /tmp/damon_reclaim.patch strict "DAMON_RECLAIM 默认参数补丁"
cat >> "$DCFG" << 'OEMDEPENDS'
CONFIG_UBSAN=y
CONFIG_UBSAN_TRAP=y
CONFIG_CC_HAS_UBSAN_ARRAY_BOUNDS=y
CONFIG_UBSAN_BOUNDS=y
CONFIG_UBSAN_ARRAY_BOUNDS=y
CONFIG_UBSAN_LOCAL_BOUNDS=y
CONFIG_UBSAN_SANITIZE_ALL=n
CONFIG_KUNIT=m
CONFIG_KUNIT_DEBUGFS=y
OEMDEPENDS

# cmdline 注入
info "对 init/main.c 注入 cmdline..."
cd common
TARGET_MAIN="init/main.c"

if [ ! -f "$TARGET_MAIN" ]; then
  error "无法定位内核入口文件 $TARGET_MAIN"
  exit 1
fi

sed -i '/setup_arch(&command_line);/a \    strlcat(boot_command_line, " schedstats=disable panic=30 page_alloc.shuffle=1 cryptomgr.notests rcutree.blimit=1024 workqueue.power_efficient=1 skew_tick=0 random.trust_cpu=on kfence.sample_interval=0 loglevel=3 transparent_hugepage=madvise", sizeof(boot_command_line));' "$TARGET_MAIN"

if grep -q "strlcat.*boot_command_line" "$TARGET_MAIN"; then
  info "cmdline 注入成功"
else
  error "cmdline 注入失败"
  exit 1
fi

# 网络功能增强
cd "$GITHUB_WORKSPACE/kernel_workspace"
cat >> ./common/arch/arm64/configs/gki_defconfig << 'NETCFG'
CONFIG_NETFILTER_XT_TARGET_HL=y
CONFIG_NETFILTER_XT_MATCH_HL=y
CONFIG_NF_CONNTRACK=y
CONFIG_NF_NAT=y
CONFIG_NF_NAT_MASQUERADE=y
CONFIG_NF_NAT_REDIRECT=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
CONFIG_IP6_NF_IPTABLES=y
CONFIG_IP6_NF_FILTER=y
CONFIG_IP6_NF_MANGLE=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_IP6_NF_TARGET_REDIRECT=y
CONFIG_IP_NF_NAT=y
CONFIG_IP_NF_TARGET_MASQUERADE=y
CONFIG_IP_NF_TARGET_REDIRECT=y
CONFIG_NF_TABLES=n
CONFIG_BPF_STREAM_PARSER=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_IP_SET=y
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_NET_SCH_FQ=y
CONFIG_NET_SCH_PIE=y
CONFIG_DEFAULT_FQ=y
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_TCP_CONG_CUBIC=y
NETCFG

# Droidspaces 配置块
if [[ "$DROIDSPACES_ENABLE" != "false" ]]; then
  cd "$GITHUB_WORKSPACE/kernel_workspace/common"
  cat >> ./arch/arm64/configs/gki_defconfig << 'DSCFG'
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_SYSVIPC=y
CONFIG_NAMESPACES=y
CONFIG_POSIX_MQUEUE=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_NTSYNC=y
DSCFG
  if [[ "$DROIDSPACES_ENABLE" == "extend" ]]; then
    echo "CONFIG_BT_HCIVHCI=y" >> ./arch/arm64/configs/gki_defconfig
    echo "CONFIG_STATIC_USERMODEHELPER=n" >> ./arch/arm64/configs/gki_defconfig
    echo "CONFIG_DRM_LINDROID_EVDI=y" >> ./arch/arm64/configs/gki_defconfig
  fi
fi

# ADIOS 配置块
cd "$GITHUB_WORKSPACE/kernel_workspace"
cat >> ./common/arch/arm64/configs/gki_defconfig << 'ADIOSCFG'
CONFIG_MQ_IOSCHED_ADIOS=y
CONFIG_MQ_IOSCHED_DEFAULT_ADIOS=y
ADIOSCFG

# 版本固化
cd "$GITHUB_WORKSPACE/kernel_workspace"
echo "CONFIG_LOCALVERSION_AUTO=y" >> ./common/arch/arm64/configs/gki_defconfig

LOCALVER="-${KERNEL_SUFFIX}"
if [[ -n "$UPSTREAM_SUBLEVEL" ]] && [[ "$UPSTREAM_SUBLEVEL" != "0" ]]; then
  LOCALVER="${LOCALVER}_${UPSTREAM_SUBLEVEL}"
fi

sed -i '/^CONFIG_LOCALVERSION=/d' ./common/arch/arm64/configs/gki_defconfig
echo "CONFIG_LOCALVERSION=\"${LOCALVER}\"" >> ./common/arch/arm64/configs/gki_defconfig

for f in ./common/scripts/setlocalversion; do
  sed -i 's|^echo "\$res"$|echo "'"${LOCALVER}"'"|' "$f"
done
sed -i 's/${scm_version}//' ./common/scripts/setlocalversion

# HZ=300
info "启用 HZ=300..."
cd "$GITHUB_WORKSPACE/kernel_workspace"
cat >> ./common/arch/arm64/configs/gki_defconfig << 'HZ300CFG'
# CONFIG_HZ_250 is not set
CONFIG_HZ_300=y
CONFIG_HZ=300
HZ300CFG

echo "CONFIG_PER_VMA_LOCK_STATS=y" >> ./common/arch/arm64/configs/gki_defconfig

info "配置注入完成"
