#!/usr/bin/env bash

adb uninstall  me.jappie.prrrrrrrrr
adb install $(nix-build nix/apk.nix)/prrrrrrrrr.apk
