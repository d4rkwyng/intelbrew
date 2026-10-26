#!/bin/bash
# Intelbrew installer.
#
# Sets up Homebrew on an Intel (x86_64) Mac in git mode, with homebrew/core cloned
# from the Intelbrew fork, which carries x86_64 macOS Sonoma bottles.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/d4rkwyng/intelbrew/main/install.sh)"
#
# Works for both:
#   (a) a Mac with no Homebrew: clones Homebrew/brew to /usr/local/Homebrew, links
#       /usr/local/bin/brew, then taps homebrew/core from the fork;
#   (b) an existing /usr/local Homebrew: taps homebrew/core from the fork, or, if a
#       core tap already exists, points its origin at the fork and checks out the
#       fork's main.
# In both cases it sets these two variables in your login shell profile:
#   export HOMEBREW_NO_INSTALL_FROM_API=1
#   export HOMEBREW_CORE_GIT_REMOTE="https://github.com/d4rkwyng/intelbrew-core"
# Existing lines for either variable in any zsh/bash startup file are rewritten in
# place (duplicates removed), never appended twice. Each file is backed up first.
# Re-running the script when everything is already set up changes nothing.
#
# Brew behaviour this relies on (Homebrew/brew source):
#   - Library/Homebrew/tap/core_tap.rb: with HOMEBREW_NO_INSTALL_FROM_API set,
#     `brew tap homebrew/core` clones HOMEBREW_CORE_GIT_REMOTE.
#   - Library/Homebrew/cmd/update.sh: `brew update` resets the core tap's origin to
#     HOMEBREW_CORE_GIT_REMOTE whenever that differs from the default remote.
#   - bin/brew: brew.env files (/etc/homebrew, <prefix>/etc/homebrew, ~/.homebrew)
#     are exported after the shell environment, so they override the profile.
#
# Options / environment:
#   --yes, INTELBREW_YES=1   don't ask before each change (still prints them)
#   INTELBREW_PREFIX         install prefix, default /usr/local (for testing only:
#                            Intel bottles are only relocatable to /usr/local)
set -euo pipefail

CORE_GIT_REMOTE="https://github.com/d4rkwyng/intelbrew-core"
BREW_GIT_URL="https://github.com/Homebrew/brew"
PREFIX="${INTELBREW_PREFIX:-/usr/local}"
REPOSITORY="$PREFIX/Homebrew"
BREW="$PREFIX/bin/brew"
MIN_MACOS=14
MARK_BEGIN="# >>> intelbrew >>>"
MARK_END="# <<< intelbrew <<<"
LINE_API="export HOMEBREW_NO_INSTALL_FROM_API=1"
LINE_REMOTE="export HOMEBREW_CORE_GIT_REMOTE=\"$CORE_GIT_REMOTE\""
STAMP="$(date +%Y%m%d-%H%M%S)"

ASSUME_YES="${INTELBREW_YES:-0}"
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,35p' "$0" 2>/dev/null || true; exit 0 ;;
    *) printf 'Error: unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
run()  { printf '+ %s\n' "$*"; "$@"; }

confirm() {  # confirm "<question>": 0 only on an explicit "yes" (or --yes)
  if [[ "$ASSUME_YES" == "1" ]]; then
    printf '%s (yes: --yes given)\n' "$1"
    return 0
  fi
  local answer=""
  printf '%s Type "yes" to continue: ' "$1" >/dev/tty
  IFS= read -r answer </dev/tty || true
  [[ "$answer" == "yes" ]]
}

# Strip one trailing "/" and ".git" so equivalent remote spellings compare equal.
normalize_url() {
  local u="$1"
  u="${u%/}"
  u="${u%.git}"
  printf '%s' "$u"
}

cat <<'EOF'
========================================================================
  Intelbrew installer: Homebrew in git mode with Intel Sonoma bottles.
  Intelbrew is not affiliated with Homebrew or with rhyn-daitenku/intelbrew.
========================================================================
EOF

# ---- 1. system checks (nothing is changed) ------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "Intelbrew is for macOS only."
[[ "$(id -u)" -ne 0 ]] || die "Don't run this as root or with sudo. It asks for sudo itself if it needs it."
if [[ "$ASSUME_YES" != "1" ]] && ! { : </dev/tty; } 2>/dev/null; then
  die "No terminal to ask for confirmation. Run it from Terminal, or pass --yes."
fi

