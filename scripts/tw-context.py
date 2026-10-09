#!/usr/bin/env python3
"""tw-context.py - is the configured context tool really used? (stdlib only, read-only)

`tools.context: serena` in the config says nothing about whether the tool indexes the
project's languages or whether the roles call it. A pilot ran days with Serena indexing
only TypeScript while the main code was Rust; agents read Rust with grep and whole
files, and nothing reported it. This script checks the two facts the config cannot:

  coverage  the languages of every area (file extensions under its source_dirs) against
            the languages the tool indexes (Serena: `languages:` in .serena/project.yml)
  usage     from .teamwright/logs/tools.jsonl: per role, calls of the tool's MCP server
            against built-in Read / Grep / Glob calls on files under the areas'
            source_dirs, over the last N sessions

  python3 tw-context.py [--project PATH] [--sessions N] [--json]

Whether the MCP server is connected in the current session is not visible from files;
/teamwright:status checks that itself.
"""
import argparse
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# file extension -> Serena language name
LANG = {".ts": "typescript", ".tsx": "typescript", ".js": "typescript", ".jsx": "typescript",
        ".mjs": "typescript", ".cjs": "typescript", ".py": "python", ".rs": "rust", ".go": "go",
        ".java": "java", ".kt": "kotlin", ".kts": "kotlin", ".dart": "dart", ".rb": "ruby",
        ".cs": "csharp", ".php": "php", ".swift": "swift", ".c": "cpp", ".h": "cpp", ".cc": "cpp",
        ".cpp": "cpp", ".hpp": "cpp", ".scala": "scala", ".ex": "elixir", ".exs": "elixir",
        ".lua": "lua", ".zig": "zig", ".vue": "vue", ".svelte": "svelte"}
BUILTIN = ("Read", "Grep", "Glob")
MIN_SHARE = 0.3        # below this share of code reading through the tool -> finding
MIN_CALLS = 20         # fewer code-reading calls than this -> too little data to judge


def _config():
    sys.path.insert(0, os.path.join(KIT, "template", "scripts", "hooks"))
    import _config
    return _config


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def area_dirs(a):
    out = []
    for k in ("source_dirs",):
        v = a.get(k) or []
        out += [str(x).split()[0].rstrip("/") for x in (v if isinstance(v, list) else [v]) if str(x).strip()]
    if not out and a.get("workdir"):
        out.append(str(a["workdir"]).rstrip("/"))
    return out


def area_languages(project, dirs):
    """{language: files} for tracked files under dirs; a language counts when it has at
    least 5 files, or 2 files and 10 % of the area."""
    if not dirs:
        return {}
    try:
        out = subprocess.run(["git", "-C", project, "ls-files", "--"] + dirs,
                             capture_output=True, text=True).stdout.splitlines()
    except OSError:
        return {}
    counts = {}
    for f in out:
        lang = LANG.get(os.path.splitext(f)[1].lower())
        if lang:
            counts[lang] = counts.get(lang, 0) + 1
    total = sum(counts.values())
    return {l: n for l, n in counts.items() if n >= 5 or (n >= 2 and n / total >= 0.1)}


def serena_languages(project):
    """Languages in .serena/project.yml (`languages:` / `language_servers:` list, or the
    older single `language:`); None when the file is missing."""
    text = _read(os.path.join(project, ".serena", "project.yml"))
    if not text:
        return None
    langs, inside = [], False
    for line in text.splitlines():
        m = re.match(r"^language:\s*(\S+)", line)
        if m:
            return [m.group(1).strip("'\"").lower()]
        if re.match(r"^(languages|language_servers):\s*$", line):
            inside = True
            continue
        m = re.match(r"^(?:languages|language_servers):\s*\[(.*)\]", line)
        if m:
            return [x.strip().strip("'\"").lower() for x in m.group(1).split(",") if x.strip()]
        if inside:
            m = re.match(r"^\s*-\s*(\S+)", line)
            if m:
                langs.append(m.group(1).strip("'\"").lower())
            elif line.strip() and not line.startswith((" ", "\t", "#")):
                inside = False
    return langs


