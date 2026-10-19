#!/usr/bin/env bash
# shellcheck disable=SC2088
# (A literal ~ is deliberate throughout: it is what users type and ghidmgt prints.)
#
# ghidmgt test suite.
#
# ghidmgt rewrites ~/.gitconfig, ~/.ssh/config and shell rc files, so this suite
# only runs inside a disposable sandbox and refuses to start anywhere else:
#
#   make test          Docker: no network, no host mounts, no capabilities
#   CI                 GitHub Actions runners are discarded after every job
#
# Inside the sandbox every test still gets its own throwaway $HOME, and the
# real gh and ssh binaries are shadowed so nothing can reach GitHub.
#
#   GHIDMGT_TEST_BASH=/bin/bash   bash to run ghidmgt with (CI pins macOS's 3.2)
#   GHIDMGT_TEST_FILTER=purge     run only the tests whose name contains this
set -uo pipefail

refuse() {
    printf 'tests/run.sh: refusing to run outside a sandbox.\n' >&2
    printf '  %s\n' "$@" >&2
    printf '  Run the suite with: make test   (Docker, no network, no host mounts)\n' >&2
    exit 2
}
[ "${GHIDMGT_TEST_SANDBOX:-}" = 1 ] || refuse "GHIDMGT_TEST_SANDBOX=1 is not set."
if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ] && [ "${GITHUB_ACTIONS:-}" != true ]; then
    refuse "This is neither a container nor a GitHub Actions runner."
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
GHIDMGT="$REPO/ghidmgt"
TEST_BASH="$(command -v "${GHIDMGT_TEST_BASH:-bash}")" || { echo "no bash at ${GHIDMGT_TEST_BASH:-bash}" >&2; exit 2; }
ZSH="$(command -v zsh || true)"

