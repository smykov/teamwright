#!/usr/bin/env python3
"""tw-install.py - deterministic steps of teamwright onboarding (python3 stdlib only).

The /teamwright:adopt, :init and :reconfigure commands talk to the user and decide;
this script does the parts that must be repeatable and reviewable:

  inventory   JSON picture of the target project (what already exists)
  plan        actions `apply` would take for a config, with conflicts
  apply       copy the template without overwriting, render placeholders and the
              tools blocks, merge .mcp.json and .claude/settings.json, enable git hooks
  enforce     set mode: enforce (gates block); lowering the mode is the owner's call
  scan        secret scan of the whole working tree, untracked files included;
              findings classified, only secret-like ones fail
  check-commands  run every configured area command once through scripts/tw-run
              (timeout; pass / fail / not-runnable; environment errors such as a
              refused database connection are not-runnable; flags a command that
              modifies tracked files inside its area's workdir; changes elsewhere
              are notes). Run it in the foreground and edit nothing meanwhile.
  next        the flow router's decision (same as scripts/tw-next.py)

Common options: --project PATH (default: cwd), --dry-run (write nothing), --json.
plan/apply/check-commands read --config FILE (default: <project>/.teamwright/config.yml).
`apply --config .teamwright/config.next.yml` shows the config diff, applies it and
removes the proposal file; `apply --accept PATH` records a hand-merged file.
Config: YAML subset or JSON, see docs/process/plugin.md.

Never overwrites a file it did not write: hashes of written files are kept in
.teamwright/installed.json; a file that exists and differs is a conflict, except
that the block between the teamwright:tools markers is always re-rendered.
"""
import argparse
import difflib
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAPABILITIES = ["spec", "context", "docs", "ui_verify", "api_verify"]
MARK_BEGIN = "<!-- teamwright:tools:begin -->"
MARK_END = "<!-- teamwright:tools:end -->"
PER_AREA = ("developer.md", "test-writer.md")
MERGED = {".claude/settings.json"}                       # merged, never copied
SKIP_PARTS = {"__pycache__", ".DS_Store"}
SKIP_TEMPLATE = {".teamwright/config.example.yml"}       # example only, config.yml is written
KIT_ONLY_DOCS = {"plugin.md"}                            # about the kit, not the process
MANIFEST = ".teamwright/installed.json"
CONFIG = ".teamwright/config.yml"
CONFIG_NEXT = ".teamwright/config.next.yml"
ACCEPTED = "@accepted"                                   # manifest key: hand-merged files
KIT_KEY = "@kit"                                         # manifest key: plugin and version
RUNNERS = ("host", "docker")
COMMAND_KEYS = ("test_command", "lint_command", "api_test_command", "e2e_ui_command",
                "generate_command", "gate_command")      # per-area: wrapped with tw-run
CHECK_KEYS = ("test_command", "lint_command", "api_test_command", "e2e_ui_command")
TW_RUN = "scripts/tw-run"
LOCK_FILES = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "pubspec.lock",
              "poetry.lock", "uv.lock", "Pipfile.lock", "requirements.txt", "Cargo.lock",
              "go.sum", "Gemfile.lock", "composer.lock", "gradle.lockfile", "Podfile.lock"]
CI_FILES = [".github/workflows", ".gitlab-ci.yml", ".circleci", "Jenkinsfile",
            "azure-pipelines.yml", "bitbucket-pipelines.yml", "Makefile", "justfile", "Taskfile.yml"]
SECRETISH = re.compile(r"(^|/)(\.env(\..+)?|[^/]*\.local\.json|[^/]*\.(pem|key|p12|pfx|keystore|jks)|"
                       r"id_(rsa|dsa|ecdsa|ed25519)|credentials(\.json)?|service-account[^/]*\.json)$")
SECRET_OK = re.compile(r"(^|/)\.env\.(example|sample|template)$")
WALK_SKIP = {".git", "node_modules", ".venv", "venv", "__pycache__", ".dart_tool", "build",
             "dist", ".gradle", "Pods", "target", ".next", ".serena"}


# ---------------------------------------------------------------- config reader
# One parser for the installer and the gates: template/scripts/hooks/_config.py
# (copied into projects with the hooks), imported from this kit.
sys.path.insert(0, os.path.join(KIT, "template", "scripts", "hooks"))
import _config  # noqa: E402

parse_yaml = _config.parse_yaml
MODES = _config.MODES


def front_matter(text):
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.S)
    if not m:
        return {}, text
    return parse_yaml(m.group(1)), m.group(2)


def section(body, title):
    m = re.search(r"^## +%s\s*$(.*?)(?=^## |\Z)" % re.escape(title), body, re.M | re.S)
    return m.group(1).strip("\n") if m else None


# ---------------------------------------------------------------- helpers
def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError):
        return None


def git(project, *args):
    try:
        r = subprocess.run(["git", "-C", project] + list(args), capture_output=True, text=True)
        return r.returncode, r.stdout
    except OSError:
        return 1, ""


def is_git(project):
    return git(project, "rev-parse", "--is-inside-work-tree")[1].strip() == "true"


