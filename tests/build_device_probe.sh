#!/usr/bin/env bash
set -euo pipefail

REWIND_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REWIND_TOOLCHAIN="${REWIND_TC:-${THEOS:?set THEOS to theos root}/toolchain/linux/iphone/bin}"
REWIND_PROBE_SDK="${REWIND_SDK_V7:?set REWIND_SDK_V7 to the armv7 sdk}"
REWIND_PROBE_APP="${REWIND_ROOT}/build/device-probe/RewindProbe.app"
REWIND_PROBE_ACCOUNT=(app/rewind_account.m)
REWIND_PROBE_FLAGS=()
if [[ "${1:-}" == --state-fixtures && $# == 1 ]]; then
    REWIND_PROBE_APP="${REWIND_ROOT}/build/state-probe/RewindProbe.app"
    REWIND_PROBE_ACCOUNT=()
    REWIND_PROBE_FLAGS=(-DREWIND_STATE_FIXTURES_ONLY)
elif [[ $# != 0 ]]; then
    echo "usage: $0 [--state-fixtures]" >&2
    exit 2
fi
mkdir -p "${REWIND_PROBE_APP}"
cd "${REWIND_ROOT}"
"${REWIND_TOOLCHAIN}/clang" -target arm-apple-darwin11 -B "${REWIND_TOOLCHAIN}" \
    -arch armv7 -miphoneos-version-min=5.0 -isysroot "${REWIND_PROBE_SDK}" \
    -fno-objc-arc -fblocks -O2 -Wall -Wextra -Iapp -Icore \
    "${REWIND_PROBE_FLAGS[@]}" tests/device_playback_probe.m app/rewind_api.m app/rewind_player.m \
    "${REWIND_PROBE_ACCOUNT[@]}" app/rewind_image_cache.m app/rewind_http.m \
    app/rewind_stream.m app/rewind_l10n.m core/rewind_model.c \
    app/rewind_download.m \
    core/rewind_audio.c core/rewind_playback.c core/rewind_fmp4.c \
    core/rewind_sabr.c core/rewind_ump.c \
    -framework Foundation -framework UIKit -framework CFNetwork \
    -framework AVFoundation -framework CoreMedia -framework MediaPlayer \
    -framework ImageIO -framework CoreGraphics -framework QuartzCore \
    -o "${REWIND_PROBE_APP}/RewindProbe"
# match the app's defaults and senkotlsfix gate without registering another app
cat > "${REWIND_PROBE_APP}/Info.plist" <<'REWIND_PROBE_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RewindProbe</string>
<key>CFBundleIdentifier</key><string>com.sqmrak.rewind</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>MinimumOSVersion</key><string>5.0</string>
</dict></plist>
REWIND_PROBE_PLIST
"${REWIND_LDID:-${REWIND_TOOLCHAIN}/ldid}" -Sapp/entitlements.plist "${REWIND_PROBE_APP}/RewindProbe"
echo "built ${REWIND_PROBE_APP}"
