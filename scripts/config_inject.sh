#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

cd "$GITHUB_WORKSPACE/kernel_workspace"
DCFG="./common/arch/arm64/configs/gki_defconfig"

if [[ "$SUSFS_ENABLE" == "true" && "$KSU_TYPE" != "none" ]]; then
  cat >> "$DCFG" << 'SUSFSCFG'
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
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
LZ4KDCFG
fi

# zram 双重压缩：主算法 lz4（解压快，页错误延迟低）+ 冷数据由 zstd 重压缩（压缩率高）
# 不能放进 LZ4KD 条件块：否则关闭 lz4kd 时会退回 Kconfig 默认的 lzo-rle
cat >> "$DCFG" << 'ZRAMDEFCFG'
CONFIG_ZRAM_DEF_COMP_LZ4=y
CONFIG_ZRAM_DEF_COMP="lz4"
ZRAMDEFCFG

# 性能模式：关闭热路径上的加固与计费（CFI/KASAN 因模块 ABI 限制必须保留）
if [ "${PERF_MODE:-balanced}" = "aggressive" ]; then
  cat >> "$DCFG" << 'PERFMODE'
# 性能模式：栈变量零初始化（-ftrivial-auto-var-init=zero，每函数开销）
CONFIG_INIT_STACK_NONE=y
# CONFIG_INIT_STACK_ALL_ZERO is not set
# CONFIG_INIT_STACK_ALL_PATTERN is not set
# usercopy 越界检查
# CONFIG_HARDENED_USERCOPY is not set
# slab 空闲链表加固（每次分配都有异或/随机化开销）
# CONFIG_SLAB_FREELIST_HARDENED is not set
# CONFIG_SLAB_FREELIST_RANDOM is not set
# 注意：CONFIG_TASK_IO_ACCOUNTING / CONFIG_TASK_XACCT 绝不能关闭！
# 二者控制 task_struct 里的 ioac 与 acct_rss_mem1/acct_vm_mem1/acct_timexpd 字段
# （include/linux/sched.h），关闭会让 task_struct 缩小 24 字节，
# 导致厂商预编译模块按旧偏移读 task 字段 -> 启动期死锁（实测卡开机 logo）。
# 中断时间计费
# CONFIG_IRQ_TIME_ACCOUNTING is not set
PERFMODE
  info "性能模式已启用：关闭 栈零初始化 / usercopy 检查 / slab 加固 / 中断时间计费（IO 计费因 ABI 保留）"
  warn "安全提示：以上加固关闭后，内核本地漏洞利用难度下降；CFI 与 KASAN 因模块 ABI 限制仍保留"
else
  info "标准模式：保留上游全部加固（栈零初始化 / usercopy / slab / 计费）"
fi

echo "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y" >> "$DCFG"
# 骁龙 6.6.14x 已从 kernel/sched/Makefile 移除 ext.o，开启该选项会导致
# bpf_sched_ext_ops 未定义，这里强制关闭
# 关闭 sched_ext：6.6 内核无此功能（6.12 才进主线），且高通 BSP 已剥离
# 核心集成（task_struct 缺 sched_ext_entity），开启只会引用不存在的符号
sed -i '/^CONFIG_SCHED_CLASS_EXT/d' "$DCFG"
echo "# CONFIG_SCHED_CLASS_EXT is not set" >> "$DCFG"
# ARM64 cluster 调度：让 EAS 感知多 cluster 拓扑（默认选项，纯拓扑感知）
echo "CONFIG_SCHED_CLUSTER=y" >> "$DCFG"
# （已移除无效的 check_defconfig 删除动作：本流水线不调用 build/build.sh，该校验从未执行）
sed -i '/^CONFIG_HEADERS_INSTALL/d' "$DCFG"
echo "CONFIG_HEADERS_INSTALL=y" >> "$DCFG"
# KSU preinit 需要 out/usr/include（Kbuild 用 wildcard 检测），必须保留
if [ "${AFDO_ENABLE:-false}" = "true" ]; then
  echo "CONFIG_AUTOFDO_CLANG=y" >> "$DCFG"
  info "AutoFDO 构建已启用（CONFIG_AUTOFDO_CLANG=y）"
else
  info "AutoFDO 未启用，跳过 CONFIG_AUTOFDO_CLANG"
fi
echo "CONFIG_SECTION_MISMATCH_WARN_ONLY=y" >> "$DCFG"

echo 'CONFIG_ZRAM=y' >> "$DCFG"
echo 'CONFIG_ZRAM_MEMORY_TRACKING=y' >> "$DCFG"
echo 'CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=y' >> "$DCFG"
echo 'CONFIG_IOMMU_DEFAULT_DMA_STRICT=y' >> "$DCFG"

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
CONFIG_CRYPTO_SHA256_ARM64=y
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

sed -i '/setup_arch(&command_line);/a \    strlcat(boot_command_line, " schedstats=disable panic=30 page_alloc.shuffle=0 cryptomgr.notests rcutree.blimit=1024 workqueue.power_efficient=1 skew_tick=0 random.trust_cpu=on kfence.sample_interval=0 loglevel=3 transparent_hugepage=madvise kasan=off init_on_alloc=0", sizeof(boot_command_line));' "$TARGET_MAIN"

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
if [[ -z "$KERNEL_SUFFIX_INPUT" ]] && [[ -n "$UPSTREAM_SUBLEVEL" ]] && [[ "$UPSTREAM_SUBLEVEL" != "0" ]]; then
  LOCALVER="${LOCALVER}_${UPSTREAM_SUBLEVEL}"
fi
echo "LOCALVER=$LOCALVER" >> "$GITHUB_ENV"

sed -i '/^CONFIG_LOCALVERSION=/d' ./common/arch/arm64/configs/gki_defconfig
echo "CONFIG_LOCALVERSION=\"${LOCALVER}\"" >> ./common/arch/arm64/configs/gki_defconfig

sed -i 's|^echo "\$res"$|echo "'"${LOCALVER}"'"|' ./common/scripts/setlocalversion

# HZ=300
info "启用 HZ=300..."
cd "$GITHUB_WORKSPACE/kernel_workspace"
cat >> ./common/arch/arm64/configs/gki_defconfig << 'HZ300CFG'
# CONFIG_HZ_250 is not set
CONFIG_HZ_300=y
CONFIG_HZ=300
HZ300CFG

echo "CONFIG_PER_VMA_LOCK_STATS=y" >> ./common/arch/arm64/configs/gki_defconfig

# 性能优先：关闭两项加固带来的固定开销。
#   INIT_ON_ALLOC_DEFAULT_ON : 每次内存分配强制清零，典型 1~5% 开销
#   SHUFFLE_PAGE_ALLOCATOR   : 页分配随机化，破坏缓存局部性，典型 1~2% 开销
# 均可通过启动参数恢复（init_on_alloc=1 / page_alloc.shuffle=1）。
echo "# CONFIG_INIT_ON_ALLOC_DEFAULT_ON is not set" >> "$DCFG"
echo "# CONFIG_SHUFFLE_PAGE_ALLOCATOR is not set" >> "$DCFG"

info "已关闭 INIT_ON_ALLOC / SHUFFLE_PAGE_ALLOCATOR（性能优先）"


info "配置注入完成"
