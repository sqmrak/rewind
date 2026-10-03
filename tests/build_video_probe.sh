#!/usr/bin/env bash
set -euo pipefail

REWIND_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REWIND_VIDEO_TC="${REWIND_TC:-${THEOS:?set THEOS or REWIND_TC}/toolchain/linux/iphone/bin}"
REWIND_VIDEO_SDK="${REWIND_SDK_V7:?set REWIND_SDK_V7 to armv7 sdk}"
REWIND_VIDEO_OUT="${REWIND_VIDEO_PROBE_OUT:-${REWIND_ROOT}/build/video-probe}"
[[ -x "${REWIND_VIDEO_TC}/clang" && -d "${REWIND_VIDEO_SDK}/System/Library/Frameworks/AVFoundation.framework" ]] || {
    echo 'missing armv7 compiler or AVFoundation sdk' >&2
    exit 1
}
mkdir -p "${REWIND_VIDEO_OUT}"
REWIND_VIDEO_STAGE="$(mktemp -d "${REWIND_VIDEO_OUT}/stage.XXXXXX")"
trap 'rm -rf "${REWIND_VIDEO_STAGE}"' EXIT
REWIND_VIDEO_APP="${REWIND_VIDEO_STAGE}/RewindVideoProbe.app"
mkdir "${REWIND_VIDEO_APP}"
cd "${REWIND_ROOT}"
"${REWIND_VIDEO_TC}/clang" -target arm-apple-darwin11 -B "${REWIND_VIDEO_TC}" \
    -arch armv7 -miphoneos-version-min=5.0 -isysroot "${REWIND_VIDEO_SDK}" \
    -fno-objc-arc -fblocks -O2 -Wall -Wextra -Iapp -Icore \
    tests/device_video_probe.m app/video_vc.m app/rewind_api.m app/rewind_player.m \
    app/rewind_account.m app/rewind_image_cache.m app/rewind_http.m app/rewind_stream.m \
    app/rewind_l10n.m app/rewind_theme.m app/rewind_ui.m app/rewind_download.m \
    core/rewind_model.c core/rewind_audio.c core/rewind_playback.c core/rewind_fmp4.c \
    core/rewind_sabr.c core/rewind_ump.c \
    -framework Foundation -framework UIKit -framework CFNetwork -framework AVFoundation \
    -framework CoreMedia -framework CoreVideo -framework MediaPlayer -framework ImageIO \
    -framework CoreGraphics -framework QuartzCore \
    -o "${REWIND_VIDEO_APP}/RewindVideoProbe"
cat > "${REWIND_VIDEO_APP}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RewindVideoProbe</string>
<key>CFBundleIdentifier</key><string>com.sqmrak.rewind.video-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>Rewind Video Probe</string>
<key>MinimumOSVersion</key><string>5.0</string>
<key>UIStatusBarHidden</key><true/>
</dict></plist>
PLIST
cp app/icons/ic-*.png "${REWIND_VIDEO_APP}/"
if [[ -n "${REWIND_VIDEO_FIXTURE:-}" ]]; then
    [[ -f "${REWIND_VIDEO_FIXTURE}" ]] || { echo 'REWIND_VIDEO_FIXTURE missing' >&2; exit 1; }
    cp "${REWIND_VIDEO_FIXTURE}" "${REWIND_VIDEO_APP}/fixture.mp4"
else
    REWIND_VIDEO_FFMPEG="${REWIND_FFMPEG:-ffmpeg}"
    command -v "${REWIND_VIDEO_FFMPEG}" >/dev/null || { echo 'set REWIND_VIDEO_FIXTURE or install ffmpeg for local UI fixture' >&2; exit 1; }
    "${REWIND_VIDEO_FFMPEG}" -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'testsrc2=size=320x240:rate=24:duration=8' \
        -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=8' \
        -c:v libx264 -profile:v baseline -level:v 3.0 -pix_fmt yuv420p -threads 1 \
        -c:a aac -b:a 64k -ac 1 -movflags +faststart -shortest "${REWIND_VIDEO_APP}/fixture.mp4"
fi
chmod 755 "${REWIND_VIDEO_APP}/RewindVideoProbe"
rm -rf "${REWIND_VIDEO_OUT}/RewindVideoProbe.app"
mv "${REWIND_VIDEO_APP}" "${REWIND_VIDEO_OUT}/RewindVideoProbe.app"
"${REWIND_VIDEO_TC}/lipo" -info "${REWIND_VIDEO_OUT}/RewindVideoProbe.app/RewindVideoProbe"
"${REWIND_VIDEO_TC}/otool" -L "${REWIND_VIDEO_OUT}/RewindVideoProbe.app/RewindVideoProbe"
echo "unsigned bundle: ${REWIND_VIDEO_OUT}/RewindVideoProbe.app"
echo 'parent signing required; no install or device execution performed'
echo 'CLI as mobile: ./RewindVideoProbe.app/RewindVideoProbe --network'
echo 'CLI codec check: ./RewindVideoProbe.app/RewindVideoProbe --local /absolute/fixture.mp4'
echo 'UI lifecycle: register distinct app, launch com.sqmrak.rewind.video-probe using generic launcher'
echo 'registered UI logs: /tmp/rewind-video-probe.*/run.log; network mode uses native device TLS'
