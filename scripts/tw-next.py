#!/usr/bin/env python3
"""tw-next.py - deterministic router for /teamwright:flow (python3 stdlib only, read-only).

Reads docs/tasks/*.md with their .reviews/ and .verify/ rounds, .teamwright/current-task,
the journal (.teamwright/logs/outcomes.jsonl), the gate mode, TEAMWRIGHT_PAUSE and git
state, and prints the next action. The skill talks to the owner; this script only
decides, so the same project state always gives the same answer.

  python3 tw-next.py [--project PATH] [--json] [--pass T-1,T-2]

--pass names the tasks this flow run (a pass) has already taken. The router then applies
`process.batch` from .teamwright/config.yml: when the pass is at its cap, `start` becomes
`stop` (end the pass at this barrier). `process.autonomy.start: auto` makes `start`
need no owner answer.

Decision order (first match wins):
  0. paused      TEAMWRIGHT_PAUSE exists: the team is stopped, report only
  1. resume      dirty tree or an interrupted session -> the task it belongs to
                 (decide when a dirty tree belongs to no task)
  2. continue    ANALYSIS / IN_PROGRESS task
  3. review      NEEDS_REVIEW -> spawn the reviewer (APPROVE recorded -> continue to
                 CODE_COMPLETE; ESCALATE -> decide; REJECT_RECURRENCE -> continue: defer)
  4. verify      CODE_COMPLETE / DEPLOYED without a PASS verify record; then the
                 acceptance verdict in ## Validation (PASS -> continue: close; FAIL ->
                 continue: back to IN_PROGRESS; NEEDS_OWNER -> decide; none -> verify:
                 task-validator). deploys: false + surface none needs no verify record,
                 only the acceptance verdict;
     reanalyze   VERIFY_FAIL -> back to ANALYSIS
  5. decide      BLOCKED on an owner decision
  6. start       ready TODO -> ANALYSIS (the owner picks among `alternatives`).
                 Ready: every depends_on is DONE/VERIFIED and blocked_on is empty, or
                 names only open questions (OQ-NN) already answered or dropped in
                 docs/open-questions.md. Order: effective priority (a task inherits
                 the highest priority of the open tasks that depend on it, directly or
                 not), then the number of open tasks it unblocks, then id.
  7. decide      unpushed commits (push is the owner's call), else idle
     stop        (with --pass) the pass took as many tasks as process.batch allows
  Parallel work (tw-parallel.py): a task on a `tw/<ID>` worktree is worked in that
  worktree's session. The main tree skips it, and offers `merge` once its record on the
  branch is CODE_COMPLETE or later. A session on `tw/<ID>` sees only its own task and
  never pushes: delivery happens from the main tree after the merge.

JSON: {"action", "task", "reason", "role", "ask_owner", "alternatives": [...],
       "state": {...}, "tasks": [...], "warnings": [...]}; action is one of resume | continue | review |
verify | reanalyze | decide | start | stop | merge | idle | paused, task is an id or null;
"settings" carries the effective process settings and "budget" the pass budget.
"""
import argparse
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ACTIVE = ("ANALYSIS", "IN_PROGRESS")
DONE = ("DONE", "VERIFIED")
CLOSED = ("DONE", "DEFERRED")
PRIO = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
OQ_RE = re.compile(r"\bOQ-\d+\b")
OQ_RESOLVED = ("answered", "closed", "resolved", "dropped", "done")
OWNER_RE = re.compile(r"(?i)\b(owner|decision|decide|approv\w*|question|OQ-\d+|choose|confirm)\b")


