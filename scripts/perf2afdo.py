#!/usr/bin/env python3
"""simpleperf perf.data -> LLVM sample profile（函数级 + 行号级计数）

为什么不用 llvm-profgen：
    llvm-profgen 的 checkPerfScriptType() 只接受带 LBR 分支记录的样本，
    而 arm64 设备普遍没有 LBR（simpleperf `-b` 报 branch stack not supported），
    ETM 又需要 bootloader 开启。本脚本绕过该限制：直接解析 perf.data 的
    调用栈叶子 IP，用 vmlinux 符号表 + DWARF 行号聚合出 AutoFDO 所需计数。

用法:
    perf2afdo.py <perf.data> [vmlinux] [输出文件]

输出格式（LLVM sample profile 文本）:
    func:总样本:总样本
     行号: 样本数
"""
import bisect
import collections
import os
import re
import struct
import subprocess
import sys

CTX_MASK = 0xFFFFFFFFFFFFFF00      # perf 调用栈上下文标记的上界
KERN_SPAN = 0x40000000             # 内核文本地址窗口


def find_toolchain():
    cand = [
        os.path.expanduser("~/.toolchains/Clang-19.0.0git-20240723/bin"),
        "/opt/toolchains/bin",
    ]
    for d in cand:
        if os.path.isfile(os.path.join(d, "llvm-nm")) and os.path.isfile(os.path.join(d, "llvm-symbolizer")):
            return d
    sys.exit("[ERROR] 找不到 llvm-nm / llvm-symbolizer")


def load_symbols(nm, vmlinux):
    out = subprocess.check_output([nm, "--defined-only", "-S", vmlinux], text=True, errors="replace")
    syms = []
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 4 and p[2] in ("t", "T", "w", "W"):
            try:
                syms.append((int(p[0], 16), int(p[1], 16), p[3]))
            except ValueError:
                pass
    syms.sort()
    return syms, [s[0] for s in syms]


def main():
    if len(sys.argv) < 2:
        sys.exit("用法: perf2afdo.py <perf.data> [vmlinux] [输出文件]")
    perf = sys.argv[1]
    vmlinux = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/.cache_patches/afdo/vmlinux.latest")
    out_path = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/.cache_patches/afdo/kernel.afdo")
    tc = find_toolchain()
    nm, symb = os.path.join(tc, "llvm-nm"), os.path.join(tc, "llvm-symbolizer")

    data = open(perf, "rb").read()
    _magic, _hsize, _attr_size, attrs_off, _attrs_sz, data_off, _data_sz = struct.unpack_from("<7Q", data, 0)
    _a_type, _a_size = struct.unpack_from("<II", data, attrs_off)
    _config, period, sample_type, _rf = struct.unpack_from("<4Q", data, attrs_off + 8)
    print("[INFO] 采样率=%d sample_type=0x%x" % (period, sample_type))

    syms, addrs = load_symbols(nm, vmlinux)
    stext_link = next((a for a, s, n in syms if n == "_stext"), 0)
    if not stext_link:
        sys.exit("[ERROR] vmlinux 中找不到 _stext")

    def find_sym(addr):
        i = bisect.bisect_right(addrs, addr) - 1
        if i < 0:
            return None
        a, s, n = syms[i]
        return n if addr < a + max(s, 1) else (n if addr < a + 0x100000 else None)

    def u64(p):
        return struct.unpack_from("<Q", data, p)[0]

    off, runtime_base = data_off, None
    leaf_ips = collections.Counter()
    n_all = n_kern = 0
    while off + 8 <= len(data):
        t, _misc, sz = struct.unpack_from("<IHH", data, off)
        if sz < 8 or off + sz > len(data):
            break
        if t == 1:  # PERF_RECORD_MMAP
            addr = struct.unpack_from("<Q", data, off + 16)[0]
            name = data[off + 40:off + sz].split(b"\x00")[0].decode("utf-8", "replace")
            if "kernel.kallsyms" in name and runtime_base is None:
                runtime_base = addr
        elif t == 9:  # PERF_RECORD_SAMPLE
            p = off + 8
            u64(p); p += 8
            if sample_type & 0x2: p += 8      # TID
            if sample_type & 0x4: p += 8      # TIME
            if sample_type & 0x40: p += 8     # ID
            if sample_type & 0x80: p += 8     # CPU
            if sample_type & 0x100: p += 8    # PERIOD
            n_all += 1
            if sample_type & 0x20 and p + 8 <= off + sz:   # CALLCHAIN
                nr = u64(p); p += 8
                leaf = None
                for _ in range(nr):
                    if p + 8 > off + sz:
                        break
                    v = u64(p); p += 8
                    if v >= CTX_MASK:
                        continue
                    leaf = v
                    break
                if leaf and runtime_base and runtime_base <= leaf < runtime_base + KERN_SPAN:
                    n_kern += 1
                    leaf_ips[leaf - runtime_base + stext_link] += 1
        off += sz

    if not runtime_base:
        sys.exit("[ERROR] perf.data 里没有内核 mmap 记录，无法确定 KASLR 基址")
    print("[INFO] 总样本=%d 内核叶子=%d 唯一地址=%d 运行时基址=0x%x"
          % (n_all, n_kern, len(leaf_ips), runtime_base))

    sorted_addrs = sorted(leaf_ips)
    inp = "\n".join("0x%x" % a for a in sorted_addrs) + "\n"
    res = subprocess.run([symb, "--obj=" + vmlinux], input=inp, text=True, capture_output=True)
    lines = [l for l in res.stdout.splitlines() if l.strip()]
    loc = {}
    k = 0
    for a in sorted_addrs:
        if k + 1 >= len(lines):
            break
        loc[a] = lines[k + 1]
        k += 2

    func_tot = collections.Counter()
    func_lines = collections.defaultdict(collections.Counter)
    unmapped = 0
    for a in sorted_addrs:
        fn = find_sym(a)
        if not fn:
            unmapped += 1
            continue
        cnt = leaf_ips[a]
        func_tot[fn] += cnt
        m = re.search(r":(\d+)(?::\d+)?$", loc.get(a, ""))
        if m and int(m.group(1)) > 0:
            func_lines[fn][int(m.group(1))] += cnt

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        for fn, tot in func_tot.most_common():
            f.write("%s:%d:%d\n" % (fn, tot, tot))
            for line_no, c in sorted(func_lines[fn].items()):
                f.write(" %d: %d\n" % (line_no, c))

    nailed = sum(func_tot.values())
    print("[INFO] 已写出 %s" % out_path)
    print("[INFO] 函数=%d 行条目=%d 未映射地址=%d 内核样本覆盖率=%.1f%%"
          % (len(func_tot), sum(len(v) for v in func_lines.values()), unmapped,
             100.0 * nailed / max(n_kern, 1)))
    print("[INFO] 热点 Top5: " + ", ".join("%s(%d)" % (n[:24], c) for n, c in func_tot.most_common(5)))


if __name__ == "__main__":
    main()