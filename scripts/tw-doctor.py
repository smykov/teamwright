#!/usr/bin/env python3
"""tw-doctor.py - what a project still needs before teamwright, and its autonomous contour, can run (stdlib only, read-only).

"In sync" from the installer says the kit's files match; it says nothing about a workflow that
is missing, a secret nobody set, a label nobody created or a runner without gitleaks. Each
requirement here is one check:

  id       a stable name (`contour-workflow`, `model-secret`, ...)
  scope    repo | contour | runner
  state    ok | missing | warn | unknown (could not be checked: `evidence` says why) |
           manual (cannot be checked: a person confirms) | n/a
  class    agent (an agent may fix it) | owner-action (only a person can: a secret, a runner,
           a plan) | owner-decision (a choice: whether to run a contour, a setting)
  why      what breaks without it
  fix      the exact command or step
  evidence what was found

Scopes: `repo` - the install, git hooks, settings left below the recommended values, tools on
this machine, and the manual steps of the versions crossed since `--since` (default: the kit
version in `.teamwright/installed.json`; none
when the project has no installed kit). `contour` - the workflows under `.github/workflows`,
and through `gh`: the model key secret, labels, branch protection, self-hosted runners, a
runner shared with other workflows. `runner` - run on the runner host: `TEAMWRIGHT_KIT`,
gitleaks, the docker images of the areas. Default: repo and contour; with no contour workflow
the GitHub checks are skipped unless `--scope contour` asks for them.

  python3 tw-doctor.py [--project PATH] [--json] [--scope repo|contour|runner ...] [--since X.Y.Z]

Nothing is written. Exit 0 with a report, 2 when the project is not a directory. TW_GH
overrides the gh binary, TW_DOCKER the docker binary.
"""
import argparse
import glob
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(HERE)
CONFIG = os.path.join(".teamwright", "config.yml")
TIMEOUT = 20
VERSION_RE = re.compile(r"^## \[(\d+)\.(\d+)\.(\d+)")
SECRET_RE = re.compile(r"\$\{\{\s*secrets\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")
LABEL_RE = re.compile(r"\btw:[a-z][a-z-]*(?![a-z0-9_${-])")  # tw:stage-${X} is built at run time
RUNS_ON_RE = re.compile(r"^\s*runs-on:\s*(.+?)\s*$", re.M)
MODEL_SECRETS = ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN")
STATES = ("missing", "warn", "unknown", "manual", "ok", "n/a")


def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def kit_config():
    return _load(os.path.join(KIT, "template", "scripts", "hooks", "_config.py"), "tw_doctor_config")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def vtuple(v):
    m = re.match(r"^\s*v?(\d+)\.(\d+)\.(\d+)", str(v or ""))
    return tuple(int(x) for x in m.groups()) if m else None


def kit_version():
    try:
        return json.load(open(os.path.join(KIT, ".claude-plugin", "plugin.json"), encoding="utf-8")).get("version")
    except (OSError, ValueError, AttributeError):
        return None


def installed_version(project):
    try:
        return (json.load(open(os.path.join(project, ".teamwright", "installed.json"),
                               encoding="utf-8")).get("@kit") or {}).get("version")
    except (OSError, ValueError, AttributeError):
        return None


def check(cid, scope, state, why, cls="agent", fix="", evidence=""):
    return {"id": cid, "scope": scope, "state": state, "class": cls, "why": why, "fix": fix, "evidence": evidence}


def run(cmd, cwd, timeout=TIMEOUT):
    """(rc, stdout, stderr); rc None when the command could not start."""
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, "", str(e)
    return p.returncode, p.stdout, p.stderr


# ---- repo ---------------------------------------------------------------------------------

