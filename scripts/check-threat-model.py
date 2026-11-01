#!/usr/bin/env python3
"""check-threat-model.py - docs/security/threat-model.md has not drifted from the code (stdlib only).

  python3 scripts/check-threat-model.py [--root PATH] [--doc PATH]

Each row of the Threats table is checked:
  - the id is unique, the status and the STRIDE letters are known, the boundary is defined;
  - every backticked repository path exists; `path::text` also needs that text in the file;
  - `mitigated` needs a test named in the check column, any other row a test or the words
    "no test" - a control is never implied by silence.
Row ids named in the attack trees and the comparison exist, and SECURITY.md and README.md
link to the document. It says nothing about whether a control is good enough.
Exit 1 with one line per problem.
"""
import argparse
import os
import re
import sys

sys.dont_write_bytecode = True
STATUSES = {"mitigated", "partial", "accepted", "open"}
ROOTS = ("template/", "scripts/", "tests/", "docs/", "skills/", "providers/", "examples/", ".github/")
FILES = ("SECURITY.md", "README.md", "CONTRIBUTING.md")
COLUMNS = 8


def refs(cell):
    """(path, text or None) for each backticked repository reference in a table cell."""
    out = []
    for tok in re.findall(r"`([^`]+)`", cell):
        path, sep, text = tok.partition("::")
        if " " not in path and (path.startswith(ROOTS) or path in FILES):
            out.append((path, text if sep else None))
    return out


def check(root, doc):
    errs = []
    text = open(doc, encoding="utf-8").read()
    boundaries = set(re.findall(r"^\| (B\d+) \|", text, re.M))
    seen = set()
    for line in text.splitlines():
        if not re.match(r"^\| TM-", line):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split(" | ")]
        tid = cells[0]
        if len(cells) != COLUMNS:
            errs.append("%s: %d columns, expected %d" % (tid, len(cells), COLUMNS))
            continue
        _, _, boundary, stride, control, checked, status, _ = cells
        if tid in seen:
            errs.append("%s: duplicate id" % tid)
        seen.add(tid)
        if status not in STATUSES:
            errs.append("%s: unknown status %r" % (tid, status))
        for b in re.split(r",\s*", boundary):
            if b not in boundaries:
                errs.append("%s: unknown boundary %r" % (tid, b))
        if not set(re.split(r",\s*", stride)) <= set("STRIDE"):
            errs.append("%s: unknown STRIDE letters %r" % (tid, stride))
        has_test = any(p.startswith("tests/") for p, _ in refs(checked))
        if status == "mitigated" and not has_test:
            errs.append("%s: mitigated without a test" % tid)
        if not has_test and "no test" not in checked:
            errs.append("%s: names no test and does not say so" % tid)
        for path, needle in refs(control) + refs(checked):
            full = os.path.join(root, path)
            if not os.path.isfile(full):
                errs.append("%s: no such file: %s" % (tid, path))
            elif needle is not None and needle not in open(full, encoding="utf-8", errors="replace").read():
                errs.append("%s: %s does not contain %r" % (tid, path, needle))
    if not seen:
        errs.append("no threat rows found")
    for tid in set(re.findall(r"\bTM-\d+\b", text)) - seen:
        errs.append("%s: named but has no row" % tid)
    for name in ("SECURITY.md", "README.md"):
        p = os.path.join(root, name)
        if "docs/security/threat-model.md" not in (open(p, encoding="utf-8").read() if os.path.isfile(p) else ""):
            errs.append("%s does not link to the threat model" % name)
    return errs


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    ap.add_argument("--doc")
    a = ap.parse_args()
    errs = check(a.root, a.doc or os.path.join(a.root, "docs", "security", "threat-model.md"))
    for e in errs:
        print("threat-model: " + e)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
