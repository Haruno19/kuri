#!/usr/bin/env python3
"""Updates the line numbers of the code references in flows.html.

Each reference is 'path:line: code'. The code is looked up in the file and
the line number rewritten, taking the occurrence nearest the old number when
the code appears more than once. References whose code is gone are listed,
and the script exits with an error, for a person to fix.

    python3 docs/sync-flow-refs.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FLOWS = ROOT / "docs" / "flows.html"
REF = re.compile(r"'(?P<path>[\w/.]+\.swift):(?P<line>\d+): (?P<code>(?:[^'\\]|\\.)*)'")


def source(path):
    base = ROOT if path.startswith("App/") else ROOT / "Packages" / "KuriKit" / "Sources"
    return base / path


def unescape(code):
    return re.sub(r"\\(.)", r"\1", code)


def main():
    text = FLOWS.read_text()
    files = {}
    missing = []
    moved = 0

    def fix(match):
        nonlocal moved
        path, line, code = match["path"], int(match["line"]), unescape(match["code"])
        file = source(path)
        if not file.exists():
            missing.append(f"{path}: no such file")
            return match[0]
        lines = files.setdefault(path, file.read_text().splitlines())
        found = [i + 1 for i, l in enumerate(lines) if code in l]
        if not found:
            missing.append(f"{path}:{line}: {code}")
            return match[0]
        best = min(found, key=lambda n: abs(n - line))
        if best != line:
            moved += 1
        return f"'{path}:{best}: {match['code']}'"

    updated = REF.sub(fix, text)
    if updated != text:
        FLOWS.write_text(updated)
    print(f"{moved} reference(s) updated.")
    if missing:
        print("Code not found, fix these by hand:", file=sys.stderr)
        for entry in missing:
            print(f"  {entry}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
