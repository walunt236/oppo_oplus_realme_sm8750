# zstd vs lz4hc：memcomp 256MB PAGEOUT 测试

QEMU virt，2 GiB，4 vCPU，TCG（无 KVM）；
CI Image 6.6.143，启动参数 memcomp.compressor=<name>；
256MB 匿名映射（一半 pattern，一半 xorshift），MADV_PAGEOUT 4 次。

## 结果（两轮）

zstd:
  PAGEOUT: 17105.7 / 17760.5 ms
  refault/touch: 1766.9 / 1714.3 ms
  STAT: 134217728 9043968 9437184
  VERIFY_OK

lz4hc:
  PAGEOUT: 49907.1 / 51007.0 ms
  refault/touch: 1733.5 / 1805.1 ms
  STAT: 134217728 9207808 10014720
  VERIFY_OK

## 结论（仅 QEMU TCG）

- lz4hc PAGEOUT 耗时约为 zstd 的 2.9 倍
- 压缩后大小 zstd 小约 1.8%，zsmalloc 池小约 5.8%
- refault/touch 差异在噪声范围内
- 该 synthetic 负载下 zstd 明显占优；最终需真机 A/B
