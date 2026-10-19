# Contributing to ghid

Thanks for helping. ghid is small on purpose: one bash script that people trust with
the files holding their credentials. Contributions that keep it that way are the
easiest to merge.

## Ground rules

- **One file, no new runtime dependencies.** `ghid` needs only bash, git, OpenSSH and
  (optionally) `gh`. No Python, no `jq`, no package manager.
- **bash 3.2 compatible.** macOS still ships bash 3.2 as `/bin/bash`. That rules out
  associative arrays, `mapfile`/`readarray`, `${var,,}`, negative substring lengths, and
  `${var//pattern/replacement}` with quotes or backslashes in the replacement (bash
  before 4.3 doesn't quote-remove it).
- **GNU and BSD userland.** No `sed -i`, `readlink -f`, `stat -c` (use `file_mode`),
  `find -perm /mode`, `grep -P`, or GNU-only regex such as `\|` and `\S`.
- **Only edit between markers.** Anything ghid writes into a file it doesn't own goes
  through `replace_block` / `remove_block`.
- **Quote everything that becomes code or config.** Values go through `shquote` for
  generated shell code and `gitquote` for git config. New user-supplied paths get the
  same validation as roots (`valid_root`).
- **Keep the zsh resolver fork-free.** `shell.zsh` runs on every zsh start and every
  `cd`; no `$(...)` or external commands in it.
- **Explain why, not what.** Comments in this codebase record the failure a line
  prevents. Keep that up for new code.

## Development setup

You need git and Docker (or Podman with `DOCKER=podman`).

```bash
git clone https://github.com/bert-bae/ghid.git
cd ghid
make test     # the full suite under bash 5 (Debian) and bash 3.2 (Alpine)
make lint     # shellcheck --severity=warning
```

### Never test against your real home directory

ghid rewrites `~/.gitconfig`, `~/.ssh/config`, your shell rc files and `gh` config
directories. Running it from a working copy against your real home can break the setup
you use every day. So:

- `tests/run.sh` refuses to start unless it is inside a container (or a GitHub Actions
  runner) **and** `GHID_TEST_SANDBOX=1` is set. Don't remove that guard.
- `make test` runs the suite in a container with the source **copied in** (no bind
  mounts), as an unprivileged user, with `--network none` and all capabilities dropped.
- Inside the sandbox, every test still gets its own throwaway `$HOME`. The real `gh` and
  `ssh` are replaced with stubs that fail loudly, so a test can never reach GitHub.

To try a change by hand, open a shell in the sandbox image:

```bash
make image-bash5
docker run --rm -it --network none ghid-test:bash5 bash
# inside: ./install.sh --shell bash && exec bash
```

### Writing a test

Add a function named `test_<what_it_proves>` to `tests/run.sh`; it is picked up
automatically and runs in a fresh `$HOME` with `set -e`. Helpers:

| Helper | |
|---|---|
| `ghid ...` | run the CLI under test |
| `eq <got> <want>` | exact match |
| `has <text> <needle>` / `lacks <text> <needle>` | substring checks |
| `must_fail <cmd...>` | assert a command fails; prints its output |
| `exists <path>` / `absent <path>` / `same <a> <b>` | file checks |
| `field <name> <ID_VAR>` | read one field of an identity's registry file |
| `fake_key <path>` / `fake_gh_login <dir> <user...>` | placeholder key / `gh` login |
| `use_gh_stub` | a fake `gh` that logs calls to `$HOME/gh-calls.log` |

Run one test while iterating:

```bash
docker run --rm --network none -e GHID_TEST_FILTER=purge ghid-test:bash5
```

Every bug fix should come with a test that fails without it.

## Pull requests

1. For anything bigger than a small fix, open an issue first so we can agree on the
   approach.
2. Keep each PR to one change. Update `README.md` when behavior changes, and add a line
   under **Unreleased** in `CHANGELOG.md`.
3. Use [Conventional Commits](https://www.conventionalcommits.org/):
   `fix(cli): ...`, `feat(install): ...`, `docs: ...`, `test: ...`.
4. CI must pass: shellcheck, the Docker suite (bash 5 and 3.2), and the macOS job.

Be kind in issues and reviews. Assume good intent, and keep feedback about the code.

## Releasing

1. Bump `GHID_VERSION` in `ghid`.
2. Move the **Unreleased** notes in `CHANGELOG.md` under the new version and date.
3. Tag `vX.Y.Z` on `main` and create a GitHub release from the changelog entry.
