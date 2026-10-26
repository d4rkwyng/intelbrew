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
#   - cmd/update.sh: `brew update` likewise resets Homebrew/brew's own origin to
#     HOMEBREW_BREW_GIT_REMOTE when that is set to a non-default value, but never
#     resets an origin back to upstream when the variable is unset.
#   - formula.rb (Formula#outdated_kegs): a keg is only outdated when the formula's
#     pkg_version is greater, so brew never "upgrades" a newer keg down to the fork's.
#   - extend/os/mac/utils/bottles.rb (find_matching_tag): brew pours the bottle for
#     this macOS, else an :all bottle, else one for an older macOS on the same arch.
#
# Options / environment:
#   --yes, INTELBREW_YES=1   don't ask before each change (still prints them);
#                            optional changes that default to No are not made
#   INTELBREW_PREFIX         install prefix, default /usr/local (for testing only:
#                            Intel bottles are only relocatable to /usr/local)
#   INTELBREW_TTY_IN/_OUT    where answers are read / prompts written, default
#                            /dev/tty (for testing only)
set -euo pipefail

# The environment of the shell the installer was started from, before this script
# changes anything: open terminal windows keep exactly these values.
ORIG_CORE_REMOTE="${HOMEBREW_CORE_GIT_REMOTE-}"
ORIG_API="${HOMEBREW_NO_INSTALL_FROM_API-}"
ORIG_BREW_REMOTE="${HOMEBREW_BREW_GIT_REMOTE-}"

CORE_GIT_REMOTE="https://github.com/d4rkwyng/intelbrew-core"
BREW_GIT_URL="https://github.com/Homebrew/brew"
# FUTURE OPTION (owner decision pending, NOT implemented): install Homebrew/brew
# itself from a patched fork, https://github.com/d4rkwyng/brew, instead of upstream.
# If that is ever decided, it would choose BREW_GIT_URL here and change what
# check_brew_remote() below treats as "upstream". Until then the installer always
# clones upstream brew and only offers to move a brew fork back to upstream.
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
    -h|--help) sed -n '2,43p' "$0" 2>/dev/null || true; exit 0 ;;
    *) printf 'Error: unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
run()  { printf '+ %s\n' "$*"; "$@"; }

TTY_IN="${INTELBREW_TTY_IN:-/dev/tty}"
TTY_OUT="${INTELBREW_TTY_OUT:-/dev/tty}"
ask() {  # ask "<prompt>": prints the prompt to the terminal, reads one line into $answer
  answer=""
  printf '%s' "$1" >&4
  IFS= read -r answer <&3 || true
}

confirm() {  # confirm "<question>": 0 only on an explicit "yes" (or --yes)
  if [[ "$ASSUME_YES" == "1" ]]; then
    printf '%s (yes: --yes given)\n' "$1"
    return 0
  fi
  ask "$1 Type \"yes\" to continue: "
  [[ "$answer" == "yes" ]]
}

offer() {  # offer "<question>": optional change, default No; never made with --yes
  if [[ "$ASSUME_YES" == "1" ]]; then
    printf '%s (no: --yes only makes the required changes)\n' "$1"
    return 1
  fi
  ask "$1 [y/N]: "
  [[ "$answer" == [Yy] || "$answer" == [Yy][Ee][Ss] ]]
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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
if [[ "$ASSUME_YES" != "1" ]]; then
  { : <"$TTY_IN"; } 2>/dev/null || die "No terminal to ask for confirmation. Run it from Terminal, or pass --yes."
  exec 3<"$TTY_IN" 4>"$TTY_OUT"
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
brew_env_remotes=()
for envfile in /etc/homebrew/brew.env "$PREFIX/etc/homebrew/brew.env" "$user_env"; do
  [[ -r "$envfile" ]] || continue
  while IFS= read -r line; do
    case "$line" in
      HOMEBREW_CORE_GIT_REMOTE=*)
        v="${line#HOMEBREW_CORE_GIT_REMOTE=}"; v="${v%\"}"; v="${v#\"}"
        [[ "$(normalize_url "$v")" == "$CORE_GIT_REMOTE" ]] \
          || die "$envfile sets HOMEBREW_CORE_GIT_REMOTE=$v, which overrides your shell profile. Remove that line or set it to $CORE_GIT_REMOTE, then run this again." ;;
      HOMEBREW_BREW_GIT_REMOTE=*)   # reported by check_brew_remote; never edited
        v="${line#HOMEBREW_BREW_GIT_REMOTE=}"; v="${v%\"}"; v="${v#\"}"
        brew_env_remotes+=("$envfile: $v") ;;
    esac
  done <"$envfile"