arch="$(uname -m)"
translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"
arm64_hw="$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"
if [[ "$arch" == "arm64" || "$translated" == "1" || "$arm64_hw" == "1" ]]; then
  die "This is an Apple Silicon Mac (including under Rosetta). Intelbrew is for Intel Macs only; use the official installer from https://brew.sh."
fi
[[ "$arch" == "x86_64" ]] || die "Unsupported architecture: $arch"

# Minimum version only. Sequoia, Tahoe and later (including OpenCore Legacy Patcher
# installs) are fine: brew uses Sonoma bottles on newer macOS. No model allow-list.
macos="$(sw_vers -productVersion)"
macos_major="${macos%%.*}"
[[ "$macos_major" =~ ^[0-9]+$ ]] || die "Could not parse the macOS version: '$macos'"
if (( macos_major < MIN_MACOS )); then
  die "macOS $macos is older than macOS $MIN_MACOS Sonoma. Intelbrew's bottles need Sonoma or newer, so this installer stops here. Nothing was changed."
fi

# Bottles target Homebrew's Intel baseline, -march=westmere
# (Library/Homebrew/extend/os/mac/hardware.rb), which needs these CPU features.
# Core 2 / Penryn CPUs lack them, and pouring the bottles there gives crashing binaries.
cpu_features=" $(sysctl -n machdep.cpu.features 2>/dev/null || true) "
missing_features=""
for feature in SSE4.2 POPCNT AES PCLMULQDQ; do
  [[ "$cpu_features" == *" $feature "* ]] || missing_features="$missing_features $feature"
done
if [[ -n "$missing_features" ]]; then
  die "This CPU lacks:$missing_features. Intelbrew's bottles need a Westmere-class CPU or newer; they won't run on Core 2 / Penryn. Nothing was changed."
fi

# Command Line Tools: needed on Intel even to pour bottles. Don't rely on
# softwareupdate (OCLP systems can't always reach the catalog).
clt_ok=0
if clt_path="$(xcode-select -p 2>/dev/null)" && [[ -n "$clt_path" && -d "$clt_path" ]]; then
  clt_ok=1
elif pkgutil --pkg-info=com.apple.pkg.CLTools_Executables >/dev/null 2>&1; then
  clt_ok=1
fi
(( clt_ok == 1 )) || die "The Command Line Tools are not installed. Run: xcode-select --install (or download them from https://developer.apple.com/download/all/), then run this again."
git --version >/dev/null 2>&1 || die "git doesn't run, though the Command Line Tools look installed. Try: xcode-select --install"

# Other package managers: warn only, never touch them.
if [[ -x /opt/local/bin/port ]]; then
  warn "MacPorts is installed (/opt/local/bin/port). Intelbrew leaves it alone, but having both on PATH can mix up libraries; consider removing whichever you don't use."
fi
if [[ -e /opt/homebrew/bin/brew ]]; then
  warn "Found an Apple Silicon-style Homebrew at /opt/homebrew. Intelbrew leaves it alone; it can't pour Intel bottles, so remove it from your PATH if you don't need it."
fi

# brew.env files override the shell environment (bin/brew), so a conflicting value
# there would silently undo everything below. Refuse rather than edit them.
if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then user_env="$XDG_CONFIG_HOME/homebrew/brew.env"
else user_env="$HOME/.homebrew/brew.env"; fi
for envfile in /etc/homebrew/brew.env "$PREFIX/etc/homebrew/brew.env" "$user_env"; do
  [[ -r "$envfile" ]] || continue
  while IFS= read -r line; do
    case "$line" in
      HOMEBREW_CORE_GIT_REMOTE=*)
        v="${line#HOMEBREW_CORE_GIT_REMOTE=}"; v="${v%\"}"; v="${v#\"}"
        [[ "$(normalize_url "$v")" == "$CORE_GIT_REMOTE" ]] \
          || die "$envfile sets HOMEBREW_CORE_GIT_REMOTE=$v, which overrides your shell profile. Remove that line or set it to $CORE_GIT_REMOTE, then run this again." ;;
    esac
  done <"$envfile"
done

# ---- 2. which shell profile ----------------------------------------------------
zdot="${ZDOTDIR:-$HOME}"
case "${SHELL:-}" in
  */zsh)  target="$zdot/.zprofile" ;;   # login shells (Terminal.app) read .zprofile
  */bash)
    # bash login shells read the first of .bash_profile, .bash_login, .profile.
    # Creating .bash_profile when only .profile exists would stop .profile being read.
    if   [[ -e "$HOME/.bash_profile" ]]; then target="$HOME/.bash_profile"
    elif [[ -e "$HOME/.bash_login" ]];   then target="$HOME/.bash_login"
    elif [[ -e "$HOME/.profile" ]];      then target="$HOME/.profile"
    else target="$HOME/.bash_profile"
    fi ;;
  *) target="" ;;
