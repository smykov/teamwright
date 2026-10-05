#!/usr/bin/env python3
"""tw-parallel.py - tasks in parallel, each in its own worktree and session (stdlib only).

The gates hold one active task per working tree, so parallel work means separate
working trees: each task gets a git worktree on branch `tw/<ID>` and its own Claude Code
session there (`/teamwright:flow <ID>`), with its own hooks, journal and current task.
The main session coordinates: it analyses the candidates in the main tree, groups those
whose seams do not overlap, starts the worktrees, and merges each branch back when its
task is approved, running the gate after every merge.

  python3 tw-parallel.py plan   [--project P] [--json]     group of analysed, disjoint tasks
  python3 tw-parallel.py start  ID [ID ...] [--project P]  create worktrees + branches
  python3 tw-parallel.py status [--project P] [--json]     worktrees, task status on each branch
  python3 tw-parallel.py logs   ID [--project P]           append the worktree's journal to the main one

Seams: path-like tokens in `analysis.seam` (a file, or a directory with a trailing part);
two tasks overlap when a path of one equals or contains a path of the other. A seam
with no path (a symbol name, prose) overlaps everything: that task runs alone.
Group size: `process.batch.parallel` (default 1 = no parallel work).
"""
import argparse
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(KIT, "template", "scripts", "hooks"))
import _config  # noqa: E402
import _task  # noqa: E402

BRANCH = "tw/"
APPROVED = ("CODE_COMPLETE", "DEPLOYED", "VERIFIED", "DONE")
PRIO = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
PATH_RE = re.compile(r"[A-Za-z0-9_.@-]+(?:/[A-Za-z0-9_.@-]+)+/?|[A-Za-z0-9_@-]+\.[A-Za-z0-9]{1,6}\b")


