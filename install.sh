#!/usr/bin/env bash
# Install the ghid CLI and wire it into your shell.
#
#   ./install.sh                  install + wire the shell named by $SHELL (safe to re-run)
#   ./install.sh --shell bash     choose the shell to wire: zsh, bash or both
#   ./install.sh --uninstall      unwire every shell and remove the symlink (identities are kept)
#
# Identities themselves are NOT created here -- that is per machine. See the
# suggestions this prints, or README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/ghid"
BIN_DIR="${GHID_BIN_DIR:-$HOME/.local/bin}"
DEST="$BIN_DIR/ghid"
ZSHENV="${GHID_ZSHENV:-$HOME/.zshenv}"
BASHRC="${GHID_BASHRC:-$HOME/.bashrc}"
GHID_HOME="${GHID_HOME:-$HOME/.config/ghid}"

info() { printf '%s\n' "$*"; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

usage() { sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE=install
SHELLS=auto
while [ $# -gt 0 ]; do
    case "$1" in
        --shell)     SHELLS="${2:?--shell needs zsh, bash or both}"; shift 2 ;;
        --shell=*)   SHELLS="${1#--shell=}"; shift ;;
        --uninstall) MODE=uninstall; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown option: $1 (try --help)" ;;
    esac
done

BEGIN_MARK='# >>> ghid shell integration >>>'
END_MARK='# <<< ghid shell integration <<<'

# A run can back a file up more than once, and `date` only resolves to the
# second -- never overwrite an existing backup with a later copy.
backup() {
    local f="$1"
    [ -f "$f" ] || return 0
    local stamp b n=0
    stamp="$(date +%Y%m%d-%H%M%S)"
    b="$f.bak.$stamp"
    while [ -e "$b" ]; do
        n=$((n + 1))
        b="$f.bak.$stamp.$n"
    done
    cp -p "$f" "$b"
    note "backed up $(tilde "$f") -> $(tilde "$b")"
}

strip_marked() {
    local f="$1"
    [ -f "$f" ] || return 0
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
    ' "$f"
}

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------
if [ "$MODE" = uninstall ]; then
    for f in "$ZSHENV" "$BASHRC"; do
        if [ -f "$f" ] && grep -qF "$BEGIN_MARK" "$f"; then
            backup "$f"
            # Write through instead of mv-ing over, so a symlinked rc file
            # (stow, chezmoi) stays a symlink and keeps its permissions.
            strip_marked "$f" > "$f.ghid.tmp"
            cat "$f.ghid.tmp" > "$f"
            rm -f "$f.ghid.tmp"
            ok "removed the ghid block from $(tilde "$f")"
        fi
    done
    if [ -L "$DEST" ]; then rm -f "$DEST"; ok "removed $(tilde "$DEST")"; fi
    note "identities and generated files kept in $(tilde "$GHID_HOME")"
    note "git and ssh blocks remain; remove them with: ghid rm <name> (before uninstalling)"
    exit 0
fi

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
if [ "$SHELLS" = auto ]; then
    case "$(basename "${SHELL:-}")" in
        zsh)  SHELLS=zsh ;;
        bash) SHELLS=bash ;;
        *)    die "cannot tell your shell from \$SHELL='${SHELL:-}'; pass --shell zsh, bash or both" ;;
    esac
fi
case "$SHELLS" in
    zsh|bash|both) ;;
    *) die "--shell must be zsh, bash or both (got '$SHELLS')" ;;
esac

