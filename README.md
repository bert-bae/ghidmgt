# ghidmgt

**One machine, several GitHub accounts, no cross-account commits.**

[![CI](https://github.com/bert-bae/ghidmgt/actions/workflows/ci.yml/badge.svg)](https://github.com/bert-bae/ghidmgt/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20WSL2-lightgrey)

`ghidmgt` ties a GitHub identity to a directory. Every repo under `~/work` acts as your work
account, every repo under `~/clients/acme` acts as that client's account, and everything
under `~/projects` stays personal. That covers the commit author, the SSH key used to
push, the HTTPS credentials, and the `gh` CLI login. You set each identity up once,
then `cd` and work.

```text
~/projects/        →  personal   you@example.com    ~/.ssh/id_ed25519        ~/.config/gh
~/work/            →  work       you@company.com    ~/.ssh/id_ed25519_work   ~/.config/gh-work
~/clients/acme/    →  acme       you@acme.example   ~/.ssh/id_ed25519_acme   ~/.config/gh-acme
```

It is a single bash script with no runtime dependencies beyond `git`, `ssh` and `gh`.
It edits your config files only between clearly marked blocks.

> Formerly **ghid**. Upgrading? Pull your clone and re-run `install.sh`. It migrates
> your existing setup ([details](CHANGELOG.md#upgrading-from-ghid-or-a-pre-release-copy)).

---

## Contents

- [The problem](#the-problem)
- [How ghidmgt solves it](#how-ghidmgt-solves-it)
- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Walkthroughs](#walkthroughs)
- [Command reference](#command-reference)
- [Verifying your setup](#verifying-your-setup)
- [Files ghidmgt manages](#files-ghidmgt-manages)
- [Configuration](#configuration)
- [Limits](#limits)
- [Uninstall](#uninstall)
- [FAQ](#faq)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

---

## The problem

Git and the GitHub CLI assume one person with one account. As soon as you add a second
account (a job, a client, an open-source alias), the defaults start working against you:

- **Commits go out under the wrong name.** `user.email` is global, so the commit you
  just pushed to your employer's repo carries your personal address, and it is in the
  history forever.
- **`git push` authenticates as the wrong account.** `ssh-agent` offers every key it
  holds, and GitHub logs you in as the owner of *the first key it accepts*. If your
  personal account also has access to the repo, the push succeeds as the wrong person.
  If it doesn't, you get `Permission denied` with no hint why.
- **`gh` acts as whoever logged in last.** `gh pr create`, `gh repo clone` and
  `gh api` use one active account per host, so switching contexts means remembering to
  run `gh auth switch`, every time, in every terminal.
- **HTTPS tokens leak between accounts.** A global `credential.helper store` keeps every
  account's token in one `~/.git-credentials`, and it answers for every repo.
- **One exported `GH_TOKEN` overrides all of it.** A token in `.zshrc` silently wins over
  every per-account setting.

The usual workarounds each fix one layer and miss the rest. SSH host aliases
(`git@github-work:org/repo`) mean rewriting every remote URL, and they don't touch your
commit email or `gh`. Per-repo `git config user.email` has to be remembered for every
clone. `direnv`-style hooks only run in an interactive shell, so your IDE, git hooks,
cron jobs and AI coding agents never see them.

## How ghidmgt solves it

You register each identity once: a name, one or more directory roots, and the email,
SSH key and `gh` config directory it should use. `ghidmgt` then generates the config that
makes every layer follow the directory:

| Layer | What ghidmgt sets up | Works without a shell hook? |
|---|---|---|
| Commit author | `includeIf "gitdir:<root>/"` → a per-identity `[user]` block | **yes** |
| SSH key for push/pull | per-identity `core.sshCommand = ssh -i <key> -o IdentitiesOnly=yes` | **yes** |
| HTTPS credentials | per-identity `credential.helper`, bound to that identity's `gh` login | **yes** |
| `gh` CLI login | `GH_CONFIG_DIR` exported on every `cd` (zsh and bash) | shell only |

Three of the four layers live in git's own config. They hold in VS Code, JetBrains IDEs,
git hooks, cron jobs, containers and agent tooling, none of which read your shell rc.

A few details are easy to get wrong and are why this tool exists:

- **`IdentitiesOnly=yes`.** Without it, `ssh` still offers every agent key before the one
  you named, and GitHub picks the first one it accepts.
- **The empty `helper =` line.** It clears credential helpers inherited from
  `~/.gitconfig` (such as `store`) before adding the identity's own, so a shared
  plaintext store can't answer for a client's repo.
- **Nested roots resolve to the most specific identity.** `~/projects` can be personal
  while `~/projects/client-x` belongs to a client. The git layer and the shell layer
  agree on which identity that is.
- **Symlinks resolve the way git resolves them**, so `gh` and `git` never disagree about
  who owns a directory reached through a link.

## Requirements

| | |
|---|---|
| OS | macOS, Linux, or Windows via WSL2 |
| Shell | zsh or bash (bash 3.2, the version macOS ships, is fine) |
| git | 2.13 or newer (for `includeIf "gitdir:"`) |
| OpenSSH | `ssh` and `ssh-keygen` |
| [GitHub CLI](https://cli.github.com) | `gh`, for `ghidmgt login` and HTTPS credentials. Optional if you only use SSH remotes and never use `gh`. |

Native Windows shells (PowerShell, cmd, Git Bash outside WSL) are not supported.

## Install

```bash
git clone https://github.com/bert-bae/ghidmgt.git ~/.local/share/ghidmgt
~/.local/share/ghidmgt/install.sh
```

The installer:

1. symlinks `ghidmgt` into `~/.local/bin`, so `git pull` in the clone updates the CLI;
2. adds one marked block to your shell rc that sources the generated resolver:
   `~/.zshenv` for zsh, `~/.bashrc` for bash;
3. backs up every file it touches with a timestamp first;
4. if no identities exist yet, lists the `gh` logins already on the machine, with a
   ready-to-edit `ghidmgt add` command for each.

It picks the shell from `$SHELL`. To choose, pass `--shell zsh`, `--shell bash` or
`--shell both`. If `~/.local/bin` is not on your `PATH`, the installer tells you what to
add.

> **Why `.zshenv` and not `.zshrc`?** `.zshrc` is only read by *interactive* shells.
> `.zshenv` is read by every zsh: scripts, `zsh -c`, git hooks, editor terminals.
> They all get the same `gh` identity as your prompt.

To update later:

```bash
git -C ~/.local/share/ghidmgt pull
```

## Quick start

This example sets up a personal account and a work account. Open a new shell after
installing, then:

**1. Register the identities.**

```bash
ghidmgt add personal --root ~/projects --email you@example.com \
  --gh-config-dir ~/.config/gh --ssh-key ~/.ssh/id_ed25519

ghidmgt add work --root ~/work --email you@company.com
```

Anything you leave out gets a sensible default (see [`ghidmgt add`](#ghidmgt-add)), so the
second line also gets `~/.ssh/id_ed25519_work` and `~/.config/gh-work`.

**2. Create an SSH key for each identity that doesn't have one yet.**

```bash
ghidmgt keygen work
```

This prints the public key. Add it to the **work** account at
<https://github.com/settings/ssh/new> while logged in as that account.

**3. Log `gh` in, once per identity.**

```bash
ghidmgt login work
```

This runs `gh auth login` in the identity's own config directory and records which
GitHub user you logged in as. If `gh` offers to upload an SSH key, pick that identity's
key (`~/.ssh/id_ed25519_work.pub`) or skip, since you added it in step 2.

**4. Verify.** `ghidmgt check` doesn't trust the config files. It asks GitHub which account
the key and the token actually belong to:

```bash
ghidmgt check work
```

**5. Work normally.**

```bash
cd ~/work/api
git commit -m "..."   # authored as you@company.com
git push              # authenticated with ~/.ssh/id_ed25519_work
gh pr create          # opened by your work account
```

## Walkthroughs

### Personal and work on one laptop

The quick start above covers this case. Keep work repos under `~/work` and personal
repos under `~/projects`. Anything outside both roots falls back to your global git
config, so `ghidmgt doctor` is worth running once to make sure that fallback is harmless.

### A freelancer or agency with several clients

Give every client its own root and identity. Credentials never overlap, and
offboarding is one command.

```bash
# Onboard
ghidmgt add acme --root ~/clients/acme --email you@acme.example
ghidmgt keygen acme       # add the printed key to the acme GitHub account
ghidmgt login acme
ghidmgt check acme

# Offboard
ghidmgt rm acme --purge
```

`--purge` logs the client's account out of `gh` (which also removes the token from
your system keyring) and deletes its `gh` config directory. Before deleting anything, it
refuses if the directory is your home or a parent of it, contains a managed root, is
shared with another identity, or doesn't look like a `gh` config directory. The SSH key
is left on disk and named in the output. Delete it yourself and remove it from the
GitHub account. Tokens are removed from this machine but not revoked; revoke them at
<https://github.com/settings/applications>.

### Adopting ghidmgt on a machine that already has gh logins

Run the installer. If no identities are registered yet, it looks at `~/.config/gh` and
`~/.config/gh-*` and prints a suggestion for each login it finds:

```text
  gh account 'octo-work' in ~/.config/gh-work:
    ghidmgt add work --root ~/CHANGE_ME \
      --gh-user octo-work --gh-config-dir ~/.config/gh-work \
      --ssh-key ~/.ssh/id_ed25519_work --email you@example.com
```

Point `--gh-config-dir` at the existing directory and `--ssh-key` at the existing key,
and nothing needs to be logged in again. Then run `ghidmgt doctor` to find leftovers that
defeat per-directory auth, such as an exported `GH_TOKEN` or a stray `IdentityFile` for
`github.com` in `~/.ssh/config`.

### Cloning a repo into a root

Once a repo exists under a root, every git command inside it uses the right identity.
The very first `git clone` can run before git applies the conditional include, so clone
in one of these two ways to be safe:

```bash
# Run the clone as the identity
ghidmgt exec work git clone git@github.com:acme-corp/api.git ~/work/api
ghidmgt exec work gh repo clone acme-corp/api ~/work/api

# Or use the identity's SSH host alias, which works from anywhere
git clone git@github.com-work:acme-corp/api.git ~/work/api
```

### Nested roots

Roots can nest, and the most specific one wins:

```bash
ghidmgt add personal --root ~/projects --email you@example.com
ghidmgt add client-x --root ~/projects/client-x --email you@client-x.example
```

Repos in `~/projects/client-x/...` act as `client-x`; everything else in `~/projects`
acts as `personal`. One identity can also own several roots: repeat `--root`.

### Running one command as another identity

`ghidmgt exec` runs one command as an identity regardless of the current directory. Use it
for scripts in `/opt`, cron jobs, or a repo you haven't moved under a root yet:

```bash
ghidmgt exec work gh pr list --repo acme-corp/api
ghidmgt exec work git -C /opt/deploy pull
```

It sets `GH_CONFIG_DIR`, the git author and committer, and `GIT_SSH_COMMAND` for that
identity. It also strips variables that would outrank them: `GH_TOKEN`,
`GITHUB_TOKEN`, `GIT_CONFIG_GLOBAL`, a stale `GIT_SSH_COMMAND`, and others. It also sets
`GHIDMGT_DISABLE=1`, so any shell the command starts keeps the identity instead of
re-resolving from its own directory.

To switch a whole shell session instead:

```bash
eval "$(ghidmgt env work)"
```

This pins the session the same way, until you `unset GHIDMGT_DISABLE` or open a new shell.

### Machine setup scripts and dotfiles

`ghidmgt add` is declarative. Re-running it with the same flags changes nothing, and
re-running it with *fewer* flags keeps the fields you left out. `ghidmgt sync` regenerates
every derived file from the registry. That makes this block safe in a provisioning
script that runs on every machine, as often as you like:

```bash
git clone https://github.com/bert-bae/ghidmgt.git ~/.local/share/ghidmgt 2>/dev/null \
  || git -C ~/.local/share/ghidmgt pull --ff-only
~/.local/share/ghidmgt/install.sh --shell zsh

ghidmgt add personal --root ~/projects --email you@example.com \
  --gh-config-dir ~/.config/gh --ssh-key ~/.ssh/id_ed25519
ghidmgt add work --root ~/work --email you@company.com --gh-user octo-work

ghidmgt doctor || true   # reports what still needs `ghidmgt keygen` / `ghidmgt login`
```

`keygen` and `login` stay manual on purpose. One needs you to paste a key into GitHub,
the other is an OAuth flow.

### Editors, git hooks, cron and AI agents

Nothing extra is needed. Commit identity, SSH key and HTTPS credentials come from git's
own config, which every git process reads. For zsh, the `gh` layer also reaches
non-interactive shells through `~/.zshenv`. For bash, which has no equivalent file, use
`ghidmgt exec` in scripts that call `gh`.

## Command reference

```text
ghidmgt add <name> --root <dir> [...]   register or update an identity, then sync
ghidmgt rm <name> [--purge] [-y]        unwire an identity (--purge also logs gh out and deletes its config dir)
ghidmgt list                            identities, roots, and whether key and gh login exist
ghidmgt show <name>                     print an identity's registry file
ghidmgt current [<dir>]                 the identity that owns a directory (alias: which)
ghidmgt sync                            regenerate every derived file from the registry
ghidmgt keygen <name>                   create the identity's SSH key and print the public key
ghidmgt login <name>                    gh auth login into the identity's own config dir
ghidmgt env [<name>]                    print exports, for eval "$(ghidmgt env work)"
ghidmgt exec <name> <cmd> [args...]     run one command as that identity
ghidmgt check [<name>] [--path <dir>] [--offline]
                                        verify one identity end to end
ghidmgt doctor                          check the whole machine for cross-account leaks
ghidmgt version | help
```

### `ghidmgt add`

```text
ghidmgt add <name> --root <dir> [--root <dir>...]
     [--email <addr>] [--git-name <name>] [--gh-user <login>]
     [--ssh-key <path>] [--gh-config-dir <path>] [--alias <host>] [--no-ssh-key]
```

| Option | Default |
|---|---|
| `--root` | required for a new identity; repeat for several |
| `--email` | none; without it, repos fall back to your global `user.email` |
| `--git-name` | your global `user.name` |
| `--gh-user` | filled in by `ghidmgt login` |
| `--gh-config-dir` | `~/.config/gh-<name>` |
| `--ssh-key` | `~/.ssh/id_ed25519_<name>` |
| `--alias` | `github.com-<name>`: an SSH host alias, unique per identity, and never `github.com` itself |
| `--no-ssh-key` | don't manage an SSH key; for HTTPS-only identities |

Identity names are lowercase letters, digits, `.`, `_` and `-`. Roots, key paths and
`gh` config dirs must be absolute and free of whitespace and shell metacharacters.
They end up in generated git, ssh and shell config, so `ghidmgt add` rejects anything that
would need escaping.

## Verifying your setup

### `ghidmgt check`: one identity, end to end

```text
$ ghidmgt check
~/work/api resolves to identity work
  ✓ shell: GHIDMGT_IDENTITY=work
  ✓ gh:    config dir ~/.config/gh-work
  ✓ ssh:   key ~/.ssh/id_ed25519_work
  ✓ git:   includeIf wired in ~/.gitconfig
  ✓ git:   commits here are authored as you@company.com
  ✓ git:   pushes here use ~/.ssh/id_ed25519_work
  ✓ git:   HTTPS credentials come from ~/.config/gh-work
  ✓ live:  gh authenticates as octo-work
  ✓ live:  ssh authenticates as octo-work

identity 'work' is wired correctly
```

The two `live` lines ask GitHub directly (`gh api user` and `ssh -T git@github.com`).
They catch the cases config can't, such as a key that was added to the wrong account.
Use `--offline` to skip them.

### `ghidmgt doctor`: the whole machine

`doctor` looks for things that defeat per-directory identities however well they are
configured:

- an exported `GH_TOKEN` / `GITHUB_TOKEN`, or a GitHub token hardcoded in a shell rc file
- `GIT_CONFIG_GLOBAL`, which replaces `~/.gitconfig` and with it every `includeIf`
- a global `credential.helper` with a shared `~/.git-credentials`
- an `IdentityFile` outside ghidmgt's blocks that applies to `github.com`
- an older `includeIf` outside ghidmgt's block that claims a managed root
- a shell rc that doesn't source the resolver, or only for the shell you don't use
- identities with no key, no `gh` login, no email, or a root that doesn't exist

## Files ghidmgt manages

| Path | |
|---|---|
| `~/.config/ghidmgt/identities/<name>.conf` | the registry, and the source of truth. Edit by hand if you like, then run `ghidmgt sync`. |
| `~/.config/ghidmgt/git/<name>.gitconfig` | generated per-identity git config |
| `~/.config/ghidmgt/shell.zsh`, `shell.sh` | generated resolvers for zsh and bash/sh |
| `~/.gitconfig` | one `# >>> ghidmgt: includeIf >>>` block |
| `~/.ssh/config` | one `# >>> ghidmgt: <name> >>>` block per identity (the host alias) |
| `~/.zshenv` / `~/.bashrc` | one `# >>> ghidmgt shell integration >>>` block |

Everything outside those markers is left exactly as you wrote it. If a marker pair is
ever broken (a half-deleted block, a merge conflict), `ghidmgt` refuses to edit the file
until you fix it, rather than guessing where the block ends. Registry files are created
with mode `600`, and ghidmgt refuses to source one that other users can write to.

## Configuration

| Variable | Effect |
|---|---|
| `GHIDMGT_HOME` | where the registry and generated files live (default `~/.config/ghidmgt`) |
| `GHIDMGT_GITCONFIG` | git config file to manage (default `~/.gitconfig`) |
| `GHIDMGT_SSHCONFIG` | ssh config file to manage (default `~/.ssh/config`) |
| `GHIDMGT_ZSHENV`, `GHIDMGT_BASHRC` | rc files the installer wires and `doctor` checks |
| `GHIDMGT_BIN_DIR` | where `install.sh` links the CLI (default `~/.local/bin`) |
| `GHIDMGT_DISABLE=1` | the shell resolver leaves `GH_CONFIG_DIR` alone in this shell and its children (`ghidmgt exec` and `ghidmgt env` set it) |
| `GHIDMGT_NO_HOOK=1` | don't register the `cd` hook; resolve once at shell start only |
| `NO_COLOR=1` | plain output |

The shell resolver also exports `GHIDMGT_IDENTITY`, which you can show in your prompt.

## Limits

- **Roots match by path.** A repo moved outside every root silently falls back to your
  global git identity. `ghidmgt doctor` flags roots that don't exist, but it doesn't hunt
  for stray clones.
- **A `git worktree` keeps its original identity.** `includeIf "gitdir:"` matches the
  repository's git directory, not the worktree's path. A worktree of a `~/work` repo
  checked out under `~/clients/acme` still commits as `work` while `gh` uses `acme`.
  Git offers no condition on the worktree path, so ghidmgt can't fix this. `ghidmgt check`
  reports it explicitly. Keep worktrees under the same root as their repo.
- **Nested identities inherit what they leave unset.** If `client-x` sits inside
  `personal` and has no `--email`, its repos get personal's email rather than your
  global one; with `--no-ssh-key`, they get personal's SSH key. Give nested
  identities every field.
- **Bash scripts don't get the `gh` layer automatically.** Bash has no `.zshenv`
  equivalent. Git-level isolation still applies; use `ghidmgt exec` for `gh` in bash scripts.
- **github.com only.** GitHub Enterprise Server hosts aren't managed yet.
- **A bind mount that hides the real path resolves to no identity** in the shell layer.
  The git layer still applies.

## Uninstall

```bash
ghidmgt rm <name>                              # for each identity: removes its git and ssh blocks
~/.local/share/ghidmgt/install.sh --uninstall  # removes the rc block and the symlink
```

Your registry and generated files stay in `~/.config/ghidmgt` until you delete them, and
`gh` logins stay in their config directories.

## FAQ

**Does ghidmgt send my data anywhere?**
No. ghidmgt never stores, prints or transmits tokens. The only network calls are the two `live` checks
in `ghidmgt check` (`gh api user` and `ssh -T git@github.com`), plus whatever `gh` itself
does during `ghidmgt login`.

**Will it overwrite my existing `.gitconfig` or `.ssh/config`?**
No. It only edits between its own markers, and `install.sh` backs up every rc file
before changing it. Run `ghidmgt doctor` afterwards to find older settings that conflict.

**My push still says `Permission denied (publickey)`.**
Run `ghidmgt check` inside the repo. It shows which key git will use and which GitHub
account that key belongs to. The usual causes: the key was added to a different
account, or the repo lives outside every root.

**Do I still need `gh auth switch`?**
No. Each identity has its own `gh` config dir, and the right one is selected by
directory. `gh auth switch` still works inside a single identity if that identity has
several accounts.

**Can I use HTTPS remotes instead of SSH?**
Yes. Inside a root, HTTPS credentials come from that identity's `gh` login through
`gh auth git-credential`. Use `--no-ssh-key` for identities that never use SSH.

**What about commit signing?**
Not managed yet. You can add `user.signingkey` and related settings to the generated
include by hand, but `ghidmgt sync` will overwrite them. A `--signing-key` option is a
welcome contribution.

## Contributing

Bug reports, fixes and new features are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
for the development setup. In short:

```bash
make test   # the full suite, in Docker, under bash 5 and bash 3.2
make lint   # shellcheck, also in Docker
```

The suite never runs on your own machine: `tests/run.sh` refuses to start outside a
container or a CI runner, because ghidmgt rewrites the same files you use every day.

## Security

ghidmgt exists to keep credentials apart, so isolation bugs are security bugs. Please
report them privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

## License

[MIT](LICENSE) © 2026 Elbert (Sangyoup) Bae
