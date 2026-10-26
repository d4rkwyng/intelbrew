#!/bin/bash
# Offline tests for install.sh. Never touches the real HOME, Homebrew or network:
# each case gets a temp HOME and prefix, stub uname/sw_vers/sysctl/xcode-select/
# pkgutil/sudo/brew on PATH, and a git wrapper that fakes the Homebrew/brew clone
# and otherwise runs real git against temp repos (the fork URL is rewritten to a
# local bare repo with url.insteadOf).
#
#   bash tests/test_install.sh
# shellcheck disable=SC2016  # single-quoted $VARs are expanded by child shells
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$HERE/../install.sh"
REAL_GIT="$(PATH=/usr/bin:/bin command -v git)"
FORK_URL="https://github.com/d4rkwyng/intelbrew-core"
UPSTREAM_URL="https://github.com/Homebrew/homebrew-core"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/intelbrew-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0; failed_names=()

# ---- shared fixtures: the "fork" bare repo -----------------------------------
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
"$REAL_GIT" config --file "$GIT_CONFIG_GLOBAL" user.name test
"$REAL_GIT" config --file "$GIT_CONFIG_GLOBAL" user.email test@example.invalid
"$REAL_GIT" config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
"$REAL_GIT" config --file "$GIT_CONFIG_GLOBAL" advice.detachedHead false
"$REAL_GIT" config --file "$GIT_CONFIG_GLOBAL" url."file://$ROOT/fork.git".insteadOf "$FORK_URL"
"$REAL_GIT" config --file "$GIT_CONFIG_GLOBAL" url."file://$ROOT/upstream.git".insteadOf "$UPSTREAM_URL"
"$REAL_GIT" init -q "$ROOT/forksrc"
echo one >"$ROOT/forksrc/Formula.rb"
"$REAL_GIT" -C "$ROOT/forksrc" add Formula.rb
"$REAL_GIT" -C "$ROOT/forksrc" commit -qm "upstream commit"
"$REAL_GIT" clone -q --bare "$ROOT/forksrc" "$ROOT/upstream.git"
echo two >>"$ROOT/forksrc/Formula.rb"
"$REAL_GIT" -C "$ROOT/forksrc" commit -qam "intelbrew bottle blocks"
"$REAL_GIT" clone -q --bare "$ROOT/forksrc" "$ROOT/fork.git"
FORK_MAIN="$("$REAL_GIT" -C "$ROOT/fork.git" rev-parse main)"

# ---- stubs ---------------------------------------------------------------------
STUBS="$ROOT/stubs"; mkdir -p "$STUBS"
cat >"$STUBS/uname" <<'S'
#!/bin/bash
case "${1:-}" in -s) echo Darwin ;; -m) echo "${STUB_ARCH:-x86_64}" ;; *) echo Darwin ;; esac
S
cat >"$STUBS/sw_vers" <<'S'
#!/bin/bash
[[ "${1:-}" == -productVersion ]] && echo "${STUB_MACOS:-15.3.1}"
S
cat >"$STUBS/sysctl" <<'S'
#!/bin/bash
[[ "${1:-}" == -n ]] && shift
case "${1:-}" in
  sysctl.proc_translated) echo "${STUB_TRANSLATED:-0}" ;;
  hw.optional.arm64) [[ -n "${STUB_ARM64_HW:-}" ]] && echo "$STUB_ARM64_HW" || exit 1 ;;
  hw.model) echo "${STUB_MODEL:-MacPro6,1}" ;;
  machdep.cpu.features) echo "${STUB_FEATURES:-FPU VME SSE3 PCLMULQDQ SSSE3 CX16 SSE4.1 SSE4.2 POPCNT AES XSAVE AVX F16C}" ;;
  *) exit 1 ;;
