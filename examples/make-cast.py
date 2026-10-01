#!/usr/bin/env python3
"""Record examples/demo.sh as an asciinema v2 cast, with reading pauses.

    python3 examples/make-cast.py demo.cast
    agg --font-size 16 demo.cast docs/assets/demo.gif     # https://github.com/asciinema/agg

The demo runs once, for real; this script only adds timing: a typed command line, a
pause before each step and each action, and a longer one after every gate decision.
The text is the demo's output unchanged. Python 3 standard library only.
"""
import json
import os
import re
import subprocess
import sys

COLS, ROWS = 86, 32
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make-cast.py OUT.cast")
    kit = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = dict(os.environ, DEMO_COLOR="1")
    run = subprocess.run(["bash", os.path.join(kit, "examples", "demo.sh")], env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    if run.returncode != 0:
        sys.stdout.write(run.stdout.decode("utf-8", "replace"))
        sys.exit("demo failed, no cast written")
    lines = run.stdout.decode("utf-8").splitlines()

    t, events = 0.5, []

    def out(text, delay):
        nonlocal t
        t += delay
        events.append([round(t, 3), "o", text])

    for ch in "$ bash examples/demo.sh":
        out(ch, 0.06)
    out("\r\n", 0.4)
    in_deny = False                     # inside a gate's DENIED block
    chunk, pending = [], 0.0

    def flush():
        if chunk:
            out("".join(x + "\r\n" for x in chunk), pending)
            del chunk[:]

    for line in lines:
        plain = ANSI.sub("", line)
        if in_deny and plain.startswith("      "):
            delay = 0.35                                  # the gate's reason
        elif in_deny:
            delay, in_deny = 2.4, False                   # time to read it
        elif plain.startswith("== "):
            delay = 1.8
        elif plain.startswith("> "):
            delay = 0.9
        elif re.match(r"  \S.*\S {2,}\S", plain):
            delay = 0.3                                   # metrics rows
        else:
            delay = 0.15
        if "DENIED by" in plain:
            in_deny = True
        # fewer, larger frames keep the GIF small: short delays join the pending chunk
        if delay < 0.5 and chunk:
            chunk.append(line)
            pending += delay
        else:
            flush()
            chunk, pending = [line], delay
    flush()
    out("", 3.0)

    header = {"version": 2, "width": COLS, "height": ROWS,
              "title": "teamwright demo: one task through every gate",
              "env": {"TERM": "xterm-256color", "SHELL": "/bin/bash"}}
    with open(sys.argv[1], "w", encoding="utf-8") as fh:
        fh.write(json.dumps(header) + "\n")
        for e in events:
            fh.write(json.dumps(e) + "\n")
    print("%s: %d events, %.0f s" % (sys.argv[1], len(events), t))


if __name__ == "__main__":
    main()