# The wiring line below is spliced into an rc file inside double quotes.
case "$GHID_HOME" in
    *[[:space:]\"\$\`\\]*) die "GHID_HOME must not contain whitespace, quotes, \$, backticks or backslashes: $GHID_HOME" ;;
esac

[ -f "$SRC" ] || die "cannot find $SRC"
command -v git >/dev/null || die "git is required"
command -v gh  >/dev/null || warn "gh is not installed; 'ghid login' will not work until it is (https://cli.github.com)"

mkdir -p "$BIN_DIR"
# A symlink means `git pull` in this repo updates the installed CLI.
ln -sfn "$SRC" "$DEST"
chmod +x "$SRC"
ok "installed $(tilde "$DEST") -> $(tilde "$SRC")"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$(tilde "$BIN_DIR") is not on your PATH; add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

mkdir -p "$GHID_HOME/identities" "$GHID_HOME/git"
chmod 700 "$GHID_HOME" "$GHID_HOME/identities"

# Written literally as $HOME/... when it is the default, so a dotfiles repo
# that carries the rc file works for any user name.
if [ "$GHID_HOME" = "$HOME/.config/ghid" ]; then
    # shellcheck disable=SC2016
    rc_dir='$HOME/.config/ghid'
else
    rc_dir="$GHID_HOME"
fi

# wire <rc file> <test-and-source line>
wire() {
    local f="$1" line="$2"
    if grep -qF "$BEGIN_MARK" "$f" 2>/dev/null; then
        note "$(tilde "$f") already wired"
        return 0
    fi
    mkdir -p "$(dirname "$f")"
    backup "$f"
    {
        [ -s "$f" ] && printf '\n'
        printf '%s\n' "$BEGIN_MARK"
        printf '# GitHub identity follows the directory. Generated by `ghid sync`.\n'
        printf '# Managed by ghid (https://github.com/bert-bae/ghid) -- edit identities with `ghid`.\n'
        printf '%s\n' "$line"
        printf '%s\n' "$END_MARK"
    } >> "$f"
    ok "wired $(tilde "$f")"
}

# zsh: .zshenv, not .zshrc. .zshenv is read by EVERY zsh, not just interactive
# ones, so scripts, git hooks, `zsh -c` and agent tooling resolve the same
# identity your prompt does. shell.zsh registers its own chpwd hook when the
# shell is interactive, so nothing needs to go in .zshrc.
if [ "$SHELLS" = zsh ] || [ "$SHELLS" = both ]; then
    wire "$ZSHENV" "[[ -r \"$rc_dir/shell.zsh\" ]] && source \"$rc_dir/shell.zsh\""
fi

# bash: .bashrc. bash has no equivalent of .zshenv for every shell, so
# non-interactive bash relies on the git layer (which needs no shell at all)
# or on `ghid exec` / BASH_ENV.
if [ "$SHELLS" = bash ] || [ "$SHELLS" = both ]; then
    wire "$BASHRC" "[ -r \"$rc_dir/shell.sh\" ] && . \"$rc_dir/shell.sh\""
    if [ "$(uname -s)" = Darwin ]; then
        note "macOS terminals start login shells, which read ~/.bash_profile, not ~/.bashrc."
        note "make sure ~/.bash_profile sources ~/.bashrc."
    fi
fi

"$DEST" sync

# ---------------------------------------------------------------------------
# If there are no identities yet, propose ones from what is already on the box.
# ---------------------------------------------------------------------------
if ! compgen -G "$GHID_HOME/identities/*.conf" >/dev/null; then
    info ""
    info "No identities registered yet. Detected on this machine:"
    found=0
    for d in "$HOME"/.config/gh "$HOME"/.config/gh-*; do
        [ -f "$d/hosts.yml" ] || continue
        user="$(sed -n 's/^    user: \(.*\)$/\1/p' "$d/hosts.yml" | head -1)"
        [ -n "$user" ] || continue
        base="$(basename "$d")"
        case "$base" in
            gh)    suffix=personal ;;
            gh-*)  suffix="${base#gh-}" ;;
            *)     continue ;;
        esac
        found=1
        key="$HOME/.ssh/id_ed25519"
        [ "$suffix" != personal ] && [ -f "$HOME/.ssh/id_ed25519_$suffix" ] && key="$HOME/.ssh/id_ed25519_$suffix"
        info ""
        info "  gh account '$user' in $(tilde "$d"):"
        info "    ghid add $suffix --root ~/CHANGE_ME \\"
        info "      --gh-user $user --gh-config-dir $(tilde "$d") \\"
        info "      --ssh-key $(tilde "$key") --email you@example.com"
    done
    [ "$found" -eq 1 ] || info "  (none -- start with: ghid add personal --root ~/projects --email you@example.com)"
fi

info ""
ok "done. Open a new shell, then run: ghid doctor"
