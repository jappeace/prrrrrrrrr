# prrrrrrrrr

This project is a consumer of [haskell-mobile](https://github.com/jappeace/haskell-mobile).
Its purpose is to drive haskell-mobile's API design by being a real-world user of it.

## Rule: fix defects upstream, not here

If you encounter a haskell-mobile defect while working on this project — a missing feature,
a wrong abstraction, a symbol that leaks into consumer code — fix it in haskell-mobile.
Do not add workarounds here (FFI exports, compatibility stubs, conditional imports, etc.).

A workaround in prrrrrrrrr that papers over a haskell-mobile bug is a code smell. It hides
the problem from the library's own test suite and makes the correct fix harder to see.

## Rule: the pin must point to jappeace/haskell-mobile master

`npins/sources.json` must pin `jappeace/haskell-mobile` master, not a fork or feature branch.

If a haskell-mobile fix is needed, open a PR there and wait for it to merge before updating
the pin here. Working against a fork branch (`jappeace-sloth/...`) is only acceptable as a
short-lived intermediate step while the upstream PR is in review.