def manual_steps(since, until, changelog=None):
    """The `What to do by hand` lines of each version in (since, until], oldest first. A line that
    only says to run /teamwright:update is left out: that is how the reader got here."""
    text = read(changelog or os.path.join(KIT, "CHANGELOG.md")) or ""
    lo, hi = vtuple(since), vtuple(until)
    items, ver, inside = [], None, False
    for line in text.splitlines():
        if line.startswith("## "):
            m = VERSION_RE.match(line)
            # a heading that is not a plain release (Unreleased, a pre-release) owns its lines
            ver = tuple(int(x) for x in m.groups()) if m and line[m.end():m.end() + 1] == "]" else None
            inside = False
            continue
        if line.startswith("### "):
            inside = line.strip() == "### What to do by hand"
            continue
        if not inside or ver is None:
            continue
        if line.startswith("- "):
            items.append([ver, line[2:].strip()])
        elif line[:1] in (" ", "\t") and line.strip() and items and items[-1][0] == ver:
            items[-1][1] += " " + line.strip()  # a bullet wrapped over several lines
    out = []
    for ver, item in items:
        if (lo is not None and ver <= lo) or (hi is not None and ver > hi):
            continue
        if re.fullmatch(r"`/teamwright:update`(, then restart Claude Code)?\.?", item):
            continue
        out.append(("%d.%d.%d" % ver, item))
    out.sort(key=lambda x: vtuple(x[0]))
    return out


def areas_of(cfg):
    areas = cfg.get("areas") if isinstance(cfg, dict) else None
    if isinstance(areas, dict):
        return [dict(a, name=k) for k, a in areas.items() if isinstance(a, dict)]
    return [a for a in (areas or []) if isinstance(a, dict)]


def _flat(d, prefix=""):
    for k, v in (d or {}).items():
        key = prefix + str(k)
        if isinstance(v, dict):
            yield from _flat(v, key + ".")
        else:
            yield key, v


def settings_checks(cfg, kc):
    """Keys left at their default whose recommended value differs: one owner decision each."""
    proc = kc.process_of(cfg)
    explicit = set(proc.get("explicit") or ())
    eff = dict(_flat({k: v for k, v in proc.items() if k != "explicit"}))
    out = []
    for key, rec in _flat(getattr(kc, "PROCESS_RECOMMENDED", {})):
        if key.startswith("stages."):
            continue  # the recommended stage values are the defaults
        if any(key == e or key.startswith(e + ".") for e in explicit):
            continue
        if eff.get(key) != rec:
            v = json.dumps(rec) if not isinstance(rec, str) else rec
            out.append(check("setting:" + key, "repo", "warn",
                             "left at its default (%s); the recommended value is %s" % (json.dumps(eff.get(key)), v),
                             "owner-decision", "/teamwright:settings %s %s" % (key, v)))
    return out


def tool_checks(project, cfg, scope):
    out = []
    gl = shutil.which("gitleaks")
    out.append(check("gitleaks", scope, "ok" if gl else "missing",
                     "without gitleaks the pre-commit scan falls back to a weaker regex, and "
                     "scripts/tw-scan exits 3 in a contour job", "owner-action",
                     "install gitleaks on this machine (https://github.com/gitleaks/gitleaks)",
                     gl or "not on PATH"))
    images = sorted({str(a.get("image")) for a in areas_of(cfg) if a.get("runner") == "docker" and a.get("image")})
    if images:
        docker = os.environ.get("TW_DOCKER", "docker")
        for img in images:
            rc, _, err = run([docker, "image", "inspect", img], project)
            if rc is None:
                out.append(check("docker-image:" + img, scope, "unknown", "a docker area runs its commands in this image",
                                 "owner-action", "install docker, then `docker pull %s`" % img, "docker: %s" % err[:200]))
            elif rc != 0 and not re.search(r"(?i)no such (image|object)", err):
                out.append(check("docker-image:" + img, scope, "unknown", "a docker area runs its commands in this image",
                                 "owner-action", "start docker, or give this user access to it",
                                 (err.strip().splitlines() or ["docker failed"])[0][:200]))
            else:
                out.append(check("docker-image:" + img, scope, "ok" if rc == 0 else "missing",
                                 "a docker area runs its commands in this image; a host clean-up removes images no "
                                 "container uses, and the run then fails to start", "agent",
                                 "docker pull %s" % img, "present" if rc == 0 else "not on this host"))
    return out


