# Android emulator lifecycle test — standalone (no haskell-mobile lib.nix helper).
#
# Boots an emulator, installs the APK, launches the activity, and verifies
# basic lifecycle events appear in logcat (onCreate, haskellOnLifecycle, setRoot).
#
# Usage:
#   nix-build nix/emulator.nix -o result-emulator
#   ./result-emulator/bin/test-lifecycle
{ sources ? import ../npins }:
let
  pkgs = import sources.nixpkgs {
    config.allowUnfree = true;
    config.android_sdk.accept_license = true;
  };

  apk = import ./apk.nix { inherit sources; };

  androidComposition = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "34" ];
    includeEmulator = true;
    includeSystemImages = true;
    systemImageTypes = [ "google_apis_playstore" ];
    abiVersions = [ "x86_64" ];
    cmdLineToolsVersion = "8.0";
  };

  sdk = androidComposition.androidsdk;
  sdkRoot = "${sdk}/libexec/android-sdk";

  platformVersion = "34";
  systemImageType = "google_apis_playstore";
  abiVersion = "x86_64";
  imagePackage = "system-images;android-${platformVersion};${systemImageType};${abiVersion}";

in pkgs.stdenv.mkDerivation {
  name = "prrrrrrrrr-emulator-test";

  dontUnpack = true;

  buildPhase = ''
    mkdir -p $out/bin

    cat > $out/bin/test-lifecycle << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
export ANDROID_SDK_ROOT="${sdkRoot}"
export ANDROID_HOME="${sdkRoot}"
unset ANDROID_NDK_HOME 2>/dev/null || true
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
EMULATOR="$ANDROID_SDK_ROOT/emulator/emulator"
AVDMANAGER="${sdk}/bin/avdmanager"
APK_PATH="${apk}/prrrrrrrrr.apk"
PACKAGE="me.jappie.prrrrrrrrr"
ACTIVITY=".MainActivity"
DEVICE_NAME="test_lifecycle"

# --- KVM detection ---
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    echo "KVM detected -- using hardware acceleration"
    ACCEL_FLAG=""
    BOOT_TIMEOUT=180
else
    echo "No KVM -- using software emulation (slow boot expected)"
    ACCEL_FLAG="-no-accel"
    BOOT_TIMEOUT=900
fi

# --- Temp dirs ---
WORK_DIR=$(mktemp -d /tmp/prrrrrrrrr-emu-lifecycle-XXXX)
export HOME="$WORK_DIR/home"
export ANDROID_USER_HOME="$WORK_DIR/user-home"
export ANDROID_AVD_HOME="$WORK_DIR/avd"
export ANDROID_EMULATOR_HOME="$WORK_DIR/emulator-home"
export TMPDIR="$WORK_DIR/tmp"
mkdir -p "$HOME" "$ANDROID_USER_HOME" "$ANDROID_AVD_HOME" "$ANDROID_EMULATOR_HOME" "$TMPDIR"

# Restart ADB server so it uses our fresh HOME for key generation.
"$ADB" kill-server 2>/dev/null || true
"$ADB" start-server 2>/dev/null || true

LOGCAT_FILE="$WORK_DIR/logcat.txt"
EMU_PID=""

cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    if [ -n "$EMU_PID" ] && kill -0 "$EMU_PID" 2>/dev/null; then
        echo "Killing emulator (PID $EMU_PID)"
        kill "$EMU_PID" 2>/dev/null || true
        wait "$EMU_PID" 2>/dev/null || true
    fi
    "$ADB" -s "emulator-$PORT" emu kill 2>/dev/null || true
    rm -rf "$WORK_DIR"
    echo "Cleanup done."
}
trap cleanup EXIT

# --- Find free port ---
echo "=== Finding free emulator port ==="
PORT=""
for p in $(seq 5554 2 5584); do
    if ! "$ADB" devices 2>/dev/null | grep -q "emulator-$p"; then
        PORT=$p
        break
    fi
done

if [ -z "$PORT" ]; then
    echo "ERROR: No free emulator port found (5554-5584 all in use)"
    exit 1
fi
echo "Using port: $PORT"
export ANDROID_SERIAL="emulator-$PORT"

# --- Create AVD ---
echo "=== Creating AVD ==="
echo "n" | "$AVDMANAGER" create avd \
    --force \
    --name "$DEVICE_NAME" \
    --package "${imagePackage}" \
    --device "pixel_6" \
    -p "$ANDROID_AVD_HOME/$DEVICE_NAME.avd"

cat >> "$ANDROID_AVD_HOME/$DEVICE_NAME.avd/config.ini" << 'AVDCONF'
hw.ramSize = 4096
hw.gpu.enabled = yes
hw.gpu.mode = swiftshader_indirect
disk.dataPartition.size = 2G
AVDCONF

# Fix system image path if needed
SYSIMG_DIR="$ANDROID_SDK_ROOT/system-images/android-${platformVersion}/${systemImageType}/${abiVersion}"
if [ ! -d "$SYSIMG_DIR" ]; then
    echo "WARNING: Expected system image dir not found: $SYSIMG_DIR"
    FOUND_SYSIMG=$(find "$ANDROID_SDK_ROOT" -name "system.img" -print -quit 2>/dev/null || echo "")
    if [ -n "$FOUND_SYSIMG" ]; then
        SYSIMG_DIR=$(dirname "$FOUND_SYSIMG")
        echo "Found system image at: $SYSIMG_DIR"
        sed -i "s|^image.sysdir.1=.*|image.sysdir.1=$SYSIMG_DIR/|" "$ANDROID_AVD_HOME/$DEVICE_NAME.avd/config.ini"
        echo "Patched image.sysdir.1 in AVD config"
    else
        echo "ERROR: Could not find system.img anywhere in SDK"
    fi