def git(project, *args):
    r = subprocess.run(["git", "-C", project] + list(args), capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def seam_paths(seam):
    """Path-like tokens of a seam, normalised (no backticks, no leading ./, no :line)."""
    out = set()
    for tok in PATH_RE.findall(str(seam or "").replace("`", " ")):
        tok = re.sub(r":\d+.*$", "", tok).lstrip("./").rstrip("/")
        if tok and not re.fullmatch(r"\d+(\.\d+)*", tok):
            out.add(tok)
    return out


def overlap(a, b):
    """Paths overlap: equal, or one is inside the other. Unknown seam (empty) overlaps all."""
    if not a or not b:
        return True
    return any(x == y or x.startswith(y + "/") or y.startswith(x + "/") for x in a for y in b)


def worktrees(project):
    """{task id: {path, branch}} for worktrees on tw/<ID> branches."""
    rc, out, _ = git(project, "worktree", "list", "--porcelain")
    res, cur = {}, {}
    for line in (out.splitlines() + [""]) if rc == 0 else []:
        if line.startswith("worktree "):
            cur = {"path": line[9:]}
        elif line.startswith("branch "):
            cur["branch"] = line[7:].replace("refs/heads/", "")
        elif not line.strip() and cur:
            br = cur.get("branch", "")
            if br.startswith(BRANCH):
                res[br[len(BRANCH):]] = cur
            cur = {}
    return res


def tasks_in(project):
    d = os.path.join(project, "docs", "tasks")
    out = {}
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not f.endswith(".md") or f.startswith("_"):
            continue
        with open(os.path.join(d, f), encoding="utf-8", errors="replace") as fh:
            rec = _task.parse(fh.read())
        tid = rec.get("id") if isinstance(rec.get("id"), str) and rec.get("id") else f[:-3]
        an = rec.get("analysis") if isinstance(rec.get("analysis"), dict) else {}
        out[tid] = {"id": tid, "status": _task.status(rec) or "TODO",
                    "priority": str(rec.get("priority") or "P2").strip(),
                    "analysis_ok": not _task.analysis_missing(rec),
                    "seam": str(an.get("seam") or ""), "rec": rec}
    return out


def _num(tid):
    m = re.search(r"(\d+)$", tid)
    return int(m.group(1)) if m else 0


def plan(project):
    proc = _config.read_process(os.path.join(project, _config.CONFIG))
    n = proc["batch"]["parallel"]
    wts = worktrees(project)
    tasks = tasks_in(project)
    busy = {tid: seam_paths(tasks[tid]["seam"]) if tid in tasks else set() for tid in wts}
    cands = sorted((t for t in tasks.values() if t["status"] == "ANALYSIS" and t["analysis_ok"] and t["id"] not in wts),
                   key=lambda t: (PRIO.get(t["priority"], 9), _num(t["id"])))
    group, skipped = [], []
    room = max(n - len(wts), 0)
    for t in cands:
        paths = seam_paths(t["seam"])
        clash = [g["id"] for g in group if overlap(paths, g["paths"])] + \
                [b for b, bp in busy.items() if overlap(paths, bp)]
        if not paths:
            skipped.append({"task": t["id"], "why": "seam names no path: runs alone, in the main tree"})
        elif clash:
            skipped.append({"task": t["id"], "why": "seam overlaps " + ", ".join(clash)})
        elif len(group) >= room:
            skipped.append({"task": t["id"], "why": "parallel limit %d reached" % n})
        else:
            group.append({"id": t["id"], "priority": t["priority"], "paths": paths})
    waiting_analysis = [t["id"] for t in tasks.values() if t["status"] == "ANALYSIS" and not t["analysis_ok"]]
    return {"parallel": n, "running": sorted(wts), "group": [dict(g, paths=sorted(g["paths"])) for g in group],
            "skipped": skipped, "analysis_incomplete": waiting_analysis,
            "note": "process.batch.parallel is 1: parallel work is off" if n <= 1 else ""}


def base_dir(project):
    return os.path.join(os.path.dirname(os.path.abspath(project)),
                        os.path.basename(os.path.abspath(project)) + ".worktrees")


def start(project, ids):
    p = plan(project)
    allowed = {g["id"] for g in p["group"]}
    out = []
    for tid in ids:
        if tid not in allowed:
            out.append({"task": tid, "error": "not in the current parallel group (run plan)"})
            continue
        path = os.path.join(base_dir(project), tid)
        rc, _, err = git(project, "worktree", "add", "-b", BRANCH + tid, path, "HEAD")
        out.append({"task": tid, "path": path, "branch": BRANCH + tid,
                    "launch": "cd %s && claude \"/teamwright:flow %s\"" % (path, tid)} if rc == 0 else
                   {"task": tid, "error": err})
    return out


def status(project):
    _, main_branch, _ = git(project, "rev-parse", "--abbrev-ref", "HEAD")
    res = []
    for tid, wt in sorted(worktrees(project).items()):
        rc, text, _ = git(project, "show", "%s:docs/tasks/%s.md" % (wt["branch"], tid))
        st = _task.status(_task.parse(text)) if rc == 0 else ""
        _, ahead, _ = git(project, "rev-list", "--count", "%s..%s" % (main_branch, wt["branch"]))
        _, behind, _ = git(project, "rev-list", "--count", "%s..%s" % (wt["branch"], main_branch))
        _, dirty, _ = git(wt["path"], "status", "--porcelain")
        res.append({"task": tid, "path": wt["path"], "branch": wt["branch"], "status": st,
                    "ahead": int(ahead or 0), "behind": int(behind or 0),
                    "dirty": len([l for l in dirty.splitlines() if l and not l[3:].startswith(".teamwright/")]),
                    "ready_to_merge": st in APPROVED})
    return {"main": main_branch, "worktrees": res}


def logs(project, tid):
    """Append the worktree's .teamwright/logs/*.jsonl to the main tree's journal before the
    worktree is removed, so metrics keep the sessions that ran there."""
    wt = worktrees(project).get(tid)
    if not wt:
        return {"task": tid, "error": "no worktree for %s" % tid}
    src = os.path.join(wt["path"], ".teamwright", "logs")
    dst = os.path.join(project, ".teamwright", "logs")
    moved = {}
    if os.path.isdir(src):
        os.makedirs(dst, exist_ok=True)
        for f in sorted(os.listdir(src)):
            if f.endswith(".jsonl"):
                with open(os.path.join(src, f), encoding="utf-8", errors="replace") as fh:
                    data = fh.read()
                if data:
                    with open(os.path.join(dst, f), "a", encoding="utf-8") as fh:
                        fh.write(data if data.endswith("\n") else data + "\n")
                    moved[f] = data.count("\n") + (0 if data.endswith("\n") else 1)
    return {"task": tid, "appended": moved}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("command", choices=("plan", "start", "status", "logs"))
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--project", default=os.getcwd())
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    project = os.path.abspath(a.project)
    if a.command == "plan":
        r = plan(project)
    elif a.command == "start":
        r = start(project, a.ids)
    elif a.command == "status":
        r = status(project)
    else:
        r = [logs(project, t) for t in a.ids]
    print(json.dumps(r, indent=2, ensure_ascii=False))
    errors = r if isinstance(r, list) else []
    return 1 if any(isinstance(x, dict) and x.get("error") for x in errors) else 0


if __name__ == "__main__":
    sys.exit(main())
