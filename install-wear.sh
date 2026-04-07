#!/usr/bin/env bash
# Install prrrrrrrrr on a Wear OS watch (armeabi-v7a / 32-bit ARM).
# Connect the watch via ADB (Wi-Fi or USB debugging) before running.

set -euo pipefail

adb uninstall me.jappie.prrrrrrrrr 2>/dev/null || true
adb install "$(nix-build nix/apk.nix --argstr androidArch armv7a)/prrrrrrrrr.apk"
