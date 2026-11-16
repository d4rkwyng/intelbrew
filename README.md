# Intelbrew

Ready-made Homebrew packages for Intel Macs.

Homebrew no longer builds ready-made packages ("bottles") for Intel Macs, so `brew install`
falls back to compiling from source, which can take a long time. Intelbrew builds them
every week on its own Intel macOS builder. Run one command to switch, then use `brew` as normal.

## Is this for me?

- An **Intel Mac** (not Apple Silicon).
- **macOS 14 Sonoma or newer**, including Sequoia and Tahoe through OpenCore Legacy
  Patcher.
- **Not a Core 2 or Penryn CPU.** Macs from 2011 on are fine; some 2010 models are too.
- Apple's **Command Line Tools**. If you don't have them, run `xcode-select --install`.

The installer checks all of these and stops, without changing anything, if one is
missing. The exact CPU check is in [docs/installer.md](docs/installer.md#before-it-starts).

## Install

Paste this into Terminal:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/d4rkwyng/intelbrew/main/install.sh)"
```

What you'll see:

1. If you already have Homebrew, a choice: press **Enter** to switch it in place and keep
   your installed packages.
2. A list of every change it will make. Type the word **`yes`** and press Enter to go
   ahead. Anything else stops it with nothing changed.
3. Possibly your Mac password, if it needs to create folders in `/usr/local`. Nothing
   shows on screen while you type it; that's normal.
4. A one-time download of about 1.3 GB (roughly 5-15 minutes).
5. A boxed **ACTION NEEDED** note at the end: quit Terminal and open it again. Windows
   that were already open keep the old settings until restarted (`exec $SHELL -l`).

To check it worked, in the new Terminal window:

```sh
brew config | grep GIT_REMOTE
```

Both lines should mention `d4rkwyng`. To check the core tap itself,
`git -C "$(brew --repository homebrew/core)" remote get-url origin` should print the
fork's URL. Then use `brew install` and `brew upgrade` as usual.

**Apps (`brew install --cask`)** need one extra step the first time:
`brew tap homebrew/cask` (about 620 MB). See [below](#brew-install---cask-says-no-cask-with-this-name-exists).

The full list of what the installer checks and changes is in
[docs/installer.md](docs/installer.md).

## Common questions

### `brew install --cask` says "No Cask with this name exists"

Casks leave API mode too, so you need to tap them once:

```sh
brew tap homebrew/cask
```

That is a full clone of about 620 MB (around a minute on a fast connection), and
`brew update` keeps it current from then on. Intelbrew does not build or test casks: they
are upstream app downloads, and each still has its own macOS minimum (for example,
Vivaldi needs Ventura).

### Why is a formula building from source?

There's no Intelbrew bottle for it yet, or there won't be one. The usual reasons:

- It's outside the top set (see [Coverage](#coverage)).
- Its version changed upstream and its new bottle is still in the rebuild backlog.
- Its Intel build broke. It's held at its last working version until it's fixed.
- It was still stuck after 8 weeks, so it was dropped: Intelbrew stops building bottles
  for it and `brew install` builds it from source. See [DROPPED.md](DROPPED.md).
- It can't be built on our Sonoma builder, for example because it needs a full Xcode or a
  newer toolchain (currently this includes `node`). Formulae that depend on it get no
  Intelbrew bottle either.

### I have a formula that's newer than Intelbrew's

That happens if you installed it earlier from Homebrew's API. It stays as it is, since
brew never downgrades, until Intelbrew catches up. A reinstall would use the older fork
version. The installer lists these formulae for you.

### How do I update?

As usual: `brew update` and `brew upgrade`.

### I already have Homebrew. What happens?

By default the installer switches it to Intelbrew in place. Nothing is reinstalled and no
formulae are removed. Formulae you already have stay as they are; new installs and
upgrades use Intelbrew bottles where there is one. You can also choose to uninstall and
install fresh, or quit. See [docs/installer.md](docs/installer.md#existing-homebrew).

### Can I switch by hand, without the installer?

Yes. Add the three `export` lines from [How it works](#how-it-works) to your shell
profile and open a new terminal. Then run `brew tap homebrew/core` (if you have no core
tap yet) and `brew update`. `brew update` resets the core and brew remotes to
`HOMEBREW_CORE_GIT_REMOTE` and `HOMEBREW_BREW_GIT_REMOTE`, fetches the fork's tags and
checks out the newest.

### How do I go back to upstream Homebrew?

1. Remove the three `export` lines from your shell profile and open a new terminal.
2. Run:

   ```sh
   git -C "$(brew --repository)" remote set-url origin https://github.com/Homebrew/brew
   brew update
   ```

3. Optionally, delete the core clone: `brew untap homebrew/core`.

## Coverage

Intelbrew bottles the top 500 formulae by installs, plus their dependencies and build
dependencies: about 880 formulae. Formulae outside that set still update weekly, but build
from source. **Coverage is partial right now:** bottles were first published in week 43 of
2026, and after each sync with upstream, formulae whose version changed need a new Intel
build; there is currently a backlog of them being rebuilt. Until a formula's bottle is
rebuilt, `brew install` builds it from source, which can take a long time for big
formulae. That fills in over the following days and weeks.

## How it works

Homebrew made Intel macOS a Tier 3 platform in September 2026. Upstream no longer builds
x86_64 bottles and plans to remove Intel support in or after September 2027. Intelbrew
rebuilds x86_64 bottles for the most-installed homebrew-core formulae every week, on our
own Intel macOS Sonoma builder. There's no wrapper command: plain `brew` uses them.

Intelbrew publishes a fork of homebrew-core, `intelbrew-core`. It is upstream's formulae
plus bottle blocks pointing at x86_64 Sonoma bottles hosted on that fork's GitHub
Releases. Homebrew uses it when it runs in git mode with the core remote set to the fork.
These three lines in your shell profile do that:

```sh
export HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_CORE_GIT_REMOTE=https://github.com/d4rkwyng/intelbrew-core
export HOMEBREW_BREW_GIT_REMOTE=https://github.com/d4rkwyng/brew
```

Homebrew itself (`Homebrew/brew`) comes from a small fork too, `d4rkwyng/brew`: each
upstream release merged with one patch that replaces brew's Intel "Tier 3" warning with a
single line, `Intelbrew: bottles from d4rkwyng/intelbrew-core`. The fork carries its own
release tags (7.0.11 = upstream 7.0.11 + the patch). `brew update` fetches them and checks
out the newest, as it does upstream. The fork is kept up to date by merges, never rebases
or force-pushes.

## Costs of git mode

- A one-off full clone of homebrew-core (about 1.3 GB). Homebrew never shallow-clones core.
- `brew update` and formula loading are slower than in API mode.
- Casks leave API mode too, so you need `brew tap homebrew/cask` once (see
  [above](#brew-install---cask-says-no-cask-with-this-name-exists)).

## Licensing

- The scripts and docs in this repo are BSD-2-Clause, the same licence as Homebrew. See
  [LICENSE](LICENSE).
- The bottles are built unmodified from upstream homebrew-core formulae, except for Intel
  fixes that are recorded in the fork's history. Each bottle keeps its upstream project's
  own licence.
- For GPL/LGPL software, the corresponding source (upstream source archives, resources,
  patches and the formula) is published in the same GitHub Release as the bottle.

## Not affiliated

Intelbrew is an independent community project. It is not affiliated with or endorsed by
the Homebrew project. "Homebrew" is used here only to describe what this works with.
Intelbrew is also **not affiliated with `rhyn-daitenku/intelbrew`**, an unrelated project
with the same name.

## Trademarks

Homebrew, Apple, Mac, macOS and Intel are trademarks of their respective owners. They are
used here only to describe compatibility. No endorsement is implied.
