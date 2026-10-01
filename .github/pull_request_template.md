## What and why

<!-- One change per pull request. Link the issue if there is one. -->

## Checks

- [ ] `make test`
- [ ] `make lint`
- [ ] `make scan`
- [ ] A change to a hook, the installer or the router has a test that fails without it

## Release

- [ ] `CHANGELOG.md` entry
- [ ] Shipped files changed (`skills/`, `scripts/`, `template/`, `providers/`, `docs/process/`): `version` bumped in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (`make release-check`)
- [ ] No hosts, IP addresses, absolute paths, real project or person names, or secrets
