# Intelbrew

Keeping Homebrew usable on Intel Macs.

Homebrew made Intel macOS a Tier 3 platform in September 2026. Upstream no longer builds x86_64
bottles and plans to remove Intel support in or after September 2027. Intelbrew
rebuilds x86_64 bottles for the most-installed homebrew-core formulae every week, on
our own Intel macOS Sonoma builder. After you switch over, plain `brew install` and
`brew upgrade` use them. There's no wrapper command.

## How it works

Intelbrew publishes a fork of homebrew-core, `intelbrew-core`. It is upstream's
formulae plus bottle blocks pointing at x86_64 Sonoma bottles hosted on that fork's
GitHub Releases. Homebrew uses it when it runs in git mode with the core remote set
to the fork.

Homebrew itself (`Homebrew/brew`) comes from a small fork too, `d4rkwyng/brew`: each
upstream release merged with one patch that replaces brew's Intel "Tier 3" warning with a
single line, `Intelbrew: bottles from d4rkwyng/intelbrew-core`. The fork carries its own
release tags (7.0.11 = upstream 7.0.11 + the patch); `brew update` fetches them and
checks out the newest, as it does upstream. It is kept up to date by merges, never
rebases or force-pushes.

```sh
export HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_CORE_GIT_REMOTE=https://github.com/d4rkwyng/intelbrew-core
export HOMEBREW_BREW_GIT_REMOTE=https://github.com/d4rkwyng/brew
```

## Install

On an Intel Mac running macOS 14 Sonoma or newer, with the Command Line Tools installed
(`xcode-select --install`), run in Terminal:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/d4rkwyng/intelbrew/main/install.sh)"
```

It prints every change and asks before making them. Then open a new terminal window and
use `brew` as usual.

- **No Homebrew yet:** it clones Homebrew from `d4rkwyng/brew` to `/usr/local/Homebrew`
  and checks out its newest release tag (asking for `sudo` only if `/usr/local` needs new
  directories), links `/usr/local/bin/brew`, and runs
  `brew tap homebrew/core`, a full clone of `intelbrew-core` (about 1.3 GB).
- **Existing `/usr/local` Homebrew:** nothing is reinstalled and no formulae are removed.
  If you have no local homebrew/core (the default, API mode), it taps it from the fork. If
  you already have one, it points its `origin` at the fork and checks out the fork's
  `main`; it refuses if that checkout has uncommitted changes. Formulae you already have
  stay as they are; new installs and upgrades use Intelbrew bottles where there is one.
- **Homebrew/brew:** `d4rkwyng/brew` is the expected remote. If `$(brew --repository)`
  has upstream `Homebrew/brew`, another fork, or no origin, the plan includes pointing its
  `origin` at `d4rkwyng/brew`, fetching its tags and checking out its newest release tag
  as branch `stable`, the way `brew update` does. Local release tags newer than the
  fork's (upstream's unpatched copies, which `brew update` would otherwise pick) are
  deleted. It refuses if tracked files there have uncommitted changes, and it warns if the
  fork's newest tag is more than one release behind upstream's.
- **Shell profile:** it puts the three `export` lines above in `~/.zshenv` (zsh; read by
  every zsh, including non-login ones in tmux and IDE terminals) or in both
  `~/.bash_profile` and `~/.bashrc` (bash; `~/.profile` instead of `~/.bash_profile` if
  that's the only one you have), then checks that a new login and non-login shell both
  see them. Windows already open keep the old settings until reopened. Existing lines
  for those variables in any zsh/bash startup file are rewritten in place, duplicates
  removed, and each edited file is backed up next to itself as
  `<file>.intelbrew-backup-<date>`. Running it again changes nothing.
- It checks afterwards that homebrew/core's `origin` really is the core fork and that
  Homebrew/brew's `origin` is `d4rkwyng/brew` at its newest release tag, and fails loudly
  if not. It refuses if a `brew.env` file sets `HOMEBREW_CORE_GIT_REMOTE` or
  `HOMEBREW_BREW_GIT_REMOTE` to anything else.
- Before the first core clone it tells you it's a one-time download of about 1.3 GB
  (roughly 5-15 minutes). It ends with a boxed **ACTION NEEDED** note: windows that were
  already open, including the one you ran it from, must be restarted
  (`exec $SHELL -l`), and it says so explicitly if that shell still has a different
  `HOMEBREW_CORE_GIT_REMOTE` or `HOMEBREW_BREW_GIT_REMOTE`.
- Once core points at the fork, it lists installed formulae that are **newer** than
  Intelbrew's version (e.g. installed earlier from Homebrew's API). They stay as they
  are, since brew never downgrades, until Intelbrew catches up; a reinstall would use the
  older fork version. It also lists installed formulae with **no Intelbrew bottle** for
  your macOS, which will build from source on upgrade or reinstall.
- If you have run a Homebrew developer command (or set `HOMEBREW_DEVELOPER`), `brew
  update` follows the fork's default branch instead of its release tags; the installer
  warns if `brew update` leaves Homebrew/brew off the release tag.

To check, in a new terminal: `brew config` should list all three variables, and
`git -C "$(brew --repository homebrew/core)" remote get-url origin` should print the fork.

To switch by hand instead, add the three lines to your shell profile, open a new terminal,
then `brew tap homebrew/core` (no core tap yet) and `brew update` (`brew update` resets
the core and brew remotes to `HOMEBREW_CORE_GIT_REMOTE` and `HOMEBREW_BREW_GIT_REMOTE`,
fetches the fork's tags and checks out the newest).

To go back to upstream Homebrew, remove the three lines, open a new terminal, run
`git -C "$(brew --repository)" remote set-url origin https://github.com/Homebrew/brew`
and `brew update`, and optionally `brew untap homebrew/core` to delete the core clone.

