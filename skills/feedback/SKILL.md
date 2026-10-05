---
name: feedback
description: Send an improvement for teamwright itself — found by /teamwright:improve or by hand in this project — to the teamwright repository, the way open-source projects take it — an issue through the repository's issue forms for an observation or idea, a pull request from a fork for a concrete change to the kit. Strips project names, paths, hosts and code first, checks for duplicates, and sends nothing until the owner has read the exact text and said yes.
argument-hint: "[issue | pr] [topic]"
disable-model-invocation: true
allowed-tools: Bash(gh auth status) Bash(gh issue list *) Bash(gh pr list *) Bash(git status *) Bash(git diff *) Bash(git log *)
---

# /teamwright:feedback — from this project back to the kit

Repository: `smykov/teamwright` (the `homepage` in `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`). Arguments: `$ARGUMENTS`; without them, take the feedback drafts from the latest `docs/process-reviews/` report, or ask what to send.

**Everything sent is public.** The owner reads the exact text before anything leaves the machine, and says yes per item.

## 1. What and where

| What | Channel | Form |
|---|---|---|
| A gate blocks what it should allow, or the reverse; the installer, router or metrics misbehave | issue, form **Bug report** (`bug_report.yml`) | fields `area`, `version`, `environment`, `what`, `reproduce`, `output` |
| A missing capability, a costly rule, a role instruction that misleads, a setting that should exist | issue, form **Feature request** (`feature_request.yml`) | fields `kind`, `problem`, `proposal`, `alternatives` |
| A concrete change to the kit you already made and tested here (a role text, a hook, a template) | **pull request from a fork** | the change in kit paths, plus a regression test for a hook, installer or router change (the kit's rule) |
| A way around a gate, a leak into the journal | **not public**: security advisory (`.../security/advisories/new`) | as `SECURITY.md` says |

## 2. Prepare

1. **Anonymise.** No project, client or person names; no paths, hosts, IPs; no code, task titles or text from this project; no secrets. Keep numbers, categories, versions and generic examples ("a list of three string literals in a new file"). Write in English (the kit's language).
2. **Evidence.** The numbers from `/teamwright:improve` or the scripts behind it (`tw-process.py`, `tw-context.py`, `teamwright-metrics`), with how they were counted; the teamwright version (`version` in the plugin manifest) and the relevant settings.
3. **Duplicates.** `gh issue list -R smykov/teamwright --state all --search "<keywords>"` and `gh pr list … --search`. A match → a comment with the new evidence on it instead of a new issue.
4. **For a PR, map the change back to the kit.** Installed files are rendered copies: `.teamwright/installed.json` lists them; the source is under `template/` (or `providers/`, `docs/process/`) in the kit, and placeholders (`{{GATE_COMMAND}}`, `{{REVIEW_BLOCKING}}` …) go back in place of this project's values. Text outside the `teamwright:tools` markers only.

## 3. Show, then send — only on "yes"

Show the complete title and body (and the diff for a PR). Then, on "yes":

- **Issue, `gh` logged in** (`gh auth status`): `gh issue create -R smykov/teamwright --title "<title>" --label "<bug|enhancement>,from-project" --body-file <file in the system temp directory>`, the body laid out under the form's field labels (`### The problem` …). A missing label is not a reason to fail: create the issue without it.
- **Issue, no `gh`**: give the owner a link that opens the form pre-filled — `https://github.com/smykov/teamwright/issues/new?template=feature_request.yml&title=<urlencoded>&problem=<urlencoded>&proposal=<urlencoded>` (field ids as in the table; `template=bug_report.yml` and its ids for a bug). The owner submits it in the browser.
- **Pull request**: in a separate clone of the kit in the system temp directory (never in this project): `gh repo fork smykov/teamwright --clone`, branch `feedback/<topic>`, apply the mapped change, run `make check` there, commit, push to the fork, `gh pr create -R smykov/teamwright --title … --body …` with: the problem, the numbers, the change, the test that fails without it.

## 4. Record

A row in `docs/decisions.md` (or the process-review report): what was sent, the issue or PR link, the date. When the kit is updated later, `/teamwright:status` and the CHANGELOG tell whether it was taken.

Report: `Feedback: <issue|PR> <link> — <title>` per item, or the pre-filled link when it is the owner's to submit.
