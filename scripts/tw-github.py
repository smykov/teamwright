#!/usr/bin/env python3
"""tw-github.py - the autonomous queue as GitHub sees it (stdlib only, read-only).

A task handed to the autonomous contour lives outside the repository: an open Issue with
the label `teamwright`, a `tw:<stage>` label for where its chain is, a run in Actions, a
pull request from `task/T-NNN`. /teamwright:progress and /teamwright:blockers read this so
a task whose chain has ended or died is not lost. Each Issue gets a state:

  queued    labelled, no chain has touched it yet
  running   a tw:<stage> label and an unfinished teamwright-agent run naming the task
  stalled   a tw:<stage> label and no such run: the chain died without saying so
  stopped   tw:stop - the chain waits for the owner
  failed    tw:failed - a stage failed; the queue does not move past it
  finished  tw:finish - the chain ended; the pull request is the owner's

  python3 tw-github.py [--project PATH] [--json]

`gh` missing, not logged in or no answer gives `checked: false` and the reason, never an
empty queue. TW_GH overrides the binary.
"""
import argparse
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
TASK_RE = re.compile(r"\bT-\d+\b")
LABEL = "teamwright"
TIMEOUT = 20


def _gh(project, *args):
    """(parsed JSON, None) or (None, why)."""
    try:
        p = subprocess.run([os.environ.get("TW_GH", "gh"), *args], cwd=project, capture_output=True,
                           text=True, timeout=TIMEOUT)
    except FileNotFoundError:
        return None, "gh is not installed"
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, "gh did not answer: %s" % e
    if p.returncode != 0:
        lines = (p.stderr or p.stdout or "gh failed").strip().splitlines()
        return None, lines[0][:200] if lines else "gh failed"
    try:
        return json.loads(p.stdout or "[]"), None
    except ValueError:
        return None, "gh returned something other than JSON"


def _has_github_remote(project):
    try:
        p = subprocess.run(["git", "remote", "-v"], cwd=project, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return "github.com" in p.stdout


def _state(labels, running):
    stages = [n[3:] for n in labels if n.startswith("tw:")]
    for s in ("failed", "stop", "finish"):
        if s in stages:
            return {"failed": "failed", "stop": "stopped", "finish": "finished"}[s]
    if not stages:
        return "running" if running else "queued"
    return "running" if running else "stalled"


def _last_comment(issue):
    comments = issue.get("comments") or []
    body = (comments[-1].get("body") or "") if comments else ""
    for line in body.splitlines():
        if line.strip():
            return line.strip()[:300]
    return ""


def queue(project):
    if not _has_github_remote(project):
        return {"checked": False, "applicable": False, "reason": "no GitHub remote"}
    issues, why = _gh(project, "issue", "list", "--state", "open", "--limit", "200",
                      "--json", "number,title,labels,url,comments")
    if why:
        return {"checked": False, "applicable": True, "reason": why}
    runs, why = _gh(project, "run", "list", "--workflow", "teamwright-agent.yml", "--limit", "30",
                    "--json", "status,displayTitle,url")
    if why:
        # no such workflow: nothing runs here, Issues can still be read
        if "not found" not in why.lower():
            return {"checked": False, "applicable": True, "reason": why}
        runs = []
    prs, why = _gh(project, "pr", "list", "--state", "open", "--limit", "100",
                   "--json", "number,title,headRefName,url")
    if why:
        return {"checked": False, "applicable": True, "reason": why}
    active = set()
    for r in runs:
        if r.get("status") != "completed":
            active.update(TASK_RE.findall(r.get("displayTitle") or ""))
    out, unlabelled = [], []
    for i in issues:
        m = TASK_RE.search(i.get("title") or "")
        names = [l.get("name") or "" for l in i.get("labels") or []]
        if LABEL not in names:
            if m and i.get("title", "").startswith(m.group(0) + ":"):
                unlabelled.append({"number": i["number"], "task": m.group(0), "url": i.get("url")})
            continue
        task = m.group(0) if m else None
        out.append({"number": i["number"], "task": task, "title": i.get("title"), "url": i.get("url"),
                    "state": _state(names, task in active), "note": _last_comment(i),
                    "stage": next((n[3:] for n in names if n.startswith("tw:")), None)})
    out.sort(key=lambda x: x["number"])
    task_prs = []
    for p in prs:
        m = re.fullmatch(r"task/(T-\d+)(?:-.*)?", p.get("headRefName") or "")
        if m:
            task_prs.append({"number": p["number"], "task": m.group(1), "title": p.get("title"), "url": p.get("url")})
    counts = {}
    for x in out:
        counts[x["state"]] = counts.get(x["state"], 0) + 1
    return {"checked": True, "applicable": True, "issues": out, "pull_requests": task_prs,
            "unlabelled": unlabelled, "counts": counts}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project", default=os.getcwd())
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    q = queue(os.path.abspath(args.project))
    print(json.dumps(q, indent=2, ensure_ascii=False) if args.json else
          (", ".join("%s %d" % kv for kv in q.get("counts", {}).items()) or "empty") if q["checked"]
          else "not checked: " + q["reason"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
