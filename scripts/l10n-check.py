#!/usr/bin/env python3
"""Check the English string table against the source.

Lucent's UI text is written in Chinese in the source and wrapped in L("…").
The English table (Resources/en.lproj/Lucent.strings) is keyed by that Chinese
text, with each \\(…) interpolation replaced by {0}, {1}, …

    scripts/l10n-check.py            list keys missing from / unused in the table
    scripts/l10n-check.py --missing  print missing keys as ready-to-fill .strings lines
    scripts/l10n-check.py --bare     also list Chinese literals not wrapped in L()

Exits non-zero when keys are missing.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "Lucent"
TABLE = ROOT / "Resources" / "en.lproj" / "Lucent.strings"
# CJK ideographs plus full-width punctuation: a literal like "，\(detail)" needs translating too.
CJK = re.compile(r"[\u3000-\u303f\u3400-\u9fff\uff00-\uffef]")
# Debug-only output is not translated.
SKIP_FILES = {"UsageDebugDump.swift", "CursorRefreshTest.swift", "UsageFixture.swift", "DebugSnapshots.swift", "L10n.swift"}
SKIP_CALLS = ("print(", "fatalError(", "assert(", "assertionFailure(", "precondition(", "NSLog(", "debugPrint(")


class Literal:
    def __init__(self, start):
        self.start = start
        self.end = start
        self.parts = []      # ("t", raw text) | ("i", [nested Literal])
        self.opaque = False  # multi-line or raw string: never translated

    def text(self):
        return "".join(p[1] for p in self.parts if p[0] == "t")

    def nested(self):
        for p in self.parts:
            if p[0] == "i":
                for lit in p[1]:
                    yield lit
                    yield from lit.nested()

    def key(self):
        out, n = "", 0
        for p in self.parts:
            if p[0] == "t":
                out += unescape(p[1])
            else:
                out += "{%d}" % n
                n += 1
        return out


def unescape(raw):
    def sub(m):
        c = m.group(1)
        if c.startswith("u{"):
            return chr(int(c[2:-1], 16))
        return {"n": "\n", "t": "\t", "r": "\r", "0": "\0"}.get(c, c)
    return re.sub(r"\\(u\{[0-9a-fA-F]+\}|.)", sub, raw)


def parse_string(s, i):
    lit = Literal(i)
    if s.startswith('"""', i):
        lit.opaque = True
        lit.end = s.index('"""', i + 3) + 3
        return lit
    j, buf = i + 1, ""
    while True:
        c = s[j]
        if c == "\\":
            if s[j + 1] == "(":
                lit.parts.append(("t", buf))
                buf = ""
                close, nested = parse_code(s, j + 2, True)
                lit.parts.append(("i", nested))
                j = close + 1
            elif s.startswith("u{", j + 1):
                k = s.index("}", j)
                buf += s[j:k + 1]
                j = k + 1
            else:
                buf += s[j:j + 2]
                j += 2
        elif c == '"':
            lit.parts.append(("t", buf))
            lit.end = j + 1
            return lit
        else:
            buf += c
            j += 1


def parse_code(s, i, until_paren=False):
    """Scan code from i. Returns (index of the closing paren or len(s), literals found)."""
    lits, depth, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if s.startswith("//", i):
            i = s.find("\n", i)
            if i < 0:
                return n, lits
        elif s.startswith("/*", i):
            level, i = 1, i + 2
            while level and i < n:
                if s.startswith("/*", i):
                    level, i = level + 1, i + 2
                elif s.startswith("*/", i):
                    level, i = level - 1, i + 2
                else:
                    i += 1
        elif c == "#" and s.startswith('"', i + 1):
            i = s.index('"#', i + 2) + 2
        elif c == '"':
            lit = parse_string(s, i)
            lits.append(lit)
            i = lit.end
        elif c == "(":
            depth, i = depth + 1, i + 1
        elif c == ")":
            if until_paren and depth == 0:
                return i, lits
            depth, i = depth - 1, i + 1
        else:
            i += 1
    return n, lits


def all_literals(s):
    _, top = parse_code(s, 0)
    for lit in top:
        yield lit
        yield from lit.nested()


def skipped_line(s, pos):
    line = s[s.rfind("\n", 0, pos) + 1:pos].lstrip()
    return line.startswith(SKIP_CALLS)


def wrapped(s, lit):
    return s[max(lit.start - 2, 0):lit.start] == "L("


def scan():
    keys, bare = {}, []
    for path in sorted(SOURCES.rglob("*.swift")):
        if path.name in SKIP_FILES:
            continue
        s = path.read_text()
        for lit in all_literals(s):
            if lit.opaque:
                continue
            where = "%s:%d" % (path.relative_to(ROOT), s.count("\n", 0, lit.start) + 1)
            if wrapped(s, lit):
                keys.setdefault(lit.key(), where)
            elif CJK.search(lit.text()) and not skipped_line(s, lit.start):
                bare.append((where, lit.key()))
    return keys, bare


def read_table():
    if not TABLE.exists():
        return {}
    out = {}
    pattern = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
    for line in TABLE.read_text().splitlines():
        m = pattern.match(line.strip())
        if m:
            out[unescape(m.group(1))] = unescape(m.group(2))
    return out


def quote(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def main():
    keys, bare = scan()
    table = read_table()
    missing = [k for k in keys if k not in table]
    unused = [k for k in table if k not in keys]
    if "--missing" in sys.argv:
        for k in missing:
            print("%s = %s;" % (quote(k), quote(k)))
        return 1 if missing else 0
    print("%d strings in source, %d in the English table" % (len(keys), len(table)))
    for k in missing:
        print("MISSING  %s  (%s)" % (quote(k), keys[k]))
    for k in unused:
        print("UNUSED   %s" % quote(k))
    # Placeholders must survive translation.
    for k, v in table.items():
        if k in keys and sorted(re.findall(r"\{\d+\}", k)) != sorted(re.findall(r"\{\d+\}", v)):
            print("PLACEHOLDERS DIFFER  %s = %s" % (quote(k), quote(v)))
    if "--bare" in sys.argv:
        for where, k in bare:
            print("NOT WRAPPED  %s  (%s)" % (quote(k), where))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
