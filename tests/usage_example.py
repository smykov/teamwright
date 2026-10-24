#!/usr/bin/env python3
"""Checks for the autonomous-run example in docs/usage.md (tests/test-usage-example.sh).

  usage_example.py extract USAGE_MD OUT_DIR
      parse the YAML block under "### Autonomous runs", check its structure, and write
      route.sh (the "Ask the router" step's script), dispatch.sh (the step that starts
      the next stage, with its no-new-commit guard) and facts.json (step outputs it must
      print, the outputs other steps read, the dispatched workflow file, the CLI flags the
      steps use, whether the journal is cached) into OUT_DIR. Exit 1 with the reasons on a
      structural error: also when nothing keeps .teamwright/logs between jobs, no step
      creates the wip/ branch, or the dispatch has no guard.

PyYAML is used when it is installed (unless TW_YAML_LITE is set); otherwise a small parser for the subset the example
uses (block mappings and sequences, `|` block scalars, one-line `{ k: v }` mappings,
comments). Standard library only otherwise.
"""
import json
import os
import re
import sys


def yaml_block(md):
    m = re.search(r"^### Autonomous runs.*?^```yaml\n(.*?)^```", md, re.S | re.M)
    return m.group(1) if m else None


def _strip_comment(line):
    out, q = [], None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
        elif ch in "'\"":
            q = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(ch)
    return "".join(out).rstrip()


def _scalar(v):
    v = v.strip()
    if v.startswith("{") and v.endswith("}"):
        d = {}
        for part in v[1:-1].split(","):
            if part.strip():
                k, _, x = part.partition(":")
                d[k.strip()] = _scalar(x)
        return d
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        return v[1:-1]
    if re.search(r":(\s|$)", v):
        raise ValueError("a plain scalar with `: ` inside is not valid YAML; quote it: %r" % v)
    if v in ("true", "false"):
        return v == "true"
    if re.match(r"^-?\d+$", v):
        return int(v)
    return v if v else None


def lite_load(text):
    """The YAML subset of the example -> Python objects."""
    raw = text.split("\n")
    lines = []          # (indent, text, raw index)
    for i, l in enumerate(raw):
        s = _strip_comment(l)
        if s.strip():
            lines.append((len(s) - len(s.lstrip(" ")), s.strip(), i))

    def block_scalar(start_raw, parent_indent):
        body, ind = [], None
        for l in raw[start_raw + 1:]:
            if l.strip() and (len(l) - len(l.lstrip(" "))) <= parent_indent:
                break
            if ind is None and l.strip():
                ind = len(l) - len(l.lstrip(" "))
            body.append(l)
        while body and not body[-1].strip():
            body.pop()
        ind = ind or 0
        return "\n".join(b[ind:] for b in body) + "\n", start_raw + 1 + len(body)

    pos = [0]

    def parse(indent):
        if pos[0] >= len(lines):
            return None
        if lines[pos[0]][1].startswith("- "):
            return parse_seq(indent)
        return parse_map(indent)

    def value_after(key_indent, rest, raw_i):
        if rest == "|":
            text, end = block_scalar(raw_i, key_indent)
            while pos[0] < len(lines) and lines[pos[0]][2] < end:
                pos[0] += 1
            return text
        if rest:
            return _scalar(rest)
        if pos[0] < len(lines) and lines[pos[0]][0] > key_indent:
            return parse(lines[pos[0]][0])
        if pos[0] < len(lines) and lines[pos[0]][0] == key_indent and lines[pos[0]][1].startswith("- "):
            return parse_seq(key_indent)
        return None

    def parse_map(indent, first=None):
        d = {}
        while pos[0] < len(lines):
            ind, s, ri = lines[pos[0]]
            if first is not None:
                ind, s, first = indent, first, None
            elif ind != indent or s.startswith("- "):
                break
            k, sep, rest = s.partition(":")
            if not sep:
                raise ValueError("line %d: expected `key: value`: %r" % (ri + 1, s))
            pos[0] += 1
            d[_scalar(k)] = value_after(indent, rest.strip(), ri)
        return d

    def parse_seq(indent):
        out = []
        while pos[0] < len(lines):
            ind, s, ri = lines[pos[0]]
            if ind != indent or not s.startswith("- "):
                break
            item = s[2:].strip()
            if ":" in item and not item.startswith("{"):
                k, _, rest = item.partition(":")
                pos[0] += 1
                d = {_scalar(k): value_after(indent + 2, rest.strip(), ri)}
                if pos[0] < len(lines) and lines[pos[0]][0] == indent + 2 and not lines[pos[0]][1].startswith("- "):
                    d.update(parse_map(indent + 2))
                out.append(d)
            else:
                pos[0] += 1
                out.append(_scalar(item))
        return out

    doc = parse(lines[0][0]) if lines else None
    if pos[0] != len(lines):
        raise ValueError("line %d: unexpected indentation" % (lines[pos[0]][2] + 1))
    return doc


