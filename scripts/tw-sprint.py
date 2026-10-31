#!/usr/bin/env python3
"""tw-sprint.py - candidates for the autonomous queue, and their Issues (stdlib only).

A sprint for the autonomous contour is the set of open Issues labelled `teamwright`. The
script does the deterministic part: what can go into the queue, what cannot and why, what
would stop a chain, and what must happen first. /teamwright:sprint chooses with the owner.

  python3 tw-sprint.py [list] [--project P] [--json]        candidates, excluded, warnings
  python3 tw-sprint.py issues ID [ID ...] [--project P]     an Issue per task, no label: nothing starts
  python3 tw-sprint.py issues ID [ID ...] --start           the same, with the label: the queue starts

--start refuses while the local default branch has commits the remote lacks, or a task is not
a candidate: the queue works from the remote's default branch and each label spends money.

The current sprint is every open Issue labelled `teamwright` and every open pull request from a
task branch. While it is not empty, `issues` refuses: `--add-to-current` is the owner's explicit
decision to add to it. The Issue closes when its pull request is merged and nothing is left to do.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(HERE)
LABEL = "teamwright"
PERSON_RE = re.compile(r"(?i)\b(real device|physical device|real phone|on a phone|android|ios|manual(ly)?|by hand|"
                       r"production|api key|credentials?)\b|телефон|устройств|вручную|на проде|боев")


def _load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _record_text(project, tid):
    try:
        with open(os.path.join(project, "docs", "tasks", tid + ".md"), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def _git(project, *args):
    r = subprocess.run(["git", "-C", project] + list(args), capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def unpushed(project, ref):
    """Commits on the local HEAD that the remote default branch lacks; None when unknown."""
    if not ref:
        return None
    rc, out = _git(project, "rev-list", "--count", "%s..HEAD" % ref)
    return int(out) if rc == 0 and out.isdigit() else None


def collect(project):
    nxt, par, gh = _load("tw-next"), _load("tw-parallel"), _load("tw-github")
    sys.path.insert(0, os.path.join(KIT, "template", "scripts", "hooks"))
    import _task as task
    tasks = nxt.load_tasks(project, task)
    if tasks is None:
        return None
    oqs = nxt.open_questions(project)
    eff = nxt.effective_priority(tasks)
    areas = nxt.config_areas(project)
    queue = gh.queue(project)
    queued = {i["task"]: i for i in queue.get("issues") or [] if i.get("task")}
    open_ids = {t["id"] for t in tasks.values() if t["status"] not in nxt.CLOSED}

    candidates, excluded = [], []
    for t in nxt._sorted(tasks.values()):
        tid = t["id"]
        if t["status"] in nxt.CLOSED:
            continue
        waiting = [d for d in t["depends_on"] if d in open_ids]
        missing = [d for d in t["depends_on"] if d not in tasks]
        blocked = nxt.blockers(t, oqs)
        why = None
        if tid in queued:
            i = queued[tid]
            if i["state"] != "finished":
                why = "already in the queue: Issue #%s, %s" % (i["number"], i["state"])
        if not why and t["status"] == "BLOCKED":
            why = "BLOCKED: %s" % (t["blocked_on"] or "no reason recorded")
        if not why and blocked:
            why = "blocked_on: %s" % ", ".join(blocked)
        if not why and missing:
            why = "depends_on a task with no record: %s" % ", ".join(missing)
        if why:
            excluded.append({"id": tid, "title": t["title"], "reason": why})
            continue
        paths = sorted(par.seam_paths(t.get("seam")))
        risks = []
        text = _record_text(project, tid)
        acceptance = task.section(text, "Acceptance") if hasattr(task, "section") else ""
        if PERSON_RE.search("%s\n%s" % (t["title"], acceptance)):
            risks.append("Acceptance may need a person, a device or production")
        pending = [q for q in t["mentions_oq"] if not nxt.oq_resolved(oqs, q)]
        if pending:
            risks.append("mentions unresolved %s" % ", ".join(pending))
        if t["surface"] in ("ui", "both"):
            risks.append("surface %s: verify needs the project's UI runner in the contour" % t["surface"])
        if not paths:
            risks.append("seam names no path: analysis decides, until then it overlaps everything")
        if t["deploys"] and t["status"] != "CODE_COMPLETE":
            risks.append("deploys: verify runs only after its pull request is merged")
        candidates.append({
            "id": tid, "title": t["title"], "type": t["type"], "status": t["status"],
            "stage": nxt.stage_of(t)[0], "priority": t["priority"],
            "effective_priority": "P%d" % eff[tid][0] if tid in eff else t["priority"],
            "unblocks": eff[tid][2] if tid in eff else 0, "surface": t["surface"], "deploys": t["deploys"],
            "depends_on": t["depends_on"], "waits_for": waiting, "seam_paths": paths,
            "areas": [n for n, dirs in areas if any(p == d or p.startswith(d + "/") for p in paths for d in dirs)],
            "acceptance_items": t.get("acceptance_items", 0), "risks": risks, "overlaps": [],
            "issue": queued[tid]["number"] if tid in queued else None,
        })
    for a in candidates:
        for b in candidates:
            if a is not b and a["seam_paths"] and b["seam_paths"] and \
                    par.overlap(set(a["seam_paths"]), set(b["seam_paths"])):
                a["overlaps"].append(b["id"])

    # the router allows one IN_PROGRESS per tree and task branches start from the default branch
    wip = [t["id"] for t in nxt._sorted(tasks.values()) if t["status"] == "IN_PROGRESS"]
    ref = nxt.default_ref(project)
    ahead = unpushed(project, ref)
    warnings = []
    if len(wip) >= 1:
        warnings.append("IN_PROGRESS on this branch: %s. Every task started from it waits until that task's pull "
                        "request is merged: put it first" % ", ".join(wip))
    if ahead:
        warnings.append("%d local commit(s) are not on %s: the queue does not see them, push first"
                        % (ahead, ref.replace("refs/remotes/", "")))
    if not queue.get("checked"):
        warnings.append("GitHub not checked: %s" % (queue.get("reason") or "unknown"))
    for i in queue.get("issues") or []:
        if i["state"] == "failed":
            warnings.append("Issue #%s failed: a failed chain stops the queue taking new tasks" % i["number"])
    current = [{"task": i["task"], "issue": i["number"], "state": i["state"], "stage": i.get("stage"),
                "note": i.get("note"), "url": i.get("url")} for i in queue.get("issues") or []]
    prs = queue.get("pull_requests") or []
    return {"current_sprint": {"active": bool(current or prs), "issues": current, "pull_requests": prs},
            "candidates": candidates, "excluded": excluded, "warnings": warnings, "in_progress": wip,
            "unpushed": ahead, "queue_checked": bool(queue.get("checked")), "unlabelled": queue.get("unlabelled") or []}


def run_gh(project, *args):
    r = subprocess.run([os.environ.get("TW_GH", "gh")] + list(args), cwd=project, capture_output=True, text=True)
    return r.returncode, (r.stdout or r.stderr).strip()


def issues(project, ids, start, add_to_current=False):
    data = collect(project)
    if data is None:
        print("tw-sprint: no docs/tasks here", file=sys.stderr)
        return 2
    if not data["queue_checked"]:
        print("tw-sprint: GitHub not checked, nothing created", file=sys.stderr)
        return 2
    cur = data["current_sprint"]
    if cur["active"] and not add_to_current:
        print("tw-sprint: the current sprint is not finished (%d Issue(s), %d pull request(s)): finish it, or "
              "--add-to-current on the owner's decision" % (len(cur["issues"]), len(cur["pull_requests"])),
              file=sys.stderr)
        return 3
    if start and data["unpushed"]:
        print("tw-sprint: %d local commit(s) are not on the remote: push first" % data["unpushed"], file=sys.stderr)
        return 2
    by_id = {c["id"]: c for c in data["candidates"]}
    bad = [i for i in ids if i not in by_id]
    if bad:
        why = {e["id"]: e["reason"] for e in data["excluded"]}
        for i in bad:
            print("tw-sprint: %s is not a candidate: %s" % (i, why.get(i, "no open task")), file=sys.stderr)
        return 2
    existing = {u["task"]: u["number"] for u in data["unlabelled"]}
    rc = 0
    for tid in ids:
        c = by_id[tid]
        number = existing.get(tid)
        if number is None:
            args = ["issue", "create", "--title", "%s: %s" % (tid, c["title"]),
                    "--body", "Task record: `docs/tasks/%s.md`." % tid]
            if start:
                args += ["--label", LABEL]
            code, out = run_gh(project, *args)
            print("%s: %s" % (tid, out))
        elif start:
            code, out = run_gh(project, "issue", "edit", str(number), "--add-label", LABEL)
            print("%s: Issue #%s labelled" % (tid, number) if code == 0 else "%s: %s" % (tid, out))
        else:
            code = 0
            print("%s: Issue #%s already open" % (tid, number))
        rc = rc or code
    return 1 if rc else 0


def show(data):
    cur = data["current_sprint"]
    if cur["active"]:
        print("current sprint is not finished: finish it before forming a new one")
        for i in cur["issues"]:
            print("  %s Issue #%s %s%s" % (i["task"] or "-", i["issue"], i["state"],
                                           ": %s" % i["note"] if i["note"] else ""))
        for r in cur["pull_requests"]:
            print("  %s pull request #%s waits for a merge" % (r["task"], r["number"]))
    for w in data["warnings"]:
        print("warning: %s" % w)
    print("candidates: %d" % len(data["candidates"]))
    for c in data["candidates"]:
        print("  %s %s %s %s/%s %s" % (c["id"], c["effective_priority"], c["status"], c["type"] or "-",
                                       c["surface"] or "-", c["title"]))
        for label, value in (("waits for", c["waits_for"]), ("overlaps", c["overlaps"]), ("risk", c["risks"])):
            if value:
                print("    %s: %s" % (label, "; ".join(value)))
    print("excluded: %d" % len(data["excluded"]))
    for e in data["excluded"]:
        print("  %s %s" % (e["id"], e["reason"]))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", nargs="?", default="list", choices=("list", "issues"))
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--project", default=os.getcwd())
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--start", action="store_true", help="issues: set the label, the queue starts")
    ap.add_argument("--add-to-current", action="store_true",
                    help="issues: add to an unfinished sprint (the owner's explicit decision)")
    a = ap.parse_args(argv)
    project = os.path.abspath(a.project)
    if a.cmd == "issues":
        if not a.ids:
            ap.error("issues: name the tasks")
        return issues(project, a.ids, a.start, a.add_to_current)
    data = collect(project)
    if data is None:
        print("tw-sprint: no docs/tasks here", file=sys.stderr)
        return 2
    if a.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        show(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
