#!/bin/bash
# Offline tests for install.sh. Never touches the real HOME, Homebrew or network:
# each case gets a temp HOME and prefix, stub uname/sw_vers/sysctl/xcode-select/
# pkgutil/sudo/brew on PATH, and a git wrapper that fakes the Homebrew/brew clone
# and otherwise runs real git against temp repos (the fork URL is rewritten to a
# local bare repo with url.insteadOf).
#
#   bash tests/test_install.sh
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
  "tap homebrew/core")
    "$REAL_GIT" clone -q "\${HOMEBREW_CORE_GIT_REMOTE}" "\$core" || exit 1
    [[ -z "\${STUB_TAP_ORIGIN:-}" ]] || "$REAL_GIT" -C "\$core" remote set-url origin "\$STUB_TAP_ORIGIN" ;;
  update)
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
  "$REAL_GIT" -C "$(core_dir)" rev-parse HEAD 2>/dev/null); }

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
start "fresh Mac, zsh: installs, taps fork, writes .zprofile"
run_install
check "exit 0" test "$RC" -eq 0
check "brew symlink" test -L "$P/bin/brew"
check "brew cloned" logged "git clone https://github.com/Homebrew/brew $P/Homebrew"
check "tap ran with env" logged "brew tap homebrew/core [API=1 REMOTE=$FORK_URL]"
check "core origin is fork" remote_is "$FORK_URL"
check "brew update ran" logged "brew update"
check ".zprofile has remote once" test "$(count '^export HOMEBREW_CORE_GIT_REMOTE=' "$H/.zprofile")" = 1
check ".zprofile has api once" test "$(count '^export HOMEBREW_NO_INSTALL_FROM_API=1$' "$H/.zprofile")" = 1
check ".zprofile exact remote line" grep -qxF "$LINE_REMOTE" "$H/.zprofile"
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
check "block appended" grep -qxF "$LINE_REMOTE" "$H/.zprofile"
check "kept EDITOR" grep -qxF 'export EDITOR=vim' "$H/.zprofile"
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
check "zdot/.zprofile written" grep -qxF "$LINE_REMOTE" "$H/zdot/.zprofile"
check "no ~/.zprofile" test ! -e "$H/.zprofile"
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
