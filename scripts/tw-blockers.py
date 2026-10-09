#!/usr/bin/env python3
"""tw-blockers.py - what waits for a person, behind /teamwright:blockers (stdlib only, read-only).

The router answers "what next"; the progress report counts. Neither answers the owner's
question "what is stuck on me, and what does each answer unblock". This collects every
item the team cannot move by itself:

  question     an unresolved OQ-NN in docs/open-questions.md, with the tasks whose
               `blocked_on` names it and the tasks that mention it
  escalated    the latest review verdict is ESCALATE (the reviewer stopped after two
               send-backs, or found a decision outside the task)
  acceptance   the latest acceptance verdict is NEEDS_OWNER (the validator needs an
               owner action: an account, a device, a decision)
  blocked      BLOCKED with a reason that is not an open question
  held         TODO with a free-text `blocked_on`
  stale        `blocked_on` names questions already answered (clear it)
  tree         uncommitted changes that belong to no task, unpushed commits

Each item carries a class read from its text (credentials, infrastructure, external
service, device or manual check, decision, other), the open tasks it unblocks (its
task and everything that depends on it, directly or not), and the records to read.
Items are ordered by what they unblock: highest priority, then count.

  python3 tw-blockers.py [--project PATH] [--json]
"""
import argparse
import importlib.util
import json
import os
import re
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))

CLASSES = (
    ("credentials", r"\b(token|api[- ]?key|secret|password|credential|login|sign[- ]?in|account|"
                    r"certificate|keystore|signing)\b"),
    ("infrastructure", r"\b(dns|server|vm|vps|quota|registry|ssl|tls|domain|hosting|runner|"
                       r"database|backup|deploy\w*|staging|production|prod)\b"),
    ("external", r"\b(oauth|provider|vendor|third[- ]party|store|play console|rustore|app store|"
                 r"payment|webhook|external|support|partner|customer|client)\b"),
    ("device", r"\b(device|phone|tablet|emulator|simulator|browser|manual\w*|visual\w*|hardware|"
               r"physical|by hand|screenshot|microphone|camera)\b"),
    ("decision", r"\b(owner|decide|decision|choose|choice|approv\w*|confirm|question|OQ-\d+|"
                 r"escalat\w*|priority|scope|trade-?off)\b"),
)


