# Intelbrew

Keeping Homebrew usable on Intel Macs.

> **Status: pre-release, not yet usable.** No bottles have been published and the
> installer is an untested draft. Please don't point a real Mac at this yet.

Homebrew made Intel macOS a Tier 3 platform in 7.0. Upstream no longer builds x86_64
bottles and plans to remove Intel support in or after September 2027. Intelbrew
rebuilds x86_64 bottles for the most-installed homebrew-core formulae every week, on
our own Intel macOS Sonoma builder. After you switch over, plain `brew install` and
`brew upgrade` use them. There's no wrapper command.

## How it works

Intelbrew publishes a fork of homebrew-core, `intelbrew-core`. It is upstream's
formulae plus bottle blocks pointing at x86_64 Sonoma bottles hosted on that fork's
GitHub Releases. Homebrew uses it when it runs in git mode with the core remote set
to the fork:

```sh
export HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_CORE_GIT_REMOTE=https://github.com/d4rkwyng/intelbrew-core
```

**An installer is coming.** `install.sh` in this repo is a draft: it installs brew to
`/usr/local`, adds those two lines to your shell profile, and clones core from the fork.
Until it's tested, there are no supported setup instructions.

## Who it's for

- **Intel (x86_64) Macs only.** Apple Silicon users should use upstream Homebrew; the
  installer refuses to run there.
- **macOS 14 Sonoma or newer** to get bottles. Sonoma bottles also serve Sequoia and
  Tahoe on Intel. Older macOS can still use the formulae, but brew builds them from source.
- **CPU baseline: Westmere.** Homebrew's Intel bottles for Ventura and later target
  Westmere, so ours do too. **Core 2 and Penryn Macs** (including many OpenCore Legacy
  Patcher machines) **are not supported**: the bottles won't run on them.
- The Command Line Tools are required. Homebrew needs them on Intel even to pour bottles.

## Coverage

The top 500 formulae by installs, plus their dependencies and build dependencies, come to
about 880 formulae. Formulae outside that set still update weekly, but build from source.
A formula whose Intel build breaks is held at its last working version until it's fixed.
Held formulae are listed in the weekly status.

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
- For GPL/LGPL software, a corresponding-source offer (upstream source tarballs and patches
  per release) is **TBD and will be in place before any bottle is published**.

## Not affiliated

- Intelbrew is an independent community project. It is not affiliated with or endorsed by
  the Homebrew project. "Homebrew" is used here only to describe what this works with.
- Intelbrew is **not affiliated with `rhyn-daitenku/intelbrew`**, an unrelated project with
  the same name.
