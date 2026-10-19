#!/usr/bin/env bash
# Install the ghid CLI and wire it into zsh.
#
#   ./install.sh                 install + wire (safe to re-run)
#   ./install.sh --migrate       also remove the older hand-rolled _gh_ctx hook
#   ./install.sh --uninstall     unwire the shell hook (identities are kept)
#
# Identities themselves are NOT created here -- that is per machine. See the
# suggestions this prints, or README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/ghid"
BIN_DIR="${GHID_BIN_DIR:-$HOME/.local/bin}"
DEST="$BIN_DIR/ghid"
ZSHENV="${GHID_ZSHENV:-$HOME/.zshenv}"
ZSHRC="${GHID_ZSHRC:-$HOME/.zshrc}"
GHID_HOME="${GHID_HOME:-$HOME/.config/ghid}"

MODE=install
MIGRATE=0
for arg in "$@"; do
    case "$arg" in
        --migrate)   MIGRATE=1 ;;
        --uninstall) MODE=uninstall ;;
        -h|--help)   sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)           echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

info() { printf '%s\n' "$*"; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

BEGIN_MARK='# >>> ghid shell integration >>>'
END_MARK='# <<< ghid shell integration <<<'

# --migrate backs a file up more than once in a run, and `date` only resolves to
# the second -- so the later copy (taken AFTER the legacy hook was stripped, and
# for a .zshenv that held nothing else, empty) would overwrite the only good
# copy. Never overwrite an existing backup.
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
    note "backed up $f -> $b"
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
    for f in "$ZSHENV" "$ZSHRC"; do
        if [ -f "$f" ] && grep -qF "$BEGIN_MARK" "$f"; then
            backup "$f"
            strip_marked "$f" > "$f.ghid.tmp" && mv "$f.ghid.tmp" "$f"
            ok "removed ghid block from $f"
        fi
    done
    [ -L "$DEST" ] && { rm -f "$DEST"; ok "removed $DEST"; }
    note "identities and generated files kept in $GHID_HOME"
    note "git and ssh blocks remain; remove them with: ghid rm <name> (before uninstalling)"
    exit 0
fi

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
[ -f "$SRC" ] || die "cannot find $SRC"
command -v git >/dev/null || die "git is required"
command -v gh  >/dev/null || warn "gh is not installed; 'ghid login' will not work until it is"

mkdir -p "$BIN_DIR"
# A symlink means `git pull` in this repo updates the installed CLI.
ln -sfn "$SRC" "$DEST"
chmod +x "$SRC"
ok "installed $DEST -> $SRC"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH; add: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

mkdir -p "$GHID_HOME/identities" "$GHID_HOME/git"
chmod 700 "$GHID_HOME" "$GHID_HOME/identities"

# ---------------------------------------------------------------------------
# Retire the older hand-rolled hook, which would keep fighting ghid over
# GH_CONFIG_DIR: whichever ran last wins, and that is not a coin flip you want
# on a machine holding two clients' credentials.
# ---------------------------------------------------------------------------
legacy=0
grep -q '_gh_ctx' "$ZSHENV" 2>/dev/null && legacy=1
grep -q '_gh_ctx' "$ZSHRC"  2>/dev/null && legacy=1

if [ "$legacy" -eq 1 ]; then
    if [ "$MIGRATE" -eq 1 ]; then
        for f in "$ZSHENV" "$ZSHRC"; do
            grep -q '_gh_ctx' "$f" 2>/dev/null || continue
            backup "$f"
            # Brace-depth scan: the old version stopped at the first line
            # starting with "}" in column 0, so an indented closing brace made
            # it delete everything to EOF, and a one-line function swallowed
            # whatever followed. If the braces never balance, delete nothing.
            awk '
                { line[NR] = $0 }
                function depth_of(t,   o, c) {
                    o = gsub(/\{/, "{", t); c = gsub(/\}/, "}", t); return o - c
                }
                END {
                    for (i = 1; i <= NR; i++) {
                        if (line[i] ~ /^[ \t]*(function[ \t]+)?_gh_ctx[ \t]*(\(\))?[ \t]*\{/) {
                            d = depth_of(line[i])
                            end = (d == 0) ? i : 0
                            for (j = i + 1; j <= NR && end == 0; j++) {
                                d += depth_of(line[j])
                                if (d <= 0) end = j
                            }
                            if (end == 0) { unbalanced = 1; continue }
                            for (j = i; j <= end; j++) del[j] = 1
                            for (j = i - 1; j >= 1 && line[j] ~ /^[ \t]*#/; j--) del[j] = 1
                        }
                        if (line[i] ~ /^[ \t]*_gh_ctx[ \t]*$/) del[i] = 1
                        if (line[i] ~ /_gh_ctx/ && line[i] ~ /add-zsh-hook/) {
                            del[i] = 1
                            j = i - 1
                            if (j >= 1 && line[j] ~ /^[ \t]*autoload .*add-zsh-hook/) { del[j] = 1; j-- }
                            for (; j >= 1 && line[j] ~ /^[ \t]*#/; j--) del[j] = 1
                        }
                    }
                    if (unbalanced) {
                        printf "ghid: could not find the end of _gh_ctx; leaving the file untouched\n" > "/dev/stderr"
                        for (i = 1; i <= NR; i++) print line[i]
                        exit 1
                    }
                    started = 0; blank = 0
                    for (i = 1; i <= NR; i++) {
                        if (del[i]) continue
                        if (line[i] ~ /^[ \t]*$/) { blank++; continue }
                        while (started && blank-- > 0) print ""
                        blank = 0; started = 1
                        print line[i]
                    }
                }
            ' "$f" > "$f.ghid.tmp" && mv "$f.ghid.tmp" "$f" || rm -f "$f.ghid.tmp"
            if grep -q '_gh_ctx' "$f" 2>/dev/null; then
                warn "could not fully remove _gh_ctx from $f -- remove it by hand."
                warn "it fights ghid over GH_CONFIG_DIR until it is gone."
            else
                ok "removed the legacy _gh_ctx hook from $f"
            fi
        done
    else
        warn "the older _gh_ctx hook is still in your zsh files and will conflict with ghid."
        warn "re-run as: ./install.sh --migrate    (a timestamped backup is kept)"
    fi
fi

# ---------------------------------------------------------------------------
# One source line in .zshenv covers everything.
#
# .zshenv is read by EVERY zsh, not just interactive ones, so scripts, git
# hooks, `zsh -c` and agent tooling resolve the same identity your prompt does.
# The generated file registers its own chpwd hook when the shell is interactive,
# so nothing needs to go in .zshrc.
# ---------------------------------------------------------------------------
if ! grep -qF "$BEGIN_MARK" "$ZSHENV" 2>/dev/null; then
    backup "$ZSHENV"
    {
        [ -f "$ZSHENV" ] && [ -s "$ZSHENV" ] && printf '\n'
        printf '%s\n' "$BEGIN_MARK"
        printf '# GitHub identity follows the directory. Generated by `ghid sync`.\n'
        printf '# Managed by ghid (https://github.com/bert-bae/ghid) -- edit identities with `ghid`.\n'
        printf '[[ -r "%s/shell.zsh" ]] && source "%s/shell.zsh"\n' '$HOME/.config/ghid' '$HOME/.config/ghid'
        printf '%s\n' "$END_MARK"
    } >> "$ZSHENV"
    ok "wired $ZSHENV"
else
    note "$ZSHENV already wired"
fi

"$DEST" sync

# ---------------------------------------------------------------------------
# If there are no identities yet, propose ones from what is already on the box.
# ---------------------------------------------------------------------------
if [ -z "$("$DEST" list 2>/dev/null | grep -E '^\S' || true)" ] || [ "$("$DEST" list 2>&1)" = "no identities yet -- ghid add <name> --root <dir>" ]; then
    info ""
    info "No identities registered yet. Detected on this machine:"
    found=0
    for d in "$HOME"/.config/gh "$HOME"/.config/gh-*; do
        [ -f "$d/hosts.yml" ] || continue
        user="$(sed -n 's/^    user: \(.*\)$/\1/p' "$d/hosts.yml" | head -1)"
        [ -n "$user" ] || continue
        found=1
        base="$(basename "$d")"
        case "$base" in
            gh)    suffix=personal ;;
            gh-*)  suffix="${base#gh-}" ;;
            *)     continue ;;
        esac
        key="$HOME/.ssh/id_ed25519"
        [ "$suffix" != personal ] && [ -f "$HOME/.ssh/id_ed25519_$suffix" ] && key="$HOME/.ssh/id_ed25519_$suffix"
        info ""
        info "  gh account '$user' in ${d/#$HOME/\~}:"
        info "    ghid add $suffix --root ~/CHANGE_ME \\"
        info "      --gh-user $user --gh-config-dir ${d/#$HOME/\~} \\"
        info "      --ssh-key ${key/#$HOME/\~} --email you@example.com"
    done
    [ "$found" -eq 1 ] || info "  (none -- start with: ghid add personal --root ~/projects --email you@example.com)"
fi

info ""
ok "done. Open a new shell, then run: ghid doctor"
