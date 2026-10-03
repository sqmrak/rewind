#!/usr/bin/env bash
set -euo pipefail

REWIND_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REWIND_UI_TC="${REWIND_TC:-${THEOS:?set THEOS or REWIND_TC}/toolchain/linux/iphone/bin}"
REWIND_UI_SDK="${REWIND_SDK_V7:?set REWIND_SDK_V7 to the armv7 sdk}"
REWIND_UI_OUT="${REWIND_UI_PROBE_OUT:-${REWIND_ROOT}/build/ui-probe}"
[[ -x "${REWIND_UI_TC}/clang" && -d "${REWIND_UI_SDK}/System/Library/Frameworks/UIKit.framework" ]] || {
    echo 'missing armv7 compiler or UIKit sdk' >&2
    exit 1
}
mkdir -p "${REWIND_UI_OUT}"
REWIND_UI_STAGE="$(mktemp -d "${REWIND_UI_OUT}/stage.XXXXXX")"
trap 'rm -rf "${REWIND_UI_STAGE}"' EXIT
REWIND_UI_APP="${REWIND_UI_STAGE}/RewindUIProbe.app"
mkdir "${REWIND_UI_APP}"
cd "${REWIND_ROOT}"
REWIND_UI_SOURCES=()
for REWIND_UI_SOURCE in app/*.m; do
    [[ "${REWIND_UI_SOURCE}" == app/app_main.m ]] || REWIND_UI_SOURCES+=("${REWIND_UI_SOURCE}")
done
"${REWIND_UI_TC}/clang" -target arm-apple-darwin11 -B "${REWIND_UI_TC}" \
    -arch armv7 -miphoneos-version-min=5.0 -isysroot "${REWIND_UI_SDK}" \
    -fno-objc-arc -fblocks -O2 -Wall -Wextra -Iapp -Icore \
    tests/device_ui_probe.m "${REWIND_UI_SOURCES[@]}" core/*.c \
    -framework Foundation -framework UIKit -framework CFNetwork \
    -weak_framework AVFoundation -framework CoreMedia -framework MediaPlayer \
    -framework ImageIO -framework CoreGraphics -framework QuartzCore \
    -o "${REWIND_UI_APP}/RewindUIProbe"
"${REWIND_UI_TC}/clang" -target arm-apple-darwin11 -B "${REWIND_UI_TC}" \
    -arch armv7 -miphoneos-version-min=5.0 -isysroot "${REWIND_UI_SDK}" \
    -fno-objc-arc -O2 -Wall -Wextra tests/device_launch_probe.m \
    -framework Foundation -framework CoreFoundation \
    -o "${REWIND_UI_STAGE}/RewindDeviceLaunch"
cat > "${REWIND_UI_APP}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RewindUIProbe</string>
<key>CFBundleIdentifier</key><string>com.sqmrak.rewind.ui-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>Rewind UI Probe</string>
<key>MinimumOSVersion</key><string>5.0</string>
<key>UIStatusBarHidden</key><true/>
<key>UIAppFonts</key><array><string>Roboto-Regular.ttf</string><string>Roboto-Medium.ttf</string><string>Roboto-Bold.ttf</string></array>
</dict></plist>
PLIST
cp app/icons/*.png app/fonts/*.ttf "${REWIND_UI_APP}/"
chmod 755 "${REWIND_UI_APP}/RewindUIProbe"
# replace only this script's isolated output bundle after a successful link
rm -rf "${REWIND_UI_OUT}/RewindUIProbe.app"
mv "${REWIND_UI_APP}" "${REWIND_UI_OUT}/RewindUIProbe.app"
mv "${REWIND_UI_STAGE}/RewindDeviceLaunch" "${REWIND_UI_OUT}/RewindDeviceLaunch"
"${REWIND_UI_TC}/lipo" -info "${REWIND_UI_OUT}/RewindUIProbe.app/RewindUIProbe"
"${REWIND_UI_TC}/otool" -L "${REWIND_UI_OUT}/RewindUIProbe.app/RewindUIProbe"
echo "unsigned bundle: ${REWIND_UI_OUT}/RewindUIProbe.app"
echo 'parent: sign both binaries, register /Applications/RewindUIProbe.app with uicache as mobile'
echo 'unlock device, then run as mobile: ./RewindDeviceLaunch com.sqmrak.rewind.ui-probe'
echo 'launcher success means request accepted; read /tmp/rewind-ui-probe.*/run.log for test results'
echo 'PNGs default to that isolated home/pngs; probe self-exits within 90 seconds'