esac
# Every zsh/bash startup file in which an existing line gets rewritten.
scan_files=("$zdot/.zshenv" "$zdot/.zprofile" "$zdot/.zshrc" "$zdot/.zlogin"
            "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile" "$HOME/.bashrc")

# Writes to $2 the new content of profile $1: every HOMEBREW_CORE_GIT_REMOTE= /
# HOMEBREW_NO_INSTALL_FROM_API= assignment is rewritten to the Intelbrew value, later
# duplicates are dropped, and (if $3 = append) missing lines are appended in a block.
rewrite_profile() {
  local src="$1" out="$2" mode="$3"
  if [[ -e "$src" ]]; then
    awk -v lr="$LINE_REMOTE" -v la="$LINE_API" -v mode="$mode" \
        -v mb="$MARK_BEGIN" -v me="$MARK_END" '
      function indent(s) { match(s, /^[ \t]*/); return substr(s, 1, RLENGTH) }
      /^[ \t]*(export[ \t]+)?HOMEBREW_CORE_GIT_REMOTE=/ {
        if (!seen_r++) print indent($0) lr; next }
      /^[ \t]*(export[ \t]+)?HOMEBREW_NO_INSTALL_FROM_API=/ {
        if (!seen_a++) print indent($0) la; next }
      { print }
      END {
        if (mode == "append" && (!seen_r || !seen_a)) {
          print ""; print mb
          if (!seen_a) print la
          if (!seen_r) print lr
          print me
        }
      }' "$src" >"$out"
  elif [[ "$mode" == "append" ]]; then
    printf '%s\n%s\n%s\n%s\n' "$MARK_BEGIN" "$LINE_API" "$LINE_REMOTE" "$MARK_END" >"$out"
  else
    : >"$out"
  fi
}

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/intelbrew.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

profile_changes=()   # files whose content would change
plan_profiles() {
  local f mode i=0
  profile_changes=()
  for f in "${scan_files[@]}"; do
    mode=keep
    [[ "$f" == "$target" ]] && mode=append
    [[ -e "$f" || "$mode" == "append" ]] || continue
    i=$((i + 1))
    rewrite_profile "$f" "$tmpdir/profile.$i" "$mode"
    if [[ ! -e "$f" ]] || ! cmp -s "$f" "$tmpdir/profile.$i"; then
      profile_changes+=("$f" "$tmpdir/profile.$i")
    fi
  done
  return 0
}