def _router():
    spec = importlib.util.spec_from_file_location("tw_next", os.path.join(HERE, "tw-next.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def classify(text):
    for name, pat in CLASSES:
        if re.search(pat, text or "", re.I):
            return name
    return "other"


def open_question_table(project):
    """{OQ-NN: {question, blocks, options, asked, status}} from docs/open-questions.md."""
    out, cols = {}, None
    try:
        with open(os.path.join(project, "docs", "open-questions.md"), encoding="utf-8",
                  errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return out
    for line in lines:
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 2 and cells[0].lower() == "id":
            cols = [c.lower() for c in cells]
            continue
        if len(cells) >= 2 and re.fullmatch(r"OQ-\d+", cells[0]):
            row = dict(zip(cols or [], cells)) if cols else {}
            out[cells[0]] = {
                "question": row.get("question", cells[1]),
                "blocks": row.get("blocks", ""),
                "options": row.get("options", ""),
                "asked": row.get("asked", ""),
                "status": row.get("status", cells[-1]),
            }
    return out


def dependents(tasks, closed):
    """{id: [open ids that depend on it, directly or not]}."""
    rev = {}
    for t in tasks.values():
        for d in t["depends_on"]:
            rev.setdefault(d, []).append(t["id"])
    out = {}
    for tid in tasks:
        seen, stack = set(), list(rev.get(tid, []))
        while stack:
            x = stack.pop()
            if x in seen or x not in tasks:
                continue
            seen.add(x)
            stack.extend(rev.get(x, []))
        out[tid] = sorted((x for x in seen if tasks[x]["status"] not in closed), key=_num)
    return out


def _num(tid):
    m = re.search(r"(\d+)$", tid or "")
    return (int(m.group(1)) if m else 0, tid or "")


def _latest(project, tid, sub):
    d = os.path.join(project, "docs", "tasks", tid + sub)
    try:
        rounds = sorted((int(f[:-3]), f) for f in os.listdir(d) if re.fullmatch(r"\d+\.md", f))
    except OSError:
        return None
    return "docs/tasks/%s%s/%s" % (tid, sub, rounds[-1][1]) if rounds else None


def _record_text(project, rel):
    try:
        with open(os.path.join(project, rel), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except (OSError, TypeError):
        return ""


def report(project):
    tw = _router()
    task, config = tw._load_helpers(project)
    tasks = tw.load_tasks(project, task)
    if tasks is None:
        return {"installed": False, "reason": "no docs/tasks/ - run /teamwright:adopt or /teamwright:init first"}
    st = tw.state_of(project, config)
    oqs = tw.open_questions(project)
    table = open_question_table(project)
    deps = dependents(tasks, tw.CLOSED)
    open_ = {k: t for k, t in tasks.items() if t["status"] not in tw.CLOSED}
    items = []

    def unblocks(ids):
        out = set()
        for i in ids:
            if i in open_:
                out.add(i)
            out.update(deps.get(i, []))
        return sorted(out, key=_num)

    def add(kind, need, task_ids, evidence=(), qid=None, cls=None, **extra):
        u = unblocks(task_ids)
        prios = [tw.PRIO.get(tasks[i]["priority"], 2) for i in u if i in tasks]
        items.append(dict(kind=kind, id=qid or (task_ids[0] if task_ids else None),
                          need=need, cls=cls or classify(need), tasks=list(task_ids),
                          unblocks=u, top_priority="P%d" % min(prios) if prios else None,
                          evidence=[e for e in evidence if e], **extra))

    # questions: every unresolved row, plus ids named in blocked_on but missing from the table
    named = {}
    for t in open_.values():
        for q in tw.OQ_RE.findall(t["blocked_on"]):
            named.setdefault(q, {"waiting": [], "mentioned": []})["waiting"].append(t["id"])
        for q in t["mentions_oq"]:
            named.setdefault(q, {"waiting": [], "mentioned": []})["mentioned"].append(t["id"])
    for q in sorted(set(table) | set(named), key=_num):
        if tw.oq_resolved(oqs, q):
            continue
        row = table.get(q, {})
        ref = named.get(q, {"waiting": [], "mentioned": []})
        waiting = sorted(set(ref["waiting"]), key=_num)
        mentioned = sorted(set(ref["mentioned"]) - set(waiting), key=_num)
        add("question", row.get("question") or "named in blocked_on but missing from "
            "docs/open-questions.md", waiting, ["docs/open-questions.md"], qid=q, cls="decision",
            options=row.get("options", ""), asked=row.get("asked", ""), blocks=row.get("blocks", ""),
            mentioned_by=mentioned, in_table=q in table)

    for t in sorted(open_.values(), key=lambda t: _num(t["id"])):
        tid = t["id"]
        if t["review"] == "ESCALATE" and t["status"] in ("NEEDS_REVIEW", "BLOCKED"):
            rec = _latest(project, tid, ".reviews")
            add("escalated", "review escalated after %d round(s): %s" % (t["review_rounds"], t["title"]),
                [tid], [rec, "docs/tasks/%s.md" % tid], cls="decision", status=t["status"],
                title=t["title"])
            continue
        if t["validation"] == "NEEDS_OWNER":
            rec = _latest(project, tid, ".validation")
            body = _record_text(project, rec)
            add("acceptance", "acceptance NEEDS_OWNER: %s" % t["title"], [tid],
                [rec, "docs/tasks/%s.md" % tid], cls=classify(body) if body else "decision",
                status=t["status"], title=t["title"])
            continue
        free = t["blocked_on"] if not tw.OQ_RE.search(t["blocked_on"]) else ""
        if t["status"] == "BLOCKED" and not tw.OQ_RE.search(t["blocked_on"]):
            add("blocked", free or "BLOCKED, no reason recorded", [tid], ["docs/tasks/%s.md" % tid],
                status=t["status"], title=t["title"])
        elif t["status"] == "TODO" and free:
            add("held", free, [tid], ["docs/tasks/%s.md" % tid], status=t["status"], title=t["title"])

    stale = [w for w in tw.warnings_for(tasks, oqs) if "already" in w]
    if st.get("dirty"):
        add("tree", "%d uncommitted file(s): commit, assign to a task or leave them"
            % len(st["dirty_files"]), [], cls="decision", files=st["dirty_files"][:10])
    if st.get("unpushed"):
        add("tree", "%d unpushed commit(s): push is the owner's call" % st["unpushed"], [],
            cls="decision")

    def key(it):
        p = int(it["top_priority"][1:]) if it["top_priority"] else 9
        return (p, -len(it["unblocks"]), it["kind"] == "tree", _num(it["id"] or ""))
    items.sort(key=key)
    counts = {}
    for it in items:
        counts[it["cls"]] = counts.get(it["cls"], 0) + 1
    return {"installed": True, "paused": bool(st.get("pause")), "items": items,
            "stale": stale, "by_class": counts,
            "open_tasks": len(open_),
            "stuck_tasks": len({u for it in items for u in it["unblocks"]})}


def human(r):
    if not r.get("installed"):
        return r.get("reason", "not installed")
    lines = ["Waiting for a person: %d item(s), holding %d of %d open task(s)%s"
             % (len(r["items"]), r["stuck_tasks"], r["open_tasks"], " - team PAUSED" if r["paused"] else "")]
    for it in r["items"]:
        head = "%s %s [%s]" % (it["kind"], it["id"] or "", it["cls"])
        if it["top_priority"]:
            head += " %s, unblocks %d: %s" % (it["top_priority"], len(it["unblocks"]),
                                              ", ".join(it["unblocks"][:8]))
        lines.append("- " + head)
        lines.append("    " + it["need"][:200])
        if it.get("options"):
            lines.append("    options: " + it["options"][:200])
        for e in it["evidence"]:
            lines.append("    read: " + e)
    for w in r["stale"]:
        lines.append("- stale: " + w)
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project", default=os.getcwd())
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    r = report(os.path.abspath(args.project))
    print(json.dumps(r, indent=2, ensure_ascii=False) if args.json else human(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