done

# ---- 2. which shell profile ----------------------------------------------------
zdot="${ZDOTDIR:-$HOME}"
# The settings must reach EVERY shell brew runs from, not just login shells: a
# non-login zsh (tmux, IDE terminals, some iTerm2 profiles) never reads .zprofile,
# and brew then silently falls back to the upstream API feed and source builds.
targets=()
case "${SHELL:-}" in
  */zsh)  targets=("$zdot/.zshenv") ;;   # read by every zsh: login, interactive or not
  */bash)
    # bash login shells read the first of .bash_profile, .bash_login, .profile;
    # interactive non-login shells read only .bashrc. Write both.
    # Creating .bash_profile when only .profile exists would stop .profile being read.
    if   [[ -e "$HOME/.bash_profile" ]]; then targets=("$HOME/.bash_profile")
    elif [[ -e "$HOME/.bash_login" ]];   then targets=("$HOME/.bash_login")
    elif [[ -e "$HOME/.profile" ]];      then targets=("$HOME/.profile")
    else targets=("$HOME/.bash_profile")
    fi
    targets+=("$HOME/.bashrc") ;;
esac
# Every zsh/bash startup file in which an existing line gets rewritten.
scan_files=("$zdot/.zshenv" "$zdot/.zprofile" "$zdot/.zshrc" "$zdot/.zlogin"
            "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile" "$HOME/.bashrc")

# Writes to $2 the new content of profile $1: every HOMEBREW_CORE_GIT_REMOTE= /
# HOMEBREW_NO_INSTALL_FROM_API= assignment is rewritten to the Intelbrew value, later
# duplicates are dropped, and (if $3 = append) missing lines are appended in a block.
# If the user accepted resetting brew to upstream (reset_brew=1), every
# HOMEBREW_BREW_GIT_REMOTE= assignment is removed too (upstream is brew's default).
reset_brew=0
rewrite_profile() {
  local src="$1" out="$2" mode="$3"
  if [[ -e "$src" ]]; then
    awk -v lr="$LINE_REMOTE" -v la="$LINE_API" -v mode="$mode" \
        -v mb="$MARK_BEGIN" -v me="$MARK_END" -v dropbrew="$reset_brew" '
      function indent(s) { match(s, /^[ \t]*/); return substr(s, 1, RLENGTH) }
      dropbrew == 1 && /^[ \t]*(export[ \t]+)?HOMEBREW_BREW_GIT_REMOTE=/ { next }
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

is_target() {
  local t
  for t in ${targets[@]+"${targets[@]}"}; do [[ "$1" == "$t" ]] && return 0; done
  return 1
}

profile_changes=()   # files whose content would change
plan_profiles() {
  local f mode i=0
  profile_changes=()
  for f in "${scan_files[@]}"; do
    mode=keep
    is_target "$f" && mode=append
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

origin_of() {  # origin URL of git repo $1, as `git remote get-url origin` prints it
  git -C "$1" remote get-url origin 2>/dev/null \
    || git -C "$1" config --get remote.origin.url 2>/dev/null || true
}
is_core_origin() {  # does repo $1 fetch from the fork?
  # get-url applies the user's url.insteadOf rewrites; the configured value is what
  # brew itself compares (cmd/update.sh), so either spelling of the fork counts.
  [[ "$(normalize_url "$(origin_of "$1")")" == "$CORE_GIT_REMOTE" ||
     "$(normalize_url "$(git -C "$1" config --get remote.origin.url 2>/dev/null || true)")" == "$CORE_GIT_REMOTE" ]]
}

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
    cat >&4 <<'EOF'
  [S] Switch it to Intelbrew in place (default). Installed packages are kept;
      the next `brew upgrade` moves them to Intelbrew bottles.
  [U] Uninstall it first with Homebrew's official uninstaller, then install fresh.
      This removes every installed formula and cask.
  [Q] Quit without changing anything.
EOF
    ask 'Choose S, U or Q [S]: '
    case "${answer:-S}" in
      [Ss]*) ;;
      [Uu]*)
        confirm "Uninstall the Homebrew at $PREFIX and every package it installed?" \
          || die "Not confirmed. Nothing was changed."
        uninstaller="$(mktemp -t brew-uninstall)"
        run curl -fsSL -o "$uninstaller" https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh
        # Interactive: Homebrew's uninstaller asks for its own confirmation.
        /bin/bash "$uninstaller" --path "$PREFIX" <&3 || die "Homebrew's uninstaller failed. Fix that, then run this again."
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
    # Checked even when the profile settings are already right: the env vars alone
    # don't move an existing tap (only `brew update` does, and only with them set),
    # so a core origin left on an old remote must be switched explicitly here.
    current="$(git -C "$core" config --get remote.origin.url || origin_of "$core")"
    if ! is_core_origin "$core"; then
      [[ -z "$(git -C "$core" status --porcelain)" ]] \
        || die "$core has uncommitted changes. Commit, stash or discard them, then run this again. Nothing was changed."
      core_action=switch
    fi
  fi
