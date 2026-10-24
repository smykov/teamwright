#!/usr/bin/env python3
"""tw-next.py - deterministic router for /teamwright:flow (python3 stdlib only, read-only).

Reads docs/tasks/*.md with their .reviews/ and .verify/ rounds, .teamwright/current-task,
the journal (.teamwright/logs/outcomes.jsonl), the gate mode, TEAMWRIGHT_PAUSE and git
state, and prints the next action. The skill talks to the owner; this script only
decides, so the same project state always gives the same answer.

  python3 tw-next.py [--project PATH] [--json [--brief]] [--pass T-1,T-2] [--stage STAGE [--task IDS]]

--brief (implies --json) prints what a stage session needs and nothing else: `request`
first, the action, stage, batch, model, command, candidates (at most max(8, 2 x the batch
cap), compact, overlaps among the shown ones; `candidates_total` says how many wait; printed
once, under `request`, when the request is for the router's stage), per-stage counts, task
counts by status, decisions, warnings, headless, alternatives, settings, a compact state. The full JSON has `request` first too, and
never lists closed tasks (DONE, DEFERRED) in `tasks` - `counts` counts every status.

--pass names the tasks this flow run (a pass) has already taken. The router then applies
`process.batch` from .teamwright/config.yml: when the pass is at its cap, `start` becomes
`stop` (end the pass at this barrier). `process.autonomy.start: auto` makes `start`
need no owner answer.

Decision order (first match wins):
  0. paused      TEAMWRIGHT_PAUSE exists: the team is stopped, report only
  1. resume      tracked changes in the tree, or the last session ended `interrupted` ->
                 the task it belongs to (the current task, else the single active one;
                 decide when a dirty tree belongs to no task). A current task on a clean
                 tree is not a resume: its stage is recorded and committed.
  2. continue    ANALYSIS / IN_PROGRESS task (role by stage: problem-investigator,
                 test-writer for red-tests, developer for implement)
  3. review      NEEDS_REVIEW -> spawn the reviewer (APPROVE recorded -> continue to
                 CODE_COMPLETE; ESCALATE -> decide; REJECT_RECURRENCE -> continue: defer)
  4. verify      CODE_COMPLETE / DEPLOYED without a PASS verify record (a task that deploys:
                 only once its code is on the delivery branch - origin/HEAD, origin/main or
                 origin/master - i.e. after DRAIN; before that the push decision names it); then the
                 acceptance verdict in ## Validation (PASS -> continue: close; FAIL ->
                 continue: back to IN_PROGRESS; NEEDS_OWNER -> decide; none -> verify:
                 task-validator). deploys: false + surface none needs no verify record,
                 only the acceptance verdict;
     reanalyze   VERIFY_FAIL -> back to ANALYSIS
  5. decide      BLOCKED on an owner decision
  6. start       ready TODO -> ANALYSIS (the owner picks among `alternatives`).
                 Ready: every depends_on is DONE/VERIFIED (also CODE_COMPLETE/DEPLOYED with
                 process.ready.after: code_complete) and blocked_on is empty, or
                 names only open questions (OQ-NN) already answered or dropped in
                 docs/open-questions.md. Order: effective priority (a task inherits
                 the highest priority of the open tasks that depend on it, directly or
                 not), then the number of open tasks it unblocks, then id.
  7. decide      unpushed commits - not on the delivery branch: against its upstream on that
                 branch, against the delivery branch on any other (a wip/ or task branch) -
                 push is the owner's call; else idle
     stop        (with --pass) the pass took as many tasks as process.batch allows
  Parallel work: a task on a linked worktree whose branch names it - `tw/<ID>` (tw-parallel.py)
  or `task/<ID>`, any suffix after the id allowed; $TEAMWRIGHT_TASK_BRANCH_RE overrides
  the pattern, group 1 = the id - is worked in that worktree's session. Its state comes
  from the worktree's copy of the record (status, analysis, review and verify rounds),
  marked `in_worktree`. The main tree skips it, and offers `merge` once that record is
  CODE_COMPLETE or later. A session on such a branch sees only its own task and never
  pushes: delivery happens from the main tree after the merge.

Stages. Every task-bound decision carries the stage that does it: analyze (TODO ->
ANALYSIS -> IN_PROGRESS, VERIFY_FAIL re-analysis), red-tests and implement (inside
IN_PROGRESS: the task's `stage:` field, checked against the evidence - `## Tests` filled
means the red tests are written; the field wins when it is behind the evidence (red-tests
with tests filled: a send-back to the tests), the evidence when the field is ahead of it
(implement without tests), with a warning; a task without the field is routed by the
evidence), review (NEEDS_REVIEW), verify (CODE_COMPLETE
and later). `process.stages.<stage>` holds a stage back while other work exists: it runs
when `min` tasks wait, a P0/P1 task waits, the oldest waiting task is older than
`max_wait_hours`, or nothing else is to do (`work_available` is the one predicate for both
"what runs" and "nothing to do"). `batch` = the tasks one stage session takes, in router
order. `process.models.<stage>` is reported as `model`.

--stage STAGE [--task IDS] answers a stage command (/teamwright:<stage>): `request` says
whether the stage may run now (ok), on which tasks (batch), and if not, which command to run
instead (hint). An explicit stage ignores `min`.

JSON: {"action", "task", "reason", "role", "ask_owner", "alternatives": [...],
       "state": {...}, "tasks": [...], "warnings": [...]}; action is one of resume | continue | review |
verify | reanalyze | decide | start | stop | merge | idle | paused, task is an id or null;
"settings" carries the effective process settings, "recommended" the values adopt, init,
status and settings offer (_config.PROCESS_RECOMMENDED), and "budget" the pass budget;
"stage", "batch", "model", "command", "work_available", "stages" (per stage: waiting
tasks, due, why, settings) and "headless" (prompt and model for one stage per job) describe
the stage to run. "decisions" lists every owner decision. "headless" is the autonomous answer:
the first piece of work in router order (past owner decisions, skipping a start that asks the
owner), a prompt without ids, and run=false only when no such work is left or a pause, a
dirty tree of no task or a used pass stops everything.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ACTIVE = ("ANALYSIS", "IN_PROGRESS")
DONE = ("DONE", "VERIFIED")
# What counts as a finished dependency, by `process.ready.after`.
DEP_DONE = {"verified": DONE, "code_complete": DONE + ("CODE_COMPLETE", "DEPLOYED")}
CLOSED = ("DONE", "DEFERRED")
PRIO = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
OQ_RE = re.compile(r"\bOQ-\d+\b")
OQ_RESOLVED = ("answered", "closed", "resolved", "dropped", "done")
OWNER_RE = re.compile(r"(?i)\b(owner|decision|decide|approv\w*|question|OQ-\d+|choose|confirm)\b")
STAGES = ("analyze", "red-tests", "implement", "review", "verify")
TASK_STAGES = ("red-tests", "implement")
# Actions that are work a session can do (a stage, a merge); decide/stop/idle/paused are not.
WORK = ("resume", "continue", "review", "verify", "reanalyze", "start", "merge")
STAGE_ROLE = {"analyze": "problem-investigator", "red-tests": "test-writer", "implement": "developer",
              "review": "code-reviewer", "verify": "task-validator"}
URGENT = 1  # effective priority rank at or above which a waiting task runs its stage now (P0, P1)


def kit_config():
    """The kit's own _config (process settings are read with the newest rules even when
    the project's installed copy predates them)."""
    import importlib.util
    path = os.path.join(KIT, "template", "scripts", "hooks", "_config.py")
    spec = importlib.util.spec_from_file_location("tw_kit_config", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def branch_re(task):
    """A branch that names a task: group 1 is the task id."""
    return re.compile(os.environ.get("TEAMWRIGHT_TASK_BRANCH_RE")
                      or r"^(?:tw|task)/(%s)(?:$|[-_/.])" % task.TASK_ID)


def task_worktrees(project, task):
    """(own task id when this tree's branch names a task else None,
    {id: {"path", "branch"}} for the other worktrees whose branch names a task)."""
    rx = branch_re(task)
    _, cur = git(project, "rev-parse", "--abbrev-ref", "HEAD")
    m = rx.match(cur.strip())
    # Only a linked worktree is a per-task tree. The main checkout on a task branch (an
    # autonomous run's `task/T-051-run18`) is the whole project: it verifies and reviews
    # any task, and a branch name alone must not shrink it to one task.
    _, gd = git(project, "rev-parse", "--absolute-git-dir")
    _, cd = git(project, "rev-parse", "--path-format=absolute", "--git-common-dir")
    linked = bool(gd.strip()) and os.path.realpath(gd.strip()) != os.path.realpath(cd.strip() or gd.strip())
    own = m.group(1) if m and linked else None
    _, top = git(project, "rev-parse", "--show-toplevel")
    here = os.path.realpath(top.strip() or project)
    rc, out = git(project, "worktree", "list", "--porcelain")
    found, path = {}, None
    for line in out.splitlines() if rc == 0 else []:
        if line.startswith("worktree "):
            path = line[len("worktree "):].strip()
        elif line.startswith("branch refs/heads/") and path:
            branch = line[len("branch refs/heads/"):].strip()
            m = rx.match(branch)
            if m and os.path.realpath(path) != here and m.group(1) != own:
                found[m.group(1)] = {"path": path, "branch": branch}
    return own, found


def with_worktrees(project, task, tasks):
    """Tasks worked in another worktree take their state from that worktree's record.
    Returns (own, {id: {path, branch, status}}); `tasks` is updated in place."""
    own, wts = task_worktrees(project, task)
    for tid, wt in wts.items():
        one = load_tasks(wt["path"], task, only=tid) or {}
        if tid in one:
            tasks[tid] = dict(one[tid], in_worktree=wt["path"], branch=wt["branch"])
        elif tid in tasks:
            tasks[tid] = dict(tasks[tid], in_worktree=wt["path"], branch=wt["branch"])
        wt["status"] = tasks[tid]["status"] if tid in tasks else "?"
    return own, wts


def budget_of(proc, tasks, taken, candidate=None):
    """Pass budget: the cap is max_tasks lowered by the by_priority cap of every task
    in the pass (and of the candidate, when given)."""
    cap = proc["batch"]["max_tasks"]
    for tid in list(taken) + ([candidate] if candidate else []):
        t = tasks.get(tid)
        if t:
            cap = min(cap, proc["batch"]["by_priority"].get(t["priority"], cap))
    return {"taken": len(taken), "limit": cap, "left": max(cap - len(taken), 0)}


HELPER_DRIFT = []   # names the project's installed _task.py lacks (filled by _load_helpers)


def _load_helpers(project):
    """The project's installed _task / _config (the gates run the same code), with every
    helper the project's copy lacks taken from the kit's: a plugin updated without
    `tw-install.py apply` must not route on missing helpers (an old _task.py without
    tests_written / task_stage sent every IN_PROGRESS task to red-tests, silently).
    HELPER_DRIFT names what was filled in; the router reports it as a warning."""
    import importlib.util
    import types
    kit_dir = os.path.join(KIT, "template", "scripts", "hooks")
    proj_dir = os.path.join(project, "scripts", "hooks")
    d = proj_dir if all(os.path.isfile(os.path.join(proj_dir, f)) for f in ("_task.py", "_config.py")) \
        else kit_dir
    sys.path.insert(0, d)
    import _task
    import _config
    del HELPER_DRIFT[:]
    if os.path.realpath(os.path.dirname(os.path.abspath(_task.__file__))) != os.path.realpath(kit_dir):
        try:
            spec = importlib.util.spec_from_file_location("tw_kit_task", os.path.join(kit_dir, "_task.py"))
            kt = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(kt)
        except Exception:  # an unreadable kit copy only loses the fallback
            kt = None
        for name in sorted(vars(kt)) if kt else []:
            v = getattr(kt, name)
            if name.startswith("_") or isinstance(v, types.ModuleType) or hasattr(_task, name):
                continue
            setattr(_task, name, v)
            HELPER_DRIFT.append(name)
    return _task, _config


def helper_warnings():
    if not HELPER_DRIFT:
        return []
    return ["install drift: scripts/hooks/_task.py predates the plugin (missing: %s) - the router uses "
            "the plugin's copies, the gates still run the old file: run `tw-install.py apply` "
            "(/teamwright:reconfigure) to update the project's hooks" % ", ".join(HELPER_DRIFT)]


def git(project, *args):
    try:
        r = subprocess.run(["git", "-C", project] + list(args), capture_output=True, text=True)
        return r.returncode, r.stdout
    except OSError:
        return 1, ""


# Process records, not code - the same set as _task.RECORD_RE in the hooks (the verify
# gate's FRESHNESS rule) and scripts/tw-ci-changes. A decision naming a task does not
# make its acceptance stale.
RECORD_RE = re.compile(r"^docs/tasks/|^docs/sprints/|^docs/process-reviews/"
                       r"|^docs/(decisions|open-questions)\.md$")


def last_code_commit(project, tid):
    """Newest commit naming the task that touches files other than process records
    (the verify gate's FRESHNESS rule)."""
    pat = r"(^|[^A-Za-z0-9_-])" + re.escape(tid) + r"([^A-Za-z0-9_]|$)"
    rc, out = git(project, "log", "--format=%H", "-E", "--grep=" + pat, "HEAD")
    for sha in (out.split() if rc == 0 else []):
        rc2, files = git(project, "show", "--name-only", "--format=", sha)
        if any(f and not RECORD_RE.search(f) for f in files.splitlines()):
            return sha
    return ""


def default_ref(project):
    """The delivery branch as a remote-tracking ref: origin/HEAD, else origin/main, else
    origin/master; None without a remote (nothing is ever pushed, so nothing waits for it)."""
    rc, out = git(project, "symbolic-ref", "-q", "refs/remotes/origin/HEAD")
    if rc == 0 and out.strip():
        return out.strip()
    for ref in ("refs/remotes/origin/main", "refs/remotes/origin/master"):
        if git(project, "rev-parse", "--verify", "-q", ref)[0] == 0:
            return ref
    return None


def delivered(project, tid, ref):
    """True when the task's code is on the delivery branch (its last code commit is reachable
    from `ref`), or when there is no delivery branch to wait for."""
    if not ref:
        return True
    code = last_code_commit(project, tid)
    return not code or git(project, "merge-base", "--is-ancestor", code, ref)[0] == 0


def mark_delivered(project, tasks, st):
    """Sets `delivered` on every CODE_COMPLETE task that deploys (step 4 waits for it)."""
    ref = default_ref(project) if st.get("git") else None
    for t in tasks.values():
        if t["status"] == "CODE_COMPLETE" and t["deploys"]:
            t["delivered"] = delivered(project, t["id"], ref)


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
    return verdict if rc == 0 and all(RECORD_RE.search(f) for f in changed.splitlines() if f) else ""


def _fail_streak(vals, sweeps=False):
    """FAIL rounds at the end of a task's validation records (with sweeps=True, only
    those with `method: sweep`)."""
    n = 0
    for _, rec in reversed(vals):
        if str(rec.get("verdict") or "").split()[:1] != ["FAIL"]:
            break
        if not sweeps or str(rec.get("method") or "").strip().lower() == "sweep":
            n += 1
    return n


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


def is_task_file(task, name):
    """Only <ID>.md is a task record: not a template, not T-089.history.md."""
    tid = getattr(task, "TASK_ID", r"[A-Z][A-Z0-9]*-\d+")
    return bool(re.fullmatch(r"(?:%s)\.md" % tid, name))


def load_tasks(project, task, only=None):
    d = os.path.join(project, "docs", "tasks")
    out = {}
    if not os.path.isdir(d):
        return None
    for f in sorted(os.listdir(d)):
        if not is_task_file(task, f) or (only and f[:-3] != only):
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
        has = lambda name: getattr(task, name, None)  # noqa: E731 - an older installed _task.py
        out[tid] = {
            "stage_field": task.task_stage(rec) if has("task_stage") else "",
            "evidence": {
                "analysis": not task.analysis_missing(rec),
                "tests": bool(has("tests_written") and task.tests_written(text)),
                "failure_branches": bool(has("failure_branches") and task.failure_branches(text)),
            },
            "id": tid,
            "type": (rec.get("type") or "").strip() if isinstance(rec.get("type"), str) else "",
            "seam": str((rec.get("analysis") or {}).get("seam") or "") if isinstance(rec.get("analysis"), dict) else "",
            "acceptance_items": len(re.findall(r"(?m)^\s*-\s*\[[ xX]\]", task.section(text, "Acceptance")))
            if hasattr(task, "section") else 0,
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
            "validation_fail_streak": _fail_streak(vals),
            "validation_sweep_fails": _fail_streak(vals, sweeps=True),
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
    st["delivery_ref"] = None
    st["wip_waiting"] = {}   # {ANALYSIS task with its analysis done: the IN_PROGRESS task it waits for}
    if st["git"]:
        _, out = git(project, "status", "--porcelain")
        rows = [(l[:2], l[3:]) for l in out.splitlines()
                if len(l) > 3 and not l[3:].startswith(".teamwright/")]
        # untracked files alone (someone else's notes, build output) do not make a
        # session "interrupted"; they are reported, not routed on
        st["dirty_files"] = [p for s_, p in rows if s_ != "??"]
        st["untracked"] = len([p for s_, p in rows if s_ == "??"])
        st["branch"] = git(project, "rev-parse", "--abbrev-ref", "HEAD")[1].strip() or None
        # Unpushed = not yet delivered. On the delivery branch that is its upstream; on any
        # other branch (a wip/ branch of an autonomous run, a task branch) the commits not on
        # the delivery branch - the wip branch's own upstream is always even after its push.
        ref = default_ref(project)
        st["delivery_ref"] = ref[len("refs/remotes/"):] if ref else None
        on_delivery = bool(ref) and st["branch"] == ref.rsplit("/", 1)[-1]
        rc, out = git(project, "rev-list", "--count", "@{u}..HEAD")
        if (rc != 0 or not on_delivery) and ref:
            rc, out = git(project, "rev-list", "--count", "%s..HEAD" % ref)
        if rc == 0 and out.strip().isdigit():
            st["unpushed"] = int(out.strip())
    st["dirty"] = bool(st["dirty_files"])
    return st


def _d(action, task=None, reason="", role=None, ask=False):
    return {"action": action, "task": task, "reason": reason, "role": role, "ask_owner": ask,
            "stage": None}


def deps_done(t, tasks, after="verified"):
    ok = DEP_DONE.get(after, DONE)
    return all((tasks.get(d) or {}).get("status") in ok for d in t["depends_on"])


def is_ready(t, tasks, oqs, after="verified"):
    return t["status"] == "TODO" and not blockers(t, oqs) and deps_done(t, tasks, after)


def warnings_for(tasks, oqs):
    """Record problems the router can see but does not decide on."""
    out = []
    for t in _sorted(tasks.values()):
        if t["status"] in CLOSED + ("VERIFIED",):
            continue
        w = stage_of(t)[1] if "evidence" in t else None
        if w:
            out.append(w)
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


def drift_warnings(project):
    """A settings change that did not reach a locally edited rendered file (kept-local):
    the role still works from the old value (tw-process.py render_drift)."""
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("tw_process", os.path.join(KIT, "scripts", "tw-process.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        drift = mod.render_drift(project)
    except Exception:  # a broken check must never stop the router
        return []
    return ["render drift: %s carries %s %s, config says %s - re-render it (tw-install.py apply "
            "after merging the local edit) or fix the line by hand" % (
                d["file"], d["setting"], d["found"] or "<line rewritten>", d["expected"]) for d in drift]


def candidates(tasks, st, oqs=None, after="verified"):
    """Every applicable decision in router order (the first one is the answer)."""
    oqs = oqs or {}
    ts = list(tasks.values())
    by = lambda *sts: _sorted([t for t in ts if t["status"] in sts])  # noqa: E731
    out = []

    # 1. dirty tree / interrupted session. A current task on a clean tree is not a resume:
    # its stage is recorded and committed, the next stage picks it up (step 2).
    hint = st["interrupted_task"] or (st["current_task"] if st["dirty"] else None)
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

    # 2. active work. One task IN_PROGRESS per working tree (one .teamwright/current-task):
    # an ANALYSIS task whose analysis is complete has only the move into IN_PROGRESS left,
    # and waits while another task of this tree is there - analyze may batch analyses, not WIP.
    wip = [t["id"] for t in by("IN_PROGRESS")]
    st["wip_waiting"] = {}
    for t in by(*ACTIVE):
        if t["status"] == "ANALYSIS" and wip and (t.get("evidence") or {}).get("analysis") \
                and not (hint == t["id"] and st["dirty"]):
            st["wip_waiting"][t["id"]] = wip[0]
            continue
        sub = ", stage %s%s" % (stage_of(t)[0], "" if t.get("stage_field") else " (no stage field: from the evidence)") \
            if t["status"] == "IN_PROGRESS" else ""
        out.append(_d("continue", t["id"], "%s is %s%s" % (t["id"], t["status"], sub), role=_role(t)))

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
                              "checks Acceptance against evidence%s%s" % (
                                  what, " (no verify record needed)" if no_record else "",
                                  "; acceptance failed in two sweep rounds: this round is NEEDS_OWNER "
                                  "(the survivors, the guarantee each breaks; the owner accepts the rest "
                                  "as follow-ups or rethinks the task), not a third sweep"
                                  if t.get("validation_sweep_fails", 0) >= 2 else
                                  "; acceptance failed %d times in a row: this round is `method: sweep` "
                                  "or NEEDS_OWNER, not another sample" % t["validation_fail_streak"]
                                  if t.get("validation_fail_streak", 0) >= 2 else ""),
                              role="task-validator"))
        elif t["status"] == "CODE_COMPLETE" and t["deploys"] and not t.get("delivered", True):
            continue  # verified after DRAIN: the push decision below names it
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
    ready = sorted([t for t in ts if is_ready(t, tasks, oqs, after)],
                   key=lambda t: (eff[t["id"]][0], -eff[t["id"]][2], _num(t["id"]), t["id"]))
    for t in ready:
        rank, src, _n = eff[t["id"]]
        why = "%s %s is ready: %s" % (t["priority"], t["id"], t["title"])
        if src:
            why += " (inherits %s from %s, which depends on it)" % (tasks[src]["priority"], src)
        out.append(_d("start", t["id"], why, role="problem-investigator", ask=True))

    # 7. push or idle
    if st["unpushed"]:
        waiting = [t["id"] for t in by("CODE_COMPLETE") if t["deploys"] and not t.get("delivered", True)
                   and t["verify"] != "PASS"]
        out.append(_d("decide", None, "%d unpushed commit(s)%s: push?%s" % (
            st["unpushed"], " (not on %s)" % st["delivery_ref"] if st.get("delivery_ref") and
            st["branch"] != st["delivery_ref"].rsplit("/", 1)[-1] else "",
            " %s deploy%s and %s verified after the push (DRAIN)" % (
                ", ".join(waiting), "s" if len(waiting) == 1 else "", "is" if len(waiting) == 1 else "are")
            if waiting else ""), ask=True))
    for c in out:
        t = tasks.get(c["task"]) if c["task"] else None
        c["stage"] = stage_of(t)[0] if t and c["action"] in WORK else None
    return out


def stage_of(t):
    """(stage, warning or None). IN_PROGRESS: the `stage:` field checked against the
    evidence; `## Tests` filled = the red tests are written (implement), else red-tests.
    The field wins when it is BEHIND the evidence (`stage: red-tests` with the tests filled:
    review or verify sent the task back to its tests, a legal step back); the evidence wins
    only when the field is AHEAD of it (`stage: implement` with no tests), with a warning. A
    task without the field (started before stages), or with an unknown value, is routed by
    the evidence."""
    s = t["status"]
    if s in ("TODO", "ANALYSIS", "VERIFY_FAIL"):
        return "analyze", None
    if s == "NEEDS_REVIEW":
        return "review", None
    if s in ("CODE_COMPLETE", "DEPLOYED", "VERIFIED"):
        return "verify", None
    if s != "IN_PROGRESS":
        return None, None
    ev = t.get("evidence") or {}
    by_evidence = "implement" if ev.get("tests") else "red-tests"
    why = "## Tests is filled" if ev.get("tests") else "## Tests is empty"
    f = t.get("stage_field") or ""
    warn = None
    if f and f not in TASK_STAGES:
        warn = "%s: `stage: %s` is not a stage (red-tests | implement); routed by the evidence (%s) " \
               "to %s" % (t["id"], f, why, by_evidence)
    elif f == "red-tests" and by_evidence == "implement":
        by_evidence = "red-tests"  # sent back to its tests: the field is authoritative
    elif f and f != by_evidence:
        warn = "%s: `stage: %s`, but the evidence says %s (%s) - routed to %s; fix the field or " \
               "the record" % (t["id"], f, by_evidence, why, by_evidence)
    if not ev.get("analysis", True):
        warn = (warn + "; " if warn else "%s: " % t["id"]) + "IN_PROGRESS without a complete analysis"
    return by_evidence, warn


def _role(t):
    if t["status"] == "ANALYSIS":
        return "problem-investigator"
    return STAGE_ROLE.get(stage_of(t)[0]) or "developer"


def is_work(c):
    return c["action"] in WORK


def work_available(cands):
    """The one predicate for "is there work a session can do": it decides both which
    stage runs (a held-back stage runs when nothing else is due) and when the router says
    there is nothing to do (idle, or only owner decisions)."""
    return any(is_work(c) for c in cands)


def _thresholded(c):
    """A candidate the stage thresholds apply to: entering or continuing a stage. Resumes
    (unfinished work in the tree) and bookkeeping moves of the orchestrator always run."""
    return bool(c.get("stage")) and c["action"] in ("continue", "review", "verify", "reanalyze", "start") \
        and c.get("role") != "orchestrator"


def _age_hours(project, tid):
    """Hours since the task's record last changed: its last commit, or - when the record is
    not committed or has uncommitted changes - the file's modification time (a task that
    waits with its move uncommitted must still age past max_wait_hours). None when unknown."""
    rel = "docs/tasks/%s.md" % tid
    rc, dirty = git(project, "status", "--porcelain", "--", rel)
    rc2, out = git(project, "log", "-1", "--format=%ct", "--", rel)
    if rc == 0 and not dirty.strip() and rc2 == 0 and out.strip().isdigit():
        stamp = int(out.strip())
    else:
        try:
            stamp = os.path.getmtime(os.path.join(project, rel))
        except OSError:
            return None
    return max(0.0, (time.time() - stamp) / 3600.0)


def stage_queues(project, cands, tasks, proc, eff):
    """{stage: {waiting, due, why, batch, min, max_wait_hours, model}}: how many tasks wait at
    each stage and whether the stage is due now. Due: `min` tasks wait, a P0/P1 task waits
    (effective priority), or the oldest waiting task is older than `max_wait_hours` (>0).
    "Nothing else to do" is applied by hold_back."""
    info = {}
    for st in STAGES:
        cfg = (proc.get("stages") or {}).get(st) or {"batch": 1, "min": 1, "max_wait_hours": 0}
        waiting = []
        for c in cands:
            if _thresholded(c) and c["stage"] == st and c["task"] not in waiting:
                waiting.append(c["task"])
        due, why = False, "nothing waiting"
        if waiting:
            urgent = [t for t in waiting if t in eff and eff[t][0] <= URGENT]
            if len(waiting) >= cfg["min"]:
                due, why = True, "%d waiting (min %d)" % (len(waiting), cfg["min"])
            elif urgent:
                due, why = True, "%s P%d waiting (P0/P1 run at once)" % (urgent[0], eff[urgent[0]][0])
            else:
                why = "%d waiting, min %d" % (len(waiting), cfg["min"])
                if cfg["max_wait_hours"]:
                    ages = [(a, t) for a, t in ((_age_hours(project, t), t) for t in waiting) if a is not None]
                    if ages:
                        oldest, tid = max(ages)
                        if oldest >= cfg["max_wait_hours"]:
                            due, why = True, "%s waiting %.1f h (max_wait_hours %d)" % (
                                tid, oldest, cfg["max_wait_hours"])
                        else:
                            why += ", oldest %.1f h of %d" % (oldest, cfg["max_wait_hours"])
        info[st] = {"waiting": waiting, "due": due, "why": why, "batch": cfg["batch"], "min": cfg["min"],
                    "max_wait_hours": cfg["max_wait_hours"], "model": (proc.get("models") or {}).get(st)}
    return info


def hold_back(cands, info):
    """Candidates of a stage that is not due move behind the last due piece of work (so an
    owner decision between them keeps its place). When no work is due, nothing is held:
    a waiting stage runs when there is nothing else to do."""
    held = lambda c: _thresholded(c) and not info[c["stage"]]["due"]  # noqa: E731
    due_work = [c for c in cands if is_work(c) and not held(c)]
    if not due_work:
        for st, i in info.items():
            if i["waiting"] and not i["due"]:
                i["due"], i["why"] = True, i["why"] + "; nothing else to do"
        return cands
    kept = [c for c in cands if not held(c)]
    back = [c for c in cands if held(c)]
    for c in back:
        c["reason"] += " (held: %s stage waits - %s)" % (c["stage"], info[c["stage"]]["why"])
    last = max(i for i, c in enumerate(kept) if is_work(c))
    return kept[:last + 1] + back + kept[last + 1:]


def _parallel_mod():
    """tw-parallel.py's seam logic (seam_paths, overlap): one definition of "two tasks touch
    the same code", used here as a hint for batching."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("tw_parallel", os.path.join(KIT, "scripts", "tw-parallel.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def config_areas(project):
    """[(area, [dirs])] from .teamwright/config.yml: source_dirs, test_dirs, workdir."""
    try:
        kc = kit_config()
        with open(os.path.join(project, kc.CONFIG), encoding="utf-8") as fh:
            cfg = kc.parse_yaml(fh.read())
    except Exception:  # an unreadable config only loses the area hint
        return []
    out = []
    for a in cfg.get("areas") or [] if isinstance(cfg, dict) else []:
        if not isinstance(a, dict) or not a.get("name"):
            continue
        dirs = []
        for k in ("source_dirs", "test_dirs", "workdir"):
            v = a.get(k)
            for d in (v if isinstance(v, list) else [v] if v else []):
                d = str(d).strip().lstrip("./").rstrip("/")
                if d:
                    dirs.append(d)
        out.append((str(a["name"]), dirs))
    return out


def stage_candidates(project, stage, cands, tasks, eff):
    """The tasks waiting at `stage`, in router order, with the facts the session needs to pick a
    batch without reading the task files: priority, effective priority, how many open tasks
    each unblocks, depends_on, seam paths and the areas they fall in, size hints, and the
    other candidates whose seam overlaps (tw-parallel.py's rule; no seam path = overlaps all)
    or that it depends on."""
    try:
        par = _parallel_mod()
    except Exception:
        par = None
    areas = config_areas(project)
    out = []
    for c in cands:
        if c.get("stage") != stage or not is_work(c) or any(x["id"] == c["task"] for x in out):
            continue
        t = tasks[c["task"]]
        paths = sorted(par.seam_paths(t.get("seam"))) if par else []
        hit = sorted({n for n, dirs in areas for pth in paths for d in dirs
                      if pth == d or pth.startswith(d + "/")})
        out.append({"id": t["id"], "action": c["action"], "title": t["title"], "type": t.get("type", ""),
                    "priority": t["priority"],
                    "effective_priority": "P%d" % eff[t["id"]][0] if eff.get(t["id"], (9,))[0] < 9 else t["priority"],
                    "unblocks": eff.get(t["id"], (0, None, 0))[2], "depends_on": t["depends_on"],
                    "seam_paths": paths, "areas": hit,
                    "size": {"seam_paths": len(paths), "acceptance_items": t.get("acceptance_items", 0),
                             "review_rounds": t.get("review_rounds", 0)},
                    "held": "(held:" in c["reason"], "reason": c["reason"]})
    for x in out:
        x["overlaps"] = [y["id"] for y in out if y is not x and par and
                         par.overlap(set(x["seam_paths"]), set(y["seam_paths"]))] if par else []
        x["depends_on_candidates"] = [d for d in x["depends_on"] if any(y["id"] == d for y in out)]
    return out


def describe_stage(first, cands, info, proc, budget):
    """Adds stage, batch, model, command, work_available, stages and headless to the
    decision: the stage session to run now and the tasks it takes."""
    stage = first.get("stage") if is_work(first) and first["action"] != "merge" else None
    batch = []
    if stage and first["action"] != "paused":
        cap = info[stage]["batch"]
        starts_left = budget["left"] if budget is not None else cap
        for c in cands:
            if len(batch) >= cap:
                break
            if c.get("stage") != stage or not is_work(c) or c["task"] in batch:
                continue
            if c["action"] == "start":
                if starts_left <= 0:
                    continue
                starts_left -= 1
            batch.append(c["task"])
    first["stage"] = stage
    first["batch"] = batch
    first["batch_cap"] = info[stage]["batch"] if stage else 0
    first["model"] = info[stage]["model"] if stage else None
    if stage:
        first["command"] = "/teamwright:%s %s" % (stage, " ".join(batch))
    elif first["action"] == "merge":
        first["command"] = "/teamwright:parallel merge %s" % first["task"]
    else:
        first["command"] = None
    first["work_available"] = work_available(cands)
    first["stages"] = info
    first["select"] = (proc.get("router") or {}).get("select", "script")
    first["decisions"] = decisions_of(cands)
    first["headless"] = headless_for(first, cands, info)


def decisions_of(cands):
    """Every owner decision the router sees ({task, reason}), in router order: in an
    autonomous run they are reported to a person while the other work goes on."""
    out, seen = [], set()
    for c in cands:
        k = (c["task"], c["reason"])
        if c["action"] == "decide" and k not in seen:
            seen.add(k)
            out.append({"task": c["task"], "reason": c["reason"]})
    return out


def headless_for(first, cands, info):
    """One stage per job (an autonomous run). Unlike the interactive answer, an owner
    decision does not stop the chain while other work is available: the job takes the
    first piece of work in router order and lists the decisions. No job runs when the team
    is paused, the tree holds uncommitted changes of no task, a pass ended (`stop`), or
    there is no work a job can do without a person."""
    def off(note, reason=None):
        return {"run": False, "prompt": None, "model": None, "stage": None, "task": None,
                "note": note, "reason": reason or note, "decisions": decisions_of(cands)}
    if first["action"] == "paused":
        return off("paused: no job runs until TEAMWRIGHT_PAUSE is removed")
    if first["action"] == "decide" and first["task"] is None and "uncommitted" in first["reason"]:
        return off("owner decision: no job runs; tell the owner the reason", first["reason"])
    if first["action"] == "stop":
        return off("owner decision: no job runs; tell the owner the reason", first["reason"])
    work = [c for c in cands if is_work(c)]
    if not work:
        if any(c["action"] == "decide" for c in cands):
            return off("owner decision: no job runs; tell the owner the reason", first["reason"])
        return off("nothing to do: no job runs", first["reason"])
    # a start that asks the owner which task to take cannot run without one (autonomy.start:
    # ask): the job skips it; when nothing else is left, no job runs
    runnable = [c for c in work if not (c["action"] == "start" and c.get("ask_owner"))]
    if not runnable:
        return off("owner decision: no job runs; process.autonomy.start is ask - the owner picks the "
                   "task to start (set autonomy.start: auto for autonomous runs)", work[0]["reason"])
    pick = runnable[0]
    if pick["action"] == "merge":
        prompt, model, stage = "/teamwright:parallel merge %s" % pick["task"], None, None
    else:
        stage = pick.get("stage")
        prompt, model = "/teamwright:%s" % stage, info[stage]["model"]
    note = "one stage per job: claude -p \"%s\"%s; the job pushes its commits to a wip/ branch " \
           "(not a delivery), then asks the router again" % (prompt, " --model %s" % model if model else "")
    if (pick["task"], pick["action"]) != (first["task"], first["action"]):
        note += "; %s comes first interactively (%s) - reported, not waited on" % (
            first["action"], first["reason"])
    return {"run": True, "prompt": prompt, "model": model, "stage": stage, "task": pick["task"],
            "note": note, "reason": pick["reason"], "decisions": decisions_of(cands)}


def explicit_batch(ids, tasks, cap):
    """Tasks a stage command names: dependencies among them first (a task goes after the one
    it depends on), at most the stage's batch cap (the rest is dropped, with a warning), and a
    warning for every pair whose seams overlap (tw-parallel.py's rule)."""
    warns, order, seen = [], [], set()

    def visit(tid, stack=()):
        if tid in seen or tid in stack:
            return
        for d in tasks[tid]["depends_on"]:
            if d in ids and d != tid:
                visit(d, stack + (tid,))
        seen.add(tid)
        order.append(tid)
    for tid in ids:
        visit(tid)
    for tid in ids:
        for d in tasks[tid]["depends_on"]:
            if d in ids:
                warns.append("%s depends on %s: %s goes first" % (tid, d, d))
    if len(order) > cap:
        warns.append("%d tasks named, the stage takes at most %d (process.stages.<stage>.batch): %s "
                     "left for the next session" % (len(order), cap, " ".join(order[cap:])))
        order = order[:cap]
    try:
        par = _parallel_mod()
    except Exception:
        par = None
    if par:
        for i, a in enumerate(order):
            for b in order[i + 1:]:
                if par.overlap(par.seam_paths(tasks[a].get("seam")), par.seam_paths(tasks[b].get("seam"))):
                    warns.append("%s and %s touch the same code (seams overlap): one after the other, "
                                 "the second re-reads the first's change" % (a, b))
    return order, warns


def request_for(res, cands, tasks, stage, ids):
    """A stage command's question: may /teamwright:<stage> run now, on which tasks? An
    explicit stage command ignores `min` (the owner asked for it), not the order of work:
    unfinished work in the tree, a pause or a task at another stage is refused with the
    command to run instead."""
    cap = (res.get("stages") or {}).get(stage, {}).get("batch", 1)
    out = {"stage": stage, "tasks": ids, "ok": False, "batch": [], "hint": "", "warnings": [], "model":
           (res.get("stages") or {}).get(stage, {}).get("model")}
    router = res.get("command") or "%s%s" % (res["action"], " " + res["task"] if res.get("task") else "")
    if res["action"] == "paused":
        out["hint"] = "paused (TEAMWRIGHT_PAUSE): nothing runs"
        return out
    first = cands[0] if cands else None
    if first and first["action"] == "resume" and first["task"] not in (ids or [first["task"]]) or \
            first and first["action"] == "resume" and first.get("stage") != stage:
        out["hint"] = "%s - finish it first: /teamwright:%s %s" % (first["reason"], first.get("stage") or "router",
                                                                  first["task"])
        return out
    if first and first["action"] == "decide" and first["task"] is None and "uncommitted" in first["reason"]:
        out["hint"] = first["reason"]
        return out
    here = [c for c in cands if c.get("stage") == stage and is_work(c)]
    if ids:
        for tid in ids:
            t = tasks.get(tid)
            if not t:
                out["hint"] = "%s: no such task" % tid
                return out
            ts = stage_of(t)[0]
            if ts != stage:
                out["hint"] = "%s is %s%s: %s" % (
                    tid, t["status"], ", stage %s" % ts if ts else "",
                    "/teamwright:%s %s" % (ts, tid) if ts else "no stage runs on it")
                return out
            if not any(c["task"] == tid for c in here):
                held = (res.get("state") or {}).get("wip_waiting") or {}
                why = next((c["reason"] for c in cands if c["task"] == tid),
                           "analysis done, it enters IN_PROGRESS when %s leaves it (one task IN_PROGRESS "
                           "per working tree)" % held[tid] if tid in held else "not ready")
                out["hint"] = "%s cannot run %s now: %s" % (tid, stage, why)
                return out
        out["batch"], out["warnings"] = explicit_batch(list(dict.fromkeys(ids)), tasks, cap)
    else:
        for c in here:
            if c["task"] not in out["batch"] and len(out["batch"]) < cap:
                out["batch"].append(c["task"])
        if not out["batch"]:
            out["hint"] = "nothing waits at %s; the router says: %s" % (stage, router)
            return out
    out["ok"] = True
    return out


def decide(project, taken=None, stage=None, ids=None):
    task, config = _load_helpers(project)
    st = state_of(project, config)
    kc = kit_config()
    proc = kc.read_process(os.path.join(project, kc.CONFIG))
    tasks = load_tasks(project, task)
    if tasks is None:
        res = _d("idle", None, "no docs/tasks/ - run /teamwright:adopt or /teamwright:init first")
        res.update(alternatives=[], state=st, tasks=[], warnings=[], settings=proc, budget=None,
                   recommended=getattr(kc, "PROCESS_RECOMMENDED", {}),
                   batch=[], model=None, command=None, work_available=False, stages={},
                   select=(proc.get("router") or {}).get("select", "script"),
                   decisions=[], headless={"run": False, "prompt": None, "model": None, "stage": None, "task": None,
                                           "note": "not adopted", "reason": "not adopted", "decisions": []})
        if stage:
            res["request"] = {"stage": stage, "tasks": ids or [], "ok": False, "batch": [], "model": None,
                              "hint": res["reason"], "candidates": []}
        res["candidates"], res["batch_cap"], res["counts"] = [], 0, {}
        return res
    oqs = open_questions(project)
    mark_delivered(project, tasks, st)
    own, wts = with_worktrees(project, task, tasks)
    elsewhere = {tid: wt["status"] for tid, wt in wts.items()}
    cands = candidates({k: v for k, v in tasks.items() if k not in elsewhere}, st, oqs, proc["ready"]["after"])
    if own:
        # a worktree session works its own task only, and never pushes
        cands = [c for c in cands if c["task"] == own]
        if own in tasks and tasks[own]["status"] in ("CODE_COMPLETE", "DEPLOYED", "VERIFIED", "DONE"):
            cands = []  # verification follows the merge and the push from the main tree
        if not cands and own in tasks:
            cands = [_d("idle", own, "%s is %s on tw/%s: this worktree's work is done - merge it from the "
                        "main tree (/teamwright:parallel)" % (own, tasks[own]["status"], own))]
    else:
        merges = [_d("merge", tid, "%s is %s on %s: merge it into this branch, run the gate, remove the "
                     "worktree %s" % (tid, wt["status"], wt["branch"], "(/teamwright:parallel)"
                                      if wt["branch"].startswith("tw/") else wt["path"]), role="orchestrator")
                  for tid, wt in sorted(wts.items(), key=lambda kv: _num(kv[0]))
                  if wt["status"] in ("CODE_COMPLETE", "DEPLOYED", "VERIFIED", "DONE")]
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
    eff = effective_priority(tasks)
    info = stage_queues(project, cands, tasks, proc, eff)
    cands = hold_back(cands, info)
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
        alts.append({"action": c["action"], "task": c["task"], "reason": c["reason"], "stage": c.get("stage")})
    first["alternatives"] = alts[:5]
    first["state"] = st
    # closed tasks (DONE, DEFERRED) are counted, never listed: on a long-lived project they
    # are most of the records and none of the work
    first["tasks"] = [dict(t, stage=stage_of(t)[0], ready=deps_done(t, tasks, proc["ready"]["after"])
                           and not blockers(t, oqs),
                           blockers=blockers(t, oqs),
                           effective_priority="P%d" % eff[t["id"]][0] if eff[t["id"]][0] < 9 else t["priority"])
                      for t in _sorted(tasks.values()) if t["status"] not in CLOSED]
    first["counts"] = {}
    for t in tasks.values():
        first["counts"][t["status"]] = first["counts"].get(t["status"], 0) + 1
    first["warnings"] = helper_warnings() + warnings_for(tasks, oqs) + drift_warnings(project)
    first["settings"] = proc
    first["recommended"] = getattr(kc, "PROCESS_RECOMMENDED", {})
    first["parallel"] = {"own": own, "elsewhere": elsewhere, "worktrees": wts}
    first["budget"] = budget
    describe_stage(first, cands, info, proc, budget)
    first["candidates"] = stage_candidates(project, first["stage"], cands, tasks, eff) if first["stage"] else []
    if stage:
        first["request"] = request_for(first, cands, tasks, stage, ids or [])
        first["request"]["candidates"] = first["candidates"] if first["stage"] == stage else \
            stage_candidates(project, stage, cands, tasks, eff)
        first["request"]["batch_cap"] = first["stages"][stage]["batch"]
    return first


BRIEF_CANDIDATES = 8   # --brief lists at most max(this, 2 x the stage's batch cap) candidates


def _brief_candidate(c):
    return {k: c[k] for k in ("id", "action", "title", "priority", "effective_priority", "unblocks",
                              "depends_on_candidates", "overlaps", "areas", "size", "held") if k in c}


def _brief_candidates(cands, cap):
    """The first max(8, 2 x cap) candidates, compact; overlaps and dependencies name only the
    candidates shown (a seam without a path overlaps every other one)."""
    keep = cands[:max(BRIEF_CANDIDATES, 2 * (cap or 1))]
    shown = {c["id"] for c in keep}
    out = []
    for c in keep:
        b = dict(_brief_candidate(c), title=(c.get("title") or "")[:70])
        b["overlaps"] = [x for x in c.get("overlaps") or [] if x in shown]
        b["depends_on_candidates"] = [x for x in c.get("depends_on_candidates") or [] if x in shown]
        out.append(b)
    return out


def ordered(res):
    """The answer with `request` (a stage command's question) first: a reader that sees only
    the head of the output - a truncated preview - still gets it."""
    out = {}
    if "request" in res:
        out["request"] = res["request"]
    for k, v in res.items():
        if k != "request":
            out[k] = v
    return out


def brief(res):
    """The fields a stage session needs, without the task list: --brief."""
    st = res.get("state") or {}
    out = {}
    req = res.get("request")
    if req is not None:
        out["request"] = dict({k: v for k, v in req.items() if k != "candidates"},
                              candidates=_brief_candidates(req.get("candidates") or [], req.get("batch_cap")),
                              candidates_total=len(req.get("candidates") or []))
    for k in ("action", "task", "reason", "role", "ask_owner", "stage", "batch", "batch_cap", "model",
              "command", "work_available", "select"):
        out[k] = res.get(k)
    if req is not None:
        # a stage command picks from request.candidates; the router's own stage's list (the
        # same one, or another stage's) is not repeated
        out["candidates"], out["candidates_in"] = [], "request"
    else:
        out["candidates"] = _brief_candidates(res.get("candidates") or [], res.get("batch_cap"))
    out["candidates_total"] = len(res.get("candidates") or [])
    out["stages"] = {s: {"waiting": len(i["waiting"]), "due": i["due"], "why": i["why"], "batch": i["batch"],
                         "model": i["model"]} for s, i in (res.get("stages") or {}).items()}
    out["counts"] = res.get("counts") or {}
    out["decisions"] = res.get("decisions") or []
    out["warnings"] = res.get("warnings") or []
    out["headless"] = res.get("headless")
    out["budget"] = res.get("budget")
    out["state"] = {k: st.get(k) for k in ("mode", "branch", "dirty", "unpushed", "delivery_ref", "pause",
                                           "current_task", "interrupted_task")}
    out["alternatives"] = [dict(a, reason=(a.get("reason") or "")[:90]) for a in (res.get("alternatives") or [])[:3]]
    out["settings"] = {k: v for k, v in (res.get("settings") or {}).items() if k != "explicit"}
    return out


def human(res):
    st = res["state"]
    counts = res.get("counts") or {}
    if not counts:
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
    wts = (res.get("parallel") or {}).get("worktrees") or {}
    if wts:
        lines.append("  in worktrees: " + ", ".join("%s %s (%s)" % (tid, wt["status"], wt["branch"])
                                                    for tid, wt in sorted(wts.items(), key=lambda kv: _num(kv[0]))))
    lines += ["", "next: %s%s - %s" % (res["action"], " " + res["task"] if res["task"] else "", res["reason"])]
    if res.get("stage"):
        lines.append("  stage: %s | batch: %s | model: %s | run: %s" % (
            res["stage"], " ".join(res.get("batch") or []) or "-", res.get("model") or "role files",
            res.get("command")))
    if res.get("role"):
        lines.append("  role: %s" % res["role"])
    if res.get("ask_owner"):
        lines.append("  owner decision needed")
    queues = ["%s %d%s" % (st, len(i["waiting"]), "" if i["due"] else " (held: %s)" % i["why"])
              for st, i in (res.get("stages") or {}).items() if i["waiting"]]
    if queues:
        lines.append("  stages: " + " · ".join(queues))
    req = res.get("request")
    if req:
        lines.append("  /teamwright:%s: %s" % (req["stage"], "run on " + " ".join(req["batch"]) if req["ok"]
                                                 else "refused - " + req["hint"]))
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
    ap.add_argument("--stage", choices=STAGES, default=None,
                    help="answer a stage command: may this stage run now, on which tasks (`request`)")
    ap.add_argument("--task", dest="ids", default=None,
                    help="with --stage: the tasks the command names, comma-separated")
    ap.add_argument("--brief", action="store_true",
                    help="with --json: what a stage session needs (request first, candidates, stage "
                         "counts, decisions, warnings, model, headless), no task list")
    args = ap.parse_args(argv)
    project = os.path.abspath(args.project)
    if not os.path.isdir(project):
        print("tw-next: no such project: %s" % project, file=sys.stderr)
        return 2
    args.json = args.json or args.brief
    taken = None if args.taken is None else [x.strip() for x in args.taken.split(",") if x.strip()]
    ids = [x.strip() for x in (args.ids or "").replace(" ", ",").split(",") if x.strip()]
    if ids and not args.stage:
        print("tw-next: --task needs --stage", file=sys.stderr)
        return 2
    res = decide(project, taken, args.stage, ids)
    try:
        if args.json:
            print(json.dumps(brief(res) if args.brief else ordered(res), indent=None if args.brief else 2,
                             ensure_ascii=False, separators=(",", ":") if args.brief else None))
        else:
            print(human(res))
        sys.stdout.flush()
    except BrokenPipeError:  # a reader that stops early (grep -q) is not an error
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    return 0


if __name__ == "__main__":
    sys.exit(main())
