# Security policy

ghid's whole job is keeping one GitHub account's credentials away from another's, so a
bug that lets one identity act as another is a security bug, even if it looks like an
ordinary misconfiguration.

## Reporting a vulnerability

**Please don't open a public issue.** Report privately through GitHub:
**[Report a vulnerability](https://github.com/bert-bae/ghid/security/advisories/new)**
(Security tab → *Report a vulnerability*).

Include what you ran, what you expected, what happened instead, and your OS, shell,
bash version (`bash --version`), git version and `ghid version`. Redact tokens, emails
and paths you don't want shared.

You'll get an acknowledgement within 7 days. Once a fix is ready, we'll agree on a
disclosure date, and you're welcome to be credited in the release notes.

## Supported versions

Only the latest release gets security fixes. Update with:

```bash
git -C ~/.local/share/ghid pull
```

## In scope

- A repo under one identity's root committing, pushing, or authenticating `gh` as
  another identity
- Command injection through registry values, paths or names written into generated
  shell code, git config or ssh config
- ghid deleting or overwriting data it shouldn't (outside its markers, outside a
  `gh` config dir on `rm --purge`)
- Registry or generated files created with permissions other users can read or write
- `ghid exec` / `ghid env` leaking a variable that overrides the chosen identity

## Out of scope

- Anything that requires an attacker who can already write to your home directory or
  run commands as you
- Weaknesses in git, OpenSSH or `gh` themselves (report those upstream)
- The documented [limits](README.md#limits), such as worktrees keeping their original
  identity

## What ghid touches

ghid never stores, prints or transmits tokens. It reads `gh`'s `hosts.yml` only to list
account names. It makes network calls only in `ghid check` (`gh api user`,
`ssh -T git@github.com`) and through `gh` during `ghid login` and `ghid rm --purge`.
