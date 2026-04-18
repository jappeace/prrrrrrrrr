> I go to gym every sunday to lift and pray 

# prrrrrrrrr

Track personal records in a nifty app.
Saves navigating annoying UI.


This project is a consumer of [haskell-mobile](https://github.com/jappeace/haskell-mobile).
Its purpose is to drive haskell-mobile's API design by being a real-world user of it.

# Hacking

## fix defects upstream, not here

If you encounter a haskell-mobile defect while working on this project — a missing feature,
a wrong abstraction, a symbol that leaks into consumer code — fix it in haskell-mobile.
Do not add workarounds here (FFI exports, compatibility stubs, conditional imports, etc.).

A workaround in prrrrrrrrr that papers over a haskell-mobile bug is a code smell. It hides
the problem from the library's own test suite and makes the correct fix harder to see.

# Deploying

## Android

```bash
export PRRRRRRRRR_API_KEY=your-key
./install.sh                    # phone (aarch64)
./install-wear.sh               # Wear OS watch (armv7a)
```

## iOS

Requires macOS with Xcode and Nix installed.

```bash
export PRRRRRRRRR_API_KEY=your-key
./setup-ios.sh              # device (default)
./setup-ios.sh --simulator  # simulator
```

This builds the Haskell library via native GHC, patches it for iOS with mac2ios,
and stages an Xcode project in `ios-project/`. Open the project in Xcode and
build/install from there (Product → Run).

