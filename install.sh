#!/usr/bin/env bash
set -euo pipefail

[ -z "${PRRRRRRRRR_API_KEY:-}" ] && echo "Set PRRRRRRRRR_API_KEY" && exit 1

sed -i "s/PRRRRRRRRR_API_KEY/$PRRRRRRRRR_API_KEY/" src/GymTracker/Config.hs
trap 'git checkout src/GymTracker/Config.hs' EXIT

adb uninstall me.jappie.prrrrrrrrr 2>/dev/null || true
adb install "$(nix-build nix/apk.nix)/prrrrrrrrr.apk"