esac
S
cat >"$STUBS/xcode-select" <<'S'
#!/bin/bash
[[ "${STUB_CLT:-yes}" == yes ]] || exit 2
echo /usr/bin    # any existing directory stands in for /Library/Developer/CommandLineTools
S
cat >"$STUBS/pkgutil" <<'S'
#!/bin/bash
[[ "${STUB_PKGUTIL:-no}" == yes ]] || exit 1
echo "package-id: com.apple.pkg.CLTools_Executables"
S
cat >"$STUBS/sudo" <<'S'
#!/bin/bash
echo "sudo $*" >>"$STUB_LOG"; echo "sudo must not be called in tests" >&2; exit 1
S
cat >"$STUBS/git" <<S
#!/bin/bash
echo "git \$*" >>"\$STUB_LOG"
if [[ "\${1:-}" == clone && "\${2:-}" == https://github.com/Homebrew/brew ]]; then
  mkdir -p "\$3/bin" && "$REAL_GIT" init -q "\$3" && cp "$STUBS/brew-impl" "\$3/bin/brew" && exit 0
fi
exec "$REAL_GIT" "\$@"
S
cat >"$STUBS/brew-impl" <<S
#!/bin/bash
echo "brew \$* [API=\${HOMEBREW_NO_INSTALL_FROM_API:-} REMOTE=\${HOMEBREW_CORE_GIT_REMOTE:-}]" >>"\$STUB_LOG"
core="\$INTELBREW_PREFIX/Homebrew/Library/Taps/homebrew/homebrew-core"
case "\$*" in
  "--repository homebrew/core") echo "\$core" ;;
  --repository) echo "\$INTELBREW_PREFIX/Homebrew" ;;
  "info --json=v2 --installed")
    if [[ -n "\${STUB_INFO_JSON:-}" ]]; then cat "\$STUB_INFO_JSON"; else echo '{"formulae":[],"casks":[]}'; fi ;;
  "tap homebrew/core")
    "$REAL_GIT" clone -q "\${HOMEBREW_CORE_GIT_REMOTE}" "\$core" || exit 1
    [[ -z "\${STUB_TAP_ORIGIN:-}" ]] || "$REAL_GIT" -C "\$core" remote set-url origin "\$STUB_TAP_ORIGIN" ;;
  update)
    echo "brewenv BREW_GIT_REMOTE=\${HOMEBREW_BREW_GIT_REMOTE:-}" >>"\$STUB_LOG"
    # cmd/update.sh: a non-default HOMEBREW_BREW_GIT_REMOTE becomes brew's origin.
    if [[ -n "\${HOMEBREW_BREW_GIT_REMOTE:-}" && "\$HOMEBREW_BREW_GIT_REMOTE" != https://github.com/Homebrew/brew ]]; then
      "$REAL_GIT" -C "\$INTELBREW_PREFIX/Homebrew" remote set-url origin "\$HOMEBREW_BREW_GIT_REMOTE" 2>/dev/null \
        || "$REAL_GIT" -C "\$INTELBREW_PREFIX/Homebrew" remote add origin "\$HOMEBREW_BREW_GIT_REMOTE"
    fi
    [[ -z "\${STUB_UPDATE_ORIGIN:-}" ]] || "$REAL_GIT" -C "\$core" remote set-url origin "\$STUB_UPDATE_ORIGIN" ;;
  *) echo "brew stub: unhandled: \$*" >&2; exit 1 ;;
esac
S
chmod +x "$STUBS"/*

# ---- harness ---------------------------------------------------------------------
new_case() {   # fresh HOME + prefix for one test case; sets T, H, P, LOG
  T="$(mktemp -d "$ROOT/case.XXXXXX")"
  H="$T/home"; P="$T/prefix"; LOG="$T/calls.log"
  mkdir -p "$H" "$P"; : >"$LOG"
}
run_install() {  # run_install [extra env...]; output in $OUT, status in $RC
  OUT="$(env -i PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$H" SHELL="${SH:-/bin/zsh}" \
    TMPDIR="$T" INTELBREW_PREFIX="$P" INTELBREW_YES=1 STUB_LOG="$LOG" USER="$(id -un)" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" "$@" \
    /bin/bash "$INSTALL" </dev/null 2>&1)"
  RC=$?
}
make_existing() {  # existing /usr/local-style install; $1 = core origin or "none"
  mkdir -p "$P/bin" "$P/Homebrew/bin"
  "$REAL_GIT" init -q "$P/Homebrew"
  cp "$STUBS/brew-impl" "$P/Homebrew/bin/brew"
  ln -s ../Homebrew/bin/brew "$P/bin/brew"
  if [[ "$1" != none ]]; then
    local core="$P/Homebrew/Library/Taps/homebrew/homebrew-core"
    "$REAL_GIT" clone -q "file://$ROOT/upstream.git" "$core"
    "$REAL_GIT" -C "$core" remote set-url origin "$1"
  fi
}
core_dir() { echo "$P/Homebrew/Library/Taps/homebrew/homebrew-core"; }
snapshot() { (cd "$T" && find home prefix -type f -o -type l | sort | while read -r f; do
  printf '%s ' "$f"; if [[ -L "$f" ]]; then readlink "$f"; else cksum <"$f"; fi; done
  "$REAL_GIT" -C "$(core_dir)" config --get remote.origin.url 2>/dev/null
  "$REAL_GIT" -C "$(core_dir)" rev-parse HEAD 2>/dev/null
  "$REAL_GIT" -C "$P/Homebrew" config --get remote.origin.url 2>/dev/null); }

CASE=""; case_ok=1
start() { CASE="$1"; case_ok=1; new_case; }
check() {  # check "<description>" <command...>
  local d="$1"; shift
  if ! "$@"; then
    case_ok=0; printf '  FAIL [%s] %s\n' "$CASE" "$d"
  fi
}
finish() {
  if (( case_ok )); then pass=$((pass + 1)); printf 'ok   %s\n' "$CASE"
  else fail=$((fail + 1)); failed_names+=("$CASE"); printf 'FAIL %s\n--- output ---\n%s\n--------------\n' "$CASE" "$OUT"
  fi
}
count() { grep -c -E "$1" "$2" 2>/dev/null || true; }
has() { grep -q -F -- "$1" <<<"$OUT"; }
logged() { grep -q -F -- "$1" "$LOG"; }
remote_is() { [[ "$("$REAL_GIT" -C "$(core_dir)" config --get remote.origin.url)" == "$1" ]]; }
no_backups() { [[ -z "$(find "$H" -name '*.intelbrew-backup-*')" ]]; }

LINE_REMOTE="export HOMEBREW_CORE_GIT_REMOTE=\"$FORK_URL\""
LINE_API="export HOMEBREW_NO_INSTALL_FROM_API=1"

# ---- cases ---------------------------------------------------------------------
start "fresh Mac, zsh: installs, taps fork, writes .zshenv"
run_install
check "exit 0" test "$RC" -eq 0
check "brew symlink" test -L "$P/bin/brew"
check "brew cloned" logged "git clone https://github.com/Homebrew/brew $P/Homebrew"
check "tap ran with env" logged "brew tap homebrew/core [API=1 REMOTE=$FORK_URL]"
check "core origin is fork" remote_is "$FORK_URL"
check "brew update ran" logged "brew update"
check ".zshenv has remote once" test "$(count '^export HOMEBREW_CORE_GIT_REMOTE=' "$H/.zshenv")" = 1
check ".zshenv has api once" test "$(count '^export HOMEBREW_NO_INSTALL_FROM_API=1$' "$H/.zshenv")" = 1
check ".zshenv exact remote line" grep -qxF "$LINE_REMOTE" "$H/.zshenv"
check "no .zprofile created" test ! -e "$H/.zprofile"
# The real-world bug: a NON-login zsh (tmux, IDE terminals) never read .zprofile.
check "non-login zsh sees remote" test "$(env -i HOME="$H" zsh -c 'printf %s "$HOMEBREW_CORE_GIT_REMOTE"')" = "$FORK_URL"
check "non-login zsh sees api" test "$(env -i HOME="$H" zsh -c 'printf %s "$HOMEBREW_NO_INSTALL_FROM_API"')" = 1
check "installer checked non-login shell" has "a new nonlogin zsh shell sees both settings"
check "no .zshrc created" test ! -e "$H/.zshrc"
check "no sudo" bash -c "! grep -q '^sudo' '$LOG'"
before="$(snapshot)"; : >"$LOG"
run_install
check "re-run: exit 0" test "$RC" -eq 0
check "re-run: says nothing to change" has "Nothing to change"
check "re-run: no tree change" test "$before" = "$(snapshot)"
check "re-run: no tap/update" bash -c "! grep -qE '^brew (tap|update)' '$LOG'"
check "re-run: no backups" no_backups
finish

start "existing install, duplicate lines in .zprofile and stale .zshrc line"
make_existing "$FORK_URL"
cat >"$H/.zprofile" <<P
# >>> intelbrew >>>
eval "\$(/usr/local/bin/brew shellenv)"
export HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_CORE_GIT_REMOTE=$FORK_URL
# <<< intelbrew <<<
export PATH="\$HOME/bin:\$PATH"
export HOMEBREW_CORE_GIT_REMOTE=https://github.com/someone/else
export HOMEBREW_CORE_GIT_REMOTE=$FORK_URL
  HOMEBREW_NO_INSTALL_FROM_API=1
# export HOMEBREW_CORE_GIT_REMOTE=commented-out-stays
P
printf 'alias ll="ls -l"\nexport HOMEBREW_CORE_GIT_REMOTE=https://github.com/Homebrew/homebrew-core\n' >"$H/.zshrc"
cp "$H/.zprofile" "$T/zprofile.orig"
run_install
check "exit 0" test "$RC" -eq 0
check "remote line exactly once" test "$(count 'HOMEBREW_CORE_GIT_REMOTE=' "$H/.zprofile")" = 2  # +1 commented line
check "remote line canonical" test "$(count "^$(printf '%s' "$LINE_REMOTE" | sed 's/[.]/\\./g')\$" "$H/.zprofile")" = 1
check "api line once" test "$(count 'HOMEBREW_NO_INSTALL_FROM_API=' "$H/.zprofile")" = 1
check "commented line untouched" grep -qxF "# export HOMEBREW_CORE_GIT_REMOTE=commented-out-stays" "$H/.zprofile"
# shellcheck disable=SC2016  # literal $HOME/$PATH text is intended
check "other lines kept" grep -qxF 'export PATH="$HOME/bin:$PATH"' "$H/.zprofile"
check "no extra block appended" test "$(count '^# >>> intelbrew >>>' "$H/.zprofile")" = 1
check ".zshrc stale value replaced" grep -qxF "$LINE_REMOTE" "$H/.zshrc"
check ".zshrc alias kept" grep -qxF 'alias ll="ls -l"' "$H/.zshrc"
check ".zprofile backup = original" bash -c "cmp -s '$T/zprofile.orig' '$H'/.zprofile.intelbrew-backup-*"
check "core untouched (already fork)" bash -c "! grep -qE '^git -C .* (remote set-url|checkout)' '$LOG'"
check "no tap/update" bash -c "! grep -qE '^brew (tap|update)' '$LOG'"
before="$(snapshot)"
run_install
check "re-run: no change" test "$before" = "$(snapshot)"
check "re-run: nothing to change" has "Nothing to change"
finish

start "existing install, API mode (no core tap): taps the fork"
make_existing none
echo 'export EDITOR=vim' >"$H/.zprofile"
run_install
check "exit 0" test "$RC" -eq 0
check "tapped" logged "brew tap homebrew/core [API=1 REMOTE=$FORK_URL]"
check "origin fork" remote_is "$FORK_URL"
check "block in .zshenv" grep -qxF "$LINE_REMOTE" "$H/.zshenv"
check ".zprofile untouched" grep -qxF 'export EDITOR=vim' "$H/.zprofile"
check ".zprofile has no remote" bash -c "! grep -q HOMEBREW_ '$H/.zprofile'"
finish

start "existing install, core tap on upstream: switches to fork main"
make_existing "$UPSTREAM_URL"
run_install
check "exit 0" test "$RC" -eq 0
check "origin fork" remote_is "$FORK_URL"
check "HEAD = fork main" test "$("$REAL_GIT" -C "$(core_dir)" rev-parse HEAD)" = "$FORK_MAIN"
check "on branch main" test "$("$REAL_GIT" -C "$(core_dir)" symbolic-ref --short HEAD)" = main
check "plan warned about reset" has "local branch \"main\" is reset to origin/main"
check "brew update ran" logged "brew update"
before="$(snapshot)"; : >"$LOG"
run_install
check "re-run: no change" test "$before" = "$(snapshot)"
check "re-run: no git writes" bash -c "! grep -qE '(set-url|checkout|fetch)' '$LOG'"
finish

start "existing core tap with local changes: refuses, changes nothing"
make_existing "$UPSTREAM_URL"
echo dirty >>"$(core_dir)/Formula.rb"
before="$(snapshot)"
run_install
check "nonzero" test "$RC" -ne 0
check "says uncommitted" has "uncommitted changes"
check "nothing changed" test "$before" = "$(snapshot)"
finish

start "bash with no profile: creates .bash_profile"
SH=/bin/bash run_install
check "exit 0" test "$RC" -eq 0
check ".bash_profile remote" grep -qxF "$LINE_REMOTE" "$H/.bash_profile"
check ".bash_profile api" grep -qxF "$LINE_API" "$H/.bash_profile"
check "no .zprofile" test ! -e "$H/.zprofile"
before="$(snapshot)"
SH=/bin/bash run_install
check "re-run: no change" test "$before" = "$(snapshot)"
finish

start "bash with only .profile: edits .profile, doesn't create .bash_profile"
echo 'export FOO=1' >"$H/.profile"
SH=/bin/bash run_install
check "exit 0" test "$RC" -eq 0
check ".profile has remote" grep -qxF "$LINE_REMOTE" "$H/.profile"
check "no .bash_profile" test ! -e "$H/.bash_profile"
check ".bashrc also written (non-login bash)" grep -qxF "$LINE_REMOTE" "$H/.bashrc"
finish

start "bash with duplicate lines in .bash_profile and .bashrc"
printf '%s\n%s\n%s\n' "export HOMEBREW_CORE_GIT_REMOTE=$FORK_URL" "export HOMEBREW_CORE_GIT_REMOTE=$FORK_URL" "export HOMEBREW_NO_INSTALL_FROM_API=1" >"$H/.bash_profile"
printf '%s\n' "export HOMEBREW_CORE_GIT_REMOTE=https://example.invalid/x.git" >"$H/.bashrc"
SH=/bin/bash run_install
check "exit 0" test "$RC" -eq 0
check ".bash_profile remote once" test "$(count 'HOMEBREW_CORE_GIT_REMOTE=' "$H/.bash_profile")" = 1
check ".bashrc fixed" grep -qxF "$LINE_REMOTE" "$H/.bashrc"
before="$(snapshot)"
SH=/bin/bash run_install
check "re-run: no change" test "$before" = "$(snapshot)"
finish

start "ZDOTDIR respected for zsh"
mkdir -p "$H/zdot"
run_install ZDOTDIR="$H/zdot"
check "exit 0" test "$RC" -eq 0
check "zdot/.zshenv written" grep -qxF "$LINE_REMOTE" "$H/zdot/.zshenv"
check "no ~/.zshenv" test ! -e "$H/.zshenv"
finish

start "unknown shell: warns, edits no profile"
SH=/usr/local/bin/fish run_install
check "exit 0" test "$RC" -eq 0
check "warns" has "Unrecognised login shell"
check "no profile files" test -z "$(ls -A "$H")"
finish

start "remote verification failure after tap: fails loudly, profile untouched"
run_install STUB_TAP_ORIGIN="$UPSTREAM_URL"
check "nonzero" test "$RC" -ne 0
check "says FAILED" has "Setup FAILED"
check "no profile written" test ! -e "$H/.zprofile"
check "no brew update" bash -c "! grep -q '^brew update' '$LOG'"
finish

start "remote verification failure after brew update"
run_install STUB_UPDATE_ORIGIN="https://github.com/someone/else"
check "nonzero" test "$RC" -ne 0
check "says FAILED" has "Setup FAILED"
finish

start "brew.env overriding the remote: refuses"
mkdir -p "$H/.homebrew"; echo "HOMEBREW_CORE_GIT_REMOTE=https://github.com/Homebrew/homebrew-core" >"$H/.homebrew/brew.env"
run_install
check "nonzero" test "$RC" -ne 0
check "names brew.env" has "brew.env sets HOMEBREW_CORE_GIT_REMOTE"
check "nothing installed" test ! -e "$P/bin/brew"
finish

# ---- real-world cases (TESTPLAN-realworld.md items 1-8) ---------------------------
STALE="https://github.com/fabiomanz/homebrew-core"
BREW_FORK="https://github.com/d4rkwyng/brew"
interactive() {  # interactive "<answers, one per line>" [env...]: run_install reading answers
  printf '%b' "$1" >"$T/answers"; shift
  run_install INTELBREW_YES=0 INTELBREW_TTY_IN="$T/answers" INTELBREW_TTY_OUT="$T/tty.out" "$@"
}
no_text() { ! grep -q -F -- "$1" <<<"$OUT"; }
line_of() { grep -n -F -- "$1" <<<"$OUT" | head -1 | cut -d: -f1; }
before_in_output() { local a b; a="$(line_of "$1")"; b="$(line_of "$2")"; [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; }

start "item 1: settings only in .zprofile: also written to .zshenv for non-login zsh"
make_existing "$FORK_URL"
printf '%s\n%s\n' "$LINE_API" "$LINE_REMOTE" >"$H/.zprofile"
cp "$H/.zprofile" "$T/zprofile.orig"
check "precondition: non-login zsh misses it" test -z "$(env -i HOME="$H" zsh -c 'printf %s "$HOMEBREW_CORE_GIT_REMOTE"')"
run_install
check "exit 0" test "$RC" -eq 0
check ".zshenv has remote" grep -qxF "$LINE_REMOTE" "$H/.zshenv"
check ".zshenv has api" grep -qxF "$LINE_API" "$H/.zshenv"
check ".zprofile unchanged" cmp -s "$T/zprofile.orig" "$H/.zprofile"
check "non-login zsh sees remote" test "$(env -i HOME="$H" zsh -c 'printf %s "$HOMEBREW_CORE_GIT_REMOTE"')" = "$FORK_URL"
check "installer checked non-login shell" has "a new nonlogin zsh shell sees both settings"
before="$(snapshot)"
run_install
check "re-run: no change" test "$before" = "$(snapshot)"
finish

start "item 2: stale fabiomanz remote in .zprofile, .zshrc and .zshenv at once"
make_existing "$FORK_URL"
printf '%s\nexport HOMEBREW_CORE_GIT_REMOTE=%s\n' "$LINE_API" "$STALE" >"$H/.zprofile"
printf 'alias ll="ls -l"\nexport HOMEBREW_CORE_GIT_REMOTE="%s"\n' "$STALE" >"$H/.zshrc"
printf 'export HOMEBREW_CORE_GIT_REMOTE=%s.git\nexport PATH="/x:$PATH"\nexport HOMEBREW_CORE_GIT_REMOTE=%s\n' "$STALE" "$STALE" >"$H/.zshenv"
run_install HOMEBREW_CORE_GIT_REMOTE="$STALE"
check "exit 0" test "$RC" -eq 0
for f in .zprofile .zshrc .zshenv; do
  check "$f: exactly one remote line" test "$(count 'HOMEBREW_CORE_GIT_REMOTE=' "$H/$f")" = 1
  check "$f: it is the fork" grep -qxF "$LINE_REMOTE" "$H/$f"
  check "$f: backed up" bash -c "ls '$H'/$f.intelbrew-backup-* >/dev/null 2>&1"
done
check "no fabiomanz left outside backups" bash -c "! grep -l fabiomanz '$H'/.zprofile '$H'/.zshrc '$H'/.zshenv"
check ".zshenv api added once" test "$(count 'HOMEBREW_NO_INSTALL_FROM_API=' "$H/.zshenv")" = 1
check ".zshrc alias kept" grep -qxF 'alias ll="ls -l"' "$H/.zshrc"
check "interactive login zsh sees fork" test "$(env -i HOME="$H" zsh -lic 'printf %s "$HOMEBREW_CORE_GIT_REMOTE"' 2>/dev/null)" = "$FORK_URL"
before="$(snapshot)"
run_install
check "re-run: no change" test "$before" = "$(snapshot)"
check "re-run: nothing to change" has "Nothing to change"
finish

start "item 3: env already right but core origin still upstream: switches, not 'already set up'"
make_existing "$UPSTREAM_URL"
printf '%s\n%s\n' "$LINE_API" "$LINE_REMOTE" >"$H/.zshenv"
run_install HOMEBREW_CORE_GIT_REMOTE="$FORK_URL" HOMEBREW_NO_INSTALL_FROM_API=1
check "exit 0" test "$RC" -eq 0
check "not 'already set up'" no_text "Nothing to change"
check "plan names old origin" has "(was $UPSTREAM_URL)"
check "origin set explicitly" logged "git -C $(core_dir) remote set-url origin $FORK_URL"
check "fetched" logged "git -C $(core_dir) fetch --force origin"
check "reset to main" logged "git -C $(core_dir) checkout --force -B main origin/main"
check "origin fork" remote_is "$FORK_URL"
check "HEAD = fork main" test "$("$REAL_GIT" -C "$(core_dir)" rev-parse HEAD)" = "$FORK_MAIN"
check "verified" has "Verified: homebrew/core origin is $FORK_URL"
check "profile untouched" no_backups
before="$(snapshot)"; : >"$LOG"
run_install HOMEBREW_CORE_GIT_REMOTE="$FORK_URL" HOMEBREW_NO_INSTALL_FROM_API=1
check "re-run: no change" test "$before" = "$(snapshot)"
check "re-run: nothing to change" has "Nothing to change"
check "re-run: no box (this shell is current)" no_text "ACTION NEEDED"
finish

start "item 3: same state with uncommitted changes in core: refuses"
make_existing "$UPSTREAM_URL"
printf '%s\n%s\n' "$LINE_API" "$LINE_REMOTE" >"$H/.zshenv"
echo dirty >>"$(core_dir)/Formula.rb"
before="$(snapshot)"
run_install HOMEBREW_CORE_GIT_REMOTE="$FORK_URL" HOMEBREW_NO_INSTALL_FROM_API=1
check "nonzero" test "$RC" -ne 0
check "says uncommitted" has "uncommitted changes"
check "nothing changed" test "$before" = "$(snapshot)"
finish

start "item 4: started from a shell with a stale HOMEBREW_CORE_GIT_REMOTE: loud box"
run_install HOMEBREW_CORE_GIT_REMOTE="$STALE"
check "exit 0" test "$RC" -eq 0
check "box" has "| ACTION NEEDED"
check "names this terminal's stale value" has "This terminal has a DIFFERENT HOMEBREW_CORE_GIT_REMOTE:"
check "shows the stale value" has "$STALE"
check "exec \$SHELL -l" has "exec /bin/zsh -l"
check "new window" has "open a new window"
check "brew config check" has "brew config | grep -E 'CORE_GIT_REMOTE|NO_INSTALL_FROM_API'"
check "expected remote" has "HOMEBREW_CORE_GIT_REMOTE: $FORK_URL"
check "expected api" has "HOMEBREW_NO_INSTALL_FROM_API: set"
check "box is the last thing printed" test "$(tail -1 <<<"$OUT" | cut -c1-3)" = "+=="
run_install HOMEBREW_CORE_GIT_REMOTE="$STALE"
check "re-run from the same stale shell: still says so" has "This terminal has a DIFFERENT HOMEBREW_CORE_GIT_REMOTE:"
check "re-run: nothing to change" has "Nothing to change"
run_install HOMEBREW_CORE_GIT_REMOTE="$FORK_URL" HOMEBREW_NO_INSTALL_FROM_API=1
check "re-run from a new shell: no box" no_text "ACTION NEEDED"
finish

INFO="$ROOT/installed.json"
cat >"$INFO" <<'J'
{"formulae":[
 {"name":"openssl@4","tap":"homebrew/core","versions":{"stable":"4.0.0","head":null,"bottle":true},"revision":0,"installed":[{"version":"4.1.0"}],"bottle":{"stable":{"files":{"sonoma":{}}}}},
 {"name":"python@3.14","tap":"homebrew/core","versions":{"stable":"3.14.0","head":null,"bottle":true},"revision":0,"installed":[{"version":"3.14.0"},{"version":"3.14.10"}],"bottle":{"stable":{"files":{"arm64_sonoma":{},"sonoma":{}}}}},
 {"name":"samever","tap":"homebrew/core","versions":{"stable":"2.0","head":null,"bottle":true},"revision":2,"installed":[{"version":"2.0_1"}],"bottle":{"stable":{"files":{"sonoma":{}}}}},
 {"name":"lettersuffix","tap":"homebrew/core","versions":{"stable":"1.1.1w","head":null,"bottle":true},"revision":0,"installed":[{"version":"1.1.1"}],"bottle":{"stable":{"files":{"all":{}}}}},
 {"name":"rcinstalled","tap":"homebrew/core","versions":{"stable":"2.0","head":null,"bottle":true},"revision":0,"installed":[{"version":"2.0rc1"}],"bottle":{"stable":{"files":{"ventura":{}}}}},
 {"name":"armonly","tap":"homebrew/core","versions":{"stable":"1.0","head":null,"bottle":true},"revision":0,"installed":[{"version":"1.0"}],"bottle":{"stable":{"files":{"arm64_sonoma":{},"arm64_sequoia":{}}}}},
 {"name":"nobottle","tap":"homebrew/core","versions":{"stable":"1.0","head":null,"bottle":false},"revision":0,"installed":[{"version":"1.0"}],"bottle":{}},
 {"name":"sequoiaonly","tap":"homebrew/core","versions":{"stable":"1.0","head":null,"bottle":true},"revision":0,"installed":[{"version":"1.0"}],"bottle":{"stable":{"files":{"sequoia":{}}}}},
 {"name":"thirdparty","tap":"someone/tools","versions":{"stable":"1.0","head":null,"bottle":false},"revision":0,"installed":[{"version":"9.0"}],"bottle":{}},
 {"name":"headonly","tap":"homebrew/core","versions":{"stable":"1.0","head":"HEAD","bottle":true},"revision":0,"installed":[{"version":"HEAD-abc1234"}],"bottle":{"stable":{"files":{"sonoma":{}}}}}
],"casks":[]}
J

start "items 5+6: newer kegs and missing bottles listed after the switch (Sequoia)"
make_existing "$UPSTREAM_URL"
run_install STUB_INFO_JSON="$INFO" STUB_MACOS=15.3
check "exit 0" test "$RC" -eq 0
check "newer count" has "2 installed formula(e) are NEWER than Intelbrew's version"
check "openssl@4 listed" has "openssl@4 4.1.0 (Intelbrew has 4.0.0)"
check "python@3.14 newest keg listed" has "python@3.14 3.14.10 (Intelbrew has 3.14.0)"
check "won't downgrade note" has "These stay as they are (brew won't downgrade) until Intelbrew catches up;"
check "reinstall note" has "a reinstall would use the older fork version."
check "revision older: not listed" no_text "samever 2.0_1"
check "letter suffix older: not listed" no_text "lettersuffix 1.1.1 "
check "rc older: not listed" no_text "rcinstalled 2.0rc1"
check "other tap: ignored" no_text "thirdparty"
check "HEAD keg: not listed as newer" no_text "headonly HEAD"
check "no-bottle count" has "2 installed formula(e) have no Intelbrew bottle for macOS 15 on Intel; these will build from source"
check "no-bottle names" has "    armonly nobottle"
check "after the switch" before_in_output "Verified: homebrew/core origin" "NEWER than Intelbrew"
check "before the final message" before_in_output "will build from source on" "Intelbrew is set up"
before="$(snapshot)"
run_install STUB_INFO_JSON="$INFO" STUB_MACOS=15.3
check "re-run: no change" test "$before" = "$(snapshot)"
check "re-run: still lists them" has "openssl@4 4.1.0 (Intelbrew has 4.0.0)"
finish

start "item 6: on Sonoma a sequoia-only bottle doesn't count (no newer-OS fallback)"
make_existing "$FORK_URL"
run_install STUB_INFO_JSON="$INFO" STUB_MACOS=14.6
check "exit 0" test "$RC" -eq 0
check "3 without bottle" has "3 installed formula(e) have no Intelbrew bottle for macOS 14 on Intel"
check "names" has "    armonly nobottle sequoiaonly"
finish

start "item 6: long list is wrapped"
make_existing "$FORK_URL"
python3 -c '
import json; print(json.dumps({"formulae":[{"name":"formula-number-%02d" % i,"tap":"homebrew/core","versions":{"stable":"1"},"revision":0,"installed":[{"version":"1"}],"bottle":{}} for i in range(30)],"casks":[]}))' >"$T/many.json"
run_install STUB_INFO_JSON="$T/many.json"
check "count" has "30 installed formula(e) have no Intelbrew bottle"
check "wrapped to <= 76 columns" bash -c "! grep -E '^    formula-number' <<<\"\$0\" | awk 'length > 76 {bad=1} END {exit !bad}'" "$OUT"
check "several lines" test "$(grep -c '^    formula-number' <<<"$OUT")" -ge 5
finish

start "item 7: one-time size/time notice before the core clone"
run_install
check "exit 0" test "$RC" -eq 0
check "notice" has "One-time download: homebrew/core from the fork is about 1.3 GB; expect roughly 5-10 minutes"
check "notice before tap command" bash -c "a=\$(grep -n 'One-time download' <<<\"\$0\" | cut -d: -f1); b=\$(grep -n '^+ .*brew tap homebrew/core' <<<\"\$0\" | cut -d: -f1); [[ \$a -lt \$b ]]" "$OUT"
finish

start "item 7: no clone notice when switching an existing core tap"
make_existing "$UPSTREAM_URL"
run_install
check "exit 0" test "$RC" -eq 0
check "no notice" no_text "One-time download"
finish

brew_fork_state() {  # existing, core on fork, profiles right, brew itself on d4rkwyng/brew
  make_existing "$FORK_URL"
  "$REAL_GIT" -C "$P/Homebrew" remote add origin "$BREW_FORK"
  printf '%s\n%s\n' "$LINE_API" "$LINE_REMOTE" >"$H/.zshenv"
  printf 'export EDITOR=vim\nexport HOMEBREW_BREW_GIT_REMOTE=%s\n' "$BREW_FORK" >"$H/.zprofile"
  printf 'export HOMEBREW_BREW_GIT_REMOTE="%s.git"\n' "$BREW_FORK" >"$H/.zshrc"
}
brew_origin() { "$REAL_GIT" -C "$P/Homebrew" config --get remote.origin.url; }

start "item 8: brew fork with --yes: warns, changes nothing"
brew_fork_state
before="$(snapshot)"
run_install HOMEBREW_BREW_GIT_REMOTE="$BREW_FORK" HOMEBREW_CORE_GIT_REMOTE="$FORK_URL" HOMEBREW_NO_INSTALL_FROM_API=1
check "exit 0" test "$RC" -eq 0
check "warns: brew from a fork" has "Homebrew itself (Homebrew/brew, not the formulae) is set to come from a fork"
check "names env" has "this shell's environment: HOMEBREW_BREW_GIT_REMOTE=$BREW_FORK"
check "names .zprofile" has "$H/.zprofile: HOMEBREW_BREW_GIT_REMOTE=$BREW_FORK"
check "names .zshrc" has "$H/.zshrc: HOMEBREW_BREW_GIT_REMOTE=$BREW_FORK.git"
check "names origin" has "origin of $P/Homebrew: $BREW_FORK"
check "may be behind" has "far behind upstream brew"
check "--yes declines" has "(no: --yes only makes the required changes)"
check "nothing changed" test "$before" = "$(snapshot)"
check "brew origin still fork" test "$(brew_origin)" = "$BREW_FORK"
check "no brew update" bash -c "! grep -q '^brew update' '$LOG'"
check "no backups" no_backups
finish

start "item 8: brew fork, interactive, default (Enter) = No: changes nothing"
brew_fork_state
before="$(snapshot)"
interactive 'S\n\n' HOMEBREW_BREW_GIT_REMOTE="$BREW_FORK"
check "exit 0" test "$RC" -eq 0
check "offered" grep -qF "Reset Homebrew/brew to upstream (https://github.com/Homebrew/brew)? [y/N]" "$T/tty.out"
check "left as is" has "Leaving Homebrew/brew as it is"
check "nothing changed" test "$before" = "$(snapshot)"
check "no backups" no_backups
finish

start "item 8: brew fork, interactive yes: resets origin, removes profile lines, brew update"
brew_fork_state
interactive 'S\ny\nyes\n' HOMEBREW_BREW_GIT_REMOTE="$BREW_FORK" HOMEBREW_CORE_GIT_REMOTE="$FORK_URL" HOMEBREW_NO_INSTALL_FROM_API=1
check "exit 0" test "$RC" -eq 0
check "plan shows origin reset" has "in $P/Homebrew: set origin to https://github.com/Homebrew/brew (was $BREW_FORK)"
check "set-url ran" logged "git -C $P/Homebrew remote set-url origin https://github.com/Homebrew/brew"
check "brew update ran" logged "brew update"
check "brew update env empty" grep -qx "brewenv BREW_GIT_REMOTE=" "$LOG"
check "brew origin upstream after update" test "$(brew_origin)" = "https://github.com/Homebrew/brew"
check "verified" has "Verified: Homebrew/brew origin is https://github.com/Homebrew/brew."
check ".zprofile line removed" bash -c "! grep -q HOMEBREW_BREW_GIT_REMOTE '$H/.zprofile'"
check ".zprofile rest kept" grep -qxF 'export EDITOR=vim' "$H/.zprofile"
check ".zshrc line removed" bash -c "! grep -q HOMEBREW_BREW_GIT_REMOTE '$H/.zshrc'"
check "backups made" bash -c "ls '$H'/.zprofile.intelbrew-backup-* '$H'/.zshrc.intelbrew-backup-* >/dev/null"
check "core untouched" remote_is "$FORK_URL"
check "box: this terminal still has it" has "This terminal still has HOMEBREW_BREW_GIT_REMOTE=$BREW_FORK"
check "box: brew config check" has "brew config | grep BREW_GIT_REMOTE"
before="$(snapshot)"; : >"$LOG"
interactive 'S\n' HOMEBREW_CORE_GIT_REMOTE="$FORK_URL" HOMEBREW_NO_INSTALL_FROM_API=1
check "re-run from a new shell: exit 0" test "$RC" -eq 0
check "re-run: no warning" no_text "come from a fork"
check "re-run: nothing to change" has "Nothing to change"
check "re-run: no change" test "$before" = "$(snapshot)"
finish

start "item 8: fork only in this shell's env: warns, nothing to offer"
make_existing "$FORK_URL"
"$REAL_GIT" -C "$P/Homebrew" remote add origin https://github.com/Homebrew/brew
printf '%s\n%s\n' "$LINE_API" "$LINE_REMOTE" >"$H/.zshenv"
interactive 'S\n' HOMEBREW_BREW_GIT_REMOTE="$BREW_FORK" HOMEBREW_CORE_GIT_REMOTE="$FORK_URL" HOMEBREW_NO_INSTALL_FROM_API=1
check "exit 0" test "$RC" -eq 0
check "warns" has "this shell's environment: HOMEBREW_BREW_GIT_REMOTE=$BREW_FORK"
check "no offer" bash -c "! grep -q 'Reset Homebrew/brew' '$T/tty.out'"
finish

start "item 8: upstream brew (any spelling) is not flagged"
make_existing "$FORK_URL"
"$REAL_GIT" -C "$P/Homebrew" remote add origin https://github.com/homebrew/brew.git
printf '%s\n%s\nexport HOMEBREW_BREW_GIT_REMOTE=https://github.com/Homebrew/brew\n' "$LINE_API" "$LINE_REMOTE" >"$H/.zshenv"
run_install HOMEBREW_CORE_GIT_REMOTE="$FORK_URL" HOMEBREW_NO_INSTALL_FROM_API=1
check "exit 0" test "$RC" -eq 0
check "no warning" no_text "come from a fork"
check "nothing to change" has "Nothing to change"
finish

start "item 9: future patched-brew option is only a marked comment"
check "marker present" grep -q "FUTURE OPTION (owner decision pending, NOT implemented)" "$INSTALL"
check "no option for it" bash -c "! grep -qiE -- '--(patched|fork)-brew|INTELBREW_BREW_' '$INSTALL'"
finish

# Platform checks
platform_case() {  # platform_case "<name>" accept|refuse "<expected text or ->" env...
  local name="$1" want="$2" text="$3"; shift 3
  start "$name"
  run_install "$@"
  if [[ "$want" == accept ]]; then
    check "accepted" test "$RC" -eq 0
    check "installed" test -L "$P/bin/brew"
  else
    check "refused" test "$RC" -ne 0
    check "nothing installed" test ! -e "$P/bin/brew"
    check "no profile" test ! -e "$H/.zprofile"
  fi
  [[ "$text" == - ]] || check "says: $text" has "$text"
  finish
}
platform_case "Sequoia 15.3 accepted"            accept - STUB_MACOS=15.3
platform_case "Sonoma 14.0 accepted"             accept - STUB_MACOS=14.0
platform_case "Tahoe 26.1 accepted"              accept - STUB_MACOS=26.1
platform_case "MacPro6,1 (OCLP, Sequoia) accepted" accept - STUB_MODEL=MacPro6,1 STUB_MACOS=15.7
platform_case "Ventura 13.6 refused"             refuse "older than macOS 14" STUB_MACOS=13.6.7
platform_case "Big Sur 11 refused"               refuse "older than macOS 14" STUB_MACOS=11.7.10
platform_case "Apple Silicon refused"            refuse "Apple Silicon" STUB_ARCH=arm64
platform_case "Rosetta refused"                  refuse "Apple Silicon" STUB_TRANSLATED=1
platform_case "Penryn CPU refused"               refuse "lacks: SSE4.2 POPCNT AES PCLMULQDQ" "STUB_FEATURES=FPU SSE3 SSSE3 SSE4.1"
platform_case "no CLT refused"                   refuse "Command Line Tools are not installed" STUB_CLT=no STUB_PKGUTIL=no
platform_case "CLT via pkgutil fallback accepted" accept - STUB_CLT=no STUB_PKGUTIL=yes

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 )) || { printf 'failed: %s\n' "${failed_names[*]}"; exit 1; }
