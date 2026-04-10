#!/usr/bin/env bash
# Install prrrrrrrrr on a Wear OS watch (armeabi-v7a / 32-bit ARM).
# Connect the watch via ADB (Wi-Fi or USB debugging) before running.

set -euo pipefail

[ -z "${PRRRRRRRRR_API_KEY:-}" ] && echo "Set PRRRRRRRRR_API_KEY" && exit 1

sed -i "s/PRRRRRRRRR_API_KEY/$PRRRRRRRRR_API_KEY/" src/GymTracker/Config.hs
trap 'git checkout src/GymTracker/Config.hs' EXIT

adb uninstall me.jappie.prrrrrrrrr 2>/dev/null || true
adb install "$(nix-build nix/apk.nix --argstr androidArch armv7a)/prrrrrrrrr.apk"
