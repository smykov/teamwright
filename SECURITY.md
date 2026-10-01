# Security policy

## Reporting a vulnerability

Report privately through GitHub: **Security → Report a vulnerability** on this repository ([private vulnerability reporting](https://github.com/smykov/teamwright/security/advisories/new)). Please do not open a public issue for a security problem.

Include what you ran, what you expected the hook or installer to do, and what it did — a hook input JSON or a short script that reproduces it is ideal. You will get an answer in the advisory thread; fixes are released as a new version with a `CHANGELOG.md` entry, and the advisory is published once a fixed version is out.

## Supported versions

Only the latest release gets fixes while teamwright is in 0.x.

## Scope

teamwright's hooks are **guardrails for a cooperative agent, not a sandbox**. They stop an agent from skipping process steps by accident or by shortcut; they do not contain a hostile process running with your user's rights.

In scope, for example:

- a gate that allows what its documentation says it blocks, with an ordinary Edit, Write or shell call;
- the installer overwriting a file it did not write, or writing outside the project;
- the secret scan missing a secret it claims to detect, or a hook leaking file contents, prompts or command arguments into the journal;
- a way for an agent to lower the gate mode or rewrite the ledgers and journals the gates rely on.

Out of scope — known and documented limits, listed in [README › Known limitations](README.md#known-limitations) and [docs/process/gates.md › Known limitations](docs/process/gates.md#known-limitations):

- `git commit --no-verify` and `git push --no-verify`;
- a script or program that writes files directly instead of through Edit/Write;
- shell forms the deny list does not match (`sh -c`, scripts);
- an agent definition named `code-reviewer` by whoever can edit `.claude/agents/`;
- ledgers and journals on another machine.

If you find a bypass that is not on these lists, report it: it either gets a fix or a documented entry.