# Resolve symlinks (macOS /var -> /private/var) so paths compare as git sees them.
# The EXIT trap rm -rf's this, so it has to be the directory mktemp made: an
# empty value would make `cd ""` a no-op and point the trap at the cwd.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ghidmgt-test.XXXXXX")" || { echo "mktemp failed" >&2; exit 2; }
SANDBOX="$(cd "$SANDBOX" && pwd -P)" || exit 2
case "$SANDBOX" in
    /*/ghidmgt-test.??????) ;;
    *) echo "unexpected sandbox path: '$SANDBOX'" >&2; exit 2 ;;
esac
trap 'rm -rf "$SANDBOX"' EXIT

# `#!/usr/bin/env bash` in ghidmgt and install.sh resolves through PATH, so this
# shim is how GHIDMGT_TEST_BASH reaches them. gh and ssh are shadowed by stubs
# that fail loudly; tests that need gh install their own recording stub.
mkdir -p "$SANDBOX/bin"
ln -s "$TEST_BASH" "$SANDBOX/bin/bash"
for tool in gh ssh; do
    printf '#!/bin/sh\necho "tests: the real %s is blocked in the sandbox" >&2\nexit 97\n' "$tool" > "$SANDBOX/bin/$tool"
    chmod +x "$SANDBOX/bin/$tool"
done
export PATH="$SANDBOX/bin:$PATH"

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
fail_test() { printf '%s\n' "$@" >&2; exit 1; }
eq()    { [ "$1" = "$2" ] || fail_test "expected: [$2]" "got:      [$1]"; }
has()   { case "$1" in *"$2"*) ;; *) fail_test "expected to find: [$2]" "in: [$1]" ;; esac; }
lacks() { case "$1" in *"$2"*) fail_test "did not expect: [$2]" "in: [$1]" ;; esac; }
exists() { [ -e "$1" ] || fail_test "expected $1 to exist"; }
absent() { [ ! -e "$1" ] || fail_test "expected $1 not to exist"; }
same()  { cmp -s "$1" "$2" || fail_test "files differ: $1 $2" "$(diff "$1" "$2")"; }
count() { grep -cF -- "$2" "$1" || true; }

# Run a command that must fail; print its combined output.
must_fail() {
    local out
    if out="$("$@" 2>&1)"; then fail_test "expected failure: $*" "$out"; fi
    printf '%s' "$out"
}

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

ghidmgt() { "$GHIDMGT" "$@"; }

# Read one field of an identity's registry file.
# shellcheck disable=SC1090
field() { local v="$2"; ( . "$HOME/.config/ghidmgt/identities/$1.conf"; printf '%s' "${!v}" ); }

# A placeholder SSH key: ghidmgt only checks that it exists with mode 600.
fake_key() { mkdir -p "$(dirname "$1")"; : > "$1"; : > "$1.pub"; chmod 600 "$1"; }

# A gh config dir that looks logged in as the given github.com accounts.
fake_gh_login() {
    local dir="$1" user; shift
    mkdir -p "$dir"
    {
        printf 'github.com:\n    users:\n'
        for user in "$@"; do printf '        %s:\n' "$user"; done
        printf '    git_protocol: ssh\n    user: %s\n' "$1"
    } > "$dir/hosts.yml"
}

# Replace the blocked gh with one that records its calls.
use_gh_stub() {
    mkdir -p "$HOME/stub-bin"
    cat > "$HOME/stub-bin/gh" <<'EOF'
#!/bin/sh
printf '%s|%s\n' "${GH_CONFIG_DIR:-}" "$*" >> "$HOME/gh-calls.log"
case "$1 $2" in
    "auth logout") exit "${GH_STUB_LOGOUT_RC:-0}" ;;
    "api user")    printf '%s\n' "${GH_STUB_LOGIN:-stub-user}" ;;
esac
exit 0
EOF
    chmod +x "$HOME/stub-bin/gh"
    : > "$HOME/gh-calls.log"
    export PATH="$HOME/stub-bin:$PATH"
}

setup_home() {
    export HOME="$SANDBOX/homes/$1"
    mkdir -p "$HOME"
    export XDG_CONFIG_HOME="$HOME/.config"
    export GIT_CONFIG_NOSYSTEM=1
    export NO_COLOR=1
    export SHELL=/bin/sh
    unset GHIDMGT_HOME GHIDMGT_GITCONFIG GHIDMGT_SSHCONFIG GHIDMGT_ZSHENV GHIDMGT_BASHRC GHIDMGT_BIN_DIR \
          GHIDMGT_IDENTITY GHIDMGT_DISABLE GH_TOKEN GITHUB_TOKEN GH_CONFIG_DIR GIT_CONFIG_GLOBAL \
          GIT_DIR GIT_WORK_TREE ZDOTDIR BASH_ENV ENV PROMPT_COMMAND
    git config --global user.name "Test User"
    git config --global init.defaultBranch main
    cd "$HOME"
}

PASSED=0 FAILED=0 FAILED_NAMES=""
run() {
    local name="$1" rc
    case "$name" in *"${GHIDMGT_TEST_FILTER:-}"*) ;; *) return 0 ;; esac
    ( set -e; setup_home "$name"; "$name" ) > "$SANDBOX/log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        PASSED=$((PASSED + 1)); printf 'ok    %s\n' "$name"
    else
        FAILED=$((FAILED + 1)); FAILED_NAMES="$FAILED_NAMES $name"
        printf 'FAIL  %s\n' "$name"
        sed 's/^/      /' "$SANDBOX/log"
    fi
}

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------
test_cli_basics() {
    has "$(ghidmgt help)" "per-directory GitHub identity manager"
    has "$(ghidmgt version)" "ghidmgt "
    has "$(must_fail ghidmgt frobnicate)" "unknown command"
    has "$(ghidmgt list)" "no identities yet"
}

test_add_fills_in_defaults() {
    # A literal ~ (as a setup script might pass it) is expanded by ghidmgt.
    ghidmgt add work --root '~/work' --email w@example.com >/dev/null
    eq "$(mode_of "$HOME/.config/ghidmgt/identities/work.conf")" 600
    eq "$(field work ID_ROOTS)" "$HOME/work"
    eq "$(field work ID_GIT_NAME)" "Test User"
    eq "$(field work ID_GIT_EMAIL)" "w@example.com"
    eq "$(field work ID_GH_CONFIG_DIR)" "$HOME/.config/gh-work"
    eq "$(field work ID_SSH_KEY)" "$HOME/.ssh/id_ed25519_work"
    eq "$(field work ID_SSH_ALIAS)" "github.com-work"
    out="$(ghidmgt list)"
    has "$out" "~/work"
    has "$out" "no-key"
    has "$out" "no-gh"
    has "$(ghidmgt show work)" "ID_GIT_EMAIL=w@example.com"
}

test_add_is_idempotent_and_keeps_omitted_fields() {
    ghidmgt add work --root "$HOME/work" --email w@example.com --gh-user octo-work >/dev/null
    cp "$HOME/.gitconfig" "$HOME/gitconfig.1"
    cp "$HOME/.ssh/config" "$HOME/sshconfig.1"
    cp "$HOME/.config/ghidmgt/identities/work.conf" "$HOME/work.conf.1"
    ghidmgt add work --root "$HOME/work" --email w@example.com --gh-user octo-work >/dev/null
    same "$HOME/.gitconfig" "$HOME/gitconfig.1"
    same "$HOME/.ssh/config" "$HOME/sshconfig.1"
    same "$HOME/.config/ghidmgt/identities/work.conf" "$HOME/work.conf.1"

    ghidmgt add work >/dev/null
    eq "$(field work ID_GIT_EMAIL)" w@example.com
    eq "$(field work ID_GH_USER)" octo-work

    ghidmgt add work --email new@example.com >/dev/null
    eq "$(field work ID_GIT_EMAIL)" new@example.com
    eq "$(field work ID_GH_USER)" octo-work
}

test_add_rejects_bad_input() {
    has "$(must_fail ghidmgt add Work --root "$HOME/w")" "invalid identity name"
    has "$(must_fail ghidmgt add work --root "$HOME/my work")" "no spaces or shell metacharacters"
    has "$(must_fail ghidmgt add work --root "$HOME/w\$(id)")" "no spaces or shell metacharacters"
    has "$(must_fail ghidmgt add work --email a@example.com)" "needs at least one --root"
    has "$(must_fail ghidmgt add work --root "$HOME/w" --bogus)" "unknown option"
    absent "$HOME/.config/ghidmgt/identities/work.conf"
}

test_add_rejects_a_root_owned_by_another_identity() {
    ghidmgt add a --root "$HOME/shared" >/dev/null
    has "$(must_fail ghidmgt add b --root "$HOME/shared")" "already owned by identity 'a'"
    absent "$HOME/.config/ghidmgt/identities/b.conf"
}

test_registry_values_are_never_executed() {
    ghidmgt add work --root "$HOME/work" --email '$(touch "$HOME/pwned")`touch "$HOME/pwned2"`' >/dev/null
    ghidmgt list >/dev/null
    ghidmgt sync >/dev/null
    absent "$HOME/pwned"
    absent "$HOME/pwned2"
    eq "$(field work ID_GIT_EMAIL)" '$(touch "$HOME/pwned")`touch "$HOME/pwned2"`'
}

test_writable_registry_file_is_refused() {
    ghidmgt add work --root "$HOME/work" >/dev/null
    chmod 666 "$HOME/.config/ghidmgt/identities/work.conf"
    has "$(must_fail ghidmgt show work)" "group- or world-writable"
    has "$(ghidmgt list 2>&1)" "skipping"
    chmod 600 "$HOME/.config/ghidmgt/identities/work.conf"
    has "$(ghidmgt show work)" "ID_ROOTS="
}

test_invalid_registry_filename_is_ignored() {
    ghidmgt add work --root "$HOME/work" >/dev/null
    cp "$HOME/.config/ghidmgt/identities/work.conf" "$HOME/.config/ghidmgt/identities/Bad.conf"
    has "$(ghidmgt sync 2>&1)" "is not a valid identity name"
    lacks "$(cat "$HOME/.config/ghidmgt/shell.zsh")" "Bad"
}

# ---------------------------------------------------------------------------
# git and ssh layers
# ---------------------------------------------------------------------------
test_git_layer_applies_inside_roots_only() {
    ghidmgt add work --root "$HOME/work" --email w@example.com --gh-user octo-work >/dev/null
    git init -q "$HOME/work/app"
    git init -q "$HOME/elsewhere"
    has "$(cat "$HOME/.gitconfig")" '[includeIf "gitdir:~/work/"]'

    eq "$(git -C "$HOME/work/app" config user.email)" w@example.com
    eq "$(git -C "$HOME/work/app" config github.user)" octo-work
    eq "$(git -C "$HOME/work/app" config core.sshCommand)" \
        "ssh -i '$HOME/.ssh/id_ed25519_work' -o IdentitiesOnly=yes"
    helpers="$(git -C "$HOME/work/app" config --get-all credential.https://github.com.helper)"
    eq "$(printf '%s\n' "$helpers" | head -n 1)" ""
    eq "$(printf '%s\n' "$helpers" | tail -n 1)" \
        "!GH_CONFIG_DIR='$HOME/.config/gh-work' gh auth git-credential"

    eq "$(git -C "$HOME/elsewhere" config user.email || true)" ""
    eq "$(git -C "$HOME/elsewhere" config core.sshCommand || true)" ""
}

test_nested_roots_resolve_to_the_most_specific_identity() {
    # "client" sorts before "personal": the order that used to let the outer
    # identity win in git while gh used the inner one.
    ghidmgt add personal --root "$HOME/projects" --email me@example.com >/dev/null
    ghidmgt add client --root "$HOME/projects/client" --email me@client.example >/dev/null
    git init -q "$HOME/projects/client/app"
    git init -q "$HOME/projects/side"

    eq "$(git -C "$HOME/projects/client/app" config user.email)" me@client.example
    has "$(git -C "$HOME/projects/client/app" config core.sshCommand)" id_ed25519_client
    eq "$(git -C "$HOME/projects/side" config user.email)" me@example.com
    eq "$(ghidmgt current "$HOME/projects/client/app")" client
    eq "$(ghidmgt current "$HOME/projects/side")" personal
    must_fail ghidmgt current "$HOME/nowhere" >/dev/null

    # Re-adding the outer identity re-syncs; the order must survive that.
    ghidmgt add personal --email me2@example.com >/dev/null
    eq "$(git -C "$HOME/projects/client/app" config user.email)" me@client.example
}

test_sync_migrates_per_identity_git_blocks() {
    ghidmgt add work --root "$HOME/work" --email w@example.com >/dev/null
    # What an older ghidmgt wrote: one block per identity.
    printf '\n# >>> ghidmgt: work >>>\n[includeIf "gitdir:~/old/"]\n\tpath = ~/old.gitconfig\n# <<< ghidmgt: work <<<\n' >> "$HOME/.gitconfig"
    ghidmgt sync >/dev/null
    gc="$(cat "$HOME/.gitconfig")"
    lacks "$gc" "# >>> ghidmgt: work >>>"
    lacks "$gc" "~/old/"
    has "$gc" "# >>> ghidmgt: includeIf >>>"
}

test_ssh_alias_block() {
    ghidmgt add work --root "$HOME/work" >/dev/null
    sc="$(cat "$HOME/.ssh/config")"
    has "$sc" "Host github.com-work"
    has "$sc" "IdentityFile ~/.ssh/id_ed25519_work"
    has "$sc" "IdentitiesOnly yes"
    eq "$(mode_of "$HOME/.ssh/config")" 600

    ghidmgt add work --no-ssh-key >/dev/null
    lacks "$(cat "$HOME/.ssh/config")" "github.com-work"
    lacks "$(cat "$HOME/.config/ghidmgt/git/work.gitconfig")" "sshCommand"
}

test_user_content_outside_markers_survives() {
    printf '[user]\n\tname = Keep Me\n[alias]\n\tco = checkout\n' > "$HOME/.gitconfig"
    mkdir -p "$HOME/.ssh"
    printf 'Host myserver\n    HostName 10.0.0.1\n\n\nHost other\n    User me\n' > "$HOME/.ssh/config"
    ghidmgt add work --root "$HOME/work" >/dev/null
    ghidmgt add home --root "$HOME/home-projects" >/dev/null
    ghidmgt sync >/dev/null
    cp "$HOME/.gitconfig" "$HOME/gitconfig.1"
    cp "$HOME/.ssh/config" "$HOME/sshconfig.1"
    ghidmgt sync >/dev/null
    ghidmgt sync >/dev/null
    same "$HOME/.gitconfig" "$HOME/gitconfig.1"
    same "$HOME/.ssh/config" "$HOME/sshconfig.1"

    gc="$(cat "$HOME/.gitconfig")"
    has "$gc" "name = Keep Me"
    has "$gc" "co = checkout"
    sc="$(cat "$HOME/.ssh/config")"
    has "$sc" "$(printf 'Host myserver\n    HostName 10.0.0.1\n\n\nHost other')"
}

test_symlinked_config_files_stay_symlinks() {
    # The layout dotfile managers (stow, chezmoi) create.
    rm -f "$HOME/.gitconfig"
    mkdir -p "$HOME/dotfiles" "$HOME/.ssh"
    printf '[alias]\n\tco = checkout\n' > "$HOME/dotfiles/gitconfig"
    printf 'Host myserver\n    HostName 10.0.0.1\n' > "$HOME/dotfiles/ssh_config"
    chmod 644 "$HOME/dotfiles/gitconfig"
    chmod 600 "$HOME/dotfiles/ssh_config"
    ln -s "$HOME/dotfiles/gitconfig" "$HOME/.gitconfig"
    ln -s ../dotfiles/ssh_config "$HOME/.ssh/config"

    ghidmgt add work --root "$HOME/work" --email w@example.com >/dev/null
    ghidmgt add home --root "$HOME/h" >/dev/null
    ghidmgt rm home >/dev/null

    [ -L "$HOME/.gitconfig" ] || fail_test "~/.gitconfig was replaced by a regular file"
    [ -L "$HOME/.ssh/config" ] || fail_test "~/.ssh/config was replaced by a regular file"
    has "$(cat "$HOME/dotfiles/gitconfig")" "# >>> ghidmgt: includeIf >>>"
    has "$(cat "$HOME/dotfiles/gitconfig")" "co = checkout"
    has "$(cat "$HOME/dotfiles/ssh_config")" "Host github.com-work"
    lacks "$(cat "$HOME/dotfiles/ssh_config")" "github.com-home"
    eq "$(mode_of "$HOME/dotfiles/gitconfig")" 644
    eq "$(mode_of "$HOME/dotfiles/ssh_config")" 600
    git init -q "$HOME/work/app"
    eq "$(git -C "$HOME/work/app" config user.email)" w@example.com
}

test_unbalanced_markers_are_refused() {
    ghidmgt add work --root "$HOME/work" >/dev/null
    printf '# >>> ghidmgt: includeIf >>>\n[alias]\n\tst = status\n' >> "$HOME/.gitconfig"
    cp "$HOME/.gitconfig" "$HOME/gitconfig.before"
    has "$(must_fail ghidmgt sync)" "unbalanced"
    same "$HOME/.gitconfig" "$HOME/gitconfig.before"
}

test_rm_unwires_and_prunes() {
    ghidmgt add a --root "$HOME/a" >/dev/null
    ghidmgt add b --root "$HOME/b" >/dev/null
    ghidmgt rm a >/dev/null
    absent "$HOME/.config/ghidmgt/identities/a.conf"
    absent "$HOME/.config/ghidmgt/git/a.gitconfig"
    gc="$(cat "$HOME/.gitconfig")"
    lacks "$gc" "gitdir:~/a/"
    has "$gc" "gitdir:~/b/"
    lacks "$(cat "$HOME/.ssh/config")" "github.com-a"
    has "$(cat "$HOME/.ssh/config")" "github.com-b"

    ghidmgt rm b >/dev/null
    lacks "$(cat "$HOME/.gitconfig")" "ghidmgt:"
    has "$(must_fail ghidmgt rm a)" "no such identity"
    has "$(must_fail ghidmgt rm --bogus)" "unknown option"
}

test_add_rejects_unsafe_paths_and_alias() {
    has "$(must_fail ghidmgt add work --root "$HOME/work" --ssh-key "$HOME/my key")" "SSH key path must be absolute"
    has "$(must_fail ghidmgt add work --root "$HOME/work" --gh-config-dir "$HOME/it's")" "gh config dir must be absolute"
    has "$(must_fail ghidmgt add work --root "$HOME/work" --alias "$(printf 'x\n    ProxyCommand touch /tmp/pwned')")" "--alias must be a plain host name"
    has "$(must_fail ghidmgt add work --root "$HOME/work" --git-name "$(printf 'a\nb')")" "single line"
    has "$(must_fail ghidmgt add work --root "$HOME/work" --alias github.com)" "every GitHub connection"
    has "$(must_fail ghidmgt add work --root "$HOME/work" --alias GitHub.com)" "every GitHub connection"
    absent "$HOME/.config/ghidmgt/identities/work.conf"

    ghidmgt add a --root "$HOME/a" --alias gh-shared >/dev/null
    has "$(must_fail ghidmgt add b --root "$HOME/b" --alias gh-shared)" "already used by identity 'a'"
    absent "$HOME/.config/ghidmgt/identities/b.conf"
}

test_no_ssh_key_survives_later_updates() {
    ghidmgt add work --root "$HOME/work" --no-ssh-key >/dev/null
    ghidmgt add work --email w@example.com >/dev/null
    ghidmgt add work >/dev/null
    eq "$(field work ID_SSH_KEY)" ""
    lacks "$(cat "$HOME/.config/ghidmgt/git/work.gitconfig")" "sshCommand"
    lacks "$(cat "$HOME/.ssh/config" 2>/dev/null || true)" "github.com-work"
}

test_git_values_keep_special_characters() {
    ghidmgt add work --root "$HOME/work" --git-name 'Jane "JJ" Doe #1; \o/' --email 'w;x#y@example.com' >/dev/null
    git init -q "$HOME/work/app"
    eq "$(git -C "$HOME/work/app" config user.name)" 'Jane "JJ" Doe #1; \o/'
    eq "$(git -C "$HOME/work/app" config user.email)" 'w;x#y@example.com'
}

test_hand_edited_paths_with_quotes_round_trip() {
    # ghidmgt add refuses such paths, but the registry is documented as
    # hand-editable, so the generators must still quote them correctly.
    key="$HOME/keys/it's a key"
    ghdir="$HOME/gh dirs/it's"
    fake_key "$key"
    ghidmgt add work --root "$HOME/work" >/dev/null
    f="$HOME/.config/ghidmgt/identities/work.conf"
    { grep -v -e '^ID_SSH_KEY=' -e '^ID_GH_CONFIG_DIR=' "$f"
      printf 'ID_SSH_KEY=%q\nID_GH_CONFIG_DIR=%q\n' "$key" "$ghdir"; } > "$f.new"
    mv "$f.new" "$f"; chmod 600 "$f"
    ghidmgt sync >/dev/null
    git init -q "$HOME/work/app"

    # git hands core.sshCommand to sh; it must parse back to the exact path.
    cmd="$(git -C "$HOME/work/app" config core.sshCommand)"
    eval "set -- $cmd"
    eq "$3" "$key"
    helper="$(git -C "$HOME/work/app" config --get-all credential.https://github.com.helper | tail -n 1)"
    eval "set -- ${helper#!}"
    eq "${1#GH_CONFIG_DIR=}" "$ghdir"

    eq "$(cd "$HOME/work/app" && "$TEST_BASH" --norc --noprofile -c \
        '. "$HOME/.config/ghidmgt/shell.sh"; printf %s "$GH_CONFIG_DIR"')" "$ghdir"
    eq "$(ghidmgt exec work sh -c 'printf %s "$GH_CONFIG_DIR"')" "$ghdir"
    cmd="$(ghidmgt exec work sh -c 'printf %s "$GIT_SSH_COMMAND"')"
    eval "set -- $cmd"
    eq "$3" "$key"
    eq "$(eval "$(ghidmgt env work)"; printf %s "$GH_CONFIG_DIR")" "$ghdir"
}

# ---------------------------------------------------------------------------
# Shell resolvers
# ---------------------------------------------------------------------------
setup_two_identities() {
    ghidmgt add work --root "$HOME/work" >/dev/null
    ghidmgt add personal --root "$HOME/projects" --gh-config-dir "$HOME/.config/gh" >/dev/null
    mkdir -p "$HOME/work/app" "$HOME/projects/app" "$HOME/elsewhere"
    ln -s "$HOME/work/app" "$HOME/projects/link-to-work"
}

test_zsh_resolver() {
    [ -n "$ZSH" ] || { echo "zsh not installed; skipping"; return 0; }
    setup_two_identities
    probe='source "$HOME/.config/ghidmgt/shell.zsh"; print -r -- "${GHIDMGT_IDENTITY:-none}|${GH_CONFIG_DIR:-unset}"'

    eq "$(cd "$HOME/work/app" && "$ZSH" -f -c "$probe")" "work|$HOME/.config/gh-work"
    eq "$(cd "$HOME/projects/app" && "$ZSH" -f -c "$probe")" "personal|$HOME/.config/gh"
    eq "$(cd "$HOME/elsewhere" && GH_CONFIG_DIR=stale "$ZSH" -f -c "$probe")" "none|unset"
    # A symlink resolves the way git resolves it: to the real path's owner.
    eq "$(cd "$HOME/projects/link-to-work" && "$ZSH" -f -c "$probe")" "work|$HOME/.config/gh-work"
    eq "$(cd "$HOME/work/app" && GHIDMGT_DISABLE=1 "$ZSH" -f -c "$probe")" "none|unset"

    # Interactive shells follow cd through the chpwd hook.
    out="$(cd "$HOME/elsewhere" && "$ZSH" -f -i -c \
        'source "$HOME/.config/ghidmgt/shell.zsh"; cd "$HOME/work/app"; print -r -- "$GHIDMGT_IDENTITY"' 2>/dev/null)"
    eq "$out" work
}

test_bash_and_sh_resolver() {
    setup_two_identities
    probe='. "$HOME/.config/ghidmgt/shell.sh"; printf "%s|%s" "${GHIDMGT_IDENTITY:-none}" "${GH_CONFIG_DIR:-unset}"'

    eq "$(cd "$HOME/work/app" && "$TEST_BASH" --norc --noprofile -c "$probe")" "work|$HOME/.config/gh-work"
    eq "$(cd "$HOME/projects/app" && sh -c "$probe")" "personal|$HOME/.config/gh"
    eq "$(cd "$HOME/elsewhere" && GH_CONFIG_DIR=stale sh -c "$probe")" "none|unset"
    eq "$(cd "$HOME/projects/link-to-work" && sh -c "$probe")" "work|$HOME/.config/gh-work"

    # Interactive bash re-resolves from PROMPT_COMMAND, and only hooks once.
    out="$("$TEST_BASH" --norc --noprofile -i -c \
        '. "$HOME/.config/ghidmgt/shell.sh"; . "$HOME/.config/ghidmgt/shell.sh"; printf %s "$PROMPT_COMMAND"' 2>/dev/null)"
    eq "$out" "_ghidmgt_apply"
    out="$(cd "$HOME/elsewhere" && "$TEST_BASH" --norc --noprofile -c \
        '. "$HOME/.config/ghidmgt/shell.sh"; cd "$HOME/work/app"; _ghidmgt_apply; printf %s "$GHIDMGT_IDENTITY"')"
    eq "$out" work
}

# ---------------------------------------------------------------------------
# env / exec
# ---------------------------------------------------------------------------
test_env_and_exec() {
    ghidmgt add work --root "$HOME/work" --email w@example.com >/dev/null
    out="$(ghidmgt env work)"
    has "$out" "export GHIDMGT_IDENTITY=work"
    has "$out" "GIT_AUTHOR_EMAIL=w@example.com"
    has "$out" "GIT_SSH_COMMAND="
    mkdir -p "$HOME/work/app"
    eq "$(cd "$HOME/work/app" && ghidmgt env | head -n 1)" "export GHIDMGT_IDENTITY=work GHIDMGT_DISABLE=1"

    out="$(GH_TOKEN=leak GITHUB_TOKEN=leak GIT_CONFIG_GLOBAL=/x GIT_SSH_COMMAND=stale ghidmgt exec work env)"
    lacks "$out" "GH_TOKEN="
    lacks "$out" "GITHUB_TOKEN="
    lacks "$out" "GIT_CONFIG_GLOBAL="
    lacks "$out" "GIT_SSH_COMMAND=stale"
    has "$out" "GH_CONFIG_DIR=$HOME/.config/gh-work"
    has "$out" "GIT_COMMITTER_EMAIL=w@example.com"
    has "$out" "GHIDMGT_IDENTITY=work"
    has "$out" "GHIDMGT_DISABLE=1"
    has "$(must_fail ghidmgt exec work)" "usage"
}

test_exec_and_env_identity_survives_child_shells() {
    [ -n "$ZSH" ] || { echo "zsh not installed; skipping"; return 0; }
    ghidmgt add work --root "$HOME/work" >/dev/null
    ghidmgt add personal --root "$HOME/projects" --gh-config-dir "$HOME/.config/gh" >/dev/null
    printf '[[ -r "$HOME/.config/ghidmgt/shell.zsh" ]] && source "$HOME/.config/ghidmgt/shell.zsh"\n' > "$HOME/.zshenv"
    mkdir -p "$HOME/projects/app" "$HOME/elsewhere"
    probe='print -r -- "${GH_CONFIG_DIR:-unset}"'

    # Control: a plain zsh resolves from its directory.
    eq "$(cd "$HOME/projects/app" && "$ZSH" -c "$probe")" "$HOME/.config/gh"
    # A zsh started by `ghidmgt exec` reads .zshenv too, and must keep the identity.
    eq "$(cd "$HOME/elsewhere" && ghidmgt exec work "$ZSH" -c "$probe")" "$HOME/.config/gh-work"
    eq "$(cd "$HOME/projects/app" && ghidmgt exec work "$ZSH" -c "$probe")" "$HOME/.config/gh-work"
    eq "$(cd "$HOME/projects/app" && eval "$(ghidmgt env work)" && "$ZSH" -c "$probe")" "$HOME/.config/gh-work"
}

# ---------------------------------------------------------------------------
# login / keygen (gh stubbed)
# ---------------------------------------------------------------------------
test_login_records_the_authenticated_user() {
    use_gh_stub
    ghidmgt add work --root "$HOME/work" >/dev/null
    GH_STUB_LOGIN=octo-work GH_TOKEN=leak ghidmgt login work >/dev/null 2>&1
    eq "$(field work ID_GH_USER)" octo-work
    calls="$(cat "$HOME/gh-calls.log")"
    has "$calls" "$HOME/.config/gh-work|auth login --hostname github.com --git-protocol ssh"
    eq "$(mode_of "$HOME/.config/gh-work")" 700
}

test_keygen_prints_an_existing_key() {
    ghidmgt add work --root "$HOME/work" >/dev/null
    fake_key "$HOME/.ssh/id_ed25519_work"
    echo "ssh-ed25519 AAAATEST work" > "$HOME/.ssh/id_ed25519_work.pub"
    out="$(ghidmgt keygen work)"
    has "$out" "key already exists"
    has "$out" "ssh-ed25519 AAAATEST work"
}

# ---------------------------------------------------------------------------
# rm --purge
# ---------------------------------------------------------------------------
test_purge_logs_out_every_account_then_deletes() {
    use_gh_stub
    ghidmgt add work --root "$HOME/work" >/dev/null
    fake_gh_login "$HOME/.config/gh-work" alice bob
    ghidmgt rm work --purge -y >/dev/null 2>&1
    absent "$HOME/.config/gh-work"
    calls="$(cat "$HOME/gh-calls.log")"
    has "$calls" "$HOME/.config/gh-work|auth logout --hostname github.com --user alice"
    has "$calls" "$HOME/.config/gh-work|auth logout --hostname github.com --user bob"
}

test_purge_keeps_the_dir_when_logout_fails() {
    use_gh_stub
    ghidmgt add work --root "$HOME/work" >/dev/null
    fake_gh_login "$HOME/.config/gh-work" alice
    out="$(GH_STUB_LOGOUT_RC=1 must_fail ghidmgt rm work --purge -y)"
    has "$out" "kept ~/.config/gh-work"
    exists "$HOME/.config/gh-work/hosts.yml"
    absent "$HOME/.config/ghidmgt/identities/work.conf"
}

test_purge_skips_an_account_another_identity_uses() {
    use_gh_stub
    ghidmgt add a --root "$HOME/a" --gh-user alice >/dev/null
    ghidmgt add b --root "$HOME/b" --gh-user alice >/dev/null
    fake_gh_login "$HOME/.config/gh-a" alice
    out="$(ghidmgt rm a --purge -y 2>&1)"
    has "$out" "kept the gh token for alice"
    lacks "$(cat "$HOME/gh-calls.log")" "auth logout"
    absent "$HOME/.config/gh-a"
}

test_purge_declined_or_eof_keeps_everything() {
    use_gh_stub
    ghidmgt add work --root "$HOME/work" >/dev/null
    fake_gh_login "$HOME/.config/gh-work" alice
    ghidmgt rm work --purge </dev/null >/dev/null 2>&1
    exists "$HOME/.config/gh-work/hosts.yml"
    lacks "$(cat "$HOME/gh-calls.log")" "auth logout"
}

test_purge_refuses_dangerous_dirs() {
    use_gh_stub
    mkdir -p "$HOME/stuff/work" "$HOME/random"
    echo keep > "$HOME/random/notes.txt"

    ghidmgt add home --root "$HOME/h" --gh-config-dir '~' >/dev/null
    has "$(must_fail ghidmgt rm home --purge -y)" "home directory"
    exists "$HOME/.config/ghidmgt/identities/home.conf"

    ghidmgt add parent --root "$HOME/stuff/work" --gh-config-dir "$HOME/stuff" >/dev/null
    has "$(must_fail ghidmgt rm parent --purge -y)" "contains the managed root"

    ghidmgt add rnd --root "$HOME/r" --gh-config-dir "$HOME/random" >/dev/null
    has "$(must_fail ghidmgt rm rnd --purge -y)" "does not look like a gh config dir"
    exists "$HOME/random/notes.txt"

    ghidmgt add one --root "$HOME/one" --gh-config-dir "$HOME/.config/gh-shared" >/dev/null
    ghidmgt add two --root "$HOME/two" --gh-config-dir "$HOME/.config/gh-shared" >/dev/null
    fake_gh_login "$HOME/.config/gh-shared" alice
    has "$(must_fail ghidmgt rm one --purge -y)" "identity two also uses it"
    exists "$HOME/.config/gh-shared/hosts.yml"

    lacks "$(cat "$HOME/gh-calls.log")" "auth logout"
    # Nothing was unwired by any refusal.
    eq "$(ghidmgt list | grep -c '^[a-z]')" 5
}

# ---------------------------------------------------------------------------
# check / doctor
# ---------------------------------------------------------------------------
setup_healthy_work() {
    ghidmgt add work --root "$HOME/work" --email w@example.com --gh-user octo-work >/dev/null
    fake_key "$HOME/.ssh/id_ed25519_work"
    fake_gh_login "$HOME/.config/gh-work" octo-work
    git init -q "$HOME/work/app"
}

test_check_offline_passes_for_a_healthy_identity() {
    setup_healthy_work
    out="$(ghidmgt check --offline --path "$HOME/work/app")"
    has "$out" "resolves to identity work"
    has "$out" "commits here are authored as w@example.com"
    has "$out" "is wired correctly"

    git -C "$HOME/work/app" config user.email someone@else.example
    has "$(must_fail ghidmgt check --offline --path "$HOME/work/app")" "would be authored as 'someone@else.example'"
}

test_check_flags_a_worktree_under_another_root() {
    setup_healthy_work
    ghidmgt add client --root "$HOME/client" --email c@client.example >/dev/null
    git -C "$HOME/work/app" commit -q --allow-empty -m init
    mkdir -p "$HOME/client"
    git -C "$HOME/work/app" worktree add -q "$HOME/client/wt"
    has "$(must_fail ghidmgt check --offline --path "$HOME/client/wt")" "this is a worktree whose git dir lives under 'work'"
}

test_doctor_passes_on_a_clean_machine() {
    setup_healthy_work
    printf '# >>> ghidmgt shell integration >>>\n[[ -r "$HOME/.config/ghidmgt/shell.zsh" ]] && source "$HOME/.config/ghidmgt/shell.zsh"\n# <<< ghidmgt shell integration <<<\n' > "$HOME/.zshenv"
    out="$(ghidmgt doctor)"
    has "$out" "no problems found"
}

test_doctor_finds_cross_account_leaks() {
    setup_healthy_work
    printf '[[ -r "$HOME/.config/ghidmgt/shell.zsh" ]] && source "$HOME/.config/ghidmgt/shell.zsh"\n' > "$HOME/.zshenv"

    has "$(GH_TOKEN=x must_fail ghidmgt doctor)" "GH_TOKEN/GITHUB_TOKEN is exported"
    has "$(GIT_CONFIG_GLOBAL=/x must_fail ghidmgt doctor)" "GIT_CONFIG_GLOBAL is set"

    printf 'export GITHUB_TOKEN=ghp_%s\n' 0123456789abcdefghij0123456789abcdef > "$HOME/.bashrc"
    has "$(must_fail ghidmgt doctor)" "GitHub token literal exported from: ~/.bashrc"
    : > "$HOME/.bashrc"

    printf 'Host github.com\n    IdentityFile ~/.ssh/id_rsa\n' >> "$HOME/.ssh/config"
    has "$(must_fail ghidmgt doctor)" "unmanaged IdentityFile applies to github.com"
    printf 'Host *\n    ServerAliveInterval 60\n' > "$HOME/.ssh/config"
    ghidmgt sync >/dev/null

    git config --global credential.helper store
    : > "$HOME/.git-credentials"
    has "$(must_fail ghidmgt doctor)" "one plaintext store shared by every account"
    git config --global --unset credential.helper
    rm "$HOME/.git-credentials"

    printf '[includeIf "gitdir:~/work/"]\n\tpath = ~/old-work.gitconfig\n' >> "$HOME/.gitconfig"
    has "$(must_fail ghidmgt doctor)" "unmanaged includeIf"
}

test_doctor_flags_the_unwired_login_shell() {
    setup_healthy_work
    printf '[[ -r "$HOME/.config/ghidmgt/shell.zsh" ]] && source "$HOME/.config/ghidmgt/shell.zsh"\n' > "$HOME/.zshenv"
    has "$(SHELL=/bin/bash must_fail ghidmgt doctor)" "your shell is bash but only ~/.zshenv sources ghidmgt"
    has "$(SHELL=/bin/zsh ghidmgt doctor)" "no problems found"
}

# ---------------------------------------------------------------------------
# install.sh
# ---------------------------------------------------------------------------
install() { GHIDMGT_BIN_DIR="$HOME/.local/bin" "$REPO/install.sh" "$@"; }

test_install_wires_zsh_and_uninstalls_cleanly() {
    [ -n "$ZSH" ] || { echo "zsh not installed; skipping"; return 0; }
    printf 'export EDITOR=vi\n' > "$HOME/.zshenv"
    out="$(SHELL=/bin/zsh install 2>&1)"
    has "$out" "wired ~/.zshenv"
    has "$out" "No identities registered yet"
    eq "$(readlink "$HOME/.local/bin/ghidmgt")" "$REPO/ghidmgt"
    zshenv="$(cat "$HOME/.zshenv")"
    has "$zshenv" "export EDITOR=vi"
    has "$zshenv" '[[ -r "$HOME/.config/ghidmgt/shell.zsh" ]] && source "$HOME/.config/ghidmgt/shell.zsh"'
    ls "$HOME"/.zshenv.bak.* >/dev/null

    SHELL=/bin/zsh install >/dev/null 2>&1
    eq "$(count "$HOME/.zshenv" '>>> ghidmgt shell integration >>>')" 1

    # End to end: a plain non-interactive zsh in a root picks up the identity.
    "$HOME/.local/bin/ghidmgt" add work --root "$HOME/work" >/dev/null
    mkdir -p "$HOME/work/app"
    eq "$(cd "$HOME/work/app" && "$ZSH" -c 'print -r -- $GH_CONFIG_DIR')" "$HOME/.config/gh-work"

    install --uninstall >/dev/null 2>&1
    absent "$HOME/.local/bin/ghidmgt"
    eq "$(cat "$HOME/.zshenv")" "export EDITOR=vi"
}

test_install_keeps_a_symlinked_rc_file() {
    mkdir -p "$HOME/dotfiles"
    printf 'export EDITOR=vi\n' > "$HOME/dotfiles/bashrc"
    chmod 600 "$HOME/dotfiles/bashrc"
    ln -s dotfiles/bashrc "$HOME/.bashrc"
    SHELL=/bin/bash install >/dev/null 2>&1
    has "$(cat "$HOME/dotfiles/bashrc")" "ghidmgt shell integration"
    install --uninstall >/dev/null 2>&1
    [ -L "$HOME/.bashrc" ] || fail_test "~/.bashrc was replaced by a regular file"
    eq "$(cat "$HOME/dotfiles/bashrc")" "export EDITOR=vi"
    eq "$(mode_of "$HOME/dotfiles/bashrc")" 600
}

test_install_wires_bash() {
    out="$(SHELL=/bin/bash install 2>&1)"
    has "$out" "wired ~/.bashrc"
    absent "$HOME/.zshenv"
    has "$(cat "$HOME/.bashrc")" '[ -r "$HOME/.config/ghidmgt/shell.sh" ] && . "$HOME/.config/ghidmgt/shell.sh"'

    "$HOME/.local/bin/ghidmgt" add work --root "$HOME/work" >/dev/null
    mkdir -p "$HOME/work/app"
    eq "$(cd "$HOME/work/app" && "$TEST_BASH" -i -c 'printf %s "$GH_CONFIG_DIR"' 2>/dev/null)" "$HOME/.config/gh-work"

    install --uninstall >/dev/null 2>&1
    lacks "$(cat "$HOME/.bashrc")" "ghidmgt"
}

test_install_shell_selection() {
    install --shell both >/dev/null 2>&1
    has "$(cat "$HOME/.zshenv")" "shell.zsh"
    has "$(cat "$HOME/.bashrc")" "shell.sh"
    has "$(SHELL=/usr/bin/fish must_fail install)" "pass --shell zsh, bash or both"
    has "$(must_fail install --shell tcsh)" "--shell must be zsh, bash or both"
    has "$(must_fail install --bogus)" "unknown option"
}

test_install_honours_a_custom_ghidmgt_home() {
    GHIDMGT_HOME="$HOME/custom-ghidmgt" SHELL=/bin/bash install >/dev/null 2>&1
    has "$(cat "$HOME/.bashrc")" ". \"$HOME/custom-ghidmgt/shell.sh\""
    exists "$HOME/custom-ghidmgt/shell.sh"
    has "$(GHIDMGT_HOME="$HOME/my ghidmgt" SHELL=/bin/bash must_fail install)" "GHIDMGT_HOME must not contain"
}

test_install_suggests_identities_from_existing_gh_logins() {
    fake_gh_login "$HOME/.config/gh-acme" acme-dev
    out="$(SHELL=/bin/bash install 2>&1)"
    has "$out" "ghidmgt add acme --root ~/CHANGE_ME"
    has "$out" "--gh-user acme-dev --gh-config-dir ~/.config/gh-acme"
}

# ---------------------------------------------------------------------------
# Upgrading from ghid, this project's old name
# ---------------------------------------------------------------------------
# What a ghid install left behind: its config dir, an includeIf block and an
# ssh block under the "ghid" prefix, and its zsh rc block.
fake_ghid_install() {
    local old="$HOME/.config/ghid"
    mkdir -p "$old/identities" "$old/git" "$HOME/.ssh"
    chmod 700 "$old" "$old/identities"
    printf 'ID_ROOTS=%q\nID_GIT_NAME=%q\nID_GIT_EMAIL=%q\nID_GH_USER=\nID_GH_CONFIG_DIR=%q\nID_SSH_KEY=%q\nID_SSH_ALIAS=github.com-work\n' \
        "$HOME/work" "Test User" w@example.com "$HOME/.config/gh-work" "$HOME/.ssh/id_ed25519_work" \
        > "$old/identities/work.conf"
    chmod 600 "$old/identities/work.conf"
    printf '[user]\n\temail = w@example.com\n' > "$old/git/work.gitconfig"
    printf '\n# >>> ghid: includeIf >>>\n[includeIf "gitdir:~/work/"]\n\tpath = ~/.config/ghid/git/work.gitconfig\n# <<< ghid: includeIf <<<\n' \
        >> "$HOME/.gitconfig"
    printf '# >>> ghid: work >>>\nHost github.com-work\n    HostName github.com\n# <<< ghid: work <<<\n' \
        > "$HOME/.ssh/config"
    printf 'export EDITOR=vi\n\n# >>> ghid shell integration >>>\n[[ -r "$HOME/.config/ghid/shell.zsh" ]] && source "$HOME/.config/ghid/shell.zsh"\n# <<< ghid shell integration <<<\n' \
        > "$HOME/.zshenv"
}

test_first_run_migrates_a_ghid_setup() {
    fake_ghid_install
    out="$(ghidmgt list 2>&1)"
    has "$out" "ghid is now ghidmgt: moved ~/.config/ghid to ~/.config/ghidmgt"
    has "$out" "~/work"
    absent "$HOME/.config/ghid"
    exists "$HOME/.config/ghidmgt/identities/work.conf"

    gc="$(cat "$HOME/.gitconfig")"
    lacks "$gc" "# >>> ghid: "
    has "$gc" "# >>> ghidmgt: includeIf >>>"
    has "$gc" "path = ~/.config/ghidmgt/git/work.gitconfig"
    sc="$(cat "$HOME/.ssh/config")"
    lacks "$sc" "# >>> ghid: "
    has "$sc" "# >>> ghidmgt: work >>>"
    eq "$(count "$HOME/.ssh/config" 'Host github.com-work')" 1

    git init -q "$HOME/work/app"
    eq "$(git -C "$HOME/work/app" config user.email)" w@example.com
    # The rc block is install.sh's to replace; doctor points at it meanwhile.
    has "$(must_fail ghidmgt doctor)" "~/.zshenv still has the old ghid block"
}

test_migration_keeps_stdout_clean_for_eval() {
    fake_ghid_install
    mkdir -p "$HOME/work/app"
    out="$(cd "$HOME/work/app" && ghidmgt env 2>/dev/null)"
    eq "$(printf '%s\n' "$out" | head -n 1)" "export GHIDMGT_IDENTITY=work GHIDMGT_DISABLE=1"
    exists "$HOME/.config/ghidmgt/identities/work.conf"
}

test_an_existing_ghidmgt_home_is_never_overwritten() {
    fake_ghid_install
    mkdir -p "$HOME/.config/ghidmgt"
    has "$(ghidmgt list 2>&1)" "ignoring ~/.config/ghid"
    exists "$HOME/.config/ghid/identities/work.conf"
    absent "$HOME/.config/ghidmgt/identities/work.conf"
}

test_install_replaces_ghid_wiring() {
    fake_ghid_install
    mkdir -p "$HOME/.local/bin"
    # After `git pull`, the old symlink into this clone dangles.
    ln -s "$REPO/ghid" "$HOME/.local/bin/ghid"
    # $SHELL says bash, but zsh was wired before: both end up wired.
    out="$(SHELL=/bin/bash install 2>&1)"
    has "$out" "removed the old ~/.local/bin/ghid symlink"
    [ ! -L "$HOME/.local/bin/ghid" ] || fail_test "old ghid symlink still present"
    has "$out" "removed the old ghid block from ~/.zshenv"
    has "$out" "wired ~/.zshenv"
    has "$out" "wired ~/.bashrc"
    zshenv="$(cat "$HOME/.zshenv")"
    lacks "$zshenv" "ghid shell integration >>>"
    lacks "$zshenv" ".config/ghid/"
    has "$zshenv" "# >>> ghidmgt shell integration >>>"
    has "$zshenv" "export EDITOR=vi"
    absent "$HOME/.config/ghid"
    exists "$HOME/.config/ghidmgt/identities/work.conf"
    has "$(SHELL=/bin/zsh ghidmgt doctor 2>&1 || true)" "resolver sourced from ~/.zshenv ~/.bashrc"

    # A ghid installed from somewhere else is not ours to delete.
    ln -s /opt/elsewhere/ghid "$HOME/.local/bin/ghid"
    has "$(SHELL=/bin/bash install 2>&1)" "an older ghid is still installed at ~/.local/bin/ghid"
    [ -L "$HOME/.local/bin/ghid" ] || fail_test "a foreign ghid symlink was removed"
}

# ---------------------------------------------------------------------------
printf 'ghidmgt tests: %s, zsh %s\n\n' "$("$TEST_BASH" -c 'echo "bash $BASH_VERSION"')" "${ZSH:+$("$ZSH" -c 'echo $ZSH_VERSION')}"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    run "$t"
done
printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || { printf 'failed:%s\n' "$FAILED_NAMES"; exit 1; }
