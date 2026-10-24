#!/usr/bin/env python3
"""tw-progress.py - progress report for the owner, behind /teamwright:progress (stdlib only, read-only).

Counts task records (docs/tasks/<ID>.md) by status, sprint, plan stage and area, and adds
what is next, what waits for the owner and what looks risky. The skill renders the JSON;
every number comes from the records, the plan and git, never from an agent's estimate.

  python3 tw-progress.py [--project PATH] [--json]

Done means status DONE; DEFERRED tasks are counted separately and left out of the
percentages (their scope moved to the rca task that absorbed them).

Plan stage of a task: the stage in docs/plan.md ("## Stages" table) whose Scope names an
FR-NN that the task's title, design_ref or body names. Area of a task: the configured area
(.teamwright/config.yml) whose source_dirs, test_dirs or workdir the task's analysis.seam names, else
its text; with a single area every task belongs to it. Tasks that match no area are listed
as `unassigned` - name the area's directory in the seam instead of guessing.

The next action, the ready queue and the owner decisions come from tw-next.py, so this
report and /teamwright:flow never disagree. A task worked in another git worktree on a
branch that names it (`tw/<ID>`, `task/<ID>`) is read from that worktree's record, as the
router does.

Per-project adaptation, written by `/teamwright:progress --adapt` (optional, committed):
.teamwright/progress.json
  {"areas": {"T-012": "ui"},                          area per task, wins over everything
   "area_rules": [{"area": "ui", "pattern": "regex"}], tried on seam, then text, before dirs
   "milestone": {"name": "MVP", "stages": ["0 — Skeleton", "1 — Core"]},   plan stages in it
   "extra_command": "python3 scripts/progress-extra.py"}   JSON on stdout -> "extra"
The extra command is the project's own reader for work kept outside docs/tasks/ (a spec
tool's task list not yet split into records, an issue tracker export); its output is
reported next to the records, never merged into their counts.
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
FR_RE = re.compile(r"\bFR-\d+\b")


def _router():
    spec = importlib.util.spec_from_file_location("tw_next", os.path.join(HERE, "tw-next.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def _section(text, heading):
    """Lines under `## <heading>` up to the next `## `."""
    out, inside = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            if inside:
                break
            inside = line[3:].strip().lower().startswith(heading.lower())
            continue
        if inside:
            out.append(line)
    return out


def _rows(lines):
    """Data rows of the first markdown table in `lines` (header and separator skipped)."""
    rows = []
    for line in lines:
        if not line.strip().startswith("|"):
            if rows:
                break
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if all(set(c) <= set("-: ") for c in cells):
            continue
        rows.append(cells)
    return rows[1:]


def _placeholder(cell):
    return not cell or cell.startswith("<")


def records(project, task, only=None):
    """{id: extra fields tw-next does not keep: sprint, type, seam, text, recurrence_of}."""
    d = os.path.join(project, "docs", "tasks")
    out = {}
    if not os.path.isdir(d):
        return out
    for f in sorted(os.listdir(d)):
        if not f.endswith(".md") or f.startswith("_") or (only and f[:-3] != only):
            continue
        text = _read(os.path.join(d, f))
        rec = task.parse(text)
        tid = (rec.get("id") if isinstance(rec.get("id"), str) else "") or f[:-3]
        s = lambda k: rec.get(k).strip() if isinstance(rec.get(k), str) else ""  # noqa: E731
        analysis = rec.get("analysis") if isinstance(rec.get("analysis"), dict) else {}
        body = task.body(text) if hasattr(task, "body") else ""
        out[tid] = {
            "sprint": s("sprint"),
            "type": s("type") or "feature",
            "seam": str(analysis.get("seam") or ""),
            "text": "\n".join([s("title"), s("design_ref"), body]),
            "recurrence_of": [x for x in re.split(r"[\s,\[\]'\"]+", s("recurrence_of")) if x],
            "class": s("class"),
            "open_items": len(re.findall(r"^\s*- \[ \]", body, re.M)),
        }
    return out


def areas_of(project, config):
    try:
        cfg = config.parse_yaml(_read(os.path.join(project, config.CONFIG))) or {}
    except Exception:  # a broken config is /teamwright:status's finding, not ours
        cfg = {}
    out = []
    for a in cfg.get("areas") or []:
        if isinstance(a, dict) and a.get("name"):
            dirs = []
            for k in ("source_dirs", "test_dirs", "workdir"):
                v = a.get(k) or []
                # "backend/src (*.spec.ts)": the directory is the first word
                dirs += [str(x).split()[0].rstrip("/") for x in (v if isinstance(v, list) else [v]) if str(x).strip()]
            out.append({"name": str(a["name"]), "dirs": dirs})
    return out


def area_of(tid, extra, areas, adapt=None):
    """The area whose directory the seam names (else the task text); the longest matching
    directory wins, so `src-tauri/src` is not read as `src`. progress.json overrides and
    rules come first."""
    adapt = adapt or {}
    if tid in (adapt.get("areas") or {}):
        return str(adapt["areas"][tid])
    for where in (extra["seam"], extra["text"]):
        for rule in adapt.get("area_rules") or []:
            try:
                if re.search(rule["pattern"], where, re.M):
                    return str(rule["area"])
            except (KeyError, TypeError, re.error):
                continue
    if len(areas) == 1:
        return areas[0]["name"]
    for where in (extra["seam"], extra["text"]):
        hits = [(len(d), a["name"]) for a in areas for d in a["dirs"]
                if re.search(r"(^|[\s`'\"(])" + re.escape(d) + r"(/|$|[\s`'\"):,;])", where, re.M)]
        if hits:
            return max(hits)[1]
        for a in areas:
            if re.search(r"\b" + re.escape(a["name"]) + r"\b", extra["seam"]):
                return a["name"]
    return "unassigned"


def stages_of(project):
    out = []
    for cells in _rows(_section(_read(os.path.join(project, "docs", "plan.md")), "Stages")):
        if len(cells) < 2 or _placeholder(cells[0]):
            continue
        out.append({
            "stage": cells[0],
            "frs": sorted(set(FR_RE.findall(cells[1])), key=lambda x: int(x[3:])),
            "done_when": cells[2] if len(cells) > 2 and not _placeholder(cells[2]) else "",
            "target": cells[3] if len(cells) > 3 and not _placeholder(cells[3]) else "",
            "plan_status": cells[4] if len(cells) > 4 else "",
        })
    return out


def sprints_of(project):
    d = os.path.join(project, "docs", "sprints")
    out = {}
    if not os.path.isdir(d):
        return out
    for f in os.listdir(d):
        m = re.fullmatch(r"(\d+)\.md", f)
        if not m:
            continue
        text = _read(os.path.join(d, f))
        goal = next((l.strip() for l in _section(text, "Goal")
                     if l.strip() and not l.strip().startswith(("<!--", "<"))), "")
        dates = re.search(r"\*\*Dates:\*\*\s*(.+)", text)
        forks = [c[0] for c in _rows(_section(text, "Forks"))
                 if c and not _placeholder(c[0]) and (len(c) < 3 or _placeholder(c[2]) or "pending" in c[2].lower())]
        out[m.group(1)] = {"goal": goal, "dates": dates.group(1).strip() if dates and "<" not in dates.group(1) else "",
                           "pending_forks": forks}
    return out


def open_question_rows(project):
    """Unresolved rows of docs/open-questions.md: [{id, question}]."""
    out = []
    for line in _read(os.path.join(project, "docs", "open-questions.md")).splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 2 and re.fullmatch(r"OQ-\d+", cells[0]):
            words = re.findall(r"[a-z]+", cells[-1].lower())
            if not words or words[0] not in ("answered", "closed", "resolved", "dropped", "done"):
                out.append({"id": cells[0], "question": cells[1][:160]})
    return out


def adaptation(project):
    """.teamwright/progress.json ({} when absent); a broken file is reported, not fatal."""
    path = os.path.join(project, ".teamwright", "progress.json")
    if not os.path.isfile(path):
        return {}, None
    try:
        data = json.loads(_read(path))
        return (data if isinstance(data, dict) else {}), None if isinstance(data, dict) else "not an object"
    except ValueError as e:
        return {}, "progress.json: %s" % e


def run_extra(project, cmd):
    try:
        r = subprocess.run(cmd, shell=True, cwd=project, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, "extra_command: %s" % e
    if r.returncode != 0:
        return None, "extra_command exited %d: %s" % (r.returncode, (r.stderr or r.stdout).strip()[-300:])
    try:
        return json.loads(r.stdout), None
    except ValueError:
        return None, "extra_command printed no JSON"


def _tally(tasks):
    done = sum(t["status"] == "DONE" for t in tasks)
    deferred = sum(t["status"] == "DEFERRED" for t in tasks)
    counted = len(tasks) - deferred
    return {"done": done, "total": counted, "deferred": deferred,
            "pct": round(100 * done / counted) if counted else None}


def report(project):
    tw = _router()
    task, config = tw._load_helpers(project)
    st = tw.state_of(project, config)
    base = tw.load_tasks(project, task)
    if base is None:
        return {"installed": False, "reason": "no docs/tasks/ - run /teamwright:adopt or /teamwright:init first"}
    extra = records(project, task)
    # a task worked in another worktree (tw/<ID>, task/<ID>): its record there is the current one
    _own, wts = tw.with_worktrees(project, task, base)
    for tid, wt in wts.items():
        extra.update(records(wt["path"], task, only=tid))
    areas = areas_of(project, config)
    adapt, adapt_error = adaptation(project)
    tasks = []
    for tid, t in base.items():
        e = extra.get(tid) or {"sprint": "", "type": "feature", "seam": "", "text": t["title"], "recurrence_of": []}
        tasks.append(dict(t, sprint=e["sprint"], type=e["type"], area=area_of(tid, e, areas, adapt),
                          frs=sorted(set(FR_RE.findall(e["text"]))), recurrence_of=e["recurrence_of"]))
    tasks = tw._sorted(tasks)

    by_status = {}
    for t in tasks:
        by_status[t["status"]] = by_status.get(t["status"], 0) + 1

    sprint_meta = sprints_of(project)
    sprint_ids = sorted(set(sprint_meta) | {t["sprint"] for t in tasks if t["sprint"]},
                        key=lambda x: int(x) if x.isdigit() else 10 ** 9)
    active = max((int(s) for s in sprint_meta), default=None)
    by_sprint = []
    for s in sprint_ids:
        sel = [t for t in tasks if t["sprint"] == s]
        tal = _tally(sel)
        meta = sprint_meta.get(s, {})
        by_sprint.append(dict(tal, sprint=s, goal=meta.get("goal", ""), dates=meta.get("dates", ""),
                              active=s.isdigit() and int(s) == active,
                              closed=bool(sel) and all(t["status"] in ("DONE", "DEFERRED") for t in sel),
                              pending_forks=meta.get("pending_forks", [])))

    by_area = []
    names = [a["name"] for a in areas]
    names += sorted({t["area"] for t in tasks} - set(names) - {"unassigned"})
    for name in names + ["unassigned"]:
        sel = [t for t in tasks if t["area"] == name]
        if sel or name != "unassigned":
            by_area.append(dict(_tally(sel), area=name))

    by_stage, current = [], None
    for sg in stages_of(project):
        sel = [t for t in tasks if set(t["frs"]) & set(sg["frs"])]
        covered = {f for t in sel for f in t["frs"]}
        tal = _tally(sel)
        row = dict(tal, stage=sg["stage"], target=sg["target"], done_when=sg["done_when"],
                   plan_status=sg["plan_status"], frs=sg["frs"],
                   frs_without_tasks=[f for f in sg["frs"] if f not in covered],
                   by_area={a: _tally([t for t in sel if t["area"] == a])
                            for a in sorted({t["area"] for t in sel})})
        if current is None and (row["frs_without_tasks"] or not sel or tal["done"] < tal["total"]):
            current = sg["stage"]
        by_stage.append(row)

    milestone = None
    ms = adapt.get("milestone") if isinstance(adapt.get("milestone"), dict) else None
    if ms and ms.get("stages"):
        names_ = [str(x) for x in ms["stages"]]
        rows = [sg for sg in by_stage if sg["stage"] in names_]
        frs = {f for sg in rows for f in sg["frs"]}
        sel = [t for t in tasks if set(t["frs"]) & frs]
        milestone = dict(_tally(sel), name=str(ms.get("name") or "milestone"), stages=names_,
                         missing_stages=[n for n in names_ if n not in {sg["stage"] for sg in rows}],
                         frs_without_tasks=[f for sg in rows for f in sg["frs_without_tasks"]],
                         by_area={a: _tally([t for t in sel if t["area"] == a])
                                  for a in sorted({t["area"] for t in sel})})

    extra_out, extra_error = (None, None)
    if adapt.get("extra_command"):
        extra_out, extra_error = run_extra(project, str(adapt["extra_command"]))

    oqs = tw.open_questions(project)
    if hasattr(tw, "mark_delivered"):
        tw.mark_delivered(project, base, st)  # the router's rule: deploying tasks wait for DRAIN
    cands = tw.candidates(base, st, oqs)
    nxt = cands[0] if cands else tw._d("idle", None, "nothing actionable - plan the next sprint")
    owner = [{"action": c["action"], "task": c["task"], "reason": c["reason"]}
             for c in cands if c["ask_owner"] and c["action"] != "start"]
    ready = [{"task": c["task"], "reason": c["reason"]} for c in cands if c["action"] == "start"]

    open_ = [t for t in tasks if t["status"] not in ("DONE", "DEFERRED")]
    risks = {
        "verify_fail": [t["id"] for t in open_ if t["status"] == "VERIFY_FAIL"],
        "open_rca": [t["id"] for t in open_ if t["type"] == "rca"],
        "recurrences": [{"task": t["id"], "of": t["recurrence_of"]} for t in open_ if t["recurrence_of"]],
        "two_plus_review_rounds": [{"task": t["id"], "rounds": t["review_rounds"]}
                                   for t in open_ if t["review_rounds"] >= 2],
        "warnings": tw.warnings_for(base, oqs),
    }

    def g(*a):
        rc, out = tw.git(project, *a)
        return out.strip() if rc == 0 else ""

    behind = g("rev-list", "--count", "HEAD..@{u}")
    return {
        "installed": True,
        "mode": st.get("mode"),
        "paused": st.get("pause"),
        "total": _tally(tasks),
        "by_status": dict(sorted(by_status.items())),
        "by_sprint": by_sprint,
        "by_area": by_area,
        # not analysed yet = no seam: the area is known after analysis, not a gap in the record
        "unassigned": [{"task": t["id"], "analysed": bool((extra.get(t["id"]) or {}).get("seam"))}
                       for t in tasks if t["area"] == "unassigned" and t["status"] != "DEFERRED"],
        "by_stage": by_stage,
        "current_stage": current,
        "milestone": milestone,
        "adapted": bool(adapt),
        "adaptation_notes": os.path.isfile(os.path.join(project, ".teamwright", "progress.md")),
        "extra": extra_out,
        "errors": [e for e in (adapt_error, extra_error) if e],
        "next": {"action": nxt["action"], "task": nxt["task"], "reason": nxt["reason"]},
        "ready": ready[:5],
        "in_flight": [{"task": t["id"], "status": t["status"], "title": t["title"]} for t in open_
                      if t["status"] not in ("TODO", "BLOCKED")],
        "owner": {"decisions": owner,
                  "open_questions": open_question_rows(project),
                  "pending_forks": [{"sprint": s["sprint"], "fork": f} for s in by_sprint for f in s["pending_forks"]]},
        "risks": risks,
        # review findings below the blocking threshold, collected per sprint by the flow
        "follow_ups": {"open_items": sum((extra.get(t["id"]) or {}).get("open_items", 0) for t in open_
                                         if (extra.get(t["id"]) or {}).get("class") == "review-follow-up"),
                       "tasks": [t["id"] for t in open_ if (extra.get(t["id"]) or {}).get("class") == "review-follow-up"]},
        "git": {"branch": st.get("branch"), "head": g("log", "-1", "--format=%h %s (%cr)"),
                "recent": g("log", "-5", "--format=%h %s").splitlines(),
                "uncommitted": len(st.get("dirty_files") or []) + (st.get("untracked") or 0),
                "unpushed": st.get("unpushed") or 0,
                "behind": int(behind) if behind.isdigit() else None},
    }


def _pct(t):
    return "%d/%d%s" % (t["done"], t["total"], " (%d%%)" % t["pct"] if t["pct"] is not None else "")


def human(r):
    if not r.get("installed"):
        return "teamwright progress: " + r["reason"]
    lines = ["teamwright progress",
             "  done: %s%s | mode: %s | branch: %s%s" % (
                 _pct(r["total"]), ", deferred %d" % r["total"]["deferred"] if r["total"]["deferred"] else "",
                 r["mode"] or "-", r["git"]["branch"] or "-", " | PAUSED" if r["paused"] else ""),
             "  status: " + (", ".join("%s %d" % kv for kv in r["by_status"].items()) or "no tasks")]
    for s in r["by_sprint"]:
        lines.append("  sprint %s%s: %s%s" % (s["sprint"], " (active)" if s["active"] else "", _pct(s),
                                             " - " + s["goal"] if s["goal"] else ""))
    for a in r["by_area"]:
        lines.append("  area %s: %s" % (a["area"], _pct(a)))
    for sg in r["by_stage"]:
        lines.append("  stage %s: %s%s" % (sg["stage"], _pct(sg),
                                          ", no tasks for " + ", ".join(sg["frs_without_tasks"])
                                          if sg["frs_without_tasks"] else ""))
    m = r.get("milestone")
    if m:
        lines.append("  %s: %s%s" % (m["name"], _pct(m), ", no tasks for " + ", ".join(m["frs_without_tasks"])
                                    if m["frs_without_tasks"] else ""))
    for e in r.get("errors") or []:
        lines.append("  error: " + e)
    n = r["next"]
    lines += ["", "next: %s%s - %s" % (n["action"], " " + n["task"] if n["task"] else "", n["reason"])]
    for d in r["owner"]["decisions"]:
        lines.append("  owner: %s%s - %s" % (d["action"], " " + d["task"] if d["task"] else "", d["reason"]))
    for q in r["owner"]["open_questions"]:
        lines.append("  open question %s: %s" % (q["id"], q["question"]))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project", default=os.getcwd(), help="project root (default: cwd)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args(argv)
    project = os.path.abspath(args.project)
    if not os.path.isdir(project):
        print("tw-progress: no such project: %s" % project, file=sys.stderr)
        return 2
    r = report(project)
    print(json.dumps(r, indent=2, ensure_ascii=False) if args.json else human(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
