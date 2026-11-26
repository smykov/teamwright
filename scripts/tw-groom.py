#!/usr/bin/env python3
"""tw-groom.py - facts about the open backlog before a sprint (stdlib only, read-only).

Nothing keeps open task records true between their creation and their start. This script
finds the records a person (or /teamwright:sprint) should look at before choosing work, and
the plan stages the records do not cover. It writes nothing and decides nothing: each
finding names its evidence, and the owner says what happens to the record.

  python3 tw-groom.py [--project P] [--json] [--old-days N]

Per record (open = not DONE or DEFERRED):
  possibly-done      TODO/BLOCKED, and a commit after the record's last change names the task
  seam-changed       TODO/BLOCKED, and files in its seam changed after the record's last change
  missing-path       a path in backticks in Context or the seam does not exist
  no-seam            TODO with no seam path: overlaps cannot be computed until analysis
  settled            BLOCKED, or blocked_on set, and everything it names is answered or closed
  inherits-priority  an open task of higher priority waits on it (depends_on, transitively)
  old                no change to the record for N days (default 90)
  too-large          a from-follow-up task with more open checklist items than one chain takes
  duplicate          another open task with the same title, or the same class and an
                     overlapping seam
  absorbed-done      DEFERRED, and its absorbed_by task is DONE: check the remainder
Per plan stage (docs/plan.md, Stages table; tasks belong to a stage by the FR-NN they name):
  stage-empty, frs-without-tasks, release-stage-empty, plan-status-stale, and
  milestone-stage-missing (a milestone stage in .teamwright/progress.json not in the plan).
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
FOLLOW_UP_MAX = 10   # open checklist items one from-follow-up task may hold
OLD_DAYS = 90
RELEASE_RE = re.compile(r"(?i)\b(release|ship(ped|ping)?|launch|e2e|end-to-end|go-live)\b|релиз|выпуск")
NOT_STARTED_RE = re.compile(r"(?i)^\W*(not started|planned|todo)\b|^\W*не\s+начат")
PATH_RE = re.compile(r"`([^`\s<>*]+)`")


def _load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _git(project, *args):
    r = subprocess.run(["git", "-C", project] + list(args), capture_output=True, text=True)
    return r.returncode, r.stdout


def record_history(project, tid):
    """(last change commit, last change epoch, first commit epoch) of docs/tasks/<ID>.md;
    (None, None, None) when the record is not committed."""
    rc, out = _git(project, "log", "--format=%H %ct", "--", "docs/tasks/%s.md" % tid)
    lines = [l.split() for l in out.splitlines() if l.strip()] if rc == 0 else []
    if not lines:
        return None, None, None
    return lines[0][0], int(lines[0][1]), int(lines[-1][1])


def commits_naming(project, tid, since):
    """Commits after `since` whose message names the task id as a whole word."""
    rc, out = _git(project, "log", "--format=%x00%h %s%n%b", "--fixed-strings", "--grep=" + tid, "%s..HEAD" % since)
    if rc != 0:
        return []
    word = re.compile(r"(?<![\w-])%s(?![\w-])" % re.escape(tid))
    found = []
    for chunk in out.split("\x00"):
        if chunk.strip() and word.search(chunk):
            found.append(chunk.strip().splitlines()[0])
    return found


def commits_touching(project, paths, since):
    rc, out = _git(project, "log", "--format=%h %s", "%s..HEAD" % since, "--", *paths)
    return [l for l in out.splitlines() if l.strip()] if rc == 0 else []


def _paths_in(text):
    out = []
    for m in PATH_RE.finditer(text or ""):
        p = re.sub(r"(:\d+([-:]\d+)?|#.*)$", "", m.group(1)).rstrip("/.,;")
        if "/" in p and not p.startswith(("http:", "https:", "/", "~")) and "://" not in p and p not in out:
            out.append(p)
    return out


def _title_key(title):
    return re.sub(r"\W+", " ", (title or "").lower()).strip()


def collect(project, old_days=OLD_DAYS, now=None):
    nxt, prog, par = _load("tw-next"), _load("tw-progress"), _load("tw-parallel")
    task, _config = nxt._load_helpers(project)
    tasks = nxt.load_tasks(project, task)
    if tasks is None:
        return None
    now = now or time.time()
    extra = prog.records(project, task)
    oqs = nxt.open_questions(project)
    eff = nxt.effective_priority(tasks)
    open_ids = [tid for tid, t in tasks.items() if t["status"] not in nxt.CLOSED]
    rows = []
    for t in nxt._sorted(tasks.values()):
        tid = t["id"]
        e = extra.get(tid) or {}
        text = prog._read(os.path.join(project, "docs", "tasks", tid + ".md"))
        rec = task.parse(text)
        s = lambda k: rec.get(k).strip() if isinstance(rec.get(k), str) else ""  # noqa: E731
        last, last_ts, first_ts = record_history(project, tid)
        paths = sorted(par.seam_paths(t.get("seam")))
        findings = []
        add = lambda kind, detail, evidence=None: findings.append(  # noqa: E731
            {"kind": kind, "detail": detail, "evidence": evidence or []})
        if t["status"] == "DEFERRED":
            ab = s("absorbed_by")
            if ab and ab in tasks and tasks[ab]["status"] == "DONE":
                add("absorbed-done", "absorbed_by %s is DONE: check what is left against the current code "
                    "(close, or a new task for the remainder)" % ab, ["docs/tasks/%s.md" % ab])
        if t["status"] in nxt.CLOSED:
            if findings:
                rows.append({"id": tid, "title": t["title"], "status": t["status"], "priority": t["priority"],
                             "age_days": None, "findings": findings})
            continue
        if t["status"] in ("TODO", "BLOCKED") and last:
            named = commits_naming(project, tid, last)
            if named:
                add("possibly-done", "%d commit(s) name %s after its record last changed" % (len(named), tid),
                    named[:5])
            if paths:
                touched = commits_touching(project, paths, last)
                if touched:
                    add("seam-changed", "%d commit(s) changed its seam after the record last changed"
                        % len(touched), touched[:5])
        context = task.section(text, "Context") if hasattr(task, "section") else ""
        seam_text = " ".join("`%s`" % p for p in paths)
        missing = [p for p in _paths_in(context + "\n" + seam_text) if not os.path.exists(os.path.join(project, p))]
        if missing:
            add("missing-path", "named in Context or the seam, not in the tree: %s" % ", ".join(missing), missing)
        if t["status"] == "TODO" and not paths:
            add("no-seam", "no seam path: tw-sprint cannot compute overlaps until analysis")
        bo = t["blocked_on"]
        if t["status"] == "BLOCKED" or bo:
            named = nxt.OQ_RE.findall(bo) + [x for x in re.findall(r"(?:%s)" % getattr(task, "TASK_ID", r"[A-Z][A-Z0-9]*-\d+"), bo)
                                              if x in tasks]
            deps_open = [d for d in t["depends_on"] if d in tasks and tasks[d]["status"] not in nxt.CLOSED]
            if named and not deps_open and all(
                    nxt.oq_resolved(oqs, x) if x.startswith("OQ-") else tasks[x]["status"] in nxt.CLOSED
                    for x in named):
                add("settled", "blocked_on names only what is answered or closed: %s" % ", ".join(named), named)
        rank, src, n = eff.get(tid, (9, None, 0))
        if src and rank < nxt.PRIO.get(t["priority"], 9):
            add("inherits-priority", "%s %s waits on it: worked as P%d, recorded as %s"
                % (tasks[src]["priority"], src, rank, t["priority"]), [src])
        age = int((now - last_ts) // 86400) if last_ts else None
        if age is not None and age >= old_days:
            add("old", "the record has not changed for %d days" % age)
        if s("class") == "from-follow-up" and e.get("open_items", 0) > FOLLOW_UP_MAX:
            add("too-large", "%d open items, more than one chain takes (%d): split"
                % (e["open_items"], FOLLOW_UP_MAX))
        for o in open_ids:
            if o == tid:
                continue
            ot = tasks[o]
            same_title = _title_key(ot["title"]) and _title_key(ot["title"]) == _title_key(t["title"])
            oc = (extra.get(o) or {}).get("class", "")
            op = set(par.seam_paths(ot.get("seam")))
            same_class = s("class") and oc == s("class") and paths and op and par.overlap(set(paths), op)
            if same_title or same_class:
                add("duplicate", "%s: %s" % (o, "same title" if same_title else "same class, overlapping seam"), [o])
        rows.append({"id": tid, "title": t["title"], "status": t["status"], "priority": t["priority"],
                     "age_days": age, "created_days": int((now - first_ts) // 86400) if first_ts else None,
                     "findings": findings})

    # plan stages: what the records do not cover
    frs_of = {tid: set(prog.FR_RE.findall((extra.get(tid) or {}).get("text", ""))) for tid in tasks}
    stages = []
    for sg in prog.stages_of(project):
        sel = [tid for tid in tasks if frs_of[tid] & set(sg["frs"])]
        done = [tid for tid in sel if tasks[tid]["status"] == "DONE"]
        covered = {f for tid in sel for f in frs_of[tid]}
        release = bool(RELEASE_RE.search("%s %s" % (sg["stage"], sg["done_when"])))
        f = []
        if not sel:
            f.append({"kind": "release-stage-empty" if release else "stage-empty",
                      "detail": "no task names this stage's FR ids%s" % (
                          ": a release stage needs a task built from its Done when" if release else "")})
        missing = [x for x in sg["frs"] if x not in covered]
        if sel and missing:
            f.append({"kind": "frs-without-tasks", "detail": "no task names %s" % ", ".join(missing)})
        if done and NOT_STARTED_RE.search(sg["plan_status"] or ""):
            f.append({"kind": "plan-status-stale", "detail": "plan says '%s', %d task(s) are DONE"
                      % (sg["plan_status"], len(done))})
        stages.append({"stage": sg["stage"], "frs": sg["frs"], "release": release, "tasks": len(sel),
                       "open": len([x for x in sel if tasks[x]["status"] not in nxt.CLOSED]),
                       "done": len(done), "findings": f})
    milestone = []
    adapt, _err = prog.adaptation(project)
    ms = adapt.get("milestone") if isinstance(adapt.get("milestone"), dict) else None
    if ms and ms.get("stages") and stages:
        names = {sg["stage"] for sg in stages}
        for n in ms["stages"]:
            if str(n) not in names:
                milestone.append({"kind": "milestone-stage-missing",
                                  "detail": "milestone stage '%s' is not a stage in docs/plan.md" % n})

    counts = {}
    for r in rows:
        for x in r["findings"]:
            counts[x["kind"]] = counts.get(x["kind"], 0) + 1
    for x in [y for sg in stages for y in sg["findings"]] + milestone:
        counts[x["kind"]] = counts.get(x["kind"], 0) + 1
    return {"installed": True, "open": len(open_ids), "records": [r for r in rows if r["findings"]],
            "stages": stages, "milestone": milestone, "counts": dict(sorted(counts.items())),
            "old_days": old_days}


def show(data):
    print("open tasks: %d; findings: %s" % (data["open"], ", ".join(
        "%s %d" % kv for kv in data["counts"].items()) or "none"))
    # no-seam is on most TODO records before analysis: a count, not a line each
    no_seam = [r["id"] for r in data["records"] if any(f["kind"] == "no-seam" for f in r["findings"])]
    for r in data["records"]:
        shown = [f for f in r["findings"] if f["kind"] != "no-seam"]
        if not shown:
            continue
        print("  %s %s %s %s" % (r["id"], r["priority"], r["status"], r["title"]))
        for f in shown:
            print("    %s: %s" % (f["kind"], f["detail"]))
    if no_seam:
        print("  no seam path (overlaps unknown until analysis): %s" % ", ".join(no_seam))
    for sg in data["stages"]:
        if sg["findings"]:
            print("  stage %s (%d task(s), %d open)" % (sg["stage"], sg["tasks"], sg["open"]))
            for f in sg["findings"]:
                print("    %s: %s" % (f["kind"], f["detail"]))
    for f in data["milestone"]:
        print("  %s: %s" % (f["kind"], f["detail"]))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project", default=os.getcwd())
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--old-days", type=int, default=OLD_DAYS)
    a = ap.parse_args(argv)
    data = collect(os.path.abspath(a.project), a.old_days)
    if data is None:
        print("tw-groom: no docs/tasks here", file=sys.stderr)
        return 2
    print(json.dumps(data, ensure_ascii=False, indent=2)) if a.json else show(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