def repo_checks(project, cfg, kc, since, cfg_ok=True):
    out = []
    have, kit = installed_version(project), kit_version()
    if not vtuple(have):
        out.append(check("kit-version", "repo", "missing", "no kit version in .teamwright/installed.json: the installer "
                         "has not applied the kit here, so the hooks and role files may be missing",
                         "agent", "/teamwright:update (or tw-install.py apply)", "kit %s, plugin %s" % (have or "none", kit or "?")))
    elif vtuple(kit) and vtuple(have) < vtuple(kit):
        out.append(check("kit-version", "repo", "missing", "the project's kit is older than the plugin: the hooks and "
                         "role files here are the old ones, and a contour job refuses to run on install drift",
                         "agent", "/teamwright:update", "kit %s, plugin %s" % (have, kit)))
    elif vtuple(kit) and vtuple(have) > vtuple(kit):
        out.append(check("kit-version", "repo", "warn", "the project's kit is newer than this plugin: the commands of this "
                         "session are older than the hooks they drive", "agent", "/teamwright:update",
                         "kit %s, plugin %s" % (have, kit)))
    else:
        out.append(check("kit-version", "repo", "ok", "the project's kit matches the plugin", "agent", "",
                         "kit %s, plugin %s" % (have or "?", kit or "?")))
    hooks = run(["git", "config", "--get", "core.hooksPath"], project)[1].strip()
    out.append(check("git-hooks", "repo", "ok" if hooks == "scripts/hooks" else "missing",
                     "without core.hooksPath the secret scan, patch-guard and the push gate never run on this clone",
                     "agent", "bash scripts/install-hooks.sh", "core.hooksPath=%s" % (hooks or "unset")))
    if cfg_ok:
        out += settings_checks(cfg, kc)
    out += tool_checks(project, cfg, "repo")
    seen = {}
    for ver, item in (manual_steps(since, kit) if since else []):
        seen[ver] = seen.get(ver, 0) + 1
        out.append(check("manual:%s:%d" % (ver, seen[ver]), "repo", "manual", "a manual step of %s: no check can tell whether it was done" % ver,
                         "owner-action", item))
    return out


# ---- contour ------------------------------------------------------------------------------

def workflows(project):
    """[(relpath, text, is_teamwright)] - a workflow is the contour's when it asks the router or
    runs a teamwright stage."""
    out = []
    for path in sorted(glob.glob(os.path.join(project, ".github", "workflows", "*.y*ml"))):
        text = read(path) or ""
        tw = "tw-next.py" in text or "/teamwright:" in text or os.path.basename(path).startswith("teamwright")
        out.append((os.path.relpath(path, project), text, tw))
    return out


def _labels(raw):
    """Labels of a flow list or a scalar; an element built at run time is left out."""
    raw = raw.split(" #")[0].strip().strip("[]")
    return [x.strip().strip("'\"").lower() for x in raw.split(",") if x.strip() and "${{" not in x]


def runs_on(text):
    """Label sets of each job's `runs-on`, lower-cased (GitHub matches labels ignoring case): a
    scalar, a flow list, a block list, or a group mapping's `labels:` (block or flow). A group
    with no labels, or a value built at run time, gives no set: it cannot be matched here."""
    lines = text.splitlines()
    sets = []
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)runs-on:\s*(.*?)\s*$", line)
        if not m:
            continue
        indent, value = len(m.group(1)), m.group(2).split(" #")[0].strip()
        labels = []
        if value.startswith("{"):
            lm = re.search(r"labels:\s*(\[[^\]]*\]|[^,}]+)", value)
            labels = _labels(lm.group(1)) if lm else []
        elif value:
            labels = _labels(value)
        else:
            block = []
            for nxt in lines[i + 1:]:
                if nxt.strip() and len(nxt) - len(nxt.lstrip()) <= indent:
                    break
                block.append(nxt)
            in_labels = False
            for b in block:
                t = b.strip()
                if t.startswith("- ") and (in_labels or not any(x.strip().startswith(("group:", "labels:")) for x in block)):
                    labels += _labels(t[2:])
                elif t.startswith("labels:"):
                    in_labels = True
                    labels += _labels(t[len("labels:"):]) if t[len("labels:"):].strip() else []
                elif t and not t.startswith("- "):
                    in_labels = False
        if labels:
            sets.append(frozenset(labels))
    return sets


