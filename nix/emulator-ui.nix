# Android emulator UI interaction test.
#
# Boots an emulator, installs the APK, and verifies the full PR entry flow:
#   1. The ExerciseList screen renders (title "PRRRRRRRRR", exercise buttons)
#   2. Tapping "Snatch: No PR" navigates to the EnterPR screen
#   3. Entering weight "100" and tapping "Save" stays on EnterPR and shows history
#   4. Tapping "Back" returns to ExerciseList showing "Snatch: 100.0 kg"
#
# Boot + install happen once. The test flow is retried up to 3 times
# (force-stop + relaunch between attempts) to handle emulator flakiness
# without the cost of rebooting each time.
#
# Usage:
#   nix-build nix/emulator-ui.nix -o result-emulator-ui
#   ./result-emulator-ui/bin/test-ui
{ sources ? import ../npins
, abiVersion ? "x86_64"   # "x86_64" or "arm64-v8a"
, apkPath ? null           # external APK path; when null, build from source
}:
let
  pkgs = import sources.nixpkgs {
    config.allowUnfree = true;
    config.android_sdk.accept_license = true;
  };

  apk = if apkPath != null then apkPath
        else import ./apk.nix { inherit sources; };

  androidComposition = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "34" ];
    includeEmulator = true;
    includeSystemImages = true;
    systemImageTypes = [ "google_apis" ];
    abiVersions = [ abiVersion ];
    cmdLineToolsVersion = "8.0";
  };

  sdk = androidComposition.androidsdk;
  sdkRoot = "${sdk}/libexec/android-sdk";

  platformVersion = "34";
  systemImageType = "google_apis";
  imagePackage = "system-images;android-${platformVersion};${systemImageType};${abiVersion}";