apply_profiles() {
  local idx f new
  (( ${#profile_changes[@]} > 0 )) || return 0
  for ((idx = 0; idx < ${#profile_changes[@]}; idx += 2)); do
    f="${profile_changes[idx]}"; new="${profile_changes[idx + 1]}"
    if [[ -e "$f" ]]; then
      run cp -p "$f" "$f.intelbrew-backup-$STAMP"
      printf '+ rewrite %s\n' "$f"
      cat "$new" >"$f"     # in place: keeps permissions, owner and symlinks
    else
      printf '+ create %s\n' "$f"
      cat "$new" >"$f"
    fi
  done
}

show_profile_plan() {
  local idx f
  for ((idx = 0; idx < ${#profile_changes[@]}; idx += 2)); do
    f="${profile_changes[idx]}"
    if [[ -e "$f" ]]; then
      printf '  edit %s (backup: %s.intelbrew-backup-%s):\n' "$f" "$f" "$STAMP"
      diff -u "$f" "${profile_changes[idx + 1]}" | sed -n '3,$p' | sed 's/^/      /' || true
    else
      printf '  create %s with:\n' "$f"
      sed 's/^/      /' "${profile_changes[idx + 1]}"
    fi
  done
}

# ---- 3. what brew/core needs ---------------------------------------------------
export HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_CORE_GIT_REMOTE="$CORE_GIT_REMOTE"

mode=""
if [[ -e "$BREW" || -e "$REPOSITORY" ]]; then
  [[ -x "$BREW" && -d "$REPOSITORY/.git" ]] \
    || die "Found a partial Homebrew ($BREW or $REPOSITORY missing or not a git checkout). Fix or remove it yourself, then run this again."
  mode=existing
  # Tell the user what is already there, and let them switch it in place,
  # uninstall it first, or stop. Uninstalling is never done unattended.
  existing_version="$("$BREW" --version 2>/dev/null | head -1 || true)"
  existing_core="$("$BREW" --repository homebrew/core 2>/dev/null || true)"
  if [[ -d "$existing_core/.git" ]]; then
    existing_source="homebrew/core tap, origin $(git -C "$existing_core" config --get remote.origin.url || echo '?')"
  else
    existing_source="API mode (no local homebrew/core tap)"
  fi
  existing_count="$("$BREW" list --formula 2>/dev/null | wc -l | tr -d ' ' || true)"
  say "Found an existing Homebrew at $PREFIX:"
  printf '    %s\n    formulae from: %s\n    installed formulae: %s\n' \
    "${existing_version:-unknown version}" "$existing_source" "${existing_count:-?}"
  if [[ "$ASSUME_YES" == "1" ]]; then
    say "--yes given: switching it to Intelbrew in place (installed packages are kept)."
  else
    cat >/dev/tty <<'EOF'
  [S] Switch it to Intelbrew in place (default). Installed packages are kept;
      the next `brew upgrade` moves them to Intelbrew bottles.
  [U] Uninstall it first with Homebrew's official uninstaller, then install fresh.
      This removes every installed formula and cask.
  [Q] Quit without changing anything.
EOF
    printf 'Choose S, U or Q [S]: ' >/dev/tty
    choice=""
    IFS= read -r choice </dev/tty || true
    case "${choice:-S}" in
      [Ss]*) ;;
      [Uu]*)
        confirm "Uninstall the Homebrew at $PREFIX and every package it installed?" \
          || die "Not confirmed. Nothing was changed."
        uninstaller="$(mktemp -t brew-uninstall)"
        run curl -fsSL -o "$uninstaller" https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh
        # Interactive: Homebrew's uninstaller asks for its own confirmation.
        /bin/bash "$uninstaller" --path "$PREFIX" </dev/tty || die "Homebrew's uninstaller failed. Fix that, then run this again."
        rm -f "$uninstaller"
        hash -r
        [[ ! -e "$BREW" ]] || die "$BREW is still there after uninstalling. Remove it, then run this again."
        if [[ -e "$REPOSITORY" ]]; then
          warn "$REPOSITORY is still there after uninstalling; moving it aside."
          run sudo mv "$REPOSITORY" "$REPOSITORY.intelbrew-old-$STAMP"
        fi
        mode=fresh
        ;;
      *) die "Quit. Nothing was changed." ;;
    esac
  fi
else
  other="$(command -v brew 2>/dev/null || true)"
  [[ -z "$other" ]] || die "Found brew at $other, outside $PREFIX. Intelbrew's bottles only work in $PREFIX; this installer won't touch that install."
  mode=fresh
fi

core=""
core_action=none   # none | tap | switch
if [[ "$mode" == "existing" ]]; then
  core="$("$BREW" --repository homebrew/core)"
  if [[ ! -e "$core" ]]; then
    core_action=tap
  elif [[ ! -d "$core/.git" ]]; then
    die "$core exists but is not a git checkout. Move it aside, then run this again."
  else
    current="$(git -C "$core" config --get remote.origin.url || true)"
    if [[ "$(normalize_url "$current")" != "$CORE_GIT_REMOTE" ]]; then
      [[ -z "$(git -C "$core" status --porcelain)" ]] \
        || die "$core has uncommitted changes. Commit, stash or discard them, then run this again. Nothing was changed."
      core_action=switch
    fi
  fi
else
  core="$REPOSITORY/Library/Taps/homebrew/homebrew-core"
  core_action=tap
fi

plan_profiles

# ---- 4. plan ---------------------------------------------------------------------
dirs=(Homebrew bin etc include lib sbin share opt var Cellar Caskroom Frameworks
      share/zsh share/zsh/site-functions var/homebrew var/homebrew/linked)
missing=()
unwritable=()
if [[ "$mode" == "fresh" ]]; then
  for d in "${dirs[@]}"; do
    if [[ ! -e "$PREFIX/$d" ]]; then missing+=("$PREFIX/$d")
    elif [[ ! -w "$PREFIX/$d" ]]; then unwritable+=("$PREFIX/$d")
    fi
  done
fi

say "macOS $macos, $arch. Homebrew: $mode install at $PREFIX."
if [[ "$core_action" == "none" && ${#profile_changes[@]} -eq 0 ]]; then
  if [[ -n "$target" ]]; then
    say "Already set up: homebrew/core comes from $CORE_GIT_REMOTE and $target has both settings. Nothing to change."
  else
    say "homebrew/core already comes from $CORE_GIT_REMOTE. Nothing to change."
    warn "Unrecognised login shell (${SHELL:-unset}). Make sure its startup file has:"
    printf '  %s\n  %s\n' "$LINE_API" "$LINE_REMOTE"
  fi
  exit 0
fi

say "Plan:"
if [[ "$mode" == "fresh" ]]; then
  (( ${#missing[@]} == 0 ))    || printf '  create, owned by %s:admin (sudo if %s is not writable): %s\n' "$USER" "$PREFIX" "${missing[*]}"
  (( ${#unwritable[@]} == 0 )) || printf '  change owner to %s:admin, not recursive (sudo): %s\n' "$USER" "${unwritable[*]}"
  printf '  git clone %s %s\n' "$BREW_GIT_URL" "$REPOSITORY"
  printf '  ln -s ../Homebrew/bin/brew %s\n' "$BREW"
fi
case "$core_action" in
  tap)    printf '  brew tap homebrew/core: full clone of %s (about 1.3 GB)\n' "$CORE_GIT_REMOTE" ;;
  switch) printf '  in %s:\n' "$core"
          printf '    set origin to %s (was %s)\n' "$CORE_GIT_REMOTE" "${current:-unset}"
          printf '    fetch it and check out its main: local branch "main" is reset to origin/main;\n'
          printf '    any local commits on it are discarded (the tree is clean, checked above)\n' ;;
esac
if [[ -n "$target" ]]; then
  show_profile_plan
else
  warn "Unrecognised login shell (${SHELL:-unset}). Add these two lines to its startup file yourself:"
  printf '  %s\n  %s\n' "$LINE_API" "$LINE_REMOTE"
  (( ${#profile_changes[@]} == 0 )) || show_profile_plan
fi
[[ "$core_action" == "none" ]] || printf '  brew update\n'
confirm "Proceed?" || die "Stopped. Nothing was changed."

# ---- 5. do it ----------------------------------------------------------------------
if [[ "$mode" == "fresh" ]]; then
  if (( ${#missing[@]} > 0 )); then
    if [[ -w "$PREFIX" ]]; then
      run mkdir -p "${missing[@]}"            # already owned by you; no sudo needed
    else
      run sudo mkdir -p "${missing[@]}"
      run sudo chown "$USER:admin" "${missing[@]}"
      run sudo chmod u+rwx "${missing[@]}"
    fi
  fi
  if (( ${#unwritable[@]} > 0 )); then
    run sudo chown "$USER:admin" "${unwritable[@]}"
    run sudo chmod u+rwx "${unwritable[@]}"
  fi
  # $REPOSITORY was just created empty, so cloning into it is safe.
  run git clone "$BREW_GIT_URL" "$REPOSITORY"
  run ln -s ../Homebrew/bin/brew "$BREW"
fi
[[ "$mode" == "existing" ]] || core="$("$BREW" --repository homebrew/core)"

case "$core_action" in
  tap)
    # CoreTap#install clones HOMEBREW_CORE_GIT_REMOTE (never shallow).
    run "$BREW" tap homebrew/core ;;
  switch)
    run git -C "$core" remote set-url origin "$CORE_GIT_REMOTE"
    run git -C "$core" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    run git -C "$core" fetch --force origin
    run git -C "$core" checkout --force -B main origin/main ;;
esac

verify_core() {
  local url
  [[ -d "$core/.git" ]] || die "homebrew/core is not tapped at $core after setup."
  url="$(git -C "$core" config --get remote.origin.url || true)"
  if [[ "$(normalize_url "$url")" != "$CORE_GIT_REMOTE" ]]; then
    die "homebrew/core's origin is '$url', not $CORE_GIT_REMOTE. Setup FAILED; brew would not use Intelbrew bottles."
  fi
  say "Verified: homebrew/core origin is $url ($(git -C "$core" rev-parse --short HEAD))."
}
verify_core

apply_profiles

if [[ "$core_action" != "none" ]]; then
  run "$BREW" update
  verify_core   # brew update rewrites the core remote from HOMEBREW_CORE_GIT_REMOTE
fi

cat <<EOF

Intelbrew is set up. Open a NEW terminal window (so ${target:-your profile} is read), then:
  brew config         # should show HOMEBREW_CORE_GIT_REMOTE and HOMEBREW_NO_INSTALL_FROM_API
  brew install <formula>

Formulae without an Intelbrew bottle build from source; see
https://github.com/d4rkwyng/intelbrew#coverage
EOF