def has_docker_area(cfg):
    return any(a.get("runner") == "docker" for a in areas_of(cfg))


def workflow_checks(project, cfg, flows):
    tw = [(p, t) for p, t, is_tw in flows if is_tw]
    if not tw:
        return [check("contour-workflow", "contour", "missing",
                      "no workflow asks the router: the autonomous contour cannot start (/teamwright:sprint has "
                      "nothing to hand the queue to)", "owner-decision",
                      "only if you want the contour: save the sketch from docs/usage.md (Autonomous chain) as "
                      ".github/workflows/teamwright-stage.yml and adapt it",
                      "no .github/workflows/*.yml runs tw-next.py or a /teamwright: stage")]
    text = "\n".join(t for _, t in tw)
    names = ", ".join(p for p, _ in tw)
    out = [check("contour-workflow", "contour", "ok", "a workflow asks the router", "owner-decision", "", names)]

    def need(cid, ok, why, fix, cls="agent"):
        out.append(check(cid, "contour", "ok" if ok else "missing", why, cls, fix, names))

    need("workflow-kit", "TEAMWRIGHT_KIT" in text or "--plugin-dir" in text,
         "the job loads the plugin from a kit checked out on the runner; without it the stage commands do not exist",
         "set `TEAMWRIGHT_KIT` (and `TEAMWRIGHT_PLUGIN_DIR`) to the kit's path on the runner and pass "
         "`--plugin-dir ${{ env.TEAMWRIGHT_KIT }}` in claude_args")
    need("workflow-hooks", "install-hooks.sh" in text,
         "a checkout does not bring core.hooksPath: without the step the job commits with no secret scan and no push gate",
         "add a step: `bash scripts/install-hooks.sh && bash scripts/install-hooks.sh --check`")
    if "claude-code-action" in text:
        need("workflow-allowed-bots", "allowed_bots" in text,
             "every stage after the first is dispatched by the chain (a bot); claude-code-action refuses a run a bot "
             "started unless allowed_bots names it",
             'add `allowed_bots: "github-actions[bot]"` to the claude-code-action step')
    joined = re.sub(r"\\\n\s*", " ", text)  # a command wrapped over lines with a backslash
    need("workflow-ci-dispatch", re.search(r"gh workflow run \S+[^\n]*--ref[ =]+[\"']?(?!(main|master|wip/)[\"'\s])", joined) is not None,
         "a branch pushed with the job's token starts no CI, and a pull request the chain opens waits in "
         "action_required: the chain's code reaches the owner unchecked",
         'end the chain with `gh workflow run <your-ci>.yml --ref "task/<ID>"` (workflow_dispatch in that workflow)')
    if "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB" in text:
        docker = has_docker_area(cfg)
        out.append(check("workflow-scrub", "contour", "missing" if docker else "ok",
                         "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB runs every command in Claude Code's sandbox, which masks "
                         "the docker socket: every scripts/tw-run stage of a docker area fails"
                         if docker else "no docker area: the sandbox does not block a runner",
                         "agent", "remove CLAUDE_CODE_SUBPROCESS_ENV_SCRUB from the workflow" if docker else "", names))
    return out


