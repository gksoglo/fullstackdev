#!/usr/bin/env python3
"""
Rewrite the MQL5 sources into something a C++ compiler will parse, so the
whole tree can be type-checked outside MetaEditor.

The rewrites are deliberately few and mechanical. Each corresponds to a
place where MQL5 and C++ genuinely differ in *syntax* — none of them
changes program logic, so a type error found in the output is a real type
error in the input.

  1. `#property ...`            -> dropped (MQL5-only metadata)
  2. `input T x = v;`           -> `const T x = v;`
  3. `D'2020.01.01'`            -> `0`  (MQL5 datetime literal)
  4. `T &name[]`                -> `MqlArray<T>& name`   (array parameter)
  5. `T name[];`                -> `MqlArray<T> name;`   (dynamic array decl)

Fixed-size arrays (`T name[N]`) are left alone: they mean the same thing
in both languages.
"""
import re
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "MQL5"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/rl_build")

# `double &dest[]` / `const MqlRates &rates[]` -> MqlArray<T>& name
ARRAY_PARAM = re.compile(r"\b([A-Za-z_]\w*)\s*&\s*([A-Za-z_]\w*)\s*\[\s*\]")

# `MqlRates rates[];` or `double a[], s[];` (empty brackets only)
ARRAY_DECL = re.compile(
    r"^(\s*)([A-Za-z_]\w*)\s+([A-Za-z_]\w*\s*\[\s*\]\s*(?:,\s*[A-Za-z_]\w*\s*\[\s*\]\s*)*);"
)

DATETIME_LIT = re.compile(r"D'[^']*'")


def strip_comment(line: str) -> str:
    """Body of the line with any // comment removed, for match testing."""
    i = line.find("//")
    return line if i < 0 else line[:i]


def convert(text: str) -> str:
    out = []
    for line in text.split("\n"):
        code = strip_comment(line)

        if code.lstrip().startswith("#property"):
            out.append("// [transpiled] " + line.strip())
            continue

        # input -> const, only as a leading declaration keyword
        line = re.sub(r"^(\s*)input\s+", r"\1const ", line)

        line = DATETIME_LIT.sub("0", line)

        # Array declarations must be handled before array params, since a
        # decl has no '&' and would otherwise be missed entirely.
        m = ARRAY_DECL.match(strip_comment(line))
        if m and "return" not in m.group(2):
            indent, typ, names = m.group(1), m.group(2), m.group(3)
            clean = [n.strip().replace("[", "").replace("]", "").strip()
                     for n in names.split(",")]
            trailing = line[len(m.group(0)):]
            line = f"{indent}MqlArray<{typ}> {', '.join(clean)};{trailing}"
        else:
            line = ARRAY_PARAM.sub(r"MqlArray<\1>& \2", line)

        out.append(line)
    return "\n".join(out)


def main() -> int:
    if OUT.exists():
        import shutil
        shutil.rmtree(OUT)

    count = 0
    for src in sorted(SRC.rglob("*")):
        if src.suffix not in (".mqh", ".mq5"):
            continue
        rel = src.relative_to(SRC)
        dst = OUT / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(convert(src.read_text()))
        count += 1

    print(f"transpiled {count} files -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
