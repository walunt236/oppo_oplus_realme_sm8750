#!/usr/bin/env python3
"""校验 configs/features/*.config 片段。

这些片段会被 config_inject.sh 无条件 append 到 gki_defconfig，
同一个 CONFIG 键出现两个不同值时后者生效、且构建日志不会有任何提示。
构建期的 assert_config 只兜住少数关键项，所以这里做前置校验：

1. 行尾/编码：不允许 CRLF、BOM
2. 格式：每行必须是 CONFIG_X=value 或 "# CONFIG_X is not set"
3. 冲突：同一个键不允许出现两个不同的值

（条件分支互斥的情况由 config_inject.sh 的 if/else 决定，不在片段内，因此不算冲突。）
"""
import re
import sys
from pathlib import Path

ASSIGN = re.compile(r"^(CONFIG_[A-Z0-9_]+)=(.*)$")
NOT_SET = re.compile(r"^# (CONFIG_[A-Z0-9_]+) is not set$")


def parse_line(text):
    """返回 (key, value)；注释/空行返回 None。"""
    s = text.strip()
    if not s:
        return None
    if s.startswith("#"):
        m = NOT_SET.match(s)
        return (m.group(1), "n") if m else None
    m = ASSIGN.match(s)
    return (m.group(1), m.group(2)) if m else ("__BAD__", s)


def main():
    root = Path(__file__).resolve().parent.parent
    files = sorted((root / "configs" / "features").glob("*.config"))
    if not files:
        print("[config][ERROR] 未找到 configs/features/*.config")
        return 1

    bad = 0
    seen = {}
    total = 0

    for f in files:
        rel = f.relative_to(root).as_posix()
        raw = f.read_bytes()
        if b"\r" in raw:
            print(f"[config][ERROR] {rel}: 含 CRLF 行尾")
            bad = 1
        if raw.startswith(b"\xef\xbb\xbf"):
            print(f"[config][ERROR] {rel}: 含 UTF-8 BOM")
            bad = 1

        count = 0
        for n, line in enumerate(raw.decode("utf-8", "replace").splitlines(), 1):
            parsed = parse_line(line)
            if parsed is None:
                continue
            key, val = parsed
            if key == "__BAD__":
                print(f"[config][ERROR] {rel}:{n}: 无法解析: {val}")
                bad = 1
                continue
            count += 1
            total += 1
            if key in seen and seen[key][0] != val:
                prev_val, prev_file = seen[key]
                print(f"[config][ERROR] {key} 冲突: {prev_val!r} ({prev_file}) 与 {val!r} ({rel})")
                bad = 1
            else:
                seen.setdefault(key, (val, rel))
        print(f"[config] {rel}: {count} 条")

    print(f"[config] 合计 {total} 条，去重后 {len(seen)} 个键")
    return bad


if __name__ == "__main__":
    sys.exit(main())