def gh(project, *args):
    """(parsed JSON, None, None) or (None, http status or None, why)."""
    rc, out, err = run([os.environ.get("TW_GH", "gh"), *args], project)
    if rc is None:
        return None, None, "gh is not installed" if "No such file" in err or "not found" in err else "gh did not answer: %s" % err[:200]
    if rc != 0:
        text = (err or out or "gh failed").strip()
        m = re.search(r"HTTP (\d{3})", text)
        return None, int(m.group(1)) if m else None, text.splitlines()[0][:200] if text else "gh failed"
    try:
        return json.loads(out or "null"), None, None
    except ValueError:
        return None, None, "gh returned something other than JSON"


def has_github_remote(project):
    """Any remote: gh itself says whether it is GitHub (github.com or an Enterprise host)."""
    return bool(run(["git", "remote"], project)[1].strip())


def github_checks(project, flows):
    out = []
    repo, _, why = gh(project, "repo", "view", "--json", "nameWithOwner,defaultBranchRef")
    if why:
        return [check("github", "contour", "unknown", "the GitHub checks need gh, logged in", "owner-action",
                      "gh auth login", why)]
    name = repo.get("nameWithOwner")
    branch = (repo.get("defaultBranchRef") or {}).get("name") or "main"
    tw_text = "\n".join(t for _, t, is_tw in flows if is_tw)

    # the model key: repository secrets, then the job's environments, then the organisation's
    owner = name.split("/")[0]
    wanted = sorted({x for x in SECRET_RE.findall(tw_text) if x != "GITHUB_TOKEN"}) or None
    envs = sorted(set(re.findall(r"^\s*environment:\s*['\"]?([A-Za-z0-9_.-]+)", tw_text, re.M)))
    have, unseen = set(), []
    for args in [()] + [("--env", e) for e in envs] + [("--org", owner)]:
        found, status, why = gh(project, "secret", "list", *args, "--json", "name")
        if why:
            if not (args and args[0] == "--org" and status == 404):  # 404: the owner is a user, not an org
                unseen.append("%s: %s" % (" ".join(args) or "repository", why))
            continue
        have |= {x.get("name") for x in found or []}
    lack = [x for x in wanted if x not in have] if wanted else ([] if have & set(MODEL_SECRETS) else [MODEL_SECRETS[0]])
    if lack and unseen:
        out.append(check("model-secret", "contour", "unknown", "the job needs the model key as a secret; with none every "
                         "stage fails", "owner-action", " && ".join("gh secret set %s" % x for x in lack),
                         "not found: %s; not listed: %s" % (", ".join(lack), "; ".join(unseen))))
    else:
        out.append(check("model-secret", "contour", "missing" if lack else "ok",
                         "the job needs the model key as a secret; with none every stage fails", "owner-action",
                         " && ".join("gh secret set %s" % x for x in lack),
                         "missing: %s" % ", ".join(lack) if lack
                         else "set: %s" % ", ".join(wanted or sorted(have & set(MODEL_SECRETS)))))

    # labels
    labels, status, why = gh(project, "label", "list", "--limit", "1000", "--json", "name")
    need_labels = sorted({"teamwright"} | set(LABEL_RE.findall(tw_text)))
    if why:
        out.append(check("labels", "contour", "unknown", "the queue lives in labels", "agent",
                         "gh label create teamwright", why))
    else:
        have = {l.get("name") for l in labels or []}
        lack = [l for l in need_labels if l not in have]
        out.append(check("labels", "contour", "missing" if lack else "ok",
                         "the queue lives in labels: Issues cannot be put in it, or a stage cannot say where it is, "
                         "without them (creating a label starts nothing; putting `teamwright` on an Issue does)",
                         "agent", " && ".join("gh label create %s" % l for l in lack),
                         "missing: %s" % ", ".join(lack) if lack else "present: %s" % ", ".join(need_labels)))

    # branch protection (TM-16): classic protection, or a ruleset that requires a pull request
    _, status, why = gh(project, "api", "repos/%s/branches/%s/protection" % (name, branch))
    rules, _, rwhy = gh(project, "api", "repos/%s/rules/branches/%s" % (name, branch))
    ruled = sorted({x.get("type") for x in (rules or []) if isinstance(x, dict)} & {"pull_request", "update"})
    if not why or ruled:
        out.append(check("branch-protection", "contour", "ok", "the job cannot push to the main branch", "owner-action",
                         "", "%s is protected%s" % (branch, " by a ruleset (%s)" % ", ".join(ruled) if ruled and why else "")))
    elif status == 404:
        out.append(check("branch-protection", "contour", "missing",
                         "the job's token has contents: write; without protection it can push to %s (TM-16)" % branch,
                         "owner-action", "protect %s in the repository settings (require a pull request)" % branch, why))
    elif status == 403:
        out.append(check("branch-protection", "contour", "warn",
                         "branch protection is not available here (a private repository on the free plan, or no admin "
                         "rights): TM-16 stays open - the job could push to %s, only the workflow keeps it on wip/" % branch,
                         "owner-decision", "accept it, make the repository public, or move to a plan with protection",
                         why))
    else:
        out.append(check("branch-protection", "contour", "unknown", "the job's token can push to an unprotected branch",
                         "owner-action", "", why))

    # self-hosted runners
    tw_sets = [s for _, t, is_tw in flows if is_tw for s in runs_on(t)]
    hosted = [s for s in tw_sets if "self-hosted" in s]
    if hosted:
        runners, unseen = [], []
        for path, is_org in (("repos/%s/actions/runners?per_page=100" % name, False),
                             ("orgs/%s/actions/runners?per_page=100" % owner, True)):
            data, status, why = gh(project, "api", path)
            if why:
                if not (is_org and status == 404):  # 404: the owner is a user, not an org
                    unseen.append("%s runners: %s%s" % ("organisation" if is_org else "repository", why,
                                                        " (listing runners needs admin rights)" if status == 403 else ""))
                continue
            runners += (data or {}).get("runners") or []
        online = [(r.get("name", "?"), {str(l.get("name", "")).lower() for l in r.get("labels") or []})
                  for r in runners if r.get("status") == "online"]
        unmet = [sorted(x) for x in dict.fromkeys(hosted) if not any(x <= labels for _, labels in online)]
        fit = sorted({n for n, labels in online if any(x <= labels for x in hosted)})
        state = "ok" if not unmet else ("unknown" if unseen else "missing")
        out.append(check("runner-online", "contour", state,
                         "no online runner has the labels a job asks for: those jobs queue forever",
                         "owner-action", "; ".join("start a self-hosted runner with labels %s" % ", ".join(u) for u in unmet),
                         ("online: %s" % ", ".join(fit) if fit else "%d runner(s) listed" % len(runners))
                         + ("; no runner for %s" % " | ".join(", ".join(u) for u in unmet) if unmet else "")
                         + ("; not listed: %s" % "; ".join(unseen) if unseen else "")))
        shared = []
        for path, text, is_tw in flows:
            if is_tw:
                continue
            for s in runs_on(text):
                if "self-hosted" in s and any(s <= h or h <= s for h in hosted):
                    secs = sorted({x for x in SECRET_RE.findall(text) if x != "GITHUB_TOKEN"})
                    shared.append(path + (" (secrets: %s)" % ", ".join(secs) if secs else ""))
                    break
        out.append(check("runner-shared", "contour", "warn" if shared else "ok",
                         "the contour's jobs run model output; on a runner shared with these workflows a prompt "
                         "injection reaches their checkouts, caches and secrets", "owner-decision",
                         "give the contour its own runner (its own labels), or accept the risk" if shared else "",
                         ", ".join(shared) or "no other workflow uses the contour's runner labels"))
    return out


