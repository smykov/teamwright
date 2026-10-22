#!/usr/bin/env python3
"""check-sh-names.py - no `$name` directly before a non-ASCII character in shell scripts (stdlib only).

  python3 scripts/check-sh-names.py FILE...

bash 3.2, the macOS default, takes the bytes of a following non-ASCII character
(for example the arrow in "$from→$to") as part of the variable name; under `set -u`
the script then dies with "unbound variable". Write "${from}→${to}" instead.
Linux CI does not see this (a bash:3.2 container runs in the C locale), so it is
checked here. Exit 1 with one line per problem.
"""
import re
import sys

PAT = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]")


def main(paths):
    bad = []
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                if PAT.search(line):
                    bad.append(f"{path}:{n}: $name before a non-ASCII character, use ${{name}}")
    for b in bad:
        print(b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