in pkgs.stdenv.mkDerivation {
  name = "prrrrrrrrr-emulator-ui-test";

  dontUnpack = true;

  buildPhase = ''
    mkdir -p $out/bin

    cat > $out/bin/test-ui << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
export ANDROID_SDK_ROOT="${sdkRoot}"
export ANDROID_HOME="${sdkRoot}"
unset ANDROID_NDK_HOME 2>/dev/null || true
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
EMULATOR="$ANDROID_SDK_ROOT/emulator/emulator"
AVDMANAGER="${sdk}/bin/avdmanager"
APK_PATH="''${OVERRIDE_APK_PATH:-${apk}/prrrrrrrrr.apk}"
PACKAGE="me.jappie.prrrrrrrrr"
ACTIVITY=".MainActivity"
DEVICE_NAME="test_ui"
MAX_TEST_ATTEMPTS=3

# --- Debug: show SDK structure ---
echo "=== SDK structure ==="
echo "SDK_ROOT: $ANDROID_SDK_ROOT"
ls "$ANDROID_SDK_ROOT/" 2>/dev/null || echo "(cannot list SDK root)"
echo "--- system-images ---"
ls -R "$ANDROID_SDK_ROOT/system-images/" 2>/dev/null | head -20 || echo "(no system-images)"
echo "=== End SDK structure ==="

# Detect KVM
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
WORK_DIR=$(mktemp -d /tmp/prrrrrrrrr-emu-ui-XXXX)
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
UI_DUMP="$WORK_DIR/ui.xml"
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
hw.ramSize = 6144
hw.gpu.enabled = yes
hw.gpu.mode = swiftshader_indirect
disk.dataPartition.size = 2G
AVDCONF

# Fix system image path if needed
SYSIMG_DIR="$ANDROID_SDK_ROOT/system-images/android-${platformVersion}/${systemImageType}/${abiVersion}"
if [ ! -d "$SYSIMG_DIR" ]; then
    echo "WARNING: Expected system image dir not found: $SYSIMG_DIR"
    echo "Searching for system image..."
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
    -memory 6144 \
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

# ============================================================
# Helper functions
# ============================================================

# --- Helper: dump UI hierarchy with retries ---
dump_ui() {
    local target_file="$1"
    local dump_ok=0
    for attempt in 1 2 3; do
        if "$ADB" -s "emulator-$PORT" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
            "$ADB" -s "emulator-$PORT" pull /data/local/tmp/ui.xml "$target_file" 2>/dev/null
            dump_ok=1
            break
        fi
        echo "  uiautomator dump attempt $attempt failed, retrying in 5s..."
        sleep 5
    done
    return $((1 - dump_ok))
}

# --- Helper: extract tap coordinates for a text element ---
tap_element() {
    local xml_file="$1"
    local search_text="$2"
    local node_line
    node_line=$(sed 's/></>\n</g' "$xml_file" | grep "$search_text" | head -1)
    if [ -z "$node_line" ]; then
        echo "WARNING: Could not find '$search_text' in UI dump"
        return 1
    fi
    local coords
    coords=$(echo "$node_line" | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1)
    if [ -z "$coords" ]; then
        echo "WARNING: Could not extract bounds for '$search_text'"
        return 1
    fi
    local left top right bottom
    left=$(echo "$coords" | grep -o '\[[0-9]*,' | head -1 | tr -d '[,')
    top=$(echo "$coords" | grep -o ',[0-9]*\]' | head -1 | tr -d ',]')
    right=$(echo "$coords" | grep -o '\[[0-9]*,' | tail -1 | tr -d '[,')
    bottom=$(echo "$coords" | grep -o ',[0-9]*\]' | tail -1 | tr -d ',]')
    local tap_x=$(( (left + right) / 2 ))
    local tap_y=$(( (top + bottom) / 2 ))
    echo "Tapping '$search_text' at ($tap_x, $tap_y)"
    "$ADB" -s "emulator-$PORT" shell input tap "$tap_x" "$tap_y"
}

# ============================================================
# Test flow — runs inside a retry loop
# ============================================================
run_test_flow() {
    local EXIT_CODE=0

    # Reset app state for clean test
    "$ADB" -s "emulator-$PORT" shell am force-stop "$PACKAGE" 2>/dev/null || true
    "$ADB" -s "emulator-$PORT" shell pm clear "$PACKAGE" 2>/dev/null || true
    sleep 2

    # Clear logcat and launch
    "$ADB" -s "emulator-$PORT" logcat -c
    "$ADB" -s "emulator-$PORT" shell am start -n "$PACKAGE/$ACTIVITY"

    # ----------------------------------------------------------
    # Step 1: Wait for initial render
    # ----------------------------------------------------------
    echo ""
    echo "=== Step 1: Waiting for initial render (timeout: 120s) ==="
    local POLL_TIMEOUT=120
    local POLL_ELAPSED=0
    local RENDER_DONE=0

    while [ $POLL_ELAPSED -lt $POLL_TIMEOUT ]; do
        "$ADB" -s "emulator-$PORT" logcat -d '*:I' > "$LOGCAT_FILE" 2>&1 || true
        if grep -q "setRoot" "$LOGCAT_FILE" 2>/dev/null; then
            RENDER_DONE=1
            echo "Initial render detected after ~''${POLL_ELAPSED}s"
            break
        fi
        sleep 2
        POLL_ELAPSED=$((POLL_ELAPSED + 2))
    done

    if [ $RENDER_DONE -eq 0 ]; then
        # Check for deterministic crash (Java exceptions OR native SIGSEGV)
        local CRASH_LINES
        CRASH_LINES=$(grep -iE "FATAL EXCEPTION|UnsatisfiedLinkError|dlopen failed|System\.loadLibrary|AndroidRuntime.*Error|Fatal signal|SIGSEGV|SIGABRT|SIGBUS" \
          "$LOGCAT_FILE" 2>/dev/null | head -10) || true

        if [ -n "$CRASH_LINES" ]; then
            echo ""
            echo "============================================================"
            echo "FATAL: App crashed on startup"
            echo "============================================================"
            echo ""
            echo "$CRASH_LINES"
            echo ""
            echo "--- All crash / library-load messages ---"
            grep -iE "FATAL|AndroidRuntime|UnsatisfiedLinkError|loadLibrary|haskellmobile|hatter|CRASH|SIGNAL|System.err" \
              "$LOGCAT_FILE" 2>/dev/null | tail -30 || echo "(none)"
            echo ""
            echo "--- Native crash tombstone (backtrace) ---"
            grep -E "DEBUG\s*:" "$LOGCAT_FILE" 2>/dev/null | tail -80 || echo "(no tombstone)"
            echo ""
            echo "--- Full logcat around crash (last 120 lines) ---"
            tail -120 "$LOGCAT_FILE" 2>/dev/null || echo "(empty)"
            echo "============================================================"
            # Return 2 to signal "don't retry"
            return 2
        fi

        echo "WARNING: No initial render after ''${POLL_TIMEOUT}s (no crash detected)"
        echo "--- UIBridge / JNI messages ---"
        grep -i "UIBridge\|Haskell\|prrrrrrrrr\|JNI\|jni" "$LOGCAT_FILE" 2>/dev/null | tail -20 || echo "(none)"
        return 1
    fi

    sleep 5

    # ----------------------------------------------------------
    # Step 2: Verify ExerciseList screen
    # ----------------------------------------------------------
    echo ""
    echo "=== Step 2: Verify ExerciseList screen ==="

    if grep -q 'setStrProp.*PRRRRRRRRR' "$LOGCAT_FILE" 2>/dev/null; then
        echo "PASS: ExerciseList — title 'PRRRRRRRRR' in logcat"
    else
        echo "FAIL: ExerciseList — title 'PRRRRRRRRR' in logcat"
        EXIT_CODE=1
    fi

    if grep -q 'setStrProp.*Snatch: No PR' "$LOGCAT_FILE" 2>/dev/null; then
        echo "PASS: ExerciseList — 'Snatch: No PR' in logcat"
    else
        echo "FAIL: ExerciseList — 'Snatch: No PR' in logcat"
        EXIT_CODE=1
    fi

    if grep -q 'setHandler.*click' "$LOGCAT_FILE" 2>/dev/null; then
        echo "PASS: ExerciseList — click handlers in logcat"
    else
        echo "FAIL: ExerciseList — click handlers in logcat"
        EXIT_CODE=1
    fi

    if dump_ui "$UI_DUMP"; then
        if grep -q 'PRRRRRRRRR' "$UI_DUMP" 2>/dev/null; then
            echo "PASS: UI hierarchy — 'PRRRRRRRRR' visible"
        else
            echo "FAIL: UI hierarchy — 'PRRRRRRRRR' visible"
            EXIT_CODE=1
        fi

        if grep -q 'Snatch: No PR' "$UI_DUMP" 2>/dev/null; then
            echo "PASS: UI hierarchy — 'Snatch: No PR' visible"
        else
            echo "FAIL: UI hierarchy — 'Snatch: No PR' visible"
            EXIT_CODE=1
        fi
    else
        echo "FAIL: UI hierarchy — could not dump view hierarchy"
        EXIT_CODE=1
    fi

    # ----------------------------------------------------------
    # Step 3: Tap "Snatch: No PR" button
    # ----------------------------------------------------------
    echo ""
    echo "=== Step 3: Tap 'Snatch: No PR' button ==="

    if ! tap_element "$UI_DUMP" "Snatch: No PR"; then
        echo "FAIL: Could not tap 'Snatch: No PR' button"
        EXIT_CODE=1
    fi

    echo "Waiting for re-render..."
    sleep 5
    "$ADB" -s "emulator-$PORT" logcat -d '*:I' > "$LOGCAT_FILE" 2>&1 || true

    # ----------------------------------------------------------
    # Step 4: Verify EnterPR screen
    # ----------------------------------------------------------
    echo ""
    echo "=== Step 4: Verify EnterPR screen ==="

    if grep -q 'Click dispatched' "$LOGCAT_FILE" 2>/dev/null; then
        echo "PASS: EnterPR — Click dispatched in logcat"
    else
        echo "FAIL: EnterPR — Click dispatched in logcat"
        EXIT_CODE=1
    fi

    # Note: "Set PR: " and exercise name are separate Text nodes in the view,
    # so they appear as separate setStrProp calls.  Check for each individually.
    if grep -q 'setStrProp.*Set PR:' "$LOGCAT_FILE" 2>/dev/null; then
        echo "PASS: EnterPR — 'Set PR:' in logcat"
    else
        echo "FAIL: EnterPR — 'Set PR:' in logcat"
        EXIT_CODE=1
    fi

    if grep -q 'setStrProp.*Snatch' "$LOGCAT_FILE" 2>/dev/null; then
        echo "PASS: EnterPR — exercise name 'Snatch' in logcat"
    else
        echo "FAIL: EnterPR — exercise name 'Snatch' in logcat"
        EXIT_CODE=1
    fi

    # Retry UI dump until EnterPR screen is visible (up to 30s)
    # "Set PR:" and exercise name are separate text nodes, so check for "Set PR:" only.
    local ENTER_PR_VISIBLE=0
    for UI_WAIT in $(seq 1 6); do
        if dump_ui "$UI_DUMP" && grep -q 'Set PR:' "$UI_DUMP" 2>/dev/null; then
            ENTER_PR_VISIBLE=1
            break
        fi
        echo "  UI not ready yet (attempt $UI_WAIT/6), waiting 5s..."
        sleep 5
    done

    if [ $ENTER_PR_VISIBLE -eq 1 ]; then
        echo "PASS: UI hierarchy — 'Set PR:' visible"

        if grep -q 'Save' "$UI_DUMP" 2>/dev/null; then
            echo "PASS: UI hierarchy — 'Save' button visible"
        else
            echo "FAIL: UI hierarchy — 'Save' button visible"
            EXIT_CODE=1
        fi

        if grep -q 'Back' "$UI_DUMP" 2>/dev/null; then
            echo "PASS: UI hierarchy — 'Back' button visible"
        else
            echo "FAIL: UI hierarchy — 'Back' button visible"
            EXIT_CODE=1
        fi
    else
        echo "FAIL: UI hierarchy — 'Set PR:' not visible after retries"
        EXIT_CODE=1
    fi

    # ----------------------------------------------------------
    # Step 5: Enter weight "100"
    # ----------------------------------------------------------
    echo ""
    echo "=== Step 5: Enter weight '100' ==="

    if dump_ui "$UI_DUMP"; then
        # Use || true so grep returning no-match doesn't kill the script
        EDIT_LINE=$(sed 's/></>\n</g' "$UI_DUMP" | grep 'EditText' | head -1) || true
        if [ -n "$EDIT_LINE" ]; then
            EDIT_COORDS=$(echo "$EDIT_LINE" | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1)
            if [ -n "$EDIT_COORDS" ]; then
                E_LEFT=$(echo "$EDIT_COORDS" | grep -o '\[[0-9]*,' | head -1 | tr -d '[,')
                E_TOP=$(echo "$EDIT_COORDS" | grep -o ',[0-9]*\]' | head -1 | tr -d ',]')
                E_RIGHT=$(echo "$EDIT_COORDS" | grep -o '\[[0-9]*,' | tail -1 | tr -d '[,')
                E_BOTTOM=$(echo "$EDIT_COORDS" | grep -o ',[0-9]*\]' | tail -1 | tr -d ',]')
                E_TAP_X=$(( (E_LEFT + E_RIGHT) / 2 ))
                E_TAP_Y=$(( (E_TOP + E_BOTTOM) / 2 ))
                echo "Tapping EditText at ($E_TAP_X, $E_TAP_Y)"
                "$ADB" -s "emulator-$PORT" shell input tap "$E_TAP_X" "$E_TAP_Y"
                sleep 1
            else
                echo "WARNING: Could not extract EditText bounds"
            fi
        else
            echo "WARNING: No EditText found in UI dump"
        fi
    fi

    echo "Entering text '100'..."
    "$ADB" -s "emulator-$PORT" shell input text "100"
    sleep 2

    # ----------------------------------------------------------
    # Step 6: Tap "Save" button
    # ----------------------------------------------------------
    echo ""
    echo "=== Step 6: Tap 'Save' button ==="

    if dump_ui "$UI_DUMP"; then
        if ! tap_element "$UI_DUMP" "Save"; then
            echo "FAIL: Could not tap 'Save' button"
            EXIT_CODE=1
        fi
    else
        echo "FAIL: Could not dump UI to find Save button"
        EXIT_CODE=1
    fi

    echo "Waiting for re-render (Save stays on EnterPR with history)..."
    sleep 5
    "$ADB" -s "emulator-$PORT" logcat -d '*:I' > "$LOGCAT_FILE" 2>&1 || true

    # ----------------------------------------------------------
    # Step 7: Verify history rendered after Save
    # ----------------------------------------------------------
    echo ""
    echo "=== Step 7: Verify history rendered after Save ==="

    if grep -q 'setStrProp.*100.0 kg' "$LOGCAT_FILE" 2>/dev/null; then
        echo "PASS: History entry — '100.0 kg' in logcat after Save"
    else
        echo "FAIL: History entry — '100.0 kg' in logcat after Save"
        EXIT_CODE=1
    fi

    # ----------------------------------------------------------
    # Step 8: Tap "Back" to return to ExerciseList
    # ----------------------------------------------------------
    echo ""
    echo "=== Step 8: Tap 'Back' to return to ExerciseList ==="

    if dump_ui "$UI_DUMP"; then
        if ! tap_element "$UI_DUMP" "Back"; then
            echo "FAIL: Could not tap 'Back' button"
            EXIT_CODE=1
        fi
    else
        echo "FAIL: Could not dump UI to find Back button"
        EXIT_CODE=1
    fi

    echo "Waiting for re-render back to ExerciseList..."
    sleep 5
    "$ADB" -s "emulator-$PORT" logcat -d '*:I' > "$LOGCAT_FILE" 2>&1 || true

    # ----------------------------------------------------------
    # Step 9: Verify updated ExerciseList
    # ----------------------------------------------------------
    echo ""
    echo "=== Step 9: Verify updated ExerciseList ==="

    if grep -q 'setStrProp.*Snatch: 100.0 kg' "$LOGCAT_FILE" 2>/dev/null; then
        echo "PASS: Updated ExerciseList — 'Snatch: 100.0 kg' in logcat"
    else
        echo "FAIL: Updated ExerciseList — 'Snatch: 100.0 kg' in logcat"
        EXIT_CODE=1
    fi

    if dump_ui "$UI_DUMP"; then
        if grep -q 'Snatch: 100.0 kg' "$UI_DUMP" 2>/dev/null; then
            echo "PASS: UI hierarchy — 'Snatch: 100.0 kg' visible"
        else
            echo "FAIL: UI hierarchy — 'Snatch: 100.0 kg' visible"
            EXIT_CODE=1
        fi

        if grep -q 'PRRRRRRRRR' "$UI_DUMP" 2>/dev/null; then
            echo "PASS: UI hierarchy — back on ExerciseList (title visible)"
        else
            echo "FAIL: UI hierarchy — back on ExerciseList (title visible)"
            EXIT_CODE=1
        fi
    else
        echo "FAIL: UI hierarchy — could not dump updated view hierarchy"
        EXIT_CODE=1
    fi

    # ----------------------------------------------------------
    # Diagnostics on failure
    # ----------------------------------------------------------
    if [ $EXIT_CODE -ne 0 ]; then
        "$ADB" -s "emulator-$PORT" logcat -d '*:I' > "$LOGCAT_FILE" 2>&1 || true
        echo ""
        echo "=== Filtered logcat (UIBridge) ==="
        grep -i "UIBridge" "$LOGCAT_FILE" 2>/dev/null || echo "(no UIBridge lines)"
        echo "--- End filtered logcat ---"
        echo ""
        echo "=== Crash / library-load messages ==="
        grep -iE "FATAL|AndroidRuntime|UnsatisfiedLinkError|System\.load|loadLibrary|haskellmobile|hatter|CRASH|SIGNAL" \
          "$LOGCAT_FILE" 2>/dev/null | tail -30 || echo "(none)"
        echo "--- End crash messages ---"
    fi

    return $EXIT_CODE
}

# ============================================================
# Retry loop — retries only the test flow, not boot/install
# ============================================================
for TEST_ATTEMPT in $(seq 1 $MAX_TEST_ATTEMPTS); do
    echo ""
    echo "########################################################"
    echo "# Test attempt $TEST_ATTEMPT/$MAX_TEST_ATTEMPTS"
    echo "########################################################"

    FLOW_RESULT=0
    run_test_flow || FLOW_RESULT=$?

    if [ $FLOW_RESULT -eq 0 ]; then
        echo ""
        echo "All UI interaction checks passed! (attempt $TEST_ATTEMPT)"
        exit 0
    fi

    if [ $FLOW_RESULT -eq 2 ]; then
        # Fatal crash — don't retry
        echo ""
        echo "FATAL: Deterministic crash detected — not retrying"
        exit 1
    fi

    echo ""
    echo "Test attempt $TEST_ATTEMPT FAILED"
    if [ $TEST_ATTEMPT -lt $MAX_TEST_ATTEMPTS ]; then
        echo "Retrying in 5s..."
        sleep 5
    fi
done

echo ""
echo "FAILED after $MAX_TEST_ATTEMPTS attempts"
exit 1
SCRIPT

    chmod +x $out/bin/test-ui
  '';

  installPhase = "true";
}
