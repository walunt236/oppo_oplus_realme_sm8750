#!/usr/bin/env python3
"""校验 configs/profiles/*.env。

配置档决定「这个内核是什么」，派发时只传档位名。少一个键就会退回脚本里的
默认值（各脚本的 :-default 并不一致），多一个键则会被静默忽略 —— 两种都很难
在构建日志里发现，所以在这里把 schema 钉死。
"""
import sys
from pathlib import Path

# 键 -> 允许的取值
SCHEMA = {
    "SUSFS_ENABLE": {"true", "false"},
    "KPM_ENABLE": {"false", "builtin", "kpn"},
    "LZ4KD_ENABLE": {"true", "false"},
    "DROIDSPACES_ENABLE": {"false", "standard", "extend"},
    "REKERNEL_ENABLE": {"true", "false"},
    "BASEBAND_GUARD": {"true", "false"},
    "ADIOS_ENABLE": {"true", "false"},
    "BBR3_ENABLE": {"true", "false"},
    "SCHED_ENABLE": {"true", "false"},
    "LZ4ZSTD_ENABLE": {"true", "false"},
    "F2FS_ENABLE": {"true", "false"},
    "BORE_ENABLE": {"true", "false"},
    "RCU_NOCB_ENABLE": {"true", "false"},
    "O3_SELECTIVE": {"true", "false"},
}


def main():
    root = Path(__file__).resolve().parent.parent
    files = sorted((root / "configs" / "profiles").glob("*.env"))
    if not files:
        print("[profile][ERROR] 未找到 configs/profiles/*.env")
        return 1

    bad = 0
    for f in files:
        rel = f.relative_to(root).as_posix()
        raw = f.read_bytes()
        if b"\r" in raw:
            print(f"[profile][ERROR] {rel}: 含 CRLF 行尾")
            bad = 1
        seen = {}
        for n, line in enumerate(raw.decode("utf-8", "replace").splitlines(), 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            if "=" not in s:
                print(f"[profile][ERROR] {rel}:{n}: 不是 KEY=VALUE: {s}")
                bad = 1
                continue
            key, val = (x.strip() for x in s.split("=", 1))
            if key in seen:
                print(f"[profile][ERROR] {rel}:{n}: {key} 重复定义")
                bad = 1
                continue
            if key not in SCHEMA:
                print(f"[profile][ERROR] {rel}:{n}: 未知键 {key}（新增特性请先更新 SCHEMA）")
                bad = 1
                continue
            if val not in SCHEMA[key]:
                print(f"[profile][ERROR] {rel}:{n}: {key}={val} 非法，允许值 {sorted(SCHEMA[key])}")
                bad = 1
                continue
            seen[key] = val

        missing = sorted(set(SCHEMA) - set(seen))
        if missing:
            print(f"[profile][ERROR] {rel}: 缺少 {len(missing)} 个键: {', '.join(missing)}")
            bad = 1
        print(f"[profile] {rel}: {len(seen)}/{len(SCHEMA)} 个键")

    return bad


if __name__ == "__main__":
    sys.exit(main())