# ---- runner -------------------------------------------------------------------------------

def runner_checks(project, cfg):
    kit = os.environ.get("TEAMWRIGHT_KIT")
    ok = bool(kit) and os.path.isfile(os.path.join(kit, "scripts", "tw-next.py"))
    out = [check("runner-kit", "runner", "ok" if ok else "missing",
                 "the job asks the router and loads the plugin from the kit checked out on the runner", "owner-action",
                 "clone teamwright on the runner and export TEAMWRIGHT_KIT=<its path> in the runner's environment",
                 "TEAMWRIGHT_KIT=%s%s" % (kit or "unset", "" if ok or not kit else " (no scripts/tw-next.py there)"))]
    return out + tool_checks(project, cfg, "runner")


# ---- report -------------------------------------------------------------------------------

def doctor(project, scopes=None, since=None):
    explicit = bool(scopes)
    scopes = list(dict.fromkeys(scopes or ["repo", "contour"]))
    cfg_text = read(os.path.join(project, CONFIG))
    checks, notes = [], []
    if cfg_text is None:
        checks.append(check("config", "repo", "missing", "teamwright is not installed in this project", "agent",
                            "/teamwright:adopt (an existing project) or /teamwright:init (a new one)", CONFIG))
        cfg = {}
        kc = None
    else:
        kc = kit_config()
        cfg_ok = True
        try:
            cfg = kc.parse_yaml(cfg_text)
        except ValueError as e:
            cfg, cfg_ok = {}, False
            checks.append(check("config", "repo", "missing", "the config does not parse", "agent",
                                "fix %s" % CONFIG, str(e)[:200]))
        if not isinstance(cfg, dict):
            cfg = {}
    if since is None:
        since = installed_version(project)
    if "repo" in scopes and kc is not None:
        checks += repo_checks(project, cfg, kc, since, cfg_ok)
    if "contour" in scopes:
        flows = workflows(project)
        checks += workflow_checks(project, cfg, flows)
        if not any(tw for _, _, tw in flows) and not explicit:
            notes.append("no contour workflow: the GitHub checks were skipped (`--scope contour` runs them)")
        elif not has_github_remote(project):
            checks.append(check("github", "contour", "n/a", "the contour runs on GitHub Actions", "owner-decision",
                                "", "no GitHub remote"))
        else:
            checks += github_checks(project, flows)
    if "runner" in scopes:
        have = {c["id"] for c in checks}
        checks += [c for c in runner_checks(project, cfg) if c["id"] not in have]
    counts = {}
    for c in checks:
        counts[c["state"]] = counts.get(c["state"], 0) + 1
    checks.sort(key=lambda c: STATES.index(c["state"]))
    return {"project": project, "kit": kit_version(), "kit_in_project": installed_version(project), "since": since,
            "scopes": scopes, "checks": checks, "counts": counts, "notes": notes,
            "ok": not any(c["state"] in ("missing", "unknown") for c in checks)}


