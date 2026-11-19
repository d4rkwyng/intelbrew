# What the installer does

This is the detail behind the one-line install in the [README](../README.md#install).
The installer prints every change and asks before making it.

## Before it starts

It refuses to run on Apple Silicon (including under Rosetta), on macOS 13 Ventura or
older, on a CPU without SSE4.2, POPCNT, AES and PCLMULQDQ (Core 2, Penryn, Nehalem, and
the Core i3 models without AES-NI), and without the Command Line Tools. See
[Is this for me?](../README.md#is-this-for-me).

The CPU check matches Homebrew's Intel bottles for Ventura and later, which target
Westmere. Core 2 and Penryn Macs (including many OpenCore Legacy Patcher machines) can't
run them, and neither can Nehalem (no AES or PCLMULQDQ) or a Core i3 without AES-NI. To
run the same check yourself (it should print `4`):

```sh
sysctl -n machdep.cpu.features | tr ' ' '\n' | grep -cxE 'SSE4\.2|POPCNT|AES|PCLMULQDQ'
```

The Command Line Tools are needed on Intel even to pour bottles. It also refuses to run as
root or with `sudo` (it asks for `sudo` itself when it needs it).

## No Homebrew yet

It clones Homebrew from `d4rkwyng/brew` to `/usr/local/Homebrew` and checks out its
newest release tag. It asks for `sudo` only to create directories in `/usr/local` or take
ownership of ones you can't write to. It links `/usr/local/bin/brew`, and runs
`brew tap homebrew/core`, a full clone of `intelbrew-core` (about 1.3 GB).

## Existing Homebrew

For an existing `/usr/local` Homebrew, its first question offers three choices:

- **Switch in place (the default).** Nothing is reinstalled and no formulae are removed.
  - If you have no local homebrew/core (the default, API mode), it taps it from the fork.
  - If you already have one, it points its `origin` at the fork and checks out the fork's
    `main`. It refuses if that checkout has uncommitted changes.
  - Formulae you already have stay as they are; new installs and upgrades use Intelbrew
    bottles where there is one.
- **Uninstall and reinstall.** It uninstalls the existing Homebrew with Homebrew's
  official uninstaller and then installs fresh. This removes every installed formula and
  cask, and needs you to type `yes`.
- **Quit.**

With `--yes` (or `INTELBREW_YES=1`) it always switches in place.

## Homebrew/brew

`d4rkwyng/brew` is the expected remote. If `$(brew --repository)` has upstream
`Homebrew/brew`, another fork, or no origin, the plan includes:

- pointing its `origin` at `d4rkwyng/brew`;
- fetching its tags and checking out its newest release tag as branch `stable`, the way
  `brew update` does;
- deleting local release tags newer than the fork's (upstream's unpatched copies, which
  `brew update` would otherwise pick).

It refuses if tracked files there have uncommitted changes. It warns if the fork's newest
tag is more than one release behind upstream's.

## Shell profile

It puts the three `export` lines from the [README](../README.md#how-it-works) in:

- **zsh:** `~/.zshenv`. Every zsh reads it, including non-login ones in tmux and IDE
  terminals. If you use `ZDOTDIR`, it also writes them to `$ZDOTDIR/.zshenv`.
- **bash:** both `~/.bash_profile` and `~/.bashrc`. If you have no `~/.bash_profile`, it
  uses `~/.bash_login` or `~/.profile`, whichever bash reads.

Then it checks that a new login and non-login shell both see them. Windows already open
keep the old settings until reopened.

Existing lines that set those variables in any zsh/bash startup file are rewritten in
place (every copy; no line is deleted). Each edited file is backed up next to itself as
`<file>.intelbrew-backup-<date>`. Running the installer again changes nothing.

## Checks and refusals

- Afterwards it checks that homebrew/core's `origin` really is the core fork, and that
  Homebrew/brew's `origin` is `d4rkwyng/brew` at its newest release tag. It fails loudly
  if not.
- It refuses if a `brew.env` file sets `HOMEBREW_CORE_GIT_REMOTE` or
  `HOMEBREW_BREW_GIT_REMOTE` to anything else.
- It refuses if an existing homebrew/core tap is a shallow clone, since `brew update`
  refuses those. It prints the `git fetch --unshallow` command to run first.
- It refuses, changing nothing, if `/usr/local` holds a partial Homebrew (only one of
  `bin/brew` and a `Homebrew` git checkout) or a `bin/brew` symlink pointing nowhere, or
  if there is no Homebrew in `/usr/local` but a `brew` elsewhere is on your `PATH` (for
  example `/opt/homebrew`): take that one off your `PATH` or uninstall it first.

## Casks (optional)

Whenever homebrew/cask isn't tapped, it shows a short boxed note before the plan
(*Casks are OFF: apps installed with brew install --cask (Chrome, VS Code, ...) won't be
found.*) and asks *Enable casks? One-time download, about 620 MB. [Y/n]*. Enter means
yes. If you say yes, `brew tap homebrew/cask` appears in the plan and runs after the
core tap. If you say no, it prints a one-line reminder of how to add them later.

It asks on a Mac that is already set up too (the "Already set up ... Nothing to change"
run): there a yes runs just `brew tap homebrew/cask`, with no plan or `yes` to type, and
changes nothing else.

It never taps casks with `--yes` alone, or when the terminal input ends without an
answer; both print the reminder. `--no-casks` skips the question. If homebrew/cask is
already tapped it doesn't ask, and the plan says so. If the cask clone fails, it warns
and carries on; the core setup is unaffected.

## Download size and the ACTION NEEDED note

Before the first core clone it tells you it's a one-time download of about 1.3 GB
(roughly 5-15 minutes).

It ends with a boxed **ACTION NEEDED** note: windows that were already open, including the
one you ran it from, must be restarted (`exec $SHELL -l`). It says so explicitly if that
shell still has a different `HOMEBREW_CORE_GIT_REMOTE` or `HOMEBREW_BREW_GIT_REMOTE`.

## Newer formulae and formulae with no bottle

Once core points at the fork, it lists:

- Installed formulae that are **newer** than Intelbrew's version (for example, installed
  earlier from Homebrew's API). They stay as they are, since brew never downgrades, until
  Intelbrew catches up. A reinstall would use the older fork version.
- Installed formulae with **no Intelbrew bottle** for your macOS. These will build from
  source on upgrade or reinstall.

## HOMEBREW_DEVELOPER

If you have run a Homebrew developer command (or set `HOMEBREW_DEVELOPER`),
`brew update` follows the fork's default branch instead of its release tags. The
installer warns if `brew update` leaves Homebrew/brew off the release tag.

## Options

- `--yes`, or `INTELBREW_YES=1`: don't ask before each change. It still prints them.
  Optional changes (casks) are not made. With an existing Homebrew it always switches in
  place.
- `--casks`, or `INTELBREW_CASKS=1`: tap homebrew/cask without asking, also with `--yes`.
  On an otherwise set-up Mac this only adds the cask tap.
- `--no-casks`, or `INTELBREW_CASKS=0`: don't tap homebrew/cask, and don't ask.

With the short form, put options after `bash -s --`:
`curl -fsSL https://intelbrew.sh | bash -s -- --yes`. Questions are always read from
the terminal, not from the pipe. With no terminal at all (CI, `ssh` without `-t`) the
installer stops, changing nothing, unless `--yes` is given.

## More questions

### I have a formula that's newer than Intelbrew's

That happens if you installed it earlier from Homebrew's API. It stays as it is, since
brew never downgrades, until Intelbrew catches up. A reinstall would use the older fork
version. The installer lists these formulae for you (see
[above](#newer-formulae-and-formulae-with-no-bottle)).

### How do I update?

As usual: `brew update` and `brew upgrade`.

### I already have Homebrew. What happens?

By default the installer switches it to Intelbrew in place. Nothing is reinstalled and no
formulae are removed. Formulae you already have stay as they are; new installs and
upgrades use Intelbrew bottles where there is one. You can also choose to uninstall and
install fresh, or quit. See [Existing Homebrew](#existing-homebrew).

### Can I switch by hand, without the installer?

Yes. Add the three `export` lines from the [README](../README.md#how-it-works) to your
shell profile and open a new terminal. Then run `brew tap homebrew/core` (if you have no
core tap yet) and `brew update`. `brew update` resets the core and brew remotes to
`HOMEBREW_CORE_GIT_REMOTE` and `HOMEBREW_BREW_GIT_REMOTE`, fetches the fork's tags and
checks out the newest.
