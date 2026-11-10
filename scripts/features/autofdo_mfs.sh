#!/usr/bin/env bash
# AutoFDO + Machine Function Splitting (MFS) backport
# Based on upstream commit 2fd65f7afd5a ("AutoFDO: Enable machine function
# split optimization for AutoFDO"), adapted to the OnePlus 6.6 tree.
set -euo pipefail
WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GITHUB_WORKSPACE="$WS"
source "$WS/scripts/common.sh"

cd "$WS/kernel_workspace/common"
AUTOFDO=scripts/Makefile.autofdo
LDS=include/asm-generic/vmlinux.lds.h

# Clang capability check (full path: apply_patches runs before build_kernel)
CLANG_BIN="$HOME/.toolchains/${CLANG_DIR_NAME}/bin/clang"
if [ -x "$CLANG_BIN" ]; then
  if ! printf 'int f(int x){return x+1;}\n' | "$CLANG_BIN" -x c - -c -o /dev/null -fsplit-machine-functions 2>/dev/null; then
    die "Clang 不支持 -fsplit-machine-functions（MFS）"
  fi
else
  warn "找不到 $CLANG_BIN，跳过 MFS 编译器能力检查"
fi

python3 - "$AUTOFDO" "$LDS" <<'PYEOF'
import sys
from pathlib import Path

autofdo = Path(sys.argv[1])
lds = Path(sys.argv[2])

s = autofdo.read_text()
if "-fsplit-machine-functions" not in s:
    old = "CFLAGS_AUTOFDO_CLANG += -fprofile-sample-use=$(CLANG_AUTOFDO_PROFILE)"
    new = old + " -ffunction-sections -fsplit-machine-functions"
    if old not in s:
        raise SystemExit("MFS: AutoFDO profile flag block not found")
    s = s.replace(old, new, 1)

    old2 = "KBUILD_LDFLAGS += --mllvm=-enable-fs-discriminator=true --mllvm=-improved-fs-discriminator=true -plugin-opt=thinlto"
    new2 = old2 + "\n  KBUILD_LDFLAGS += -plugin-opt=-split-machine-functions"
    if old2 not in s:
        raise SystemExit("MFS: ThinLTO flag block not found")
    s = s.replace(old2, new2, 1)
    autofdo.write_text(s)
    print("MFS: patched scripts/Makefile.autofdo")

s = lds.read_text()
if "TEXT_SPLIT" not in s:
    macro = """#define TEXT_SPLIT							\\
		__split_text_start = .;					\\
		*(.text.split .text.split.[0-9a-zA-Z_]*)		\\
		__split_text_end = .;

"""
    marker = "#define TEXT_TEXT"
    if marker not in s:
        raise SystemExit("MFS: TEXT_TEXT marker not found")
    s = s.replace(marker, macro + marker, 1)

    lines = s.splitlines()
    out = []
    inserted = False
    for line in lines:
        out.append(line)
        if not inserted and "*(TEXT_MAIN .text.fixup)" in line:
            out.append("\t\tTEXT_SPLIT\t\t\t\t\t\t\\")
            inserted = True
    if not inserted:
        raise SystemExit("MFS: TEXT_MAIN line not found")
    lds.write_text("\n".join(out) + "\n")
    print("MFS: patched include/asm-generic/vmlinux.lds.h")
# Add __unlikely_text_start/end boundaries (Clang19 MFS uses .text.unlikely)
s = lds.read_text()
if "__unlikely_text_start" not in s:
    lines = s.splitlines()
    out = []
    inserted = False
    for line in lines:
        if "*(.text.unlikely .text.unlikely.*)" in line:
            out.append("\t\t__unlikely_text_start = .;\t\t\t\t\\")
            out.append(line)
            out.append("\t\t__unlikely_text_end = .;\t\t\t\t\\")
            inserted = True
        else:
            out.append(line)
    if not inserted:
        raise SystemExit("MFS: .text.unlikely line not found")
    lds.write_text("\n".join(out) + "\n")
    print("MFS: added unlikely text boundaries")

PYEOF

grep -q -- '-fsplit-machine-functions' "$AUTOFDO" || die "MFS: AutoFDO flags missing"
grep -q 'TEXT_SPLIT' "$LDS" || die "MFS: linker TEXT_SPLIT missing"
info "AutoFDO MFS 补丁已应用"