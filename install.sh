#!/bin/bash
# Intelbrew installer: DRAFT, UNTESTED. Do not use yet.
#
# Installs Homebrew on an Intel (x86_64) Mac in git mode, pointed at the Intelbrew
# fork of homebrew-core, which carries x86_64 macOS Sonoma bottles:
#   1. git clone https://github.com/Homebrew/brew -> /usr/local/Homebrew
#   2. symlink /usr/local/bin/brew
#   3. add HOMEBREW_NO_INSTALL_FROM_API=1 and HOMEBREW_CORE_GIT_REMOTE=<intelbrew-core>
#      to your shell profile (once; an existing Intelbrew block is left alone)
#   4. `brew tap homebrew/core`, which clones core from the Intelbrew fork
#
# It refuses to run on Apple Silicon (including under Rosetta), as root, without a
# terminal, or without the Command Line Tools. It never deletes anything. It prints
# every command before running it and asks before making any change.
#
# Why our own installer: the official Homebrew/install script aborts on Intel
# (Homebrew/install PR #1140, 2026-09-11).
#
# TODO(before release), all UNVERIFIED:
#   - Run end to end on a clean Intel Sonoma VM and on a Mac with an existing
#     /usr/local Homebrew.
#   - Compare the directory list and ownership handling with the official installer.
#   - Confirm a fresh git-mode clone of core (~1.3 GB) and `brew update` behave as the
#     design doc describes (tap/core_tap.rb, cmd/update.sh).
#   - Confirm the CPU feature check matches the bottles' Westmere baseline.
set -euo pipefail

BREW_GIT_URL="https://github.com/Homebrew/brew"
# TODO(confirm): final fork URL once the repo exists.
CORE_GIT_REMOTE="https://github.com/d4rkwyng/intelbrew-core"
PREFIX="/usr/local"
REPOSITORY="$PREFIX/Homebrew"
MARK_BEGIN="# >>> intelbrew >>>"
MARK_END="# <<< intelbrew <<<"

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
run()  { printf '+ %s\n' "$*"; "$@"; }

confirm() {  # confirm "<question>" -> returns 0 only on an explicit "yes"
  local answer=""
  printf '%s Type "yes" to continue: ' "$1" >/dev/tty
  IFS= read -r answer </dev/tty || true
  [[ "$answer" == "yes" ]]
}

cat <<'EOF'
========================================================================
  Intelbrew installer: DRAFT, UNTESTED, NOT YET USABLE.
  Intelbrew is not affiliated with Homebrew or with rhyn-daitenku/intelbrew.
========================================================================
EOF

# ---- checks (no changes made) ------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "Intelbrew is for macOS only."
[[ "${EUID:-$(id -u)}" -ne 0 ]] || die "Don't run this as root or with sudo. It asks for sudo itself when needed."
[[ -r /dev/tty && -w /dev/tty ]] || die "This installer needs an interactive terminal to confirm each step."

arch="$(uname -m)"
translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"
arm64_hw="$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"
if [[ "$arch" == "arm64" || "$translated" == "1" || "$arm64_hw" == "1" ]]; then
  die "This is an Apple Silicon Mac. Use the official Homebrew installer from https://brew.sh instead."
fi
[[ "$arch" == "x86_64" ]] || die "Unsupported architecture: $arch"

macos="$(sw_vers -productVersion)"
macos_major="${macos%%.*}"
if (( macos_major < 11 )); then
  die "macOS $macos is older than Homebrew's minimum (11). See https://www.macports.org"
fi
if (( macos_major < 14 )); then
  warn "Intelbrew bottles are built on macOS 14 (Sonoma). On macOS $macos, brew will build formulae from source."
fi

# Bottles target the Westmere baseline (Homebrew extend/os/mac/hardware.rb), so they
# need at least SSE4.2, POPCNT and AES. Core 2 / Penryn Macs lack them.
cpu_features="$(sysctl -n machdep.cpu.features 2>/dev/null || true)"
for feature in SSE4.2 POPCNT AES; do
  if [[ " $cpu_features " != *" $feature "* ]]; then
    warn "CPU lacks $feature. Intelbrew bottles won't run on this Mac (Core 2 / Penryn are not supported)."
    confirm "Continue anyway? Everything will build from source." || die "Stopped. Nothing was changed."
    break
  fi
done

if ! xcode-select -p >/dev/null 2>&1; then
  die "The Command Line Tools are required, even to pour bottles on Intel. Run: xcode-select --install, then run this again."
fi
command -v git >/dev/null 2>&1 || die "git not found, though the Command Line Tools are installed."