## Who it's for

- **Intel (x86_64) Macs only.** Apple Silicon users should use upstream Homebrew; the
  installer refuses to run there, including under Rosetta.
- **macOS 14 Sonoma or newer.** Sonoma bottles also serve Sequoia and Tahoe on Intel,
  including Macs running them through OpenCore Legacy Patcher. The installer refuses
  macOS 13 Ventura and older, where the bottles wouldn't be used.
- **CPU baseline: Westmere.** Homebrew's Intel bottles for Ventura and later target
  Westmere, so ours do too. **Core 2 and Penryn Macs** (including many OpenCore Legacy
  Patcher machines) **are not supported**: the bottles won't run on them, and the
  installer refuses to run without SSE4.2, POPCNT, AES and PCLMULQDQ.
- The Command Line Tools are required. Homebrew needs them on Intel even to pour bottles.

## Coverage

**Coverage is partial right now.** Bottles were first published in week 43 of 2026.
After each sync with upstream, formulae whose version changed need a new Intel build, and
there is currently a backlog of them being rebuilt. Until a formula's bottle is rebuilt,
`brew install` builds it from source, which can take a long time for big formulae. That
fills in over the following days and weeks.

The top 500 formulae by installs, plus their dependencies and build dependencies, come to
about 880 formulae. Formulae outside that set still update weekly, but build from source.
A few formulae can't be built on our Sonoma builder (for example ones that need a full
Xcode or a newer toolchain; currently this includes `node`). Those, and formulae that
depend on them, get no Intelbrew bottle and also build from source.
A formula whose Intel build breaks is held at its last working version until it's fixed.
Held formulae are listed in the weekly status. If a formula is still stuck after 8 weeks,
we drop it: Intelbrew stops building bottles for it and `brew install` builds it from
source. Dropped formulae are listed in [DROPPED.md](DROPPED.md).

## Costs of git mode

- A one-off full clone of homebrew-core (about 1.3 GB). Homebrew never shallow-clones core.
- `brew update` and formula loading are slower than in API mode.
- Casks also leave API mode, and `brew install --cask` may need an extra clone. This is
  not yet verified.

## Licensing

- The scripts and docs in this repo are BSD-2-Clause, the same licence as Homebrew. See
  [LICENSE](LICENSE).
- The bottles are built unmodified from upstream homebrew-core formulae, except for
  Intel fixes that are recorded in the fork's history. Each bottle keeps its upstream
  project's own licence.
- For GPL/LGPL software, the corresponding source (upstream source archives, resources,
  patches and the formula) is published in the same GitHub Release as the bottle.

## Not affiliated

- Intelbrew is an independent community project. It is not affiliated with or endorsed by
  the Homebrew project. "Homebrew" is used here only to describe what this works with.
- Intelbrew is **not affiliated with `rhyn-daitenku/intelbrew`**, an unrelated project with
  the same name.

## Trademarks

Homebrew, Apple, Mac, macOS and Intel are trademarks of their respective owners. They are
used here only to describe compatibility. No endorsement is implied.
