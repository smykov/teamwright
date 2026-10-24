#!/usr/bin/env python3
"""check-versions.py - the version rule of the plugin manifests, per release channel.

WHY. Claude Code computes a plugin's version from plugin.json `version`, else the
marketplace entry's `version`, else (git sources) the commit SHA; `/plugin update` acts
only when that computed version changes. The two channels need opposite rules:

  stable  (marketplace `teamwright`, branch main): plugin.json and the marketplace entry
          carry the same `version`, and CHANGELOG.md has a `## [x.y.z]` section for it -
          a shipped change without a bump never reaches users.
  channel (marketplace `teamwright-<channel>`, e.g. `teamwright-next` on branch next):
          NO `version` in either file - a fixed version would keep users on the cached
          copy while the branch moves; without it every pushed commit is a new version.

The channel is read from the marketplace name, not from the git branch: CI checks out a
detached HEAD. Prints the channel and the version rule it checked; exit 1 on a violation.
Usage: check-versions.py [--root DIR] [--channel]   (--channel: print only the channel)
"""
import json
import os
import re
import sys


def load(root):
    pj = json.load(open(os.path.join(root, ".claude-plugin", "plugin.json"), encoding="utf-8"))
    mj = json.load(open(os.path.join(root, ".claude-plugin", "marketplace.json"), encoding="utf-8"))
    return pj, mj


def channel_of(pj, mj):
    """'stable', a channel name ('next'), or None for a marketplace name that is neither."""
    name, mname = pj.get("name") or "", mj.get("name") or ""
    if mname == name:
        return "stable"
    m = re.match(r"^%s-([a-z][a-z0-9-]*)$" % re.escape(name), mname)
    return m.group(1) if m else None


def main(argv):
    root = "."
    if "--root" in argv:
        root = argv[argv.index("--root") + 1]
    try:
        pj, mj = load(root)
    except (OSError, ValueError) as e:
        print("check-versions: cannot read the manifests: %s" % e)
        return 1
    ch = channel_of(pj, mj)
    if "--channel" in argv:
        print(ch or "")
        return 0 if ch else 1
    name = pj.get("name") or ""
    entries = [p for p in mj.get("plugins") or [] if p.get("name") == name]
    errs = []
    if ch is None:
        errs.append("marketplace name %r is neither %r (stable) nor %r-<channel>" % (
            mj.get("name"), name, name))
    elif len(entries) != 1:
        errs.append("marketplace.json needs exactly one entry named %r" % name)
    elif ch == "stable":
        v, mv = pj.get("version"), entries[0].get("version")
        if not v:
            errs.append("stable: plugin.json has no version")
        if mv != v:
            errs.append("stable: marketplace.json version %r differs from plugin.json %r" % (mv, v))
        try:
            text = open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8").read()
        except OSError:
            text = ""
        if v and not re.search(r"^## \[%s\]" % re.escape(v), text, re.M):
            errs.append("stable: CHANGELOG.md has no '## [%s]' section" % v)
        if not errs:
            print("version consistent (plugin.json, marketplace.json, CHANGELOG.md): %s" % v)
    else:
        for where, v in (("plugin.json", pj.get("version")), ("marketplace.json entry", entries[0].get("version"))):
            if v:
                errs.append("channel %s: %s has version %r - a channel carries no version, so every "
                            "commit is a new version for /plugin update" % (ch, where, v))
        if not errs:
            print("channel %s (marketplace %s): no fixed version - the commit SHA is the version"
                  % (ch, mj.get("name")))
    for e in errs:
        print("check-versions: " + e)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
