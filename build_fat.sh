#!/usr/bin/env bash
# make one binary for both cpu families so the same app runs on old and newer devices
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
THEOS="${THEOS:?set THEOS to theos root}"
TC="${TUNETUBE_TC:-${THEOS}/toolchain/linux/iphone/bin}"
LIPO="${TUNETUBE_LIPO:-${TC}/lipo}"
LDID="${TUNETUBE_LDID:-${TC}/ldid}"
SDK_V7="${TUNETUBE_SDK_V7:?set TUNETUBE_SDK_V7 to the armv7 sdk}"
SDK_V64="${TUNETUBE_SDK_V64:?set TUNETUBE_SDK_V64 to the arm64 sdk}"
SLICES="${ROOT}/.build-slices"

rm -rf "${SLICES}"
mkdir -p "${SLICES}/armv7" "${SLICES}/arm64"

make -C "${ROOT}" clean all \
    THEOS="${THEOS}" TC="${TC}" LDID="${LDID}" \
    TRIPLE=arm-apple-darwin11 SDK="${SDK_V7}" \
    ARCH="-arch armv7 -miphoneos-version-min=5.0" \
    BIN="${SLICES}/armv7/TuneTube" OBJDIR=build/obj-armv7

make -C "${ROOT}" clean all \
    THEOS="${THEOS}" TC="${TC}" LDID="${LDID}" \
    TRIPLE=arm64-apple-darwin SDK="${SDK_V64}" \
    ARCH="-arch arm64 -miphoneos-version-min=7.0" \
    BIN="${SLICES}/arm64/TuneTube" OBJDIR=build/obj-arm64

rm -rf "${ROOT}/build"
mkdir -p "${ROOT}/build/TuneTube.app"
"${LIPO}" -create "${SLICES}/armv7/TuneTube" "${SLICES}/arm64/TuneTube" \
    -output "${ROOT}/build/TuneTube.app/TuneTube"
cp "${ROOT}/Info.plist" "${ROOT}/build/TuneTube.app/"
cp "${ROOT}/app/icons/"TuneTubeIcon*.png "${ROOT}/build/TuneTube.app/"
cp "${ROOT}/app/icons/icon-settings.png" "${ROOT}/build/TuneTube.app/"
cp "${ROOT}/app/icons/sqmrak.jpg" "${ROOT}/build/TuneTube.app/"
cp "${ROOT}/app/icons/"player-*.png "${ROOT}/build/TuneTube.app/"
cp "${ROOT}/app/icons/"menu-*.png "${ROOT}/build/TuneTube.app/"
cp "${ROOT}/app/icons/"Default*.png "${ROOT}/build/TuneTube.app/"
"${LDID}" -S "${ROOT}/build/TuneTube.app/TuneTube"

file "${ROOT}/build/TuneTube.app/TuneTube"
"${LIPO}" -info "${ROOT}/build/TuneTube.app/TuneTube"
echo "built fat app ${ROOT}/build/TuneTube.app"
