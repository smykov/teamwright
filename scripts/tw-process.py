#!/usr/bin/env python3
"""tw-process.py - what the process costs, for /teamwright:improve (stdlib only, read-only).

The facts teamwright-metrics does not compute, all from git and the records:

  findings      review findings by severity and category, and which of them returned
                the task (verdict REQUEST_CHANGES) - with the threshold in force when
                each round was written
  verdicts      review rounds by verdict; share of send-backs
  settings      when `process:` in .teamwright/config.yml changed (git history), so
                metrics can be split at those dates (teamwright-metrics --split-date)
  ratified      commits that set `tail_code: ratified` (each is a DRAIN false positive
                or a deliberate exception - worth reading)
  bookkeeping   share of commits that are `chore(task)` records
  records       task record sizes (every role re-reads them)
  follow_ups    open review follow-ups (unchecked items in tasks of class review-follow-up)

  python3 tw-process.py [--project PATH] [--json]
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

FOLLOW_UP_CLASS = "review-follow-up"


def git(project, *args):
    try:
        r = subprocess.run(["git", "-C", project] + list(args), capture_output=True, text=True)
        return r.stdout if r.returncode == 0 else ""
    except OSError:
        return ""


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def findings_of(text):
    """[(severity, category)] lower-cased; uncategorised rows get a category of their own."""
    return [(sv.strip().lower(), (c or "uncategorised").strip().lower()) for sv, c in _task.findings(text)]


def settings_history(project):
    """[(date, sha, effective process settings)] for each commit that changed them."""
    out, last = [], None
    for line in reversed(git(project, "log", "--format=%H %cs", "--", _config.CONFIG).splitlines()):
        sha, date = line.split()
        text = git(project, "show", "%s:%s" % (sha, _config.CONFIG))
        try:
            proc = _config.process_of(_config.parse_yaml(text))
        except ValueError:
            continue
        key = json.dumps({k: v for k, v in proc.items() if k != "explicit"}, sort_keys=True)
        if key != last:
            out.append({"date": date, "commit": sha[:8],
                        "settings": {k: v for k, v in proc.items() if k != "explicit"},
                        "explicit": proc["explicit"]})
            last = key
    return out


def blocking_when_written(project, rel):
    """Threshold in the config of the commit that added the record (the working tree's
    config when the record is not committed yet)."""
    sha = git(project, "log", "--diff-filter=A", "--format=%H", "-1", "--", rel).strip()
    if sha:
        text = git(project, "show", "%s:%s" % (sha, _config.CONFIG))
        try:
            return _config.process_of(_config.parse_yaml(text))["review"]["blocking"]
        except ValueError:
            return "low"
    return _config.read_process(os.path.join(project, _config.CONFIG))["review"]["blocking"]


def report(project):
    tdir = os.path.join(project, "docs", "tasks")
    history = settings_history(project)
    sev, cat, cat_blocking = {}, {}, {}
    verdicts, rounds_per_task, sizes = {}, {}, []
    follow_open, follow_tasks = 0, []
    names = sorted(os.listdir(tdir)) if os.path.isdir(tdir) else []
    for f in names:
        p = os.path.join(tdir, f)
        if f.endswith(".md") and not f.startswith("_") and os.path.isfile(p):
            text = _read(p)
            rec = _task.parse(text)
            tid = rec.get("id") if isinstance(rec.get("id"), str) and rec.get("id") else f[:-3]
            sizes.append((len(text.encode("utf-8")), tid,
                          len(json.dumps(rec.get("analysis") or "", ensure_ascii=False).encode("utf-8"))))
            if str(rec.get("class") or "").strip() == FOLLOW_UP_CLASS and _task.status(rec) not in ("DONE", "DEFERRED"):
                n = len(re.findall(r"^\s*- \[ \]", text, re.M))
                follow_open += n
                follow_tasks.append({"task": tid, "open_items": n})
        if f.endswith(".reviews") and os.path.isdir(p):
            tid = f[:-len(".reviews")]
            for r in sorted(os.listdir(p)):
                if not r.endswith(".md"):
                    continue
                text = _read(os.path.join(p, r))
                rv = _task.parse(text)
                v = _task.first_word(rv.get("verdict")) or "?"
                verdicts[v] = verdicts.get(v, 0) + 1
                rounds_per_task[tid] = rounds_per_task.get(tid, 0) + 1
                th = blocking_when_written(project, os.path.join("docs", "tasks", f, r))
                for s, c in findings_of(text):
                    sev[s] = sev.get(s, 0) + 1
                    cat[c] = cat.get(c, 0) + 1
                    if v == "REQUEST_CHANGES" and _config.severity_blocks(s, c, th):
                        cat_blocking[c] = cat_blocking.get(c, 0) + 1
    total_rounds = sum(verdicts.values())
    subjects = git(project, "log", "--format=%s").splitlines()
    ratified = [l for l in git(project, "log", "-G", r"^tail_code:\s*ratified", "--format=%h %cs %s",
                                "--", "docs/tasks").splitlines() if l]
    sizes.sort(reverse=True)
    return {
        "settings_now": {k: v for k, v in _config.read_process(os.path.join(project, _config.CONFIG)).items()},
        "settings_history": history,
        "verdicts": verdicts,
        "send_back_share": round(verdicts.get("REQUEST_CHANGES", 0) / total_rounds, 2) if total_rounds else None,
        "rounds": {"total": total_rounds, "tasks_reviewed": len(rounds_per_task),
                   "per_task": round(total_rounds / len(rounds_per_task), 2) if rounds_per_task else None,
                   "max": max(rounds_per_task.values()) if rounds_per_task else 0},
        "findings": {"by_severity": dict(sorted(sev.items(), key=lambda x: -x[1])),
                     "by_category": dict(sorted(cat.items(), key=lambda x: -x[1])),
                     "returned_by_category": dict(sorted(cat_blocking.items(), key=lambda x: -x[1]))},
        "ratified": {"count": len(ratified), "commits": ratified[:10]},
        "bookkeeping": {"commits": len(subjects),
                        "chore_task": sum(1 for s in subjects if s.startswith("chore(task)")),
                        "share": round(sum(1 for s in subjects if s.startswith("chore(task)")) / len(subjects), 2)
                        if subjects else None},
        "records": {"total_kb": round(sum(s for s, _, _ in sizes) / 1024, 1),
                    "largest": [{"task": t, "kb": round(s / 1024, 1), "analysis_kb": round(a / 1024, 1)}
                                for s, t, a in sizes[:5]]},
        "follow_ups": {"open_items": follow_open, "tasks": follow_tasks},
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project", default=os.getcwd())
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    r = report(os.path.abspath(args.project))
    if args.json:
        print(json.dumps(r, indent=2, ensure_ascii=False))
    else:
        print("review: %s rounds, send-back share %s; findings %s" % (
            r["rounds"]["total"], r["send_back_share"], r["findings"]["by_severity"]))
        print("bookkeeping: %s of %s commits; ratified: %d; records %s KB; open follow-ups: %d" % (
            r["bookkeeping"]["chore_task"], r["bookkeeping"]["commits"], r["ratified"]["count"],
            r["records"]["total_kb"], r["follow_ups"]["open_items"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
