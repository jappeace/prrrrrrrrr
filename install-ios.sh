#!/usr/bin/env bash
# Install prrrrrrrrr on an iOS device or simulator.
# Requires macOS with Xcode and Nix installed.
#
# Usage:
#   ./install-ios.sh              # build for connected device
#   ./install-ios.sh --simulator  # build for booted simulator

set -euo pipefail

[ -z "${PRRRRRRRRR_API_KEY:-}" ] && echo "Set PRRRRRRRRR_API_KEY" && exit 1

TARGET="device"
if [ "${1:-}" = "--simulator" ]; then
  TARGET="simulator"
fi

REPO_DIR="$(pwd)"
sed -i '' "s/PRRRRRRRRR_API_KEY/$PRRRRRRRRR_API_KEY/" src/GymTracker/Config.hs
trap 'cd "$REPO_DIR" && git checkout src/GymTracker/Config.hs' EXIT

if [ "$TARGET" = "simulator" ]; then
  result=$(nix-build nix/ios-app.nix)
else
  result=$(nix-build nix/ios-device-app.nix)
fi

# Copy nix output to a writable directory (nix store is read-only)
workdir=$(mktemp -d)
cp -r "$result/share/ios/." "$workdir/"
chmod -R u+w "$workdir"

# Generate Xcode project and build
cd "$workdir"
xcodegen generate

if [ "$TARGET" = "simulator" ]; then
  xcodebuild -scheme Hatter \
      -destination 'generic/platform=iOS Simulator' \
      -configuration Debug build \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Hatter.app
  xcrun simctl launch booted me.jappie.hatter
else
  xcodebuild -scheme Hatter \
      -destination 'generic/platform=iOS' \
      -configuration Debug \
      -allowProvisioningUpdates \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  echo ""
  echo "Build succeeded. To install on your device:"
  echo "  open $workdir/Hatter.xcodeproj"
  echo "Then select your device in Xcode and press Run."
fi
