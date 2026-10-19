#!/usr/bin/env bash
# Install the ghidmgt CLI and wire it into your shell.
#
#   ./install.sh                  install + wire the shell named by $SHELL (safe to re-run)
#   ./install.sh --shell bash     choose the shell to wire: zsh, bash or both
#   ./install.sh --uninstall      unwire every shell and remove the symlink (identities are kept)
#
# Identities themselves are NOT created here -- that is per machine. See the
# suggestions this prints, or README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/ghidmgt"
BIN_DIR="${GHIDMGT_BIN_DIR:-$HOME/.local/bin}"
DEST="$BIN_DIR/ghidmgt"
ZSHENV="${GHIDMGT_ZSHENV:-$HOME/.zshenv}"
BASHRC="${GHIDMGT_BASHRC:-$HOME/.bashrc}"
GHIDMGT_HOME="${GHIDMGT_HOME:-$HOME/.config/ghidmgt}"

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

BEGIN_MARK='# >>> ghidmgt shell integration >>>'
END_MARK='# <<< ghidmgt shell integration <<<'
# The block this project wrote under its old name, ghid.
LEGACY_BEGIN='# >>> ghid shell integration >>>'
LEGACY_END='# <<< ghid shell integration <<<'

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

# strip_marked <file> <begin> <end>: drop that block in place. Written through
# rather than mv-ed over, so a symlinked rc file (stow, chezmoi) stays a
# symlink and keeps its permissions.
strip_marked() {
    local f="$1"
    [ -f "$f" ] || return 0
    awk -v b="$2" -v e="$3" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
    ' "$f" > "$f.ghidmgt.tmp"
    cat "$f.ghidmgt.tmp" > "$f"
    rm -f "$f.ghidmgt.tmp"
}

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------
if [ "$MODE" = uninstall ]; then
    for f in "$ZSHENV" "$BASHRC"; do
        if [ -f "$f" ] && grep -qF -e "$BEGIN_MARK" -e "$LEGACY_BEGIN" "$f"; then
            backup "$f"
            strip_marked "$f" "$BEGIN_MARK" "$END_MARK"
            strip_marked "$f" "$LEGACY_BEGIN" "$LEGACY_END"
            ok "removed the ghidmgt block from $(tilde "$f")"
        fi
    done
    if [ -L "$DEST" ]; then rm -f "$DEST"; ok "removed $(tilde "$DEST")"; fi
    note "identities and generated files kept in $(tilde "$GHIDMGT_HOME")"
    note "git and ssh blocks remain; remove them with: ghidmgt rm <name> (before uninstalling)"
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
case "$GHIDMGT_HOME" in
    *[[:space:]\"\$\`\\]*) die "GHIDMGT_HOME must not contain whitespace, quotes, \$, backticks or backslashes: $GHIDMGT_HOME" ;;
esac

[ -f "$SRC" ] || die "cannot find $SRC"
command -v git >/dev/null || die "git is required"
command -v gh  >/dev/null || warn "gh is not installed; 'ghidmgt login' will not work until it is (https://cli.github.com)"

mkdir -p "$BIN_DIR"
# A symlink means `git pull` in this repo updates the installed CLI.
ln -sfn "$SRC" "$DEST"
chmod +x "$SRC"
ok "installed $(tilde "$DEST") -> $(tilde "$SRC")"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$(tilde "$BIN_DIR") is not on your PATH; add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# ghidmgt was called ghid. Its symlink dangles once this clone renames the
# file, and an older copy elsewhere would keep rewriting the old blocks.
# (`ghidmgt sync` below moves ~/.config/ghid and replaces its git and ssh
# blocks, which is why this script no longer creates the config dir itself.)
LEGACY_DEST="$BIN_DIR/ghid"
if [ -L "$LEGACY_DEST" ]; then
    if [ "$(readlink "$LEGACY_DEST")" = "$HERE/ghid" ]; then
        rm -f "$LEGACY_DEST"
        ok "removed the old $(tilde "$LEGACY_DEST") symlink (ghid is now ghidmgt)"
    else
        warn "an older ghid is still installed at $(tilde "$LEGACY_DEST"); remove it so it cannot rewrite the old config blocks"
    fi
fi

# Replace an rc block left by ghid in place: whichever shell it wired stays
# wired, under the new name.
legacy_zsh=0 legacy_bash=0
for f in "$ZSHENV" "$BASHRC"; do
    [ -f "$f" ] && grep -qF "$LEGACY_BEGIN" "$f" || continue
    backup "$f"
    strip_marked "$f" "$LEGACY_BEGIN" "$LEGACY_END"
    ok "removed the old ghid block from $(tilde "$f")"
    if [ "$f" = "$ZSHENV" ]; then legacy_zsh=1; else legacy_bash=1; fi
done

# Written literally as $HOME/... when it is the default, so a dotfiles repo
# that carries the rc file works for any user name.
if [ "$GHIDMGT_HOME" = "$HOME/.config/ghidmgt" ]; then
    # shellcheck disable=SC2016
    rc_dir='$HOME/.config/ghidmgt'
else
    rc_dir="$GHIDMGT_HOME"
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
        printf '# GitHub identity follows the directory. Generated by `ghidmgt sync`.\n'
        printf '# Managed by ghidmgt (https://github.com/bert-bae/ghidmgt) -- edit identities with `ghidmgt`.\n'
        printf '%s\n' "$line"
        printf '%s\n' "$END_MARK"
    } >> "$f"
    ok "wired $(tilde "$f")"
}

# zsh: .zshenv, not .zshrc. .zshenv is read by EVERY zsh, not just interactive
# ones, so scripts, git hooks, `zsh -c` and agent tooling resolve the same
# identity your prompt does. shell.zsh registers its own chpwd hook when the
# shell is interactive, so nothing needs to go in .zshrc.
if [ "$SHELLS" = zsh ] || [ "$SHELLS" = both ] || [ "$legacy_zsh" -eq 1 ]; then
    wire "$ZSHENV" "[[ -r \"$rc_dir/shell.zsh\" ]] && source \"$rc_dir/shell.zsh\""
fi

# bash: .bashrc. bash has no equivalent of .zshenv for every shell, so
# non-interactive bash relies on the git layer (which needs no shell at all)
# or on `ghidmgt exec` / BASH_ENV.
if [ "$SHELLS" = bash ] || [ "$SHELLS" = both ] || [ "$legacy_bash" -eq 1 ]; then
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
if ! compgen -G "$GHIDMGT_HOME/identities/*.conf" >/dev/null; then
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
        info "    ghidmgt add $suffix --root ~/CHANGE_ME \\"
        info "      --gh-user $user --gh-config-dir $(tilde "$d") \\"
        info "      --ssh-key $(tilde "$key") --email you@example.com"
    done
    [ "$found" -eq 1 ] || info "  (none -- start with: ghidmgt add personal --root ~/projects --email you@example.com)"
fi

info ""
ok "done. Open a new shell, then run: ghidmgt doctor"
