#!/usr/bin/env bash
# Prepare an Xcode project for prrrrrrrrr on iOS.
# The user opens the generated project in Xcode and builds/installs from there
# (device code signing requires the Xcode GUI).
#
# Usage:
#   ./setup-ios.sh              # build for connected device
#   ./setup-ios.sh --simulator  # build for simulator

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

# Copy nix output to a stable in-repo directory (nix store is read-only)
rm -rf ios-project
cp -r "$result/share/ios/." ios-project/
chmod -R u+w ios-project

# Clear Xcode's DerivedData for Hatter so stale build settings don't persist
find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name 'Hatter-*' -exec rm -rf {} + 2>/dev/null || true

# Generate Xcode project
cd ios-project
xcodegen generate

echo ""
echo "Xcode project ready. Open it with:"
echo "  open ios-project/Hatter.xcodeproj"
echo ""
echo "Then build and install from Xcode (Product → Run)."
