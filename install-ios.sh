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
  # Auto-discover Apple Development team ID from keychain
  TEAM_ID=$(security find-identity -v -p codesigning \
    | grep "Apple Development" \
    | head -1 \
    | sed 's/.*(\(.*\)).*/\1/')
  [ -z "$TEAM_ID" ] && echo "No Apple Development signing identity found in keychain" && exit 1
  echo "Using team ID: $TEAM_ID"

  xcodebuild -scheme Hatter \
      -destination 'generic/platform=iOS' \
      -configuration Debug \
      -allowProvisioningUpdates \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
      DEVELOPMENT_TEAM="$TEAM_ID" \
      CODE_SIGN_STYLE=Automatic

  # Install on connected device
  APP_PATH=$(ls -d "$workdir"/build/Build/Products/Debug-iphoneos/Hatter.app 2>/dev/null \
    || ls -d DerivedData/Build/Products/Debug-iphoneos/Hatter.app 2>/dev/null)
  if [ -n "$APP_PATH" ]; then
    ios-deploy --bundle "$APP_PATH" || echo "ios-deploy not found — open Xcode to install: open $workdir/Hatter.xcodeproj"
  else
    echo "Build succeeded. Open Xcode to deploy: open $workdir/Hatter.xcodeproj"
  fi
fi
