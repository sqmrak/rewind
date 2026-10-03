#!/usr/bin/env bash
set -euo pipefail
REWIND_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REWIND_TOOLCHAIN="${REWIND_TC:-${THEOS:?set THEOS}/toolchain/linux/iphone/bin}"
REWIND_PROBE_ARCH="${REWIND_DOWNLOAD_PROBE_ARCH:-armv7}"
case "${REWIND_PROBE_ARCH}" in
    armv7)
        REWIND_PROBE_SDK="${REWIND_SDK_V7:?set REWIND_SDK_V7}"
        REWIND_PROBE_TARGET=arm-apple-darwin11
        REWIND_PROBE_MIN=5.0
        ;;
    arm64)
        REWIND_PROBE_SDK="${REWIND_SDK_V64:?set REWIND_SDK_V64}"
        REWIND_PROBE_TARGET=arm64-apple-darwin
        REWIND_PROBE_MIN=7.0
        ;;
    *) printf 'unsupported probe architecture: %s\n' "${REWIND_PROBE_ARCH}" >&2; exit 2 ;;
esac
REWIND_PROBE_CC="${REWIND_DOWNLOAD_PROBE_CC:-${REWIND_TOOLCHAIN}/clang}"
command -v "${REWIND_PROBE_CC}" >/dev/null || { printf 'missing clang: %s\n' "${REWIND_PROBE_CC}" >&2; exit 2; }
[[ -d "${REWIND_PROBE_SDK}/System/Library/Frameworks" ]] || { printf 'invalid SDK: %s\n' "${REWIND_PROBE_SDK}" >&2; exit 2; }
REWIND_PROBE_OUTPUT="${REWIND_DOWNLOAD_PROBE_OUTPUT:-/tmp/RewindDownloadProbe}"
REWIND_PROBE_OPTIONAL=()
if [[ -d "${REWIND_PROBE_SDK}/System/Library/Frameworks/AVFAudio.framework" ]]; then
    REWIND_PROBE_OPTIONAL=(-weak_framework AVFAudio)
fi
cd "${REWIND_ROOT}"
"${REWIND_PROBE_CC}" -target "${REWIND_PROBE_TARGET}" -B "${REWIND_TOOLCHAIN}" \
    -arch "${REWIND_PROBE_ARCH}" -miphoneos-version-min="${REWIND_PROBE_MIN}" -isysroot "${REWIND_PROBE_SDK}" \
    -fno-objc-arc -fblocks -O2 -Wall -Wextra -Iapp -Icore \
    tests/device_download_probe.m app/rewind_api.m app/rewind_player.m \
    app/rewind_image_cache.m \
    app/rewind_http.m app/rewind_stream.m app/rewind_l10n.m \
    core/rewind_model.c core/rewind_audio.c core/rewind_fmp4.c \
    core/rewind_sabr.c core/rewind_ump.c core/rewind_playback.c \
    -framework Foundation -framework UIKit -framework CFNetwork \
    -framework AVFoundation -framework CoreMedia "${REWIND_PROBE_OPTIONAL[@]}" \
    -framework MediaPlayer -framework ImageIO -framework CoreGraphics -framework QuartzCore \
    -o "${REWIND_PROBE_OUTPUT}"
printf 'unsigned probe: %s\n' "${REWIND_PROBE_OUTPUT}"
