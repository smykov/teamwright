#!/usr/bin/env python3
"""check-links.py - relative links and anchors in the kit's Markdown resolve (stdlib only).

  python3 scripts/check-links.py [--root PATH]

Checks every tracked or untracked (not ignored) *.md file:
  - [text](path) and [text](path#anchor) point to an existing file, and the anchor
    to a heading in it (GitHub rules: lowercase, punctuation removed, spaces -> -,
    repeated headings get -1, -2 ...);
  - links to a URL, and targets with a <placeholder>, are skipped;
  - fenced code blocks and inline code are ignored.
Files copied into projects (docs/process/*.md except plugin.md, template/**) must not
name kit paths such as `template/...`: in a project those files live elsewhere.
Exit 1 with one line per problem.
"""
import argparse
import os
import re
import subprocess
import sys

LINK = re.compile(r"(?<!\!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
IMAGE = re.compile(r"\!\[[^\]]*\]\(([^)\s]+)\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")
KIT_PATH = re.compile(r"`template/[^`]*`")


def md_files(root):
    out = subprocess.run(["git", "-C", root, "ls-files", "-co", "--exclude-standard", "*.md"],
                         capture_output=True, text=True, check=True).stdout
    return sorted(p for p in out.splitlines() if os.path.isfile(os.path.join(root, p)))


def prose_lines(text):
    """(line number, line) outside fenced code blocks, inline code removed."""
    fenced = False
    for i, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            yield i, line


def slug(heading):
    h = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading.strip().lower())
    h = re.sub(r"<[^>]+>", "", h).replace("`", "")
    h = re.sub(r"[^\w\- ]", "", h)
    return h.replace(" ", "-")


def anchors(path, cache={}):
    if path not in cache:
        seen, out = {}, set()
        with open(path, encoding="utf-8") as fh:
            for _, line in prose_lines(fh.read()):
                m = HEADING.match(line)
                if not m:
                    continue
                s = slug(m.group(2))
                n = seen.get(s, 0)
                out.add(s if n == 0 else "%s-%d" % (s, n))
                seen[s] = n + 1
        cache[path] = out
    return cache[path]


def installed(rel):
    return rel.startswith("template/") or (
        rel.startswith("docs/process/") and os.path.basename(rel) != "plugin.md")


def check(root):
    problems = []
    for rel in md_files(root):
        path = os.path.join(root, rel)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        for n, line in prose_lines(text):
            if installed(rel):
                for m in KIT_PATH.finditer(line):
                    problems.append("%s:%d: kit path %s in a file copied into projects"
                                    % (rel, n, m.group(0)))
            bare = re.sub(r"`[^`]*`", "", line)
            for target in LINK.findall(bare) + IMAGE.findall(bare):
                if re.match(r"^[a-z][a-z0-9+.-]*:", target) or "<" in target or "{{" in target:
                    continue
                file_part, _, anchor = target.partition("#")
                dest = os.path.normpath(os.path.join(os.path.dirname(path), file_part)) \
                    if file_part else path
                if not os.path.exists(dest):
                    problems.append("%s:%d: %s - no such file" % (rel, n, target))
                    continue
                if anchor and (os.path.isdir(dest) or not dest.endswith(".md")):
                    problems.append("%s:%d: %s - anchor on a non-Markdown target" % (rel, n, target))
                elif anchor and anchor not in anchors(dest):
                    problems.append("%s:%d: %s - no heading #%s in %s"
                                    % (rel, n, target, anchor, os.path.relpath(dest, root)))
    return problems


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = ap.parse_args(argv)
    problems = check(args.root)
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
