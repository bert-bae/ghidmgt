# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-10-18

First public release.

### Added

- `ghid add | rm | list | show | current | sync | keygen | login | env | exec | check |
  doctor`: per-directory GitHub identities covering the commit author, the SSH key, HTTPS
  credentials and the `gh` CLI login.
- `install.sh` with `--shell zsh|bash|both` (default: from `$SHELL`) and `--uninstall`.
  bash is wired through `~/.bashrc`; zsh through `~/.zshenv`.
- A sandboxed test suite (`make test`: Docker, no network, no host mounts) running under
  bash 5 and bash 3.2, with CI on Linux and macOS.

### Fixed (compared with the pre-release script)

- **Nested roots now resolve to the most specific identity in git.** Per-identity
  `includeIf` blocks were appended alphabetically, so with `personal → ~/projects` and
  `client → ~/projects/client`, the client's repos committed and pushed as `personal`.
  All `includeIf` lines now live in one block sorted by specificity.
- Values written to git config are quoted. A path containing `'`, or a name containing
  `"`, `#` or `;`, no longer produces config git rejects or silently truncates.
- `--ssh-key`, `--gh-config-dir` and `--alias` are validated, so a newline in an alias
  can't inject `ssh_config` directives.
- `rm --purge` logs the account out of `gh`, so its token leaves the system keyring
  rather than staying in the macOS Keychain or Secret Service. It refuses to delete
  `$HOME` or its parents, a dir holding a managed root, a dir shared with another
  identity, or a dir that doesn't look like a `gh` config dir.
- Runs on macOS: no GNU-only `stat -c` or `find -perm /mode`, and quoting that works on
  bash 3.2.
- A symlinked `~/.gitconfig` or `~/.ssh/config` (stow, chezmoi, home-manager) is edited
  through the link. Before, it was replaced by a world-writable regular file.
- `ghid exec` and `ghid env` pin the identity with `GHID_DISABLE=1`. Before, any zsh the
  command started re-resolved from its own directory and switched accounts.
- `--no-ssh-key` survives later `ghid add` updates; they no longer re-add the default key.
- `--alias` rejects `github.com` and aliases another identity already uses. Either would
  offer one identity's key on another's connections.

### Upgrading from a pre-release copy

Run `ghid sync` once. It replaces the old per-identity `# >>> ghid: <name> >>>` blocks
in `~/.gitconfig` with the single sorted `# >>> ghid: includeIf >>>` block.

[Unreleased]: https://github.com/bert-bae/ghid/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/bert-bae/ghid/releases/tag/v1.0.0