else
  core="$REPOSITORY/Library/Taps/homebrew/homebrew-core"
  core_action=tap
fi

# ---- 3b. Homebrew/brew itself from a fork? -----------------------------------------
# HOMEBREW_BREW_GIT_REMOTE (env, profile or brew.env) or the origin of the brew
# checkout can point Homebrew/brew itself at a fork, e.g. d4rkwyng/brew, which may be
# far behind upstream. `brew update` keeps such an origin, and re-applies the variable
# whenever it is set (cmd/update.sh). Warn always; offer the reset only interactively.
is_upstream_brew() { [[ "$(lower "$(normalize_url "$1")")" == "$(lower "$BREW_GIT_URL")" ]]; }
brew_fork_sources=()   # "where: what", for the warning
brew_fork_profiles=0   # profile lines we could remove
brew_origin_fix=0      # brew checkout origin we could reset
brew_repo=""
if [[ -n "$ORIG_BREW_REMOTE" ]] && ! is_upstream_brew "$ORIG_BREW_REMOTE"; then
  brew_fork_sources+=("this shell's environment: HOMEBREW_BREW_GIT_REMOTE=$ORIG_BREW_REMOTE")
fi
for f in "${scan_files[@]}"; do
  [[ -r "$f" ]] || continue
  while IFS= read -r v; do
    if [[ -z "$v" ]] || is_upstream_brew "$v"; then continue; fi
    brew_fork_sources+=("$f: HOMEBREW_BREW_GIT_REMOTE=$v")
    brew_fork_profiles=1
  done < <(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?HOMEBREW_BREW_GIT_REMOTE=//p' "$f" \
             | sed -E "s/[[:space:]]*(#.*)?\$//; s/^[\"']//; s/[\"']\$//")
done
brew_env_fork=0
for e in ${brew_env_remotes[@]+"${brew_env_remotes[@]}"}; do
  is_upstream_brew "${e#*: }" && continue
  brew_fork_sources+=("$e (brew.env: not edited by this installer)")
  brew_env_fork=1
done
if [[ "$mode" == "existing" ]]; then
  brew_repo="$("$BREW" --repository 2>/dev/null || true)"
  [[ -d "$brew_repo/.git" ]] || brew_repo="$REPOSITORY"
  brew_origin="$(origin_of "$brew_repo")"
  if [[ -n "$brew_origin" ]] && ! is_upstream_brew "$brew_origin"; then
    brew_fork_sources+=("origin of $brew_repo: $brew_origin")
    brew_origin_fix=1
  fi