else
    echo "System image dir exists: $SYSIMG_DIR"
fi

# --- Boot emulator ---
echo "=== Booting emulator ==="
"$EMULATOR" \
    -avd "$DEVICE_NAME" \
    -no-window \
    -no-audio \
    -no-boot-anim \
    -no-metrics \
    -port "$PORT" \
    -gpu swiftshader_indirect \
    -no-snapshot \
    -memory 4096 \
    $ACCEL_FLAG \
    &
EMU_PID=$!
echo "Emulator PID: $EMU_PID"

# --- Wait for boot ---
echo "=== Waiting for boot (timeout: ''${BOOT_TIMEOUT}s) ==="
BOOT_DONE=""
ELAPSED=0
while [ $ELAPSED -lt $BOOT_TIMEOUT ]; do
    BOOT_DONE=$("$ADB" -s "emulator-$PORT" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || echo "")
    if [ "$BOOT_DONE" = "1" ]; then
        echo "Boot completed after ~''${ELAPSED}s"
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    if [ $((ELAPSED % 60)) -eq 0 ]; then
        echo "  Still waiting... (''${ELAPSED}s elapsed)"
    fi
done

if [ "$BOOT_DONE" != "1" ]; then
    echo "ERROR: Emulator failed to boot within ''${BOOT_TIMEOUT}s"
    exit 1
fi

# Wait for device to settle
echo "Waiting for device to settle..."
sleep 30

# --- Install APK ---
echo "=== Installing APK ==="
INSTALL_OK=0
for attempt in 1 2 3; do
    if "$ADB" -s "emulator-$PORT" install -t "$APK_PATH" 2>&1; then
        INSTALL_OK=1
        break
    fi
    echo "Install attempt $attempt failed, retrying in 10s..."
    sleep 10
done

if [ $INSTALL_OK -eq 0 ]; then
    echo "ERROR: Failed to install APK after 3 attempts"
    exit 1
fi
echo "APK installed."

# --- Clear logcat and launch ---
echo "=== Preparing logcat ==="
"$ADB" -s "emulator-$PORT" logcat -c

echo "=== Launching $PACKAGE/$ACTIVITY ==="
"$ADB" -s "emulator-$PORT" shell am start -n "$PACKAGE/$ACTIVITY"

# --- Wait for lifecycle events ---
echo "=== Waiting for lifecycle events (timeout: 120s) ==="
POLL_TIMEOUT=120
POLL_ELAPSED=0
RENDER_DONE=0

while [ $POLL_ELAPSED -lt $POLL_TIMEOUT ]; do
    "$ADB" -s "emulator-$PORT" logcat -d '*:I' > "$LOGCAT_FILE" 2>&1
    if grep -q "setRoot" "$LOGCAT_FILE" 2>/dev/null; then
        RENDER_DONE=1
        echo "Initial render detected after ~''${POLL_ELAPSED}s"
        break
    fi
    sleep 2
    POLL_ELAPSED=$((POLL_ELAPSED + 2))
done

if [ $RENDER_DONE -eq 0 ]; then
    echo "WARNING: setRoot not found in logcat after ''${POLL_TIMEOUT}s"
fi

# Extra settle time
sleep 5

# Capture final logcat
"$ADB" -s "emulator-$PORT" logcat -d '*:I' > "$LOGCAT_FILE" 2>&1

# --- Verify lifecycle ---
echo ""
echo "=== Verifying lifecycle events ==="
EXIT_CODE=0

if grep -q 'haskellOnLifecycle' "$LOGCAT_FILE" 2>/dev/null; then
    echo "PASS: haskellOnLifecycle in logcat"
else
    echo "FAIL: haskellOnLifecycle in logcat"
    EXIT_CODE=1
fi

if grep -q 'setRoot' "$LOGCAT_FILE" 2>/dev/null; then
    echo "PASS: setRoot in logcat (initial render)"
else
    echo "FAIL: setRoot in logcat (initial render)"
    EXIT_CODE=1
fi

if grep -q 'setStrProp.*PRRRRRRRRR' "$LOGCAT_FILE" 2>/dev/null; then
    echo "PASS: App title 'PRRRRRRRRR' rendered"
else
    echo "FAIL: App title 'PRRRRRRRRR' rendered"
    EXIT_CODE=1
fi

if grep -q 'setHandler.*click' "$LOGCAT_FILE" 2>/dev/null; then
    echo "PASS: Click handlers registered"
else
    echo "FAIL: Click handlers registered"
    EXIT_CODE=1
fi

# --- Report ---
echo ""
echo "=== Filtered logcat (UIBridge + Haskell) ==="
grep -iE "UIBridge|Haskell|haskellOnLifecycle" "$LOGCAT_FILE" 2>/dev/null | tail -20 || echo "(none)"
echo "--- End filtered logcat ---"

if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo "=== Crash / library-load messages ==="
    grep -iE "FATAL|AndroidRuntime|UnsatisfiedLinkError|loadLibrary|haskellmobile|CRASH|SIGNAL" \
      "$LOGCAT_FILE" 2>/dev/null | tail -30 || echo "(none)"
    echo "--- End crash messages ---"
fi

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "All lifecycle checks passed!"
else
    echo "Some lifecycle checks FAILED."
fi

exit $EXIT_CODE
SCRIPT

    chmod +x $out/bin/test-lifecycle
  '';

  installPhase = "true";
}
