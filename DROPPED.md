# Dropped formulae

Intelbrew builds x86_64 Sonoma bottles for the most-installed homebrew-core formulae.
When a formula's Intel build keeps failing, we hold it at its last working version (a
"pin"). If it is still stuck after 8 weeks, we drop it: Intelbrew stops building
bottles for it, and `brew install` builds it from source instead. The formula itself is
still upstream's and still updates.

A dropped formula may be re-added once its Intel build works again.

This file is generated from Intelbrew's build state. Please don't edit it by hand.

No formulae have been dropped.