def load(text):
    if os.environ.get("TW_YAML_LITE"):
        return lite_load(text), "subset parser"
    try:
        import yaml  # noqa: F401
    except ImportError:
        return lite_load(text), "subset parser"
    import yaml
    d = yaml.safe_load(text)
    if True in d and "on" not in d:   # YAML 1.1: the key `on` loads as True
        d["on"] = d.pop(True)
    return d, "PyYAML"


def main(argv):
    if len(argv) != 4 or argv[1] != "extract":
        print(__doc__)
        return 2
    md = open(argv[2], encoding="utf-8").read()
    text = yaml_block(md)
    errs = []
    if text is None:
        print("no ```yaml block under '### Autonomous runs' in %s" % argv[2])
        return 1
    try:
        doc, how = load(text)
    except Exception as e:  # noqa: BLE001 - any parse error is the finding
        print("the example does not parse: %s" % e)
        return 1
    if not isinstance(doc, dict):
        print("the example is not a mapping")
        return 1
    if "workflow_dispatch" not in (doc.get("on") or {}):
        errs.append("on: workflow_dispatch missing (the next stage is dispatched)")
    if not doc.get("concurrency"):
        errs.append("concurrency missing (one stage at a time)")
    perms = doc.get("permissions") or {}
    for p in ("contents", "actions"):
        if perms.get(p) != "write":
            errs.append("permissions.%s: write missing" % p)
    jobs = doc.get("jobs") or {}
    steps = [s for j in jobs.values() for s in (j.get("steps") or [])] if isinstance(jobs, dict) else []
    route = [s for s in steps if s.get("id") == "route"]
    if len(route) != 1 or not isinstance(route[0].get("run"), str):
        errs.append("exactly one step with id: route and a run script")
    printed = set(re.findall(r'print\("(\w+)=', route[0]["run"])) if route else set()
    used = set(re.findall(r"steps\.route\.outputs\.(\w+)", text))
    for o in sorted(used - printed):
        errs.append("steps.route.outputs.%s is read but the route step never prints it" % o)
    # the journal and ledgers survive the job boundary: a cache of .teamwright/logs, or a
    # checkout that does not clean the workspace
    cached = any(isinstance(s.get("with"), dict) and ".teamwright/logs" in str(s["with"].get("path") or "")
                 for s in steps if str(s.get("uses") or "").startswith("actions/cache"))
    unclean = any(isinstance(s.get("with"), dict) and s["with"].get("clean") is False
                  for s in steps if str(s.get("uses") or "").startswith("actions/checkout"))
    if not (cached or unclean):
        errs.append("nothing keeps .teamwright/logs between jobs (actions/cache or checkout clean: false)")
    # the work branch is created when it does not exist yet
    if not any("refs/heads/wip/" in str(s.get("run") or "") for s in steps):
        errs.append("no step creates the wip/ branch when it is missing")
    # no new commit -> stop: the dispatching step compares HEAD with the route step's head
    disp = [s for s in steps if "gh workflow run" in str(s.get("run") or "")]
    if disp and not all("steps.route.outputs.head" in json.dumps(s) and "rev-parse HEAD" in str(s.get("run"))
                        for s in disp):
        errs.append("the step that dispatches the next stage does not stop when the stage made no commit")
    dispatched = re.findall(r"gh workflow run (\S+)", text)
    m = re.search(r"saved as `\.github/workflows/([^`]+)`", md)
    if not dispatched:
        errs.append("no `gh workflow run <file>`: the chain does not continue")
    elif not m:
        errs.append("docs/usage.md does not say the file name the example is saved as")
    elif any(d != m.group(1) for d in dispatched):
        errs.append("dispatches %s, but the example is saved as %s" % (", ".join(dispatched), m.group(1)))
    flags = sorted(set(re.findall(r"--[a-z][a-z-]+", " ".join(
        str(s.get("with", {}).get("claude_args", "")) for s in steps if isinstance(s.get("with"), dict)))))
    os.makedirs(argv[3], exist_ok=True)
    if route:
        with open(os.path.join(argv[3], "route.sh"), "w") as fh:
            fh.write(route[0]["run"])
    if disp:
        with open(os.path.join(argv[3], "dispatch.sh"), "w") as fh:
            fh.write(disp[0]["run"])
    with open(os.path.join(argv[3], "facts.json"), "w") as fh:
        json.dump({"parser": how, "printed": sorted(printed), "used": sorted(used),
                   "claude_flags": flags, "dispatched": dispatched, "cached": cached,
                   "unclean": unclean}, fh)
    for e in errs:
        print(e)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