def dump_json(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


# ---------------------------------------------------------------- config
def load_config(path):
    text = read(path)
    if text is None:
        raise SystemExit("tw-install: config not found: %s" % path)
    try:
        cfg = parse_yaml(text)
    except ValueError as e:
        raise SystemExit("tw-install: cannot parse %s: %s" % (path, e))
    errors = []
    if not isinstance(cfg, dict):
        raise SystemExit("tw-install: config must be a mapping")
    if cfg.get("mode") is not None and cfg.get("mode") not in MODES:
        errors.append("mode must be gate-first or enforce")
    areas = cfg.get("areas") or []
    if not isinstance(areas, list) or not areas:
        errors.append("areas: at least one area is required")
    for a in areas if isinstance(areas, list) else []:
        if not isinstance(a, dict) or not a.get("name"):
            errors.append("every area needs a name")
        elif not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", str(a["name"])):
            errors.append("area name %r: use lower-case letters, digits, - and _" % a["name"])
        else:
            n = a["name"]
            runner = a.get("runner") or "host"
            if runner not in RUNNERS:
                errors.append("areas[%s].runner must be host or docker" % n)
            if runner == "docker" and not str(a.get("image") or "").strip():
                errors.append("areas[%s].image is required with runner: docker" % n)
            cache = a.get("cache")
            if cache is not None and not (isinstance(cache, list) and all(isinstance(c, str) for c in cache)):
                errors.append("areas[%s].cache must be a list of directories" % n)
            wd = a.get("workdir")
            if wd is not None and (not isinstance(wd, str) or wd.startswith("/") or ".." in wd.split("/")):
                errors.append("areas[%s].workdir must be a relative path inside the project" % n)
            for k in ("generated", "generate_inputs", "source_dirs", "test_dirs"):
                v = a.get(k)
                if v is None:
                    continue
                vs = v if isinstance(v, list) else [v]
                if not all(isinstance(x, str) and x.strip() and not x.startswith("/")
                           and ".." not in x.split("/") for x in vs):
                    errors.append("areas[%s].%s must be a list of paths relative to the project root" % (n, k))
            if a.get("generated") and not str(a.get("generate_command") or "").strip():
                errors.append("areas[%s].generated names the outputs of generate_command, which the area "
                              "does not have" % n)
            ce = a.get("copy_env")
            if ce is not None and not (isinstance(ce, dict) and all(
                    re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", str(k)) and isinstance(v, (str, int, float))
                    for k, v in ce.items())):
                errors.append("areas[%s].copy_env must map variable names to values, e.g. "
                              "CARGO_TARGET_DIR: \"{cache}/target\"" % n)
            cw = a.get("ci_workflow")
            if cw is not None and not (isinstance(cw, str) and cw.strip()):
                errors.append("areas[%s].ci_workflow must name the CI workflow that runs the tests "
                              "the host cannot (e.g. windows.yml)" % n)
            ts = a.get("test_select_command")
            if ts is not None:
                if not (isinstance(ts, str) and "{tests}" in ts):
                    errors.append("areas[%s].test_select_command must be a command with a {tests} placeholder, "
                                  "e.g. \"pytest -q -n ${PYTEST_WORKERS:-4} {tests}\" (scripts/tw-test puts the "
                                  "selected tests there)" % n)
                elif ts.lstrip().startswith(("scripts/tw-test", "scripts/tw-gate")):
                    errors.append("areas[%s].test_select_command: write the bare test command, not a "
                                  "teamwright wrapper" % n)
            for k in COMMAND_KEYS + ("test_select_command",):
                if a.get(k) and str(a[k]).lstrip().startswith(TW_RUN):
                    errors.append("areas[%s].%s: write the bare command; tw-run is applied "
                                  "automatically" % (n, k))
    tools = cfg.get("tools") or {}
    if not isinstance(tools, dict):
        errors.append("tools must be a mapping")
    else:
        for k in tools:
            if k not in CAPABILITIES:
                errors.append("tools.%s: unknown capability (known: %s)" % (k, ", ".join(CAPABILITIES)))
    defer = cfg.get("ui_verify_deferred")
    if defer is not None and not (isinstance(defer, str) and defer.strip()):
        errors.append("ui_verify_deferred must be a non-empty reason (e.g. \"decisions.md #6\")")
    no_mcp = cfg.get("no_mcp")
    if no_mcp is not None and not (isinstance(no_mcp, list) and all(x in CAPABILITIES for x in no_mcp)):
        errors.append("no_mcp must be a list of capabilities (%s)" % ", ".join(CAPABILITIES))
    trp = cfg.get("test_runner_patterns")
    if trp is not None:
        if not (isinstance(trp, list) and all(isinstance(x, str) and x.strip() for x in trp)):
            errors.append("test_runner_patterns must be a list of regular expressions (commands the "
                          "test guard treats as test runs)")
        else:
            for x in trp:
                try:
                    re.compile(x)
                except re.error as e:
                    errors.append("test_runner_patterns: %r is not a valid regular expression: %s" % (x, e))
    errors += _config.process_errors(cfg)
    if errors:
        raise SystemExit("tw-install: invalid config %s:\n  %s" % (path, "\n  ".join(errors)))
    proc = _config.process_of(cfg)
    # rendered into AGENTS.md and the role files ({{REVIEW_BLOCKING}} ...); not written back
    cfg["review_blocking"] = proc["review"]["blocking"]
    cfg["batch_max_tasks"] = str(proc["batch"]["max_tasks"])
    cfg["batch_parallel"] = str(proc["batch"]["parallel"])
    cfg["batch_by_priority"] = ", ".join("%s %s" % kv for kv in sorted(proc["batch"]["by_priority"].items()))
    cfg["autonomy_start"] = proc["autonomy"]["start"]
    cfg["autonomy_continue"] = "true" if proc["autonomy"]["continue"] else "false"
    explicit = cfg.get("mode") in MODES
    cfg["mode"] = _config.mode_of(cfg)          # missing -> enforce, as the gates read it
    if not explicit:
        text = _config.set_mode(text, cfg["mode"])  # the written config states its mode
    return cfg, text


# Documents whose content belongs to the project: the template only seeds them. An
# existing one (filled by /teamwright:requirements before install, or the project's own)
# is kept as is, not reported as a conflict.
PROJECT_DOCS = ("docs/requirements.md", "docs/open-questions.md", "docs/plan.md",
                "docs/architecture.md", "docs/decisions.md")


def owner_override():
    """The owner's explicit consent to lower the mode: TEAMWRIGHT_OWNER=1, honoured only
    outside Claude Code (CLAUDECODE is set in every Claude Code tool call, and the gates
    deny agent commands that mention either variable)."""
    return os.environ.get("TEAMWRIGHT_OWNER") == "1" and not os.environ.get("CLAUDECODE")


def _fmt(v):
    if v is None:
        return None
    if isinstance(v, list):
        return ", ".join(str(x) for x in v) if v else "n/a"
    v = str(v)
    return v if v.strip() else "n/a"


def wrap_command(area, cmd):
    """`scripts/tw-run <area> -- <cmd>`; a command with shell syntax is passed as one
    quoted string (tw-run runs it with sh -c and appends any extra arguments)."""
    cmd = str(cmd).strip()
    if not cmd:
        return cmd
    if re.search(r"[^\w\s./:=@%+,-]", cmd):
        cmd = shlex.quote(cmd)
    return "%s %s -- %s" % (TW_RUN, area["name"], cmd)


def area_value(area, key):
    v = area[key]
    if key in COMMAND_KEYS and isinstance(v, str) and v.strip():
        return wrap_command(area, v)
    return v


def render_placeholders(text, cfg, area):
    unresolved = []

    def sub(m):
        key = m.group(1).lower()
        if area is not None:
            if key == "area":
                return area["name"]
            if key in area:
                return _fmt(area_value(area, key))
        if key != "areas" and key in cfg and not isinstance(cfg[key], dict):
            return _fmt(cfg[key])
        areas = cfg.get("areas") or []
        if area is not None:
            # a per-area file never borrows another area's value: unresolved instead
            unresolved.append(m.group(0))
            return m.group(0)
        vals = [(a["name"], area_value(a, key)) for a in areas if key in a]
        if vals:
            if len(areas) == 1:
                return _fmt(vals[0][1])
            return "; ".join("%s: %s" % (n, _fmt(v)) for n, v in vals)
        unresolved.append(m.group(0))
        return m.group(0)

    return re.sub(r"\{\{([A-Z][A-Z0-9_]*)\}\}", sub, text), unresolved


# ---------------------------------------------------------------- providers
def load_adapter(providers_dir, cap, name):
    if not name:
        return None
    path = os.path.join(providers_dir, cap, "%s.md" % name)
    text = read(path)
    if name == "none" and text is None:
        # "none" without an adapter file: nothing to inject.
        return None
    if text is None:
        return {"missing": True, "capability": cap, "provider": name}
    try:
        fm, body = front_matter(text)
    except ValueError as e:
        return {"missing": True, "capability": cap, "provider": name, "error": str(e)}
    mcp = fm.get("mcp")
    server = None
    if isinstance(mcp, dict) and mcp.get("name"):
        conf = mcp.get("config")
        if isinstance(conf, dict):
            server = (mcp["name"], conf)
        else:
            inst = section(body, "Install") or ""
            for block in re.findall(r"```json\s*\n(.*?)```", inst, re.S):
                try:
                    servers = json.loads(block).get("mcpServers") or {}
                except (ValueError, AttributeError):
                    continue
                if mcp["name"] in servers:
                    server = (mcp["name"], servers[mcp["name"]])
                    break
    return {"capability": cap, "provider": name, "front": fm, "server": server,
            "add": mcp.get("add") if isinstance(mcp, dict) else None,
            "rules": (section(body, "Rules for agents") or "").strip()}


def tools_block(cfg, adapters):
    tools = cfg.get("tools") or {}
    summary = ", ".join("%s=%s" % (c, tools[c]) for c in CAPABILITIES if c in tools)
    parts = [MARK_BEGIN, "## Tools", "",
             "Configured by teamwright from `.teamwright/config.yml` (%s). "
             "Re-rendered by `/teamwright:reconfigure`; edit outside the markers." % (summary or "none")]
    for c in CAPABILITIES:
        ad = adapters.get(c)
        if ad and not ad.get("missing") and ad["rules"]:
            parts += ["", "### %s: %s" % (c, ad["provider"]), "", ad["rules"]]
    parts.append(MARK_END)
    return "\n".join(parts)


def replace_block(text, block):
    b, e = text.find(MARK_BEGIN), text.find(MARK_END)
    if b < 0 or e < b:
        return None
    return text[:b] + block + text[e + len(MARK_END):]


# ---------------------------------------------------------------- inventory
def inventory(project, providers_dir, kit=KIT):
    j = os.path.join
    ex = lambda p: os.path.exists(j(project, p))  # noqa: E731
    out = {"project": ".", "git": {"repo": is_git(project)}}
    if out["git"]["repo"]:
        out["git"]["hooks_path"] = git(project, "config", "--get", "core.hooksPath")[1].strip() or None
        out["git"]["dirty"] = bool(git(project, "status", "--porcelain")[1].strip())
        hooks_dir = j(project, ".git", "hooks")
        out["git"]["legacy_hooks"] = sorted(
            f for f in (os.listdir(hooks_dir) if os.path.isdir(hooks_dir) else [])
            if not f.endswith(".sample"))
    for f in ("CLAUDE.md", "AGENTS.md", "PRINCIPLES.md"):
        p = j(project, f)
        out[f] = {"exists": os.path.isfile(p), "bytes": os.path.getsize(p) if os.path.isfile(p) else 0,
                  "teamwright_markers": MARK_BEGIN in (read(p) or "")}
    for d, key in ((".claude/agents", "claude_agents"), (".claude/commands", "claude_commands"),
                   (".claude/skills", "claude_skills")):
        p = j(project, d)
        out[key] = sorted(os.listdir(p)) if os.path.isdir(p) else []
    s = read(j(project, ".claude/settings.json"))
    try:
        sj = json.loads(s) if s else None
    except ValueError:
        sj = "invalid"
    out["settings_json"] = {"exists": s is not None, "valid": sj != "invalid",
                            "hook_events": sorted((sj or {}).get("hooks", {}).keys()) if isinstance(sj, dict) else []}
    m = read(j(project, ".mcp.json"))
    try:
        out["mcp_servers"] = sorted((json.loads(m).get("mcpServers") or {}).keys()) if m else []
    except (ValueError, AttributeError):
        out["mcp_servers"] = "invalid .mcp.json"
    out["spec_tools"] = {"spec-kit": ex(".specify"), "openspec": ex("openspec")}
    out["ci_and_build"] = [f for f in CI_FILES if ex(f)]
    out["test_dirs"] = [d for d in ("test", "tests", "spec", "__tests__", "e2e", "integration_test",
                                    "playwright.config.ts", "playwright.config.js") if ex(d)]
    out["lock_files"] = sorted(os.path.relpath(p, project) for p in _walk(project, depth=2)
                               if os.path.basename(p) in LOCK_FILES)
    out["secret_looking_files"] = secret_looking(project)
    cfg_text = read(j(project, CONFIG))
    mode = _config.read_mode(j(project, CONFIG)) if cfg_text is not None else None
    out["teamwright"] = {"config": cfg_text is not None, "mode": mode,
                         "installed_files": len(_manifest(project))}
    out["providers_detected"] = detect_providers(project, providers_dir)
    out["versions"] = detect_versions(project)
    out["unfilled_docs"] = unfilled_docs(project, kit)
    out["kind"], out["requirement_docs"] = repo_kind(project)
    return out


# ---------------------------------------------------------------- repository kind
# init vs adopt is decided here, not by the model's impression: `empty` and
# `docs-only` take /teamwright:init, `code` takes /teamwright:adopt.
KIND_IGNORE_DIRS = (".git/", ".teamwright/", ".claude/", ".github/", ".specify/", ".serena/",
                    ".vscode/", ".idea/")
KIND_IGNORE_FILES = (".gitignore", ".gitattributes", ".editorconfig", ".mcp.json", ".DS_Store",
                     "CLAUDE.md", "AGENTS.md", "PRINCIPLES.md")
DOC_EXT = (".md", ".markdown", ".txt", ".rst", ".adoc", ".doc", ".docx", ".odt", ".rtf", ".pdf",
           ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".drawio", ".csv", ".xlsx", ".pptx")
# Words of a file name (split on anything that is not a letter or digit) that mark a
# requirements document; whole words or word prefixes only, so "отзывы" is not "тз".
REQ_WORDS = {"requirement", "requirements", "spec", "specs", "specification", "prd", "brief",
             "tz", "srs", "scope", "vision", "\u0442\u0437", "terms"}
REQ_PREFIXES = ("\u0442\u0435\u0445\u0437\u0430\u0434", "\u0442\u0435\u0445\u043d\u0438\u0447\u0435\u0441\u043a",
                "\u0442\u0440\u0435\u0431\u043e\u0432\u0430\u043d", "\u0441\u043f\u0435\u0446\u0438\u0444\u0438\u043a\u0430\u0446")


def _req_score(f):
    """2 = the name says requirements, 1 = a top-level or docs/ README, 0 = neither."""
    stem = os.path.splitext(os.path.basename(f))[0].lower()
    words = [x for x in re.split(r"[\W_]+", stem) if x]
    if any(x in REQ_WORDS for x in words) or any(x.startswith(REQ_PREFIXES) for x in words):
        return 2
    if stem == "readme" and f.count("/") <= 1 and (f.count("/") == 0 or f.startswith("docs/")):
        return 1
    return 0


def repo_kind(project):
    """('empty' | 'docs-only' | 'code', [candidate requirement documents, best first]).

    Files teamwright itself installed (installed.json) do not count, so an init that was
    interrupted after `apply` is still a new project. A git listing that fails falls back
    to walking the tree: an unreadable index must not make a codebase look empty."""
    files = None
    if is_git(project):
        rc, out = git(project, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
        if rc == 0:
            files = [f for f in out.split("\0") if f]
    if files is None:
        files = [os.path.relpath(p, project).replace(os.sep, "/") for p in _walk(project)]
    installed = set(_manifest(project))
    files = [f for f in files if not f.startswith(KIND_IGNORE_DIRS) and f not in installed
             and os.path.basename(f) not in KIND_IGNORE_FILES
             and not os.path.basename(f).upper().startswith(("LICENSE", "COPYING"))]
    if not files:
        return "empty", []
    docs = [f for f in files if f.lower().endswith(DOC_EXT)]
    kind = "docs-only" if len(docs) == len(files) else "code"
    scored = sorted((-_req_score(f), f) for f in docs if _req_score(f))
    return kind, [f for _, f in scored][:20]


# ---------------------------------------------------------------- versions
# Read from manifests and lock files only: a version that is not written down in the
# project is reported as absent, never guessed.
MANIFEST_FILES = ("package.json", "package-lock.json", "pubspec.yaml", "pubspec.lock",
                  ".nvmrc", ".node-version", ".tool-versions", ".fvmrc", "go.mod", ".python-version")


def _pub_sections(text):
    """pubspec.yaml / pubspec.lock -> {section: {name: value or {sub: value}}} (2 levels)."""
    out, sec, name = {}, None, None
    for raw in text.splitlines():
        line = raw.split(" #")[0].rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        ind = len(line) - len(line.lstrip(" "))
        m = re.match(r"^\s*([^:\s][^:]*?)\s*:\s*(.*)$", line)
        if not m:
            continue
        k, v = m.group(1).strip("\"'"), m.group(2).strip().strip("\"'")
        if ind == 0:
            sec, name = k, None
            out[sec] = v if v else {}
        elif ind == 2 and isinstance(out.get(sec), dict):
            name = k
            out[sec][name] = v if v else {}
        elif ind == 4 and isinstance(out.get(sec), dict) and isinstance(out[sec].get(name), dict):
            out[sec][name][k] = v
    return out


def _versions_of(rel, text):
    base = os.path.basename(rel)
    if base == "package.json":
        j = json.loads(text)
        res = {}
        for sec in ("engines", "dependencies", "devDependencies", "peerDependencies"):
            if isinstance(j.get(sec), dict) and j[sec]:
                res[sec] = j[sec]
        if j.get("packageManager"):
            res["packageManager"] = j["packageManager"]
        return {"kind": "declared", **res}
    if base == "package-lock.json":
        j = json.loads(text)
        pk = j.get("packages") or {}
        root = pk.get("") or {}
        direct = sorted(set(root.get("dependencies") or {}) | set(root.get("devDependencies") or {}))
        res = {}
        for name in direct:
            v = (pk.get("node_modules/" + name) or {}).get("version") \
                or ((j.get("dependencies") or {}).get(name) or {}).get("version")
            if v:
                res[name] = v
        return {"kind": "resolved", "direct": res}
    if base == "pubspec.yaml":
        sec = _pub_sections(text)
        res = {"kind": "declared"}
        for k in ("environment", "dependencies", "dev_dependencies"):
            if isinstance(sec.get(k), dict) and sec[k]:
                res[k] = {n: (v if isinstance(v, str) else ", ".join("%s: %s" % kv for kv in v.items()))
                          for n, v in sec[k].items()}
        return res
    if base == "pubspec.lock":
        sec = _pub_sections(text)
        res = {"kind": "resolved", "direct": {}}
        for n, v in (sec.get("packages") or {}).items():
            if isinstance(v, dict) and v.get("dependency", "").startswith("direct") and v.get("version"):
                res["direct"][n] = v["version"]
        if isinstance(sec.get("sdks"), dict):
            res["sdks"] = sec["sdks"]
        return res
    if base == "go.mod":
        m = re.search(r"^go\s+(\S+)", text, re.M)
        t = re.search(r"^toolchain\s+(\S+)", text, re.M)
        return {"kind": "declared", **({"go": m.group(1)} if m else {}),
                **({"toolchain": t.group(1)} if t else {})}
    if base == ".tool-versions":
        return {"kind": "declared", "tools": dict(l.split(None, 1) for l in text.splitlines()
                                                  if l.strip() and not l.startswith("#") and len(l.split()) > 1)}
    if base == ".fvmrc":
        j = json.loads(text)
        return {"kind": "declared", "flutter": j.get("flutter") or j.get("flutterSdkVersion")}
    return {"kind": "declared", "version": text.strip().splitlines()[0] if text.strip() else ""}


def detect_versions(project):
    """{relpath: versions} for manifests and lock files within 3 levels."""
    out = {}
    for p in _walk(project, depth=3):
        if os.path.basename(p) not in MANIFEST_FILES:
            continue
        rel = os.path.relpath(p, project).replace(os.sep, "/")
        text = read(p)
        if text is None:
            continue
        try:
            out[rel] = _versions_of(rel, text)
        except (ValueError, AttributeError, TypeError) as e:
            out[rel] = {"kind": "unreadable", "error": str(e)[:120]}
    return dict(sorted(out.items()))


def unfilled_docs(project, kit):
    """Project docs still identical to the template (installed and never filled in)."""
    manifest = _manifest(project)
    tpl = os.path.join(kit, "template", "docs")
    out = []
    if not os.path.isdir(tpl):
        return out
    for f in sorted(os.listdir(tpl)):
        if not f.endswith(".md") or f.startswith("_"):
            continue
        rel = "docs/" + f
        disk = read(os.path.join(project, rel))
        if disk is None:
            continue
        if disk == read(os.path.join(tpl, f)) or manifest.get(rel) == sha(disk):
            out.append(rel)
    return out


def _walk(project, depth=None):
    base = project.rstrip(os.sep).count(os.sep)
    for root, dirs, files in os.walk(project):
        dirs[:] = [d for d in dirs if d not in WALK_SKIP]
        if depth is not None and root.count(os.sep) - base >= depth:
            dirs[:] = []
        for f in files:
            yield os.path.join(root, f)


def secret_looking(project):
    """Secret-looking files present in the tree: tracked, untracked or ignored."""
    tracked = set()
    if is_git(project):
        tracked = set(git(project, "ls-files", "-z")[1].split("\0"))
    out = []
    for p in _walk(project):
        rel = os.path.relpath(p, project).replace(os.sep, "/")
        if SECRETISH.search(rel) and not SECRET_OK.search(rel):
            out.append({"path": rel, "tracked": rel in tracked})
    return sorted(out, key=lambda x: x["path"])


def detect_providers(project, providers_dir):
    found = []
    if not os.path.isdir(providers_dir):
        return found
    for cap in sorted(os.listdir(providers_dir)):
        d = os.path.join(providers_dir, cap)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if not f.endswith(".md"):
                continue
            try:
                fm, _ = front_matter(read(os.path.join(d, f)) or "")
            except ValueError:
                continue
            det = fm.get("detect") if isinstance(fm.get("detect"), dict) else {}
            hits = [p for p in det.get("files") or [] if os.path.exists(os.path.join(project, p))]
            hits += ["cmd:" + c for c in det.get("commands") or [] if shutil.which(str(c))]
            if hits:
                found.append({"capability": cap, "provider": f[:-3], "evidence": hits})
    return found


# ---------------------------------------------------------------- plan
def _manifest_raw(project):
    try:
        m = json.loads(read(os.path.join(project, MANIFEST)) or "{}")
    except ValueError:
        return {}
    return m if isinstance(m, dict) else {}


def _manifest(project):
    """Installed files -> sha of what the installer wrote (keys starting with @ are metadata)."""
    return {k: v for k, v in _manifest_raw(project).items() if not k.startswith("@")}


def _accepted(project):
    """Hand-merged files: path -> {"disk": sha accepted, "template": sha of the template then}."""
    a = _manifest_raw(project).get(ACCEPTED)
    return a if isinstance(a, dict) else {}


def write_manifest(project, files, accepted, kit_info=None):
    """kit_info: the "@kit" record (plugin, version); None keeps the recorded one."""
    out = dict(sorted(files.items()))
    if accepted:
        out[ACCEPTED] = dict(sorted(accepted.items()))
    rec = kit_info if kit_info is not None else _manifest_raw(project).get(KIT_KEY)
    if rec:
        out[KIT_KEY] = rec
    write(project, MANIFEST, dump_json(out))


def _json_file(path):
    try:
        d = json.loads(read(path) or "{}")
    except ValueError:
        return {}
    return d if isinstance(d, dict) else {}


def kit_version(kit, plugin_id):
    """The kit's version when plugin.json names none (a release channel such as
    `teamwright-next` leaves it out, so every commit is a new version for /plugin update).
    Claude Code then versions the plugin by its commit: the first 12 hex digits of the
    SHA. From a git checkout of the kit that is HEAD; from the plugin cache (a copy
    without .git) it is the version Claude Code recorded for that install path in
    plugins/installed_plugins.json. "" when neither says."""
    rc, out = git(kit, "rev-parse", "HEAD")
    rc2, top = git(kit, "rev-parse", "--show-toplevel")
    if rc == 0 and rc2 == 0 and os.path.realpath(top.strip()) == os.path.realpath(kit) \
            and re.match(r"^[0-9a-f]{40}$", out.strip()):
        return out.strip()[:12]
    reg = _json_file(os.path.join(claude_dir(), "plugins", "installed_plugins.json")).get("plugins")
    here = os.path.realpath(kit)
    for pid, entries in (reg.items() if isinstance(reg, dict) else []):
        for e in entries if isinstance(entries, list) else []:
            if isinstance(e, dict) and e.get("installPath") and \
                    os.path.realpath(e["installPath"]) == here and (pid == plugin_id or not plugin_id):
                return str(e.get("version") or "")
    return ""


def kit_info(kit):
    """The "@kit" record: which plugin set the project up, at which version."""
    pj = _json_file(os.path.join(kit, ".claude-plugin", "plugin.json"))
    mj = _json_file(os.path.join(kit, ".claude-plugin", "marketplace.json"))
    name = pj.get("name") or "teamwright"
    pid = "%s@%s" % (name, mj.get("name") or name)
    return {"plugin": pid, "version": pj.get("version") or kit_version(kit, pid)}


def other_channel(project, pid):
    """An enabled install of the same plugin from another marketplace (another release
    channel) in the project's settings.json or settings.local.json: (file, id) or None.
    Two enabled copies with one name do not mix - one copy's hooks silently do not run -
    so the installer does not enable a second one."""
    name = pid.split("@", 1)[0]
    for f in ("settings.json", "settings.local.json"):
        ep = _json_file(os.path.join(project, ".claude", f)).get("enabledPlugins")
        for k, v in (ep.items() if isinstance(ep, dict) else []):
            if k != pid and k.split("@", 1)[0] == name and v is True:
                return ".claude/" + f, k
    return None


def claude_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


_GITHUB = re.compile(r"^(?:https://(?:[^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)"
                     r"([\w.-]+/[\w.-]+?)(?:\.git)?/?$")


def _git_source(path):
    """A marketplace source another machine can fetch: the origin of the kit checkout, with
    its branch when that is not the default one. None for a copy without a usable remote."""
    rc, top = git(path, "rev-parse", "--show-toplevel")
    if rc or os.path.realpath(top.strip()) != os.path.realpath(path):
        return None
    url = git(path, "remote", "get-url", "origin")[1].strip()
    m = _GITHUB.match(url)
    if m:
        src = {"source": "github", "repo": m.group(1)}
    elif url.endswith(".git") and not re.match(r"^https?://[^/]*@", url):   # never a token
        src = {"source": "git", "url": url}
    else:
        return None
    branch = git(path, "symbolic-ref", "--short", "-q", "HEAD")[1].strip()
    default = git(path, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD")[1].strip()
    default = default.split("/", 1)[1] if "/" in default else ""
    if branch and branch != default and (default or branch not in ("main", "master")):
        src["ref"] = branch
    return src


def kit_marketplace(kit):
    """(marketplace name, its source for the project's settings or None).

    The project settings name the marketplace (extraKnownMarketplaces) and enable the
    plugin, so Claude Code offers both on a fresh clone. A source Claude Code already
    knows by github/git/url is reused; a local directory becomes its git origin."""
    name = kit_info(kit)["plugin"].split("@", 1)[1]
    known = _json_file(os.path.join(claude_dir(), "plugins", "known_marketplaces.json")).get(name)
    src = known.get("source") if isinstance(known, dict) else None
    if isinstance(src, dict) and src.get("source") in ("github", "git", "url"):
        return name, {k: v for k, v in src.items() if k in ("source", "repo", "url", "ref", "path")}
    local = src.get("path") if isinstance(src, dict) and src.get("source") == "directory" else None
    for p in ([local] if local else []) + [kit]:
        g = _git_source(p) if p and os.path.isdir(p) else None
        if g:
            return name, g
    return name, None


def template_files(kit):
    tpl = os.path.join(kit, "template")
    for root, dirs, files in os.walk(tpl):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_PARTS)
        for f in sorted(files):
            if f in SKIP_PARTS or f.endswith(".pyc"):
                continue
            rel = os.path.relpath(os.path.join(root, f), tpl).replace(os.sep, "/")
            if rel not in SKIP_TEMPLATE:
                yield rel, os.path.join(root, f)
    proc = os.path.join(kit, "docs", "process")
    if os.path.isdir(proc):
        for f in sorted(os.listdir(proc)):
            if f.endswith(".md") and f not in KIT_ONLY_DOCS:
                yield "docs/process/" + f, os.path.join(proc, f)


def desired_files(kit, cfg, adapters):
    """[(dest_rel, content_or_None_for_binary, src, unresolved)]"""
    block = tools_block(cfg, adapters)
    areas = cfg.get("areas") or []
    out = []
    for rel, src in template_files(kit):
        if rel in MERGED:
            continue
        text = read(src)
        if text is None:
            out.append((rel, None, src, []))
            continue
        targets = [(rel, None)]
        if rel.startswith(".claude/agents/") and os.path.basename(rel) in PER_AREA:
            if len(areas) == 1:
                targets = [(rel, areas[0])]
            else:
                targets = [(rel[:-3] + "-%s.md" % a["name"], a) for a in areas]
        for dest, area in targets:
            t = text
            if area is not None and len(areas) > 1:
                t = re.sub(r"^(name:\s*)(\S+)\s*$", lambda m: "%s%s-%s" % (m.group(1), m.group(2), area["name"]),
                           t, count=1, flags=re.M)
            t, unresolved = render_placeholders(t, cfg, area)
            if MARK_BEGIN in t:
                t = replace_block(t, block) or t
            out.append((dest, t, src, unresolved))
    return out


def merge_settings(existing, tpl, plugin=None):
    """Add teamwright env, deny rules, hooks and the plugin; never remove or change what exists.

    plugin: (plugin id, marketplace name, marketplace source or None)."""
    res = json.loads(json.dumps(existing or {}))
    if plugin:
        pid, mname, msrc = plugin
        ep = res.setdefault("enabledPlugins", {})
        if isinstance(ep, dict):
            ep.setdefault(pid, True)
        km = res.setdefault("extraKnownMarketplaces", {}) if msrc else None
        if isinstance(km, dict):
            km.setdefault(mname, {"source": msrc})
    if "$schema" in tpl and "$schema" not in res:
        res["$schema"] = tpl["$schema"]
    env = res.setdefault("env", {})
    for k, v in (tpl.get("env") or {}).items():
        env.setdefault(k, v)
    deny = res.setdefault("permissions", {}).setdefault("deny", [])
    for rule in (tpl.get("permissions") or {}).get("deny", []):
        if rule not in deny:
            deny.append(rule)
    hooks = res.setdefault("hooks", {})
    for ev, groups in (tpl.get("hooks") or {}).items():
        cur = hooks.setdefault(ev, [])
        present = {h.get("command") for g in cur for h in g.get("hooks", [])}
        for g in groups:
            missing = [h for h in g.get("hooks", []) if h.get("command") not in present]
            if not missing:
                continue
            same = [c for c in cur if c.get("matcher") == g.get("matcher")]
            if same:
                same[0].setdefault("hooks", []).extend(missing)
            else:
                ng = dict(g)
                ng["hooks"] = missing
                cur.append(ng)
            present.update(h.get("command") for h in missing)
    return res


def gitignore_patterns(kit):
    text = read(os.path.join(kit, "template", "scripts", "install-hooks.sh")) or ""
    m = re.search(r"for pat in (.*?); do", text)
    return re.findall(r"'([^']*)'", m.group(1)) if m else []


def plan(project, kit, cfg, cfg_text, cfg_src, providers_dir):
    actions, notes = [], []
    adapters = {}
    tools = cfg.get("tools") or {}
    for c in CAPABILITIES:
        ad = load_adapter(providers_dir, c, tools.get(c))
        if ad is None:
            notes.append("tools.%s: %s - no adapter block" % (c, tools.get(c) or "not set"))
        elif ad.get("missing"):
            notes.append("tools.%s: adapter providers/%s/%s.md not found%s" % (
                c, c, ad["provider"], (" (%s)" % ad["error"]) if ad.get("error") else ""))
        adapters[c] = ad
    manifest = _manifest(project)
    accepted = _accepted(project)

    # 1. config
    dest_cfg = os.path.join(project, CONFIG)
    cur = read(dest_cfg)
    if cur is not None and cfg["mode"] == "gate-first" \
            and _config.read_mode(dest_cfg) == "enforce" and not owner_override():
        raise SystemExit(
            "tw-install: refusing enforce -> gate-first: lowering the mode is the owner's "
            "decision. The owner runs this outside Claude Code with TEAMWRIGHT_OWNER=1, or "
            "edits %s by hand." % CONFIG)
    if cur != cfg_text:
        actions.append({"op": "write-config" if cur is None else "update-config", "path": CONFIG,
                        "content": cfg_text, "change": True})

    # 2. template files
    desired = desired_files(kit, cfg, adapters)
    for dest, content, src, unresolved in desired:
        p = os.path.join(project, dest)
        a = {"path": dest, "src": src}
        if unresolved:
            a["unresolved"] = sorted(set(unresolved))
        if not os.path.exists(p):
            a.update(op="create", content=content, change=True)
        elif content is None:
            same = open(p, "rb").read() == open(src, "rb").read()
            a.update(op="same" if same else "conflict", change=False)
        else:
            disk = read(p)
            if disk == content:
                a.update(op="same", change=False)
            elif disk is not None and manifest.get(dest) == sha(disk):
                a.update(op="update", content=content, change=True)
            elif disk is not None and MARK_BEGIN in disk and MARK_END in disk:
                new = replace_block(disk, tools_block(cfg, adapters))
                if new is None:
                    a.update(op="conflict", change=False,
                             reason="teamwright:tools markers out of order - not touched")
                else:
                    a.update(op="tools" if new != disk else "same", content=new,
                             change=new != disk, keep_manifest=True)
                a.pop("unresolved", None)
            elif dest in manifest:
                a.update(op="kept-local", change=False)
                a.pop("unresolved", None)
            elif dest in PROJECT_DOCS:
                # the project's own document (written before install, e.g. by
                # /teamwright:requirements, or the project's existing doc): never a conflict
                a.update(op="kept-project", change=False)
                a.pop("unresolved", None)
            else:
                a.update(op="conflict", change=False)
                a.pop("unresolved", None)
                acc = accepted.get(dest) or {}
                if disk is not None and acc.get("disk") == sha(disk):
                    if acc.get("template") == sha(content):
                        a.update(op="accepted", reason="merged by hand, accepted")
                    else:
                        a["reason"] = "accepted merge, but the template changed since: merge " \
                                      "again, then `apply --accept %s`" % dest
            if a["op"] == "conflict":
                a["template_sha"] = sha(content)
        actions.append(a)

    # 2b. installer-owned files no longer desired (e.g. per-area roles after an area change)
    wanted_paths = {d[0] for d in desired}
    for dest in sorted(manifest):
        if dest in wanted_paths or dest in (MANIFEST, CONFIG):
            continue
        disk = read(os.path.join(project, dest))
        if disk is None or sha(disk) == manifest[dest]:
            actions.append({"op": "stale", "path": dest, "change": True,
                            "reason": "no longer installed%s" % (", already gone" if disk is None else "")})
        else:
            actions.append({"op": "conflict", "path": dest, "change": False,
                            "reason": "no longer installed, edited since install - not removed"})

    # 3. settings.json
    tpl = json.loads(read(os.path.join(kit, "template", ".claude", "settings.json")))
    sp = os.path.join(project, ".claude", "settings.json")
    s = read(sp)
    try:
        existing = json.loads(s) if s else {}
    except ValueError:
        existing = None
    if existing is None:
        actions.append({"op": "conflict", "path": ".claude/settings.json", "change": False,
                        "reason": "invalid JSON, not merged"})
    else:
        info = kit_info(kit)
        mname, msrc = kit_marketplace(kit)
        other = other_channel(project, info["plugin"])
        if other and info["plugin"] not in (existing.get("enabledPlugins") or {}):
            notes.append("%s enables %s; this kit is %s - one channel per project, so it is not "
                         "enabled too (README, Channels: switch in %s)" % (
                             other[0], other[1], info["plugin"], other[0]))
            merged = merge_settings(existing, tpl, None)
        else:
            merged = merge_settings(existing, tpl, (info["plugin"], mname, msrc))
        if msrc is None and mname not in (merged.get("extraKnownMarketplaces") or {}):
            notes.append(".claude/settings.json: no shareable source for marketplace %r (a local copy "
                         "without a git remote) - a fresh clone is not offered the plugin; add "
                         "extraKnownMarketplaces by hand" % mname)
        ch = merged != existing or s is None
        actions.append({"op": "merge-settings" if ch else "same", "path": ".claude/settings.json",
                        "content": dump_json(merged), "change": ch})

    info = kit_info(kit)
    if _manifest_raw(project).get(KIT_KEY) != info:
        actions.append({"op": "kit-version", "path": MANIFEST, "kit": info, "change": True})

    # 4. .mcp.json
    skip_mcp = set(cfg.get("no_mcp") or [])   # tool used through its CLI only, no MCP server
    wanted = [(c, adapters[c]["server"]) for c in CAPABILITIES if c not in skip_mcp
              and adapters.get(c) and not adapters[c].get("missing") and adapters[c].get("server")]
    if wanted:
        mp = os.path.join(project, ".mcp.json")
        m = read(mp)
        try:
            mj = json.loads(m) if m else {}
            servers = mj.setdefault("mcpServers", {})
        except (ValueError, AttributeError):
            mj = None
        if mj is None:
            actions.append({"op": "conflict", "path": ".mcp.json", "change": False,
                            "reason": "invalid JSON, not merged"})
        else:
            added = []
            for c, (name, conf) in wanted:
                if name in servers:
                    if servers[name] != conf:
                        notes.append(".mcp.json: server %r exists with a different config - kept" % name)
                else:
                    servers[name] = conf
                    added.append(name)
            actions.append({"op": "merge-mcp" if added else "same", "path": ".mcp.json",
                            "servers": added, "content": dump_json(mj), "change": bool(added)})

    # 5. git hooks
    if is_git(project):
        hp = git(project, "config", "--get", "core.hooksPath")[1].strip()
        if hp and hp != "scripts/hooks":
            actions.append({"op": "conflict", "path": "core.hooksPath", "change": False,
                            "reason": "already set to %r (another hook manager?)" % hp})
        else:
            gi = (read(os.path.join(project, ".gitignore")) or "").splitlines()
            missing = [p for p in gitignore_patterns(kit) if p not in gi]
            ch = hp != "scripts/hooks" or bool(missing)
            actions.append({"op": "git-hooks" if ch else "same", "path": "core.hooksPath",
                            "gitignore_add": missing, "change": ch})
            legacy = [f for f in os.listdir(os.path.join(project, ".git", "hooks"))
                      if not f.endswith(".sample")] if os.path.isdir(os.path.join(project, ".git", "hooks")) else []
            if legacy and not hp:
                notes.append(".git/hooks has %s - core.hooksPath disables them; port them to scripts/hooks"
                             % ", ".join(sorted(legacy)))
    else:
        notes.append("not a git repository - git hooks not enabled")

    for c in CAPABILITIES:
        ad = adapters.get(c)
        if ad and not ad.get("missing") and ad.get("add") and not ad.get("server"):
            notes.append("tools.%s: install manually: %s" % (c, ad["add"]))
    if cfg["mode"] == "gate-first":
        notes.append("analysis/review/verify gates warn only; "
                     "run `tw-install.py enforce` to make them block")
    return actions, notes


# ---------------------------------------------------------------- apply
def write(project, rel, content):
    p = os.path.join(project, rel)
    os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(content)


def apply(project, kit, actions):
    manifest = _manifest(project)
    before = dict(manifest)
    accepted = _accepted(project)
    kit_rec = None
    for a in actions:
        if not a.get("change"):
            if a["op"] == "same" and "src" in a and a["path"] not in manifest:
                pass  # identical by chance: not ours, leave it unowned
            continue
        rel = a["path"]
        if a["op"] == "kit-version":
            kit_rec = a["kit"]
            continue
        if a["op"] == "stale":
            p = os.path.join(project, rel)
            if os.path.isfile(p):
                os.remove(p)
            manifest.pop(rel, None)
            continue
        if a["op"] == "git-hooks":
            git(project, "config", "core.hooksPath", "scripts/hooks")
            if a["gitignore_add"]:
                gp = os.path.join(project, ".gitignore")
                cur = read(gp) or ""
                if cur and not cur.endswith("\n"):
                    cur += "\n"
                write(project, ".gitignore", cur + "\n".join(a["gitignore_add"]) + "\n")
            continue
        if a.get("content") is None and "src" in a:
            if a["op"] != "create":
                continue  # binary files are only ever created, never overwritten
            p = os.path.join(project, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            shutil.copy2(a["src"], p)
            continue
        write(project, rel, a["content"])
        if "src" in a and not a.get("keep_manifest"):
            manifest[rel] = sha(a["content"])
            if os.access(a["src"], os.X_OK):
                os.chmod(os.path.join(project, rel), 0o755)
    if manifest != before or kit_rec is not None:
        write_manifest(project, manifest, accepted, kit_rec)


def accept(project, actions, paths, dry):
    """Record the current content of hand-merged files, so plan stops calling them conflicts."""
    by_path = {a["path"]: a for a in actions}
    accepted = _accepted(project)
    done, errors = [], []
    for raw in paths:
        rel = os.path.relpath(os.path.abspath(os.path.join(project, raw)), project).replace(os.sep, "/")
        disk = read(os.path.join(project, rel))
        a = by_path.get(rel)
        if disk is None:
            errors.append("%s: not found" % rel)
        elif a is None or "template_sha" not in a and a["op"] != "accepted":
            errors.append("%s: not a template conflict (%s) - nothing to accept"
                          % (rel, a["op"] if a else "not installed by teamwright"))
        else:
            tsha = a.get("template_sha") or accepted.get(rel, {}).get("template")
            accepted[rel] = {"disk": sha(disk), "template": tsha}
            done.append(rel)
    if done and not dry:
        write_manifest(project, _manifest(project), accepted)
    return done, errors


# ---------------------------------------------------------------- enforce
def enforce(project, dry):
    p = os.path.join(project, CONFIG)
    text = read(p)
    if text is None:
        raise SystemExit("tw-install: %s not found - run apply first" % CONFIG)
    try:
        cfg = parse_yaml(text)
    except ValueError as e:
        raise SystemExit("tw-install: cannot parse %s: %s" % (CONFIG, e))
    if isinstance(cfg, dict) and cfg.get("mode") == "enforce":
        return False
    new = _config.set_mode(text, "enforce")
    if not dry:
        write(project, CONFIG, new)
    return True


# ---------------------------------------------------------------- scan
def scan_files(project):
    if is_git(project):
        out = git(project, "ls-files", "-co", "--exclude-standard", "-z")[1]
        files = [f for f in out.split("\0") if f]
    else:
        files = [os.path.relpath(p, project) for p in _walk(project)]
    return sorted(set(files))


def scan(project, kit):
    chunks = []
    n = 0
    for rel in scan_files(project):
        p = os.path.join(project, rel)
        try:
            if not os.path.isfile(p) or os.path.getsize(p) > 2 * 1024 * 1024:
                continue
            raw = open(p, "rb").read()
        except OSError:
            continue
        if b"\0" in raw:
            continue
        text = raw.decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", "\n")
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        if not lines:
            continue
        n += 1
        # One single-line hunk per line: exact line numbers whatever the content, and a
        # line that starts with "++ " is hunk body, never mistaken for a file header.
        chunks.append("+++ b/%s\n" % rel)
        chunks.extend("@@ -0,0 +%d,1 @@\n+%s\n" % (i, x) for i, x in enumerate(lines, 1))
    hook = os.path.join(kit, "template", "scripts", "hooks", "pre-commit")
    r = subprocess.run(["bash", hook, "--scan-stdin"], input="".join(chunks), capture_output=True, text=True)
    out = [{"rule": a, "path": b, "line": int(c), "class": "secret-like", "blocks": True}
           for a, b, c in re.findall(r"possible secret \[([^\]]+)\] at (.+):(\d+)$", r.stderr, re.M)]
    out += [{"rule": a, "path": b, "line": int(c), "class": d, "blocks": False}
            for a, b, c, d in re.findall(r"note - \[([^\]]+)\] at (.+):(\d+) looks like (\S+) \(not blocking\)$",
                                         r.stderr, re.M)]
    out.sort(key=lambda f: (not f["blocks"], f["path"], f["line"]))
    return n, out, r.returncode


SCAN_CLASSES = ("secret-like", "config-placeholder", "test-fixture", "docs-example")


def scan_summary(findings):
    return {c: sum(1 for f in findings if f["class"] == c) for c in SCAN_CLASSES}


# ---------------------------------------------------------------- check-commands
def _tree_state(project):
    """{path: (status, sha of content)} for every entry `git status` reports."""
    out = {}
    rc, txt = git(project, "status", "--porcelain", "-z", "--untracked-files=all")
    if rc != 0:
        return None
    for e in txt.split("\0"):
        if len(e) < 4:
            continue
        st, path = e[:2], e[3:]
        if path.startswith((".teamwright/logs/", ".teamwright/cache/")):
            continue                          # our own logs and runner caches
        try:
            with open(os.path.join(project, path), "rb") as fh:
                h = hashlib.sha256(fh.read()).hexdigest()
        except OSError:
            h = None
        out[path] = (st, h)
    return out


def _tree_diff(before, after):
    changed = sorted(p for p in set(before) | set(after) if before.get(p) != after.get(p))
    tracked = [p for p in changed if (after.get(p) or before.get(p))[0] != "??"]
    untracked = [p for p in changed if p not in tracked]
    return tracked, untracked


# Environment errors: the command could not exercise the code because something it
# needs is absent (a database or service not listening, a missing binary, no Docker
# daemon, no device for a UI run). Such a run says nothing about the code, so it is
# `not-runnable` with the matching line as the reason, not `fail`. Checked only when the
# command exited non-zero; patterns are deliberately specific (an assertion that merely
# mentions "connection" does not match). Order: first match wins.
ENV_ERRORS = (
    ("service not reachable", re.compile(
        r"ECONNREFUSED|connection refused|could not connect to server|"
        r"Can't reach database server|\bP1001\b|getaddrinfo (?:ENOTFOUND|EAI_AGAIN)|"
        r"Name or service not known|Temporary failure in name resolution", re.I)),
    ("package not installed", re.compile(
        r"npx canceled due to missing packages", re.I)),
    ("docker unavailable", re.compile(
        r"Cannot connect to the Docker daemon|docker: (?:command )?not found|"
        r"permission denied while trying to connect to the Docker daemon", re.I)),
    ("missing binary", re.compile(
        r"\b(?:sh|bash|zsh|dash|env)(?:: line \d+|: \d+)?: [\w./-]+: (?:command )?not found|"
        r"executable file not found in \$PATH|spawn \S+ ENOENT")),
    ("no device", re.compile(
        r"No (?:connected )?devices? (?:found|connected|attached|available)|no devices/emulators found|"
        r"error: device (?:'[^']*' )?not found|No supported devices (?:found|connected)|"
        r"Unable to locate a development device|No booted (?:simulator|device)", re.I)),
)


def env_error(output):
    """(kind, line) of the first environment-error pattern in the output, or None."""
    for kind, rx in ENV_ERRORS:
        m = rx.search(output or "")
        if m:
            start = output.rfind("\n", 0, m.start()) + 1
            end = output.find("\n", m.end())
            return kind, output[start:end if end >= 0 else None].strip()[:200]
    return None


def _run_one(project, tw_run, env, area, key, cmd, timeout, logdir, runner="host"):
    log = os.path.join(logdir, "%s.%s.log" % (area, key.replace("_command", "")))
    res = {"area": area, "key": key, "command": cmd, "runner": runner,
           "log": os.path.relpath(log, project)}
    import time
    t0 = time.time()
    # own process group, so a timeout kills the whole tree (a test runner's children too)
    p = subprocess.Popen(["bash", tw_run, area, "--", cmd], cwd=project, env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         errors="replace", stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        output, _ = p.communicate(timeout=timeout)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        import signal
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        output, _ = p.communicate()
        rc = None
    try:
        with open(log, "w", encoding="utf-8") as fh:
            fh.write(output)
    except OSError:
        pass
    tail = [l for l in output.splitlines() if l.strip()][-1:] or [""]
    res["duration_s"] = round(time.time() - t0, 1)
    res["exit"] = rc
    if rc is None:
        res.update(status="fail", reason="timeout after %ds" % timeout)
    elif rc == 0:
        res.update(status="pass")
    elif rc in (125, 126, 127) or (rc == 2 and re.search(r"^tw-run: ", output, re.M)):
        res.update(status="not-runnable", reason=tail[0][:200])
    elif env_error(output):
        kind, line = env_error(output)
        res.update(status="not-runnable", environment=kind,
                   reason="environment (%s): %s" % (kind, line))
    else:
        res.update(status="fail", reason=tail[0][:200])
    return res


def _in_workdir(path, workdir):
    wd = (workdir or "").strip().strip("/")
    return not wd or wd == "." or path == wd or path.startswith(wd + "/")


def check_commands(project, kit, cfg, cfg_src, timeout, only_area=None, dry=False):
    """Run generate commands first, then every check command once via tw-run."""
    tw_run = os.path.join(project, TW_RUN)
    if not os.path.isfile(tw_run):
        tw_run = os.path.join(kit, "template", TW_RUN)
    env = dict(os.environ, TEAMWRIGHT_ROOT=project, TEAMWRIGHT_CONFIG=os.path.abspath(cfg_src))
    logdir = os.path.join(project, ".teamwright", "logs", "check-commands")
    areas = [a for a in cfg.get("areas") or [] if not only_area or a.get("name") == only_area]
    workdirs = {a["name"]: str(a.get("workdir") or "") for a in areas}
    runners = {a["name"]: str(a.get("runner") or "host") for a in areas}
    planned = [(a["name"], "generate_command", a["generate_command"]) for a in areas
               if str(a.get("generate_command") or "").strip()]
    gen_count = len(planned)
    planned += [(a["name"], k, a[k]) for a in areas for k in CHECK_KEYS if str(a.get(k) or "").strip()]
    if dry:
        return [{"area": n, "key": k, "command": c, "status": "planned"} for n, k, c in planned], []
    os.makedirs(logdir, exist_ok=True)
    results, notes = [], []
    state = None
    for i, (name, key, cmd) in enumerate(planned):
        if i == gen_count:
            state = _tree_state(project)     # baseline after code generation
        res = _run_one(project, tw_run, env, name, key, cmd, timeout, logdir, runners.get(name, "host"))
        if state is not None:
            now_state = _tree_state(project) or {}
            tracked, untracked = _tree_diff(state, now_state)
            # Only the area's own tree is attributed to the command: a file outside it
            # changed while the command ran was most likely edited by someone else
            # (an agent or a person working in parallel) - a note, never a failure.
            outside = [p_ for p_ in tracked if not _in_workdir(p_, workdirs.get(name))]
            tracked = [p_ for p_ in tracked if p_ not in outside]
            if outside:
                res["changed_outside_workdir"] = outside
                notes.append("%s %s: tracked files outside workdir '%s' changed during the run "
                             "(another process? not counted as the command's change): %s"
                             % (name, key, workdirs.get(name) or ".", ", ".join(outside[:5])))
            if tracked:
                res["modifies"] = tracked
                res["status"] = "fail" if res["status"] == "pass" else res["status"]
                res["reason"] = "gate modifies tracked files: %s" % ", ".join(tracked[:5]) + \
                                (" (+%d more)" % (len(tracked) - 5) if len(tracked) > 5 else "")
            if untracked:
                res["creates_untracked"] = untracked
                notes.append("%s %s creates untracked files (gitignore them?): %s"
                             % (name, key, ", ".join(untracked[:5])))
            state = now_state
        results.append(res)
    ui = str((cfg.get("tools") or {}).get("ui_verify") or "none")
    deferred = str(cfg.get("ui_verify_deferred") or "").strip()
    if deferred and not any(str(a.get("e2e_ui_command") or "").strip()
                            for a in cfg.get("areas") or []):
        notes.append("UI verification deferred by the owner (%s): tools.ui_verify is %s, no "
                     "e2e_ui_command yet" % (deferred, ui))
    elif ui != "none" and not only_area and not any(str(a.get("e2e_ui_command") or "").strip()
                                                    for a in cfg.get("areas") or []):
        # a UI runner that has no command cannot verify anything: not a silent skip
        results.append({"area": "*", "key": "e2e_ui_command", "command": "", "status": "not-runnable",
                        "runner": "-", "reason": "tools.ui_verify is %s but no area has an "
                        "e2e_ui_command: UI verification cannot run" % ui, "log": "-"})
    if not planned:
        notes.append("no commands configured")
    return results, notes


# ---------------------------------------------------------------- CLI
def main(argv=None):
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--project", default=argparse.SUPPRESS, help="target project root (default: cwd)")
    common.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS, help="write nothing")
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="machine-readable output")
    common.add_argument("--providers", default=argparse.SUPPRESS, help="adapter dir (default: <kit>/providers)")
    common.add_argument("--kit", default=argparse.SUPPRESS, help="teamwright checkout to install from (default: this one)")
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], parents=[common])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("inventory", "enforce", "scan"):
        sub.add_parser(name, parents=[common])
    for name in ("plan", "apply", "check-commands"):
        sp = sub.add_parser(name, parents=[common])
        sp.add_argument("--config", help="config file (default: <project>/%s)" % CONFIG)
        if name == "apply":
            sp.add_argument("--accept", action="append", metavar="PATH",
                            help="record a hand-merged file as resolved (repeatable); nothing else is applied")
        if name == "check-commands":
            sp.add_argument("--timeout", type=int, default=900, help="seconds per command (default 900)")
            sp.add_argument("--area", help="only this area")
    sub.add_parser("next", parents=[common], help="flow router decision (see scripts/tw-next.py)")
    args = ap.parse_args(argv)
    project = os.path.abspath(getattr(args, "project", None) or os.getcwd())
    dry = getattr(args, "dry_run", False)
    as_json = getattr(args, "json", False)
    kit = os.path.abspath(getattr(args, "kit", None) or KIT)
    providers_dir = os.path.abspath(getattr(args, "providers", None) or os.path.join(kit, "providers"))
    if not os.path.isdir(project):
        raise SystemExit("tw-install: no such project: %s" % project)

    if args.cmd == "inventory":
        sys.stdout.write(dump_json(inventory(project, providers_dir, kit)))
        return 0

    if args.cmd == "next":
        import importlib.util
        spec = importlib.util.spec_from_file_location("tw_next", os.path.join(kit, "scripts", "tw-next.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.main(["--project", project] + (["--json"] if as_json else []))

    if args.cmd == "enforce":
        changed = enforce(project, dry)
        msg = ("mode: enforce%s - gates now block" % (" (dry run)" if dry else "")) if changed \
            else "mode already enforce - no changes"
        print(json.dumps({"changed": changed, "dry_run": dry}) if as_json else msg)
        return 0

    if args.cmd == "scan":
        n, findings, rc = scan(project, kit)
        summary = scan_summary(findings)
        high = summary["secret-like"]
        if as_json:
            print(json.dumps({"files": n, "summary": summary, "blocking": high,
                              "findings": findings}, indent=2))
        else:
            for f in findings:
                print("%-18s [%s] %s:%d" % ("SECRET?" if f["blocks"] else f["class"], f["rule"],
                                           f["path"], f["line"]))
            if findings:
                print("summary: " + ", ".join("%s %d" % (c, summary[c]) for c in SCAN_CLASSES))
            print("scan: %d file(s), %s" % (n, "%d finding(s), %d blocking" % (len(findings), high)
                                             if findings else "clean"))
        return 1 if high or rc not in (0, 1) else 0

    cfg_src = os.path.abspath(args.config or os.path.join(project, CONFIG))
    cfg, cfg_text = load_config(cfg_src)

    if args.cmd == "check-commands":
        results, notes = check_commands(project, kit, cfg, cfg_src, args.timeout, args.area, dry)
        bad = [r for r in results if r["status"] not in ("pass", "planned")]
        if as_json:
            print(json.dumps({"results": results, "notes": notes, "ok": not bad}, indent=2))
        else:
            for r in results:
                print("%-13s %-10s %-17s %-7s %6s  %s%s" % (
                    r["status"], r["area"], r["key"], r.get("runner", "-"),
                    "%.1fs" % r["duration_s"] if "duration_s" in r else "-", r["command"],
                                                 ("\n              -> %s (log: %s)" % (r["reason"], r["log"]))
                                                 if r.get("reason") else ""))
            for n_ in notes:
                print("note: %s" % n_)
            print("check-commands: %d command(s), %d pass, %d fail, %d not runnable" % (
                len(results), sum(r["status"] == "pass" for r in results),
                sum(r["status"] == "fail" for r in results),
                sum(r["status"] == "not-runnable" for r in results)))
        return 1 if bad else 0

    proj_cfg = os.path.join(project, CONFIG)
    config_diff = ""
    if cfg_src != os.path.abspath(proj_cfg):
        cur = read(proj_cfg)
        if cur is not None and cur != cfg_text:
            config_diff = "".join(difflib.unified_diff(
                cur.splitlines(True), cfg_text.splitlines(True), CONFIG, CONFIG + " (new)"))
    actions, notes = plan(project, kit, cfg, cfg_text, cfg_src, providers_dir)

    if args.cmd == "apply" and args.accept:
        done, errors = accept(project, actions, args.accept, dry)
        if as_json:
            print(json.dumps({"accepted": done, "errors": errors, "dry_run": dry}, indent=2))
        else:
            for d in done:
                print("accepted        %s%s" % (d, " (dry run)" if dry else ""))
            for e in errors:
                print("error: %s" % e)
        return 1 if errors else 0

    removed_next = False
    if args.cmd == "apply" and not dry:
        apply(project, kit, actions)
        if cfg_src == os.path.abspath(os.path.join(project, CONFIG_NEXT)):
            os.remove(cfg_src)
            removed_next = True
    changes = [a for a in actions if a.get("change")]
    conflicts = [a for a in actions if a["op"] == "conflict"]
    unresolved = sorted({"%s %s" % (a["path"], u) for a in actions for u in a.get("unresolved", [])
                         if a["op"] in ("create", "update")})
    if as_json:
        print(json.dumps({"command": args.cmd, "dry_run": dry or args.cmd == "plan", "mode": cfg["mode"],
                          "changes": len(changes), "conflicts": [dict(path=a["path"], reason=a.get("reason", "exists and differs")) for a in conflicts],
                          "actions": [{k: v for k, v in a.items()
                                       if k not in ("content", "src", "keep_manifest", "template_sha")}
                                      for a in actions if a["op"] != "same"],
                          "unresolved": unresolved, "notes": notes,
                          "config_diff": config_diff, "removed_proposal": removed_next}, indent=2))
    else:
        if config_diff:
            sys.stdout.write(config_diff if config_diff.endswith("\n") else config_diff + "\n")
        for a in actions:
            if a["op"] == "same":
                continue
            extra = a.get("reason") or (", ".join(a["servers"]) if a.get("servers") else "") \
                or ("%s %s" % (a["kit"]["plugin"], a["kit"]["version"]) if a.get("kit") else "")
            if a.get("gitignore_add"):
                extra = ".gitignore += %d line(s)" % len(a["gitignore_add"])
            print("%-15s %s%s" % (a["op"], a["path"], ("  (%s)" % extra) if extra else ""))
        for u in unresolved:
            print("unresolved      %s" % u)
        for n in notes:
            print("note: %s" % n)
        print("mode: %s (%s)" % (cfg["mode"], "gates block" if cfg["mode"] == "enforce"
                                 else "gates warn, `enforce` makes them block"))
        if removed_next:
            print("removed %s (applied)" % CONFIG_NEXT)
        verb = "would change" if (dry or args.cmd == "plan") else "changed"
        print("%s: %d %s, %d conflict(s)" % (args.cmd, len(changes), verb, len(conflicts)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
