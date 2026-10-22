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
  render_drift  rendered files (AGENTS.md, role files) whose settings line still carries
                another value than `process:` - a locally edited file the installer
                keeps (kept-local) does not get a settings change

Review facts are keyed by the date of the commit that added each review record (today for
one not committed yet). --since keeps rounds from that date on; --split-date adds `split`:
every review section before and after the date - the evidence for a settings change, which
teamwright-metrics' split (lead time, rounds) does not cover. `send_backs_without_blocking`
counts REQUEST_CHANGES rounds with no finding at or above the threshold in force.

  python3 tw-process.py [--project PATH] [--json] [--since YYYY-MM-DD] [--split-date YYYY-MM-DD]
"""
import datetime
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


SETTING_KEYS = ("REVIEW_BLOCKING", "BATCH_MAX_TASKS", "BATCH_PARALLEL", "BATCH_BY_PRIORITY",
                "AUTONOMY_START", "AUTONOMY_CONTINUE")
_PH = re.compile(r"\{\{([A-Z][A-Z0-9_]*)\}\}")


def setting_values(proc):
    """What the installer renders for each settings placeholder (tw-install.py, load_config)."""
    return {"REVIEW_BLOCKING": proc["review"]["blocking"],
            "BATCH_MAX_TASKS": str(proc["batch"]["max_tasks"]),
            "BATCH_PARALLEL": str(proc["batch"]["parallel"]),
            "BATCH_BY_PRIORITY": ", ".join("%s %s" % kv for kv in sorted(proc["batch"]["by_priority"].items())),
            "AUTONOMY_START": proc["autonomy"]["start"],
            "AUTONOMY_CONTINUE": "true" if proc["autonomy"]["continue"] else "false"}


def render_drift(project, kit=KIT):
    """[{file, setting, expected, found}] for each template line with a settings placeholder
    whose rendered form is not in the installed file. `found` is the value the file carries
    on that line (None when the line itself was rewritten). Only the settings fragment is
    compared, so local edits elsewhere in the file do not count."""
    if not os.path.isfile(os.path.join(project, _config.CONFIG)):
        return []
    values = setting_values(_config.read_process(os.path.join(project, _config.CONFIG)))
    tpl = os.path.join(kit, "template")
    out = []
    for root, _dirs, files in os.walk(tpl):
        for f in files:
            src = os.path.join(root, f)
            text = _read(src)
            if not any("{{%s}}" % k in text for k in SETTING_KEYS):
                continue
            rel = os.path.relpath(src, tpl).replace(os.sep, "/")
            disk = _read(os.path.join(project, rel))
            if not disk:
                continue
            for line in text.splitlines():
                keys = [k for k in _PH.findall(line) if k in SETTING_KEYS]
                if not keys:
                    continue
                exact, shape, order = "", "", []
                for i, part in enumerate(_PH.split(line)):
                    if i % 2 == 0:
                        exact += re.escape(part)
                        shape += re.escape(part)
                    elif part in SETTING_KEYS:
                        exact += re.escape(values[part])
                        shape += "(.*?)"
                        order.append(part)
                    else:
                        exact += ".*?"
                        shape += ".*?"
                if re.search("^" + exact + "$", disk, re.M):
                    continue
                m = re.search("^" + shape + "$", disk, re.M)
                for j, k in enumerate(order):
                    found = m.group(j + 1) if m else None
                    if found != values[k]:
                        out.append({"file": rel, "setting": k.lower(), "expected": values[k], "found": found})
    seen, uniq = set(), []
    for d in out:
        key = (d["file"], d["setting"], d["found"])
        if key not in seen:
            seen.add(key)
            uniq.append(d)
    return uniq


def written(project, rel):
    """(date, threshold) of the commit that added the record: its commit date and the
    threshold in its config (today and the working tree's config when not committed yet)."""
    line = git(project, "log", "--diff-filter=A", "--format=%H %cs", "-1", "--", rel).strip()
    if line:
        sha, date = line.split()
        text = git(project, "show", "%s:%s" % (sha, _config.CONFIG))
        try:
            return date, _config.process_of(_config.parse_yaml(text))["review"]["blocking"]
        except ValueError:
            return date, "low"
    return (datetime.date.today().isoformat(),
            _config.read_process(os.path.join(project, _config.CONFIG))["review"]["blocking"])


def review_facts(rounds):
    """Verdicts, rounds, findings and send-backs over a list of review rounds."""
    sev, cat, cat_blocking, verdicts, per_task = {}, {}, {}, {}, {}
    without = []
    for r in rounds:
        v = r["verdict"]
        verdicts[v] = verdicts.get(v, 0) + 1
        per_task[r["task"]] = per_task.get(r["task"], 0) + 1
        blocking = 0
        for s, c in r["findings"]:
            sev[s] = sev.get(s, 0) + 1
            cat[c] = cat.get(c, 0) + 1
            if _config.severity_blocks(s, c, r["threshold"]):
                blocking += 1
                if v == "REQUEST_CHANGES":
                    cat_blocking[c] = cat_blocking.get(c, 0) + 1
        if v == "REQUEST_CHANGES" and not blocking:
            without.append("%s r%s (%s, threshold %s)" % (r["task"], r["round"], r["date"], r["threshold"]))
    total = sum(verdicts.values())
    send_backs = verdicts.get("REQUEST_CHANGES", 0)
    return {
        "verdicts": verdicts,
        "send_back_share": round(send_backs / total, 2) if total else None,
        "rounds": {"total": total, "tasks_reviewed": len(per_task),
                   "per_task": round(total / len(per_task), 2) if per_task else None,
                   "max": max(per_task.values()) if per_task else 0},
        "findings": {"by_severity": dict(sorted(sev.items(), key=lambda x: -x[1])),
                     "by_category": dict(sorted(cat.items(), key=lambda x: -x[1])),
                     "returned_by_category": dict(sorted(cat_blocking.items(), key=lambda x: -x[1]))},
        "send_backs_without_blocking": {"count": len(without), "of": send_backs, "rounds": without[:20]},
    }


def report(project, since=None, split=None):
    tdir = os.path.join(project, "docs", "tasks")
    history = settings_history(project)
    rounds, sizes = [], []
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
                date, th = written(project, os.path.join("docs", "tasks", f, r))
                rounds.append({"task": tid, "round": r[:-3], "date": date, "threshold": th,
                               "verdict": _task.first_word(rv.get("verdict")) or "?",
                               "findings": findings_of(text)})
    if since:
        rounds = [r for r in rounds if r["date"] >= since]
    since_args = ["--since", since + " 00:00"] if since else []
    subjects = git(project, "log", "--format=%s", *since_args).splitlines()
    ratified = [l for l in git(project, "log", "-G", r"^tail_code:[[:space:]]*ratified", "--format=%h %cs %s",
                                *since_args, "--", "docs/tasks").splitlines() if l]
    sizes.sort(reverse=True)
    out = {
        "settings_now": {k: v for k, v in _config.read_process(os.path.join(project, _config.CONFIG)).items()},
        "settings_history": history,
        "since": since,
    }
    out.update(review_facts(rounds))
    if split:
        out["split"] = {"date": split,
                        "before": review_facts([r for r in rounds if r["date"] < split]),
                        "after": review_facts([r for r in rounds if r["date"] >= split])}
    out.update({
        "ratified": {"count": len(ratified), "commits": ratified[:10]},
        "bookkeeping": {"commits": len(subjects),
                        "chore_task": sum(1 for s in subjects if s.startswith("chore(task)")),
                        "share": round(sum(1 for s in subjects if s.startswith("chore(task)")) / len(subjects), 2)
                        if subjects else None},
        "records": {"total_kb": round(sum(s for s, _, _ in sizes) / 1024, 1),
                    "largest": [{"task": t, "kb": round(s / 1024, 1), "analysis_kb": round(a / 1024, 1)}
                                for s, t, a in sizes[:5]]},
        "follow_ups": {"open_items": follow_open, "tasks": follow_tasks},
        "render_drift": render_drift(project),
    })
    return out


def _date(s):
    try:
        return datetime.date.fromisoformat(s).isoformat()
    except ValueError:
        raise argparse.ArgumentTypeError("expected YYYY-MM-DD, got %r" % s)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project", default=os.getcwd())
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--since", type=_date, help="only review rounds and commits from this date on")
    ap.add_argument("--split-date", type=_date, help="review facts before and after this date")
    args = ap.parse_args(argv)
    r = report(os.path.abspath(args.project), args.since, args.split_date)
    if args.json:
        print(json.dumps(r, indent=2, ensure_ascii=False))
    else:
        print("review: %s rounds, send-back share %s (%d without a blocking finding); findings %s" % (
            r["rounds"]["total"], r["send_back_share"], r["send_backs_without_blocking"]["count"],
            r["findings"]["by_severity"]))
        for d in r["render_drift"]:
            print("render drift: %s carries %s %s, config says %s - re-render it (tw-install apply)" % (
                d["file"], d["setting"], d["found"] or "<line rewritten>", d["expected"]))
        if r.get("split"):
            for side in ("before", "after"):
                f = r["split"][side]
                print("  %s %s: %s rounds, send-back share %s, %d without a blocking finding" % (
                    side, r["split"]["date"], f["rounds"]["total"], f["send_back_share"],
                    f["send_backs_without_blocking"]["count"]))
        print("bookkeeping: %s of %s commits; ratified: %d; records %s KB; open follow-ups: %d" % (
            r["bookkeeping"]["chore_task"], r["bookkeeping"]["commits"], r["ratified"]["count"],
            r["records"]["total_kb"], r["follow_ups"]["open_items"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
