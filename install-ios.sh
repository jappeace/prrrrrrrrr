#!/usr/bin/env bash
# Install prrrrrrrrr on the booted iOS simulator.
# Requires macOS with Xcode and Nix installed.

set -euo pipefail

[ -z "${PRRRRRRRRR_API_KEY:-}" ] && echo "Set PRRRRRRRRR_API_KEY" && exit 1

REPO_DIR="$(pwd)"
sed -i '' "s/PRRRRRRRRR_API_KEY/$PRRRRRRRRR_API_KEY/" src/GymTracker/Config.hs
trap 'cd "$REPO_DIR" && git checkout src/GymTracker/Config.hs' EXIT

# Build iOS simulator library and stage Xcode project
result=$(nix-build nix/ios-app.nix)

# Copy nix output to a writable directory (nix store is read-only)
workdir=$(mktemp -d)
cp -r "$result/share/ios/." "$workdir/"
chmod -R u+w "$workdir"

# Generate Xcode project and build
cd "$workdir"
xcodegen generate
xcodebuild -scheme Hatter -sdk iphonesimulator -configuration Debug build \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES

# Install on booted simulator
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Hatter.app
xcrun simctl launch booted me.jappie.hatter