# ---- shell profile -------------------------------------------------------------
case "${SHELL:-}" in
  */zsh)  profile="$HOME/.zprofile" ;;
  */bash) profile="$HOME/.bash_profile" ;;
  *)      profile="" ;;
esac

profile_block() {
  cat <<EOF
$MARK_BEGIN
eval "\$($PREFIX/bin/brew shellenv)"
export HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_CORE_GIT_REMOTE=$CORE_GIT_REMOTE
$MARK_END
EOF
}

write_profile() {
  if [[ -z "$profile" ]]; then
    warn "Unrecognised shell (${SHELL:-unset}). Add these lines to your shell's startup file yourself:"
    profile_block
    return 0
  fi
  if [[ -f "$profile" ]] && grep -qF "$MARK_BEGIN" "$profile"; then
    say "$profile already has an Intelbrew block. Leaving it unchanged."
    return 0
  fi
  say "This block will be appended to $profile:"
  profile_block
  if confirm "Append it?"; then
    printf '+ append Intelbrew block to %s\n' "$profile"
    { printf '\n'; profile_block; } >>"$profile"
  else
    warn "Skipped. Add the block above to $profile yourself."
  fi
}

# Apply the settings to this script's own environment too, for the steps below.
export HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_CORE_GIT_REMOTE="$CORE_GIT_REMOTE"

# ---- existing installation: switch mode only -----------------------------------
if [[ -e "$REPOSITORY" || -e "$PREFIX/bin/brew" ]]; then
  say "Found an existing Homebrew at $REPOSITORY. Nothing will be reinstalled or deleted."
  say "Intelbrew will only add the two settings to your shell profile."
  write_profile
  cat <<EOF

Next steps, in a new terminal:
  brew update        # re-points homebrew/core at $CORE_GIT_REMOTE
  brew upgrade

Expect a one-off full clone of homebrew-core (about 1.3 GB).
EOF
  exit 0
fi

# ---- fresh installation ----------------------------------------------------------
dirs=(Homebrew bin etc include lib sbin share opt var Cellar Caskroom Frameworks
      share/zsh share/zsh/site-functions var/homebrew var/homebrew/linked)
missing=()
unwritable=()
for d in "${dirs[@]}"; do
  if [[ ! -e "$PREFIX/$d" ]]; then
    missing+=("$PREFIX/$d")
  elif [[ ! -w "$PREFIX/$d" ]]; then
    unwritable+=("$PREFIX/$d")
  fi
done

say "Plan:"
(( ${#missing[@]} == 0 ))    || printf '  create, owned by %s:admin (sudo): %s\n' "$USER" "${missing[*]}"
(( ${#unwritable[@]} == 0 )) || printf '  change owner to %s:admin, not recursive (sudo): %s\n' "$USER" "${unwritable[*]}"
printf '  git clone %s %s\n' "$BREW_GIT_URL" "$REPOSITORY"
printf '  ln -s ../Homebrew/bin/brew %s/bin/brew\n' "$PREFIX"
printf '  append the Intelbrew settings to %s (asked separately)\n' "${profile:-your shell profile}"
printf '  brew tap homebrew/core   (full clone of %s, about 1.3 GB)\n' "$CORE_GIT_REMOTE"
confirm "Proceed?" || die "Stopped. Nothing was changed."

if (( ${#missing[@]} > 0 )); then
  run sudo mkdir -p "${missing[@]}"
  run sudo chown "$USER:admin" "${missing[@]}"
  run sudo chmod u+rwx "${missing[@]}"
fi
if (( ${#unwritable[@]} > 0 )); then
  run sudo chown "$USER:admin" "${unwritable[@]}"
  run sudo chmod u+rwx "${unwritable[@]}"
fi

# $REPOSITORY was just created empty, so cloning into it is safe.
run git clone "$BREW_GIT_URL" "$REPOSITORY"
run ln -s ../Homebrew/bin/brew "$PREFIX/bin/brew"

write_profile

# With HOMEBREW_NO_INSTALL_FROM_API=1, CoreTap#install clones HOMEBREW_CORE_GIT_REMOTE
# (Library/Homebrew/tap/core_tap.rb). Never shallow, by Homebrew's design.
run "$PREFIX/bin/brew" tap homebrew/core
run "$PREFIX/bin/brew" update

cat <<EOF

Intelbrew is set up. Open a new terminal, then try:
  brew install wget

Note: casks also leave API mode with these settings. 'brew install --cask' may
need an extra homebrew/cask clone (UNVERIFIED).
EOF