def human(rep):
    lines = []
    for c in rep["checks"]:
        if c["state"] in ("ok", "n/a"):
            continue
        lines.append("%-8s %-24s %s" % (c["state"].upper(), c["id"], c["why"]))
        if c["evidence"] and c["state"] != "manual":
            lines.append("%-33s found: %s" % ("", c["evidence"]))
        if c["fix"]:
            lines.append("%-33s %s: %s" % ("", c["class"], c["fix"]))
    for n in rep["notes"]:
        lines.append("note: %s" % n)
    lines.append("doctor: %d check(s): %s" % (len(rep["checks"]), ", ".join(
        "%s %d" % (s, rep["counts"][s]) for s in STATES if rep["counts"].get(s)) or "none"))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project", default=os.getcwd())
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--scope", action="append", choices=("repo", "contour", "runner"),
                    help="repeatable (default: repo and contour)")
    ap.add_argument("--since", help="list the manual steps of the versions after this one (default: the project's kit)")
    args = ap.parse_args(argv)
    project = os.path.abspath(args.project)
    if not os.path.isdir(project):
        print("tw-doctor: no such project: %s" % project, file=sys.stderr)
        return 2
    rep = doctor(project, args.scope, args.since)
    print(json.dumps(rep, indent=2, ensure_ascii=False) if args.json else human(rep))
    return 0


if __name__ == "__main__":
    sys.exit(main())
