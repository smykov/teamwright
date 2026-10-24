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
  python3 tw-parallel.py prepare ID [ID ...] [--project P] the worktree's context index: copy the main tree's, refresh it
  python3 tw-parallel.py launch ID [ID ...] [--project P]  run each worktree's stages in the background (headless)
  python3 tw-parallel.py run    ID [--project P]           (what launch starts) one stage per session until done

launch / run: in the worktree, ask the router (`tw-next.py --json` there sees that task only); while
`headless.run` is true, run `claude -p <headless.prompt>` - one stage per session, a fresh context -
and ask again; stop at CODE_COMPLETE (merged and verified from the main tree), at an owner decision
(`headless.run` false: escalate, blocked, idle), on TEAMWRIGHT_PAUSE, after a stage that moved
nothing twice, or after $TW_PARALLEL_MAX_STAGES (12) stages. At most `process.batch.parallel` runs at
once. State: `.teamwright/parallel/<ID>.json`, log `.teamwright/parallel/<ID>.log` in the main tree.
The command is `$TW_CLAUDE` (default `claude`) with `$TEAMWRIGHT_CLAUDE_ARGS` (default: acceptEdits,
the tools a stage needs, no `git push`, `git merge` or `gh`, and the autonomous-run note). Bash is
otherwise unrestricted: run it where a headless agent may run commands (a container, a VM).