def journal_dir(project):
    """The journal directory: $TEAMWRIGHT_LOG_DIR, else <project>/.teamwright/logs; from a
    git worktree without its own journal, the main checkout's (the hooks write to
    $CLAUDE_PROJECT_DIR, which is the main checkout when the session runs in a worktree)."""
    if os.environ.get("TEAMWRIGHT_LOG_DIR"):
        return os.environ["TEAMWRIGHT_LOG_DIR"]
    own = os.path.join(project, ".teamwright", "logs")
    if os.path.isdir(own):
        return own
    try:
        out = subprocess.run(["git", "-C", project, "worktree", "list", "--porcelain"],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return own
    first = next((l[len("worktree "):] for l in out.splitlines() if l.startswith("worktree ")), "")
    main = os.path.join(first, ".teamwright", "logs") if first else ""
    return main if main and os.path.isdir(main) else own


def usage(project, provider, dirs, sessions):
    path = os.path.join(journal_dir(project), "tools.jsonl")
    rows, order = [], []
    for line in _read(path).splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("event") != "pre":
            continue
        sid = r.get("session_id") or ""
        if sid and sid not in order:
            order.append(sid)
        rows.append(r)
    keep = set(order[-sessions:]) if sessions else set(order)
    root = os.path.realpath(project)

    def code_path(d):
        d = str(d or "")
        if os.path.isabs(d):
            d = os.path.realpath(d)
            if not d.startswith(root + os.sep):
                return False
            d = d[len(root) + 1:]
        return any(d == x or d.startswith(x + "/") for x in dirs)

    by = {}
    for r in rows:
        if (r.get("session_id") or "") not in keep:
            continue
        role = r.get("agent_type") or "main"
        tool = r.get("tool") or ""
        b = by.setdefault(role, {"tool": 0, "builtin": 0})
        if tool.startswith("mcp__") and provider in tool.lower():
            b["tool"] += 1
        elif tool in BUILTIN and code_path(r.get("detail")):
            b["builtin"] += 1
    out = {}
    for role, b in sorted(by.items()):
        n = b["tool"] + b["builtin"]
        if n:
            out[role] = dict(b, share=round(b["tool"] / n, 2))
    total_t = sum(v["tool"] for v in out.values())
    total_b = sum(v["builtin"] for v in out.values())
    n = total_t + total_b
    return {"sessions": len(keep), "by_role": out, "tool": total_t, "builtin": total_b,
            "share": round(total_t / n, 2) if n else None, "journal": os.path.isfile(path)}


def check(project, sessions=20):
    c = _config()
    try:
        cfg = c.parse_yaml(_read(os.path.join(project, c.CONFIG))) or {}
    except ValueError:
        cfg = {}
    provider = str(((cfg.get("tools") or {}) if isinstance(cfg.get("tools"), dict) else {}).get("context") or "builtin")
    res = {"provider": provider, "areas": [], "findings": []}
    if provider in ("builtin", "none"):
        res["note"] = "no context tool configured: built-in search is the tool"
        return res
    indexed = serena_languages(project) if provider == "serena" else None
    res["indexed_languages"] = indexed
    if provider == "serena" and indexed is None:
        res["findings"].append("serena is configured but .serena/project.yml is missing: the project "
                               "is not indexed (run the adapter's install step)")
    all_dirs = []
    for a in cfg.get("areas") or []:
        if not isinstance(a, dict) or not a.get("name"):
            continue
        dirs = area_dirs(a)
        all_dirs += dirs
        langs = area_languages(project, dirs)
        missing = sorted(l for l in langs if indexed is not None and l not in indexed)
        res["areas"].append({"area": a["name"], "runner": a.get("runner") or "host",
                             "languages": langs, "not_indexed": missing})
        if missing:
            hint = (" - the area runs in docker, so the language server is likely missing on "
                    "the host" if (a.get("runner") == "docker") else "")
            res["findings"].append("area %s: %s not indexed by %s (%s)%s" % (
                a["name"], ", ".join(missing), provider, ", ".join("%s %d files" % (l, langs[l]) for l in missing), hint))
    if provider == "serena" and indexed is not None and "markdown" not in indexed and any(
            os.path.isdir(os.path.join(project, d)) for d in ("specs", "openspec", "docs")):
        res["notes"] = ["documents are not indexed: add `markdown` to languages in .serena/project.yml "
                        "(Marksman) so roles read spec sections, not whole files"]
    u = usage(project, provider, all_dirs, sessions)
    res["usage"] = u
    n = u["tool"] + u["builtin"]
    if not u["journal"]:
        res["findings"].append("no .teamwright/logs/tools.jsonl: usage cannot be measured (journal hook off?)")
    elif n >= MIN_CALLS and u["share"] is not None and u["share"] < MIN_SHARE:
        low = [r for r, v in u["by_role"].items() if v["tool"] + v["builtin"] >= 5 and v["share"] < MIN_SHARE]
        res["findings"].append("only %d%% of code reading went through %s (%d of %d calls, last %d sessions)%s" % (
            round(100 * u["share"]), provider, u["tool"], n, u["sessions"],
            "; roles reading around it: " + ", ".join(low) if low else ""))
    return res


def human(r):
    lines = ["context tool: %s" % r["provider"]]
    if r.get("note"):
        return lines[0] + " - " + r["note"]
    if r.get("indexed_languages") is not None:
        lines.append("  indexed: " + (", ".join(r["indexed_languages"]) or "none"))
    for a in r["areas"]:
        lines.append("  area %s: %s%s" % (a["area"], ", ".join("%s %d" % kv for kv in sorted(a["languages"].items())) or "-",
                                          " | NOT indexed: " + ", ".join(a["not_indexed"]) if a["not_indexed"] else ""))
    u = r.get("usage") or {}
    if u.get("journal"):
        lines.append("  usage: %s through the tool, %s built-in on code (%s), last %d sessions" % (
            u["tool"], u["builtin"], "n/a" if u["share"] is None else "%d%%" % round(100 * u["share"]), u["sessions"]))
    for f in r["findings"]:
        lines.append("  finding: " + f)
    for n in r.get("notes") or []:
        lines.append("  note: " + n)
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project", default=os.getcwd())
    ap.add_argument("--sessions", type=int, default=20, help="last N sessions of the journal (0 = all)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    r = check(os.path.abspath(args.project), args.sessions)
    print(json.dumps(r, indent=2, ensure_ascii=False) if args.json else human(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