fi
if (( ${#brew_fork_sources[@]} > 0 )); then
  warn "Homebrew itself (Homebrew/brew, not the formulae) is set to come from a fork, not $BREW_GIT_URL:"
  printf '    %s\n' "${brew_fork_sources[@]}" >&2
  printf '  A fork can be far behind upstream brew (missing fixes), and "brew update" keeps\n  you on it. Intelbrew only needs upstream brew.\n' >&2
  if (( brew_fork_profiles || brew_origin_fix )); then
    if offer "Reset Homebrew/brew to upstream ($BREW_GIT_URL)?"; then
      reset_brew=1
    else
      say "Leaving Homebrew/brew as it is. To reset it later, run this installer again without --yes."
    fi
  fi
  if (( brew_env_fork )); then
    warn "A brew.env file sets HOMEBREW_BREW_GIT_REMOTE and overrides everything else; remove that line yourself to use upstream brew."
  fi
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

# Installed formulae the fork can't serve as-is. Needs homebrew/core on the fork,
# so it runs only after the tap/switch. Read-only.
#   brew info --json=v2 --installed -> {"formulae": [Formula#to_hash...]} (formula.rb):
#     "tap", "versions" {"stable"}, "revision", "installed" [{"version"} = keg
#     PkgVersion, sorted oldest first], "bottle" {"stable" {"files" {<tag>: ...}}}.
report_installed() {
  local json="$tmpdir/installed.json" tsv="$tmpdir/installed.tsv" names n
  if ! "$BREW" info --json=v2 --installed >"$json" 2>"$tmpdir/info.err"; then
    warn "Could not list installed formulae (brew info --json=v2 --installed failed): $(head -3 "$tmpdir/info.err")"
    return 0
  fi
  if ! /usr/bin/python3 -I - "$json" "$macos_major" >"$tsv" 2>"$tmpdir/py.err" <<'PY'
import json, re, sys

data = json.load(open(sys.argv[1]))
major = int(sys.argv[2])
# Intel tags brew can pour here: this macOS, :all, or an older macOS on the same
# arch (extend/os/mac/utils/bottles.rb, find_older_compatible_tag). macos_version.rb:
RELEASES = {"golden_gate": 27, "tahoe": 26, "sequoia": 15, "sonoma": 14,
            "ventura": 13, "monterey": 12, "big_sur": 11, "catalina": 10.15,
            "mojave": 10.14, "high_sierra": 10.13, "sierra": 10.12, "el_capitan": 10.11}
PRE = {"alpha", "beta", "rc", "pre", "preview", "dev", "a", "b"}

def tokens(v):
    return [(1, int(t)) if t.isdigit() else (0, t.lower())
            for t in re.findall(r"\d+|[A-Za-z]+", v)]

def vcmp(a, b):
    # Approximates brew's Version#<=>: numeric parts compare as numbers, missing
    # parts as 0, and a pre-release word (rc, beta...) sorts before "nothing" while
    # any other letter suffix (1.1.1w) sorts after it.
    ta, tb = tokens(a), tokens(b)
    for i in range(max(len(ta), len(tb))):
        x = ta[i] if i < len(ta) else None
        y = tb[i] if i < len(tb) else None
        if x == y:
            continue
        if x is None:
            x = (1, 0) if y[0] == 1 else ((-1, "") if y[1] not in PRE else (2, ""))
        if y is None:
            y = (1, 0) if x[0] == 1 else ((-1, "") if x[1] not in PRE else (2, ""))
        if x != y:
            return -1 if x < y else 1
    return 0

def pkg_cmp(a, b):  # PkgVersion: "<version>_<revision>"
    ma = re.match(r"^(.+?)(?:_(\d+))?$", a)
    mb = re.match(r"^(.+?)(?:_(\d+))?$", b)
    c = vcmp(ma.group(1), mb.group(1))
    return c or (int(ma.group(2) or 0) > int(mb.group(2) or 0)) - (int(ma.group(2) or 0) < int(mb.group(2) or 0))

for f in sorted(data.get("formulae", []), key=lambda f: f["name"]):
    if f.get("tap") != "homebrew/core":
        continue
    stable = (f.get("versions") or {}).get("stable")
    kegs = [k["version"] for k in f.get("installed", []) if not k["version"].startswith("HEAD")]
    if stable and kegs:
        fork = stable + ("_%d" % f["revision"] if f.get("revision") else "")
        newest = kegs[0]
        for k in kegs[1:]:
            if pkg_cmp(k, newest) > 0:
                newest = k
        if pkg_cmp(newest, fork) > 0:
            print("N\t%s\t%s\t%s" % (f["name"], newest, fork))
    files = ((f.get("bottle") or {}).get("stable") or {}).get("files") or {}
    if not any(t == "all" or (t in RELEASES and RELEASES[t] <= major) for t in files):
        print("B\t%s" % f["name"])
PY
  then
    warn "Could not check installed formulae against Intelbrew: $(tail -1 "$tmpdir/py.err")"
    return 0
  fi
  n="$(grep -c '^N' "$tsv" || true)"
  if (( n > 0 )); then
    printf '\n'
    warn "$n installed formula(e) are NEWER than Intelbrew's version (installed from Homebrew's API before switching):"
    awk -F'\t' '$1 == "N" { printf "    %s %s (Intelbrew has %s)\n", $2, $3, $4 }' "$tsv" >&2
    printf '  These stay as they are (brew won'"'"'t downgrade) until Intelbrew catches up;\n  a reinstall would use the older fork version.\n' >&2
  fi
  n="$(grep -c '^B' "$tsv" || true)"
  if (( n > 0 )); then
    names="$(awk -F'\t' '$1 == "B" { printf "%s ", $2 }' "$tsv")"
    printf '\n'
    say "$n installed formula(e) have no Intelbrew bottle for macOS $macos_major on Intel; these will build from source on upgrade/reinstall:"
    printf '%s\n' "${names% }" | fold -s -w 72 | sed 's/^/    /'
  fi
  return 0
}

# The loud closing note. Open windows (and the shell that started this installer)
# keep their old environment until restarted.
action_box() {
  local lines=() rule l
  lines+=("ACTION NEEDED")
  lines+=("")
  lines+=("Terminal windows that were already open, INCLUDING THIS ONE, still have")
  lines+=("the OLD settings: brew run from them does not use Intelbrew.")
  if [[ -n "$ORIG_CORE_REMOTE" && "$(normalize_url "$ORIG_CORE_REMOTE")" != "$CORE_GIT_REMOTE" ]]; then
    lines+=("" "This terminal has a DIFFERENT HOMEBREW_CORE_GIT_REMOTE:" "  $ORIG_CORE_REMOTE")
  elif [[ -z "$ORIG_CORE_REMOTE" ]]; then
    lines+=("" "This terminal does not have HOMEBREW_CORE_GIT_REMOTE set.")
  fi
  [[ "$ORIG_API" == "1" ]] || lines+=("This terminal does not have HOMEBREW_NO_INSTALL_FROM_API=1.")
  if (( reset_brew )) && [[ -n "$ORIG_BREW_REMOTE" ]] && ! is_upstream_brew "$ORIG_BREW_REMOTE"; then
    lines+=("This terminal still has HOMEBREW_BREW_GIT_REMOTE=$ORIG_BREW_REMOTE")
  fi
  lines+=("")
  lines+=("In every open window, run:    exec ${SHELL:-/bin/zsh} -l")
  lines+=("or close it and open a new window. Then check:")
  lines+=("  brew config | grep -E 'CORE_GIT_REMOTE|NO_INSTALL_FROM_API'")
  lines+=("Expected output:")
  lines+=("  HOMEBREW_CORE_GIT_REMOTE: $CORE_GIT_REMOTE")
  lines+=("  HOMEBREW_NO_INSTALL_FROM_API: set")
  (( reset_brew )) && lines+=("and \`brew config | grep BREW_GIT_REMOTE\` should print nothing.")
  rule="+$(printf '%76s' '' | tr ' ' '=')+"
  printf '\n%s\n' "$rule"
  for l in "${lines[@]}"; do printf '| %-74s |\n' "$l"; done
  printf '%s\n' "$rule"
}

env_is_current() {  # does the shell that started the installer already have both?
  [[ "$(normalize_url "$ORIG_CORE_REMOTE")" == "$CORE_GIT_REMOTE" && "$ORIG_API" == "1" ]]
}

say "macOS $macos, $arch. Homebrew: $mode install at $PREFIX."
if [[ "$core_action" == "none" && ${#profile_changes[@]} -eq 0 && "$reset_brew" == 0 ]]; then
  if (( ${#targets[@]} > 0 )); then
    say "Already set up: homebrew/core comes from $CORE_GIT_REMOTE and ${targets[*]} has both settings. Nothing to change."
  else
    say "homebrew/core already comes from $CORE_GIT_REMOTE. Nothing to change."
    warn "Unrecognised login shell (${SHELL:-unset}). Make sure its startup file has:"
    printf '  %s\n  %s\n' "$LINE_API" "$LINE_REMOTE"
  fi
  [[ "$mode" != "existing" ]] || report_installed
  env_is_current || action_box
  exit 0
fi

need_update=0
[[ "$core_action" == "none" && "$reset_brew" == 0 ]] || need_update=1

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
if (( reset_brew && brew_origin_fix )); then
  printf '  in %s: set origin to %s (was %s)\n' "$brew_repo" "$BREW_GIT_URL" "$brew_origin"
fi
if (( ${#targets[@]} > 0 )); then
  show_profile_plan
else
  warn "Unrecognised login shell (${SHELL:-unset}). Add these two lines to its startup file yourself:"
  printf '  %s\n  %s\n' "$LINE_API" "$LINE_REMOTE"
  (( ${#profile_changes[@]} == 0 )) || show_profile_plan
fi
(( need_update == 0 )) || printf '  brew update\n'
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
    say "One-time download: homebrew/core from the fork is about 1.3 GB; expect roughly 5-10 minutes on a normal connection."
    # CoreTap#install clones HOMEBREW_CORE_GIT_REMOTE (never shallow).
    run "$BREW" tap homebrew/core ;;
  switch)
    run git -C "$core" remote set-url origin "$CORE_GIT_REMOTE"
    run git -C "$core" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    run git -C "$core" fetch --force origin
    run git -C "$core" checkout --force -B main origin/main
    [[ "$(git -C "$core" rev-parse HEAD)" == "$(git -C "$core" rev-parse origin/main)" ]] \
      || die "$core is not at the fork's main after the switch. Setup FAILED." ;;
esac

verify_core() {
  local url
  [[ -d "$core/.git" ]] || die "homebrew/core is not tapped at $core after setup."
  url="$(origin_of "$core")"
  is_core_origin "$core" \
    || die "homebrew/core's origin is '$url', not $CORE_GIT_REMOTE. Setup FAILED; brew would not use Intelbrew bottles."
  say "Verified: homebrew/core origin is $(git -C "$core" config --get remote.origin.url) ($(git -C "$core" rev-parse --short HEAD))."
}
verify_core

apply_profiles

if (( reset_brew )); then
  # Without the variable, `brew update` leaves an upstream origin alone.
  unset HOMEBREW_BREW_GIT_REMOTE
  (( brew_origin_fix == 0 )) || run git -C "$brew_repo" remote set-url origin "$BREW_GIT_URL"
fi

if (( need_update )); then
  run "$BREW" update
  verify_core   # brew update rewrites the core remote from HOMEBREW_CORE_GIT_REMOTE
  if (( reset_brew && brew_origin_fix )); then
    if is_upstream_brew "$(origin_of "$brew_repo")"; then
      say "Verified: Homebrew/brew origin is $BREW_GIT_URL."
    else
      warn "Homebrew/brew's origin is '$(origin_of "$brew_repo")' after brew update, not $BREW_GIT_URL (a brew.env file may set HOMEBREW_BREW_GIT_REMOTE)."
    fi
  fi
fi

# A shell started the way the user's terminals start must see both settings,
# including a NON-login one (tmux, IDE terminals), or brew silently uses the
# upstream API feed instead of Intelbrew. Check in fresh child shells.
# shellcheck disable=SC2016  # the $VARs are expanded by the child shell
probe='printf "%s|%s" "$HOMEBREW_CORE_GIT_REMOTE" "$HOMEBREW_NO_INSTALL_FROM_API"'
shell_sees() {  # shell_sees login|nonlogin: prints "<remote>|<api>" as that shell sees them
  local zd=()
  [[ -n "${ZDOTDIR:-}" ]] && zd=("ZDOTDIR=$ZDOTDIR")
  case "${SHELL:-}:$1" in
    */zsh:nonlogin)  env -i HOME="$HOME" ${zd[@]+"${zd[@]}"} zsh -c "$probe" 2>/dev/null ;;
    */zsh:login)     env -i HOME="$HOME" ${zd[@]+"${zd[@]}"} zsh -lc "$probe" 2>/dev/null ;;
    */bash:login)    env -i HOME="$HOME" bash -lc "$probe" 2>/dev/null ;;
    */bash:nonlogin) env -i HOME="$HOME" bash -ic "$probe" 2>/dev/null </dev/null ;;
  esac
}
if (( ${#targets[@]} > 0 )); then
  for how in login nonlogin; do
    seen="$(shell_sees "$how" || true)"
    if [[ "$(normalize_url "${seen%%|*}")" != "$CORE_GIT_REMOTE" || "${seen#*|}" != "1" ]]; then
      warn "A new $how ${SHELL##*/} shell does not see both settings (got '${seen:-nothing}'). Something later in your startup files may override them; check with: grep -n HOMEBREW_ ~/.z* ~/.bash* ~/.profile"
    else
      say "Checked: a new $how ${SHELL##*/} shell sees both settings."
    fi
  done
fi

report_installed

cat <<EOF

Intelbrew is set up. The settings are in: ${targets[*]:-the startup file of your shell}.
Formulae without an Intelbrew bottle build from source; see
https://github.com/d4rkwyng/intelbrew#coverage
EOF
action_box