Seams: path-like tokens in `analysis.seam` (a file, or a directory with a trailing part);
two tasks overlap when a path of one equals or contains a path of the other. A seam
with no path (a symbol name, prose) overlaps everything: that task runs alone.
Group size: `process.batch.parallel` (default 1 = no parallel work).
"""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

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
        if not re.fullmatch(r"(?:%s)\.md" % getattr(_task, "TASK_ID", r"[A-Z][A-Z0-9]*-\d+"), f):
            continue  # a task record is <ID>.md: not a template, not T-089.history.md
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
                    "launch": "tw-parallel.py prepare %s && tw-parallel.py launch %s" % (tid, tid),
                    "manual": "cd %s && claude \"/teamwright:flow %s\"" % (path, tid)} if rc == 0 else
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
        run_st = read_state(project, tid)
        res.append({"task": tid, "path": wt["path"], "branch": wt["branch"], "status": st,
                    "ahead": int(ahead or 0), "behind": int(behind or 0),
                    "dirty": len([l for l in dirty.splitlines() if l and not l[3:].startswith(".teamwright/")]),
                    "ready_to_merge": st in APPROVED,
                    "run": {"running": alive(run_st.get("pid")), "stage": run_st.get("stage", ""),
                            "outcome": run_st.get("outcome", ""), "reason": run_st.get("reason", ""),
                            "stages": len(run_st.get("stages") or [])} if run_st else None})
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


AUTONOMY = ("AUTONOMOUS RUN, NO OWNER IN THIS SESSION. Run only the stage command you were given, for this "
            "worktree's task. Never call AskUserQuestion. Run every role agent in the foreground. When the "
            "process needs the owner (a decision point, an unclear requirement, a missing tool), write the "
            "question with your recommended option into the task record's Notes, commit it, and stop with "
            "Outcome: escalate. Do not push, do not merge.")
DEFAULT_ARGS = ["--permission-mode", "acceptEdits", "--allowedTools",
                "Bash Read Edit Write Glob Grep Task TodoWrite Skill mcp__serena mcp__context7 mcp__codegraphcontext",
                "--disallowedTools", "Bash(git push:*) Bash(git merge:*) Bash(gh:*)",
                "--append-system-prompt", AUTONOMY]
# context providers whose index lives in the tree: (cache dir, refresh command)
INDEX = {"serena": (".serena/cache", ["serena", "project", "index", "."])}


def state_dir(project):
    d = os.path.join(project, ".teamwright", "parallel")
    os.makedirs(d, exist_ok=True)
    return d


def read_state(project, tid):
    try:
        with open(os.path.join(state_dir(project), tid + ".json"), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def write_state(project, tid, **kw):
    st = read_state(project, tid)
    st.update(kw, updated=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    path = os.path.join(state_dir(project), tid + ".json")
    with open(path + ".tmp", "w", encoding="utf-8") as fh:
        json.dump(st, fh, ensure_ascii=False, indent=1)
    os.replace(path + ".tmp", path)
    return st


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def running(project):
    """Task ids whose background run is alive."""
    return sorted(t for t in worktrees(project) if alive(read_state(project, t).get("pid")))


def context_provider(project):
    try:
        cfg = _config.parse_yaml(open(os.path.join(project, _config.CONFIG), encoding="utf-8").read())
    except (OSError, ValueError):
        return ""
    tools = cfg.get("tools") if isinstance(cfg.get("tools"), dict) else {}
    return str(tools.get("context") or "").strip()


def prepare(project, ids):
    """The worktree's context index: copy the main tree's cache (a full index takes minutes),
    then let the provider refresh it for the files that differ. A worktree whose provider cannot
    index is reported, not hidden: its stage sessions stop before any role (stage protocol §0)."""
    prov = context_provider(project)
    wts = worktrees(project)
    out = []
    for tid in ids:
        wt = wts.get(tid)
        if not wt:
            out.append({"task": tid, "error": "no worktree for %s (start it first)" % tid})
            continue
        if prov not in INDEX:
            out.append({"task": tid, "provider": prov or "none", "index": "nothing to prepare"})
            continue
        cache, cmd = INDEX[prov]
        src, dst = os.path.join(project, cache), os.path.join(wt["path"], cache)
        copied = False
        if os.path.isdir(src) and not os.path.isdir(dst):
            shutil.copytree(src, dst, symlinks=True)
            copied = True
        cmd = shlex.split(os.environ.get("TW_CONTEXT_INDEX_CMD", "")) or cmd
        if not shutil.which(cmd[0]):
            out.append({"task": tid, "provider": prov, "copied": copied,
                        "error": "%s is not installed: the worktree has no fresh index" % cmd[0]})
            continue
        try:
            r = subprocess.run(cmd, cwd=wt["path"], capture_output=True, text=True,
                               timeout=int(os.environ.get("TW_CONTEXT_INDEX_TIMEOUT", "1800")))
            rc, tail = r.returncode, (r.stderr or r.stdout)[-300:]
        except subprocess.TimeoutExpired:
            rc, tail = 124, "timed out"
        out.append(dict({"task": tid, "provider": prov, "copied": copied, "index_rc": rc},
                        **({"error": "index failed: " + tail} if rc else {})))
    return out


def launch(project, ids):
    """Start `run` for each worktree in the background, up to process.batch.parallel at once."""
    n = _config.read_process(os.path.join(project, _config.CONFIG))["batch"]["parallel"]
    wts, live = worktrees(project), running(project)
    out = []
    for tid in ids:
        if tid not in wts:
            out.append({"task": tid, "error": "no worktree for %s (start it first)" % tid})
        elif tid in live:
            out.append({"task": tid, "running": True, "pid": read_state(project, tid).get("pid")})
        elif len(live) >= n:
            out.append({"task": tid, "waiting": "parallel limit %d reached (%s running)" % (n, ", ".join(live))})
        else:
            log = open(os.path.join(state_dir(project), tid + ".log"), "a", encoding="utf-8")
            p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "run", tid, "--project", project],
                                 stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                 start_new_session=True)
            write_state(project, tid, pid=p.pid, started=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                        outcome="", stages=[])
            live.append(tid)
            out.append({"task": tid, "launched": True, "pid": p.pid,
                        "log": os.path.join(state_dir(project), tid + ".log")})
    return out


def _wt_status(path, tid):
    try:
        return _task.status(_task.parse(open(os.path.join(path, "docs", "tasks", tid + ".md"),
                                             encoding="utf-8", errors="replace").read())) or ""
    except OSError:
        return ""


def run(project, tid):
    """Foreground loop of one worktree: router, one stage per `claude -p` session, again."""
    wt = worktrees(project).get(tid)
    if not wt:
        return {"task": tid, "error": "no worktree for %s" % tid}
    path = wt["path"]
    claude = shlex.split(os.environ.get("TW_CLAUDE", "")) or ["claude"]
    args = shlex.split(os.environ["TEAMWRIGHT_CLAUDE_ARGS"]) if "TEAMWRIGHT_CLAUDE_ARGS" in os.environ else DEFAULT_ARGS
    env = dict(os.environ, CLAUDE_CODE_DISABLE_BACKGROUND_TASKS="1")
    nxt = os.path.join(KIT, "scripts", "tw-next.py")
    stages, idle = [], 0
    write_state(project, tid, pid=os.getpid(), outcome="")
    for _ in range(int(os.environ.get("TW_PARALLEL_MAX_STAGES", "12"))):
        status = _wt_status(path, tid)
        if status in APPROVED:
            return write_state(project, tid, outcome="done", status=status, stages=stages)
        if any(os.path.exists(os.path.join(d, "TEAMWRIGHT_PAUSE")) for d in (project, path)):
            return write_state(project, tid, outcome="paused", status=status, stages=stages)
        r = subprocess.run([sys.executable, nxt, "--project", path, "--json"], capture_output=True, text=True)
        try:
            d = json.loads(r.stdout)
        except ValueError:
            return write_state(project, tid, outcome="error", reason="router: " + (r.stderr or r.stdout)[-300:],
                               status=status, stages=stages)
        h = d.get("headless") or {}
        if not h.get("run"):
            dec = "; ".join(str(x.get("reason") or x) for x in (h.get("decisions") or d.get("decisions") or []))[:500]
            return write_state(project, tid, outcome="escalate" if dec or d.get("ask_owner") else "idle",
                               reason=dec or h.get("reason") or d.get("reason") or "", status=status, stages=stages)
        head = git(path, "rev-parse", "HEAD")[1]
        stage = h.get("stage") or h.get("prompt")
        write_state(project, tid, stage=stage, status=status, stages=stages)
        print("[%s] %s: %s" % (time.strftime("%H:%M:%S"), tid, h.get("prompt")), file=sys.stderr, flush=True)
        rc = subprocess.run(claude + ["-p", h.get("prompt") or "/teamwright:router"] + args,
                            cwd=path, env=env).returncode
        moved = git(path, "rev-parse", "HEAD")[1] != head or _wt_status(path, tid) != status
        stages.append({"stage": stage, "rc": rc, "moved": moved})
        idle = 0 if moved else idle + 1
        if idle >= 2:
            return write_state(project, tid, outcome="stuck", reason="two stages moved nothing",
                               status=_wt_status(path, tid), stages=stages)
    return write_state(project, tid, outcome="limit", status=_wt_status(path, tid), stages=stages)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("command", choices=("plan", "start", "status", "logs", "prepare", "launch", "run"))
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
    elif a.command == "prepare":
        r = prepare(project, a.ids)
    elif a.command == "launch":
        r = launch(project, a.ids)
    elif a.command == "run":
        r = run(project, a.ids[0]) if a.ids else {"error": "run needs a task id"}
    else:
        r = [logs(project, t) for t in a.ids]
    print(json.dumps(r, indent=2, ensure_ascii=False))
    errors = r if isinstance(r, list) else []
    return 1 if any(isinstance(x, dict) and x.get("error") for x in errors) else 0


if __name__ == "__main__":
    sys.exit(main())