def kit_config():
    """The kit's own _config (process settings are read with the newest rules even when
    the project's installed copy predates them)."""
    import importlib.util
    path = os.path.join(KIT, "template", "scripts", "hooks", "_config.py")
    spec = importlib.util.spec_from_file_location("tw_kit_config", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def parallel_state(project, task):
    """(own task id when this tree is on tw/<ID> else None, {id: status on its branch}
    for tasks in other tw/<ID> worktrees)."""
    rc, out = git(project, "worktree", "list", "--porcelain")
    _, cur = git(project, "rev-parse", "--abbrev-ref", "HEAD")
    cur = cur.strip()
    own = cur[3:] if cur.startswith("tw/") else None
    others = {}
    for line in out.splitlines() if rc == 0 else []:
        if line.startswith("branch refs/heads/tw/"):
            tid = line[len("branch refs/heads/tw/"):].strip()
            if tid == own:
                continue
            rc2, text = git(project, "show", "tw/%s:docs/tasks/%s.md" % (tid, tid))
            others[tid] = (task.status(task.parse(text)) or "?") if rc2 == 0 else "?"
    return own, others


def budget_of(proc, tasks, taken, candidate=None):
    """Pass budget: the cap is max_tasks lowered by the by_priority cap of every task
    in the pass (and of the candidate, when given)."""
    cap = proc["batch"]["max_tasks"]
    for tid in list(taken) + ([candidate] if candidate else []):
        t = tasks.get(tid)
        if t:
            cap = min(cap, proc["batch"]["by_priority"].get(t["priority"], cap))
    return {"taken": len(taken), "limit": cap, "left": max(cap - len(taken), 0)}


def _load_helpers(project):
    for d in (os.path.join(project, "scripts", "hooks"),
              os.path.join(KIT, "template", "scripts", "hooks")):
        if os.path.isfile(os.path.join(d, "_task.py")) and os.path.isfile(os.path.join(d, "_config.py")):
            sys.path.insert(0, d)
            break
    import _task
    import _config
    return _task, _config


def git(project, *args):
    try:
        r = subprocess.run(["git", "-C", project] + list(args), capture_output=True, text=True)
        return r.returncode, r.stdout
    except OSError:
        return 1, ""


def last_code_commit(project, tid):
    """Newest commit naming the task that touches files outside docs/tasks/ (the verify
    gate's FRESHNESS rule)."""
    pat = r"(^|[^A-Za-z0-9_-])" + re.escape(tid) + r"([^A-Za-z0-9_]|$)"
    rc, out = git(project, "log", "--format=%H", "-E", "--grep=" + pat, "HEAD")
    for sha in (out.split() if rc == 0 else []):
        rc2, files = git(project, "show", "--name-only", "--format=", sha)
        if any(f and not f.startswith("docs/tasks/") for f in files.splitlines()):
            return sha
    return ""


def acceptance(project, tid, rec):
    """The latest acceptance verdict if it covers the task's current code, else ''.

    A verdict written before the code last changed is stale: after FAIL -> fix the task
    needs a new acceptance round, not the old FAIL again (and an old PASS proves nothing)."""
    verdict = str(rec.get("verdict") or "").split()[0].upper() if str(rec.get("verdict") or "").split() else ""
    sha = str(rec.get("commit") or "").strip()
    if not verdict or not sha:
        return ""
    rc, full = git(project, "rev-parse", "--verify", "-q", sha + "^{commit}")
    if rc != 0:
        return ""
    full = full.strip()
    code = last_code_commit(project, tid)
    if code:
        return verdict if git(project, "merge-base", "--is-ancestor", code, full)[0] == 0 else ""
    rc, changed = git(project, "diff", "--name-only", full, "HEAD")
    return verdict if rc == 0 and all(f.startswith("docs/tasks/") for f in changed.splitlines() if f) else ""


def _list(v):
    if isinstance(v, list):
        return [str(x).strip() for x in v if str(x).strip()]
    v = (v or "").strip()
    if v.startswith("[") and v.endswith("]"):
        v = v[1:-1]
    return [x.strip().strip("'\"") for x in v.split(",") if x.strip().strip("'\"")]


def _num(tid):
    m = re.search(r"(\d+)$", tid or "")
    return int(m.group(1)) if m else 0


def open_questions(project):
    """{OQ-NN: status word} from the table in docs/open-questions.md."""
    out = {}
    try:
        with open(os.path.join(project, "docs", "open-questions.md"), encoding="utf-8",
                  errors="replace") as fh:
            for line in fh:
                cells = [c.strip() for c in line.strip().strip("|").split("|")]
                if len(cells) >= 2 and re.fullmatch(r"OQ-\d+", cells[0]):
                    words = re.findall(r"[a-z]+", cells[-1].lower())
                    out[cells[0]] = words[0] if words else ""
    except OSError:
        pass
    return out


def oq_resolved(oqs, qid):
    return oqs.get(qid, "") in OQ_RESOLVED


def blockers(t, oqs):
    """What keeps a task from being ready because of `blocked_on` (empty = nothing).
    A blocked_on naming open questions blocks while any of them is unresolved (or not
    listed); free text without an OQ id always blocks until it is cleared."""
    b = t["blocked_on"]
    if not b:
        return []
    ids = OQ_RE.findall(b)
    if not ids:
        return [b]
    return [q for q in ids if not oq_resolved(oqs, q)]


def load_tasks(project, task):
    d = os.path.join(project, "docs", "tasks")
    out = {}
    if not os.path.isdir(d):
        return None
    for f in sorted(os.listdir(d)):
        if not f.endswith(".md") or f.startswith("_"):
            continue
        try:
            with open(os.path.join(d, f), encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            rec = task.parse(text)
        except OSError:
            continue
        body = task.body(text) if hasattr(task, "body") else ""
        tid = (rec.get("id") if isinstance(rec.get("id"), str) else "") or f[:-3]
        reviews = task.review_rounds(project, tid)
        vals = task.validation_rounds(project, tid) if hasattr(task, "validation_rounds") else []
        verifies = task.verify_rounds(project, tid)
        out[tid] = {
            "id": tid,
            "title": rec.get("title") if isinstance(rec.get("title"), str) else "",
            "status": task.status(rec) or "TODO",
            "priority": (rec.get("priority") or "P2").strip() if isinstance(rec.get("priority"), str) else "P2",
            "depends_on": _list(rec.get("depends_on")),
            "deploys": str(rec.get("deploys") or "true").strip().lower() not in ("false", "no"),
            "surface": (rec.get("surface") or "").strip() if isinstance(rec.get("surface"), str) else "",
            "blocked_on": (rec.get("blocked_on") or "").strip() if isinstance(rec.get("blocked_on"), str) else "",
            "review": task.first_word(reviews[-1][1].get("verdict", "")) if reviews else "",
            "review_rounds": len(reviews),
            "verify": task.first_word(verifies[-1][1].get("result", "")).upper() if verifies else "",
            "validation": acceptance(project, tid, vals[-1][1]) if vals else "",
            # a line marked `non-blocking` (e.g. "non-blocking: OQ-04 - default chosen") is a
            # deliberate mention: the task does not wait for it, so no warning
            "mentions_oq": sorted(set(q for line in body.splitlines()
                                      if not re.search(r"(?i)non-blocking", line)
                                      for q in OQ_RE.findall(line)), key=_num),
        }
    return out


def effective_priority(tasks):
    """{id: (rank, inherited_from or None, open dependents count)}.

    A prerequisite inherits the highest priority among the open tasks that wait on it
    through depends_on (transitively): a P2 task that unblocks a P1 task is worked as P1,
    otherwise the P1 task starves behind unrelated P2 work."""
    dependents = {}
    for t in tasks.values():
        if t["status"] in CLOSED:
            continue
        for d in t["depends_on"]:
            dependents.setdefault(d, []).append(t["id"])
    out = {}
    for tid, t in tasks.items():
        best, src, seen, stack = PRIO.get(t["priority"], 9), None, {tid}, list(dependents.get(tid, []))
        while stack:
            x = stack.pop()
            if x in seen or x not in tasks:
                continue
            seen.add(x)
            p = PRIO.get(tasks[x]["priority"], 9)
            if p < best or (p == best and src is not None and _num(x) < _num(src)):
                best, src = p, x
            stack.extend(dependents.get(x, []))
        out[tid] = (best, src, len(seen) - 1)
    return out


def _sorted(ts):
    return sorted(ts, key=lambda t: (PRIO.get(t["priority"], 9), _num(t["id"]), t["id"]))


def state_of(project, config):
    st = {"mode": config.read_mode(os.path.join(project, config.CONFIG))
          if os.path.isfile(os.path.join(project, config.CONFIG)) else None}
    pause = os.environ.get("TEAMWRIGHT_PAUSE_FILE") or os.path.join(project, "TEAMWRIGHT_PAUSE")
    st["pause"] = os.path.exists(pause)
    try:
        with open(os.path.join(project, ".teamwright", "current-task")) as fh:
            st["current_task"] = (fh.read().split() or [""])[0] or None
    except OSError:
        st["current_task"] = None
    last = None
    try:
        with open(os.path.join(project, ".teamwright", "logs", "outcomes.jsonl"),
                  encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("event") == "Stop":
                    last = r
    except OSError:
        pass
    st["interrupted_task"] = (last.get("current_task") or None) \
        if last and last.get("outcome") == "interrupted" else None
    rc, out = git(project, "rev-parse", "--is-inside-work-tree")
    st["git"] = rc == 0 and out.strip() == "true"
    st["dirty_files"], st["untracked"], st["unpushed"], st["branch"] = [], 0, 0, None
    if st["git"]:
        _, out = git(project, "status", "--porcelain")
        rows = [(l[:2], l[3:]) for l in out.splitlines()
                if len(l) > 3 and not l[3:].startswith(".teamwright/")]
        # untracked files alone (someone else's notes, build output) do not make a
        # session "interrupted"; they are reported, not routed on
        st["dirty_files"] = [p for s_, p in rows if s_ != "??"]
        st["untracked"] = len([p for s_, p in rows if s_ == "??"])
        st["branch"] = git(project, "rev-parse", "--abbrev-ref", "HEAD")[1].strip() or None
        rc, out = git(project, "rev-list", "--count", "@{u}..HEAD")
        if rc == 0 and out.strip().isdigit():
            st["unpushed"] = int(out.strip())
    st["dirty"] = bool(st["dirty_files"])
    return st


def _d(action, task=None, reason="", role=None, ask=False):
    return {"action": action, "task": task, "reason": reason, "role": role, "ask_owner": ask}


def is_ready(t, tasks, oqs):
    return t["status"] == "TODO" and not blockers(t, oqs) and \
        all((tasks.get(d) or {}).get("status") in DONE for d in t["depends_on"])


def warnings_for(tasks, oqs):
    """Record problems the router can see but does not decide on."""
    out = []
    for t in _sorted(tasks.values()):
        if t["status"] in CLOSED + ("VERIFIED",):
            continue
        named = OQ_RE.findall(t["blocked_on"])
        if t["blocked_on"] and named and not blockers(t, oqs):
            out.append("%s: blocked_on names %s, already %s in docs/open-questions.md - clear "
                       "blocked_on" % (t["id"], ", ".join(named), "/".join(sorted({oqs.get(q, "?") for q in named}))))
        if not t["blocked_on"] and t["status"] in ("TODO", "BLOCKED"):
            pending = [q for q in t["mentions_oq"] if not oq_resolved(oqs, q)]
            if pending:
                out.append("%s mentions unresolved %s but blocked_on is empty: if the question must "
                           "be answered before analysis, set `blocked_on: %s`" % (
                               t["id"], ", ".join(pending), ", ".join(pending)))
    return out


def candidates(tasks, st, oqs=None):
    """Every applicable decision in router order (the first one is the answer)."""
    oqs = oqs or {}
    ts = list(tasks.values())
    by = lambda *sts: _sorted([t for t in ts if t["status"] in sts])  # noqa: E731
    out = []

    # 1. dirty tree / interrupted session
    hint = st["interrupted_task"] or st["current_task"]
    if hint and hint in tasks and tasks[hint]["status"] not in CLOSED + ("VERIFIED",):
        why = "interrupted session" if st["interrupted_task"] == hint else "current task"
        if st["dirty"]:
            why += ", uncommitted changes (%d file(s))" % len(st["dirty_files"])
        out.append(_d("resume", hint, "%s: %s is %s" % (why, hint, tasks[hint]["status"]),
                      role=_role(tasks[hint])))
    elif st["dirty"]:
        active = by(*ACTIVE)
        if len(active) == 1:
            out.append(_d("resume", active[0]["id"], "uncommitted changes (%d file(s)); %s is %s"
                          % (len(st["dirty_files"]), active[0]["id"], active[0]["status"]),
                          role=_role(active[0])))
        else:
            out.append(_d("decide", None, "uncommitted changes (%d file(s)) that belong to no "
                          "single active task: commit, assign to a task or leave them"
                          % len(st["dirty_files"]), ask=True))

    # 2. active work
    for t in by(*ACTIVE):
        out.append(_d("continue", t["id"], "%s is %s" % (t["id"], t["status"]), role=_role(t)))

    # 3. review
    for t in by("NEEDS_REVIEW"):
        v = t["review"]
        if v == "APPROVE":
            out.append(_d("continue", t["id"], "round %d APPROVE recorded: move %s to CODE_COMPLETE"
                          % (t["review_rounds"], t["id"]), role="orchestrator"))
        elif v == "ESCALATE":
            out.append(_d("decide", t["id"], "review escalated after %d round(s): the owner decides"
                          % t["review_rounds"], ask=True))
        elif v == "REJECT_RECURRENCE":
            out.append(_d("continue", t["id"], "REJECT_RECURRENCE: defer %s into its rca task"
                          % t["id"], role="orchestrator"))
        else:
            out.append(_d("review", t["id"], "%s awaits review round %d" % (t["id"], t["review_rounds"] + 1),
                          role="code-reviewer"))

    # 4. verify, then acceptance (task-validator's verdict in ## Validation)
    for t in by("CODE_COMPLETE", "DEPLOYED", "VERIFIED"):
        no_record = t["status"] == "CODE_COMPLETE" and not t["deploys"] and t["surface"] in ("none", "")
        if t["verify"] == "PASS" or no_record or t["status"] == "VERIFIED":
            what = "PASS verify recorded" if t["verify"] == "PASS" else (
                "deploys: false, nothing to verify" if no_record else "VERIFIED")
            v = t["validation"]
            if v == "PASS":
                out.append(_d("continue", t["id"], "%s, acceptance PASS: close %s as DONE"
                              % (what, t["id"]), role="orchestrator"))
            elif v == "FAIL":
                out.append(_d("continue", t["id"], "acceptance FAIL: %s goes back to IN_PROGRESS "
                              "with the validator's findings" % t["id"], role="orchestrator"))
            elif v == "NEEDS_OWNER":
                out.append(_d("decide", t["id"], "acceptance NEEDS_OWNER: the validator needs an "
                              "owner action; once it is done, spawn task-validator for a new round",
                              ask=True))
            else:
                out.append(_d("verify", t["id"], "%s, no acceptance verdict for the current code: task-validator "
                              "checks Acceptance against evidence%s" % (
                                  what, " (no verify record needed)" if no_record else ""),
                              role="task-validator"))
        else:
            out.append(_d("verify", t["id"], "%s is %s without a PASS verify record"
                          % (t["id"], t["status"]), role="task-validator"))
    for t in by("VERIFY_FAIL"):
        out.append(_d("reanalyze", t["id"], "verify failed: %s goes back to ANALYSIS" % t["id"],
                      role="problem-investigator"))

    # 5. owner decisions
    for t in by("BLOCKED"):
        if OWNER_RE.search(t["blocked_on"]) or not t["blocked_on"]:
            out.append(_d("decide", t["id"], "BLOCKED: %s" % (t["blocked_on"] or "no reason recorded"),
                          ask=True))

    # 6. ready TODO, by effective priority, then how much it unblocks, then id
    eff = effective_priority(tasks)
    ready = sorted([t for t in ts if is_ready(t, tasks, oqs)],
                   key=lambda t: (eff[t["id"]][0], -eff[t["id"]][2], _num(t["id"]), t["id"]))
    for t in ready:
        rank, src, _n = eff[t["id"]]
        why = "%s %s is ready: %s" % (t["priority"], t["id"], t["title"])
        if src:
            why += " (inherits %s from %s, which depends on it)" % (tasks[src]["priority"], src)
        out.append(_d("start", t["id"], why, role="problem-investigator", ask=True))

    # 7. push or idle
    if st["unpushed"]:
        out.append(_d("decide", None, "%d unpushed commit(s): push?" % st["unpushed"], ask=True))
    return out


def _role(t):
    return "problem-investigator" if t["status"] == "ANALYSIS" else "developer"


def decide(project, taken=None):
    task, config = _load_helpers(project)
    st = state_of(project, config)
    kc = kit_config()
    proc = kc.read_process(os.path.join(project, kc.CONFIG))
    tasks = load_tasks(project, task)
    if tasks is None:
        res = _d("idle", None, "no docs/tasks/ - run /teamwright:adopt or /teamwright:init first")
        res.update(alternatives=[], state=st, tasks=[], warnings=[], settings=proc, budget=None)
        return res
    oqs = open_questions(project)
    own, elsewhere = parallel_state(project, task)
    cands = candidates({k: v for k, v in tasks.items() if k not in elsewhere}, st, oqs)
    if own:
        # a worktree session works its own task only, and never pushes
        cands = [c for c in cands if c["task"] == own]
        if own in tasks and tasks[own]["status"] in ("CODE_COMPLETE", "DEPLOYED", "VERIFIED", "DONE"):
            cands = []  # verification follows the merge and the push from the main tree
        if not cands and own in tasks:
            cands = [_d("idle", own, "%s is %s on tw/%s: this worktree's work is done - merge it from the "
                        "main tree (/teamwright:parallel)" % (own, tasks[own]["status"], own))]
    else:
        merges = [_d("merge", tid, "%s is %s on tw/%s: merge it into this branch, run the gate, remove the "
                     "worktree (/teamwright:parallel)" % (tid, stt, tid), role="orchestrator")
                  for tid, stt in sorted(elsewhere.items(), key=lambda kv: _num(kv[0]))
                  if stt in ("CODE_COMPLETE", "DEPLOYED", "VERIFIED", "DONE")]
        at = next((i for i, c in enumerate(cands) if c["action"] == "start" or
                   (c["action"] == "decide" and c["task"] is None and "unpushed" in c["reason"])), len(cands))
        cands = cands[:at] + merges + cands[at:]
    auto = proc["autonomy"]["start"] == "auto"
    budget = None
    if taken is not None:
        budget = budget_of(proc, tasks, taken)
        kept, dropped_at = [], None
        for c in cands:
            if c["action"] == "start" and c["task"] in taken:
                continue
            if c["action"] == "start":
                b = budget_of(proc, tasks, taken, c["task"])
                if len(taken) >= b["limit"]:
                    # a higher-priority task does not fit, a lower one may still
                    dropped_at = len(kept) if dropped_at is None else dropped_at
                    continue
            kept.append(c)
        if dropped_at is not None and not any(c["action"] == "start" for c in kept):
            kept.insert(dropped_at, _d("stop", None, "pass budget used: %d task(s), cap %d (process.batch; "
                                       "the lowest priority cap in the pass wins) - end the pass at "
                                       "this barrier" % (len(taken), budget["limit"])))
        cands = kept
    for c in cands:
        if c["action"] == "start" and auto:
            c["ask_owner"] = False
            c["reason"] += " (autonomy.start: auto)"
    if st["pause"]:
        first = _d("paused", None, "TEAMWRIGHT_PAUSE exists: the team is stopped; remove the file "
                   "to resume (next would be: %s)" % (
                       ("%s %s" % (cands[0]["action"], cands[0]["task"] or "")).strip()
                       if cands else "idle"), ask=True)
        rest = cands
    elif cands:
        first, rest = cands[0], cands[1:]
    else:
        counts = {}
        for t in tasks.values():
            counts[t["status"]] = counts.get(t["status"], 0) + 1
        waiting = [t["id"] for t in tasks.values() if t["status"] in ("TODO", "BLOCKED")]
        first = _d("idle", None, "nothing actionable%s - plan the next sprint" % (
            " (%s waiting on dependencies or external blockers)" % ", ".join(sorted(waiting, key=_num))
            if waiting else ""))
        rest = []
    seen, alts = set(), []
    for c in rest:
        k = (c["action"], c["task"])
        if k in seen or k == (first["action"], first["task"]):
            continue
        seen.add(k)
        alts.append({"action": c["action"], "task": c["task"], "reason": c["reason"]})
    first["alternatives"] = alts[:5]
    first["state"] = st
    eff = effective_priority(tasks)
    first["tasks"] = [dict(t, ready=all((tasks.get(d) or {}).get("status") in DONE for d in t["depends_on"])
                           and not blockers(t, oqs),
                           blockers=blockers(t, oqs),
                           effective_priority="P%d" % eff[t["id"]][0] if eff[t["id"]][0] < 9 else t["priority"])
                      for t in _sorted(tasks.values())]
    first["warnings"] = warnings_for(tasks, oqs)
    first["settings"] = proc
    first["parallel"] = {"own": own, "elsewhere": elsewhere}
    first["budget"] = budget
    return first


def human(res):
    st = res["state"]
    counts = {}
    for t in res["tasks"]:
        counts[t["status"]] = counts.get(t["status"], 0) + 1
    lines = ["teamwright flow",
             "  mode: %s | branch: %s | %s | unpushed: %d%s" % (
                 st.get("mode") or "not adopted", st.get("branch") or "-",
                 "dirty (%d file(s))" % len(st["dirty_files"]) if st.get("dirty") else "clean tree",
                 st.get("unpushed") or 0, " | PAUSED" if st.get("pause") else ""),
             "  tasks: " + (", ".join("%s %d" % kv for kv in sorted(counts.items())) or "none")]
    if st.get("current_task"):
        lines.append("  current task: %s" % st["current_task"])
    lines += ["", "next: %s%s - %s" % (res["action"], " " + res["task"] if res["task"] else "", res["reason"])]
    if res.get("role"):
        lines.append("  role: %s" % res["role"])
    if res.get("ask_owner"):
        lines.append("  owner decision needed")
    for w in res.get("warnings") or []:
        lines.append("  warning: %s" % w)
    if res["alternatives"]:
        lines.append("then / instead:")
        lines += ["  %s%s - %s" % (a["action"], " " + a["task"] if a["task"] else "", a["reason"])
                  for a in res["alternatives"]]
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project", default=os.getcwd(), help="project root (default: cwd)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--pass", dest="taken", default=None,
                    help="tasks this pass already took, comma-separated (applies process.batch)")
    args = ap.parse_args(argv)
    project = os.path.abspath(args.project)
    if not os.path.isdir(project):
        print("tw-next: no such project: %s" % project, file=sys.stderr)
        return 2
    taken = None if args.taken is None else [x.strip() for x in args.taken.split(",") if x.strip()]
    res = decide(project, taken)
    print(json.dumps(res, indent=2, ensure_ascii=False) if args.json else human(res))
    return 0


if __name__ == "__main__":
    sys.exit(main())
