#!/usr/bin/env bash
# Install prrrrrrrrr on the booted iOS simulator.
# Requires macOS with Xcode and Nix installed.

set -euo pipefail

[ -z "${PRRRRRRRRR_API_KEY:-}" ] && echo "Set PRRRRRRRRR_API_KEY" && exit 1

sed -i '' "s/PRRRRRRRRR_API_KEY/$PRRRRRRRRR_API_KEY/" src/GymTracker/Config.hs
trap 'git checkout src/GymTracker/Config.hs' EXIT

# Build iOS simulator library and stage Xcode project
result=$(nix-build nix/ios-app.nix)

# Generate Xcode project and build
cd "$result/share/ios"
xcodegen generate
xcodebuild -scheme HaskellMobile -sdk iphonesimulator -configuration Debug build

# Install on booted simulator
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/HaskellMobile.app
xcrun simctl launch booted me.jappie.haskellmobile
