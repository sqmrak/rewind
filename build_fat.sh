#!/usr/bin/env bash
# make one binary for both cpu families so the same app runs on old and newer devices
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
THEOS="${THEOS:?set THEOS to theos root}"
TC="${REWIND_TC:-${THEOS}/toolchain/linux/iphone/bin}"
LIPO="${REWIND_LIPO:-${TC}/lipo}"
LDID="${REWIND_LDID:-${TC}/ldid}"
SDK_V7="${REWIND_SDK_V7:?set REWIND_SDK_V7 to the armv7 sdk}"
SDK_V64="${REWIND_SDK_V64:?set REWIND_SDK_V64 to the arm64 sdk}"
SLICES="${ROOT}/.build-slices"

rm -rf "${SLICES}"
mkdir -p "${SLICES}/armv7" "${SLICES}/arm64"

make -C "${ROOT}" clean all \
    THEOS="${THEOS}" TC="${TC}" LDID="${LDID}" \
    TRIPLE=arm-apple-darwin11 SDK="${SDK_V7}" \
    ARCH="-arch armv7 -miphoneos-version-min=5.0" \
    BIN="${SLICES}/armv7/Rewind" OBJDIR=build/obj-armv7

make -C "${ROOT}" clean all \
    THEOS="${THEOS}" TC="${TC}" LDID="${LDID}" \
    TRIPLE=arm64-apple-darwin SDK="${SDK_V64}" \
    ARCH="-arch arm64 -miphoneos-version-min=7.0" \
    BIN="${SLICES}/arm64/Rewind" OBJDIR=build/obj-arm64

rm -rf "${ROOT}/build"
mkdir -p "${ROOT}/build/Rewind.app"
"${LIPO}" -create "${SLICES}/armv7/Rewind" "${SLICES}/arm64/Rewind" \
    -output "${ROOT}/build/Rewind.app/Rewind"
cp "${ROOT}/Info.plist" "${ROOT}/build/Rewind.app/"
cp "${ROOT}/app/icons/"RewindIcon*.png "${ROOT}/build/Rewind.app/"
cp "${ROOT}/app/icons/icon-settings.png" "${ROOT}/build/Rewind.app/"
cp "${ROOT}/app/icons/sqmrak.jpg" "${ROOT}/build/Rewind.app/"
cp "${ROOT}/app/icons/rewind-fall.png" "${ROOT}/build/Rewind.app/"
cp "${ROOT}/app/icons/"player-*.png "${ROOT}/build/Rewind.app/"
cp "${ROOT}/app/icons/"menu-*.png "${ROOT}/build/Rewind.app/"
cp "${ROOT}/app/icons/"ic-*.png "${ROOT}/build/Rewind.app/"
cp "${ROOT}/app/fonts/"Roboto-*.ttf "${ROOT}/build/Rewind.app/"
cp "${ROOT}/app/fonts/LICENSE-Roboto.txt" "${ROOT}/art/LICENSE-MaterialSymbols.txt" "${ROOT}/build/Rewind.app/"
cp "${ROOT}/app/icons/"Default*.png "${ROOT}/build/Rewind.app/"
# ios 14 and later confine unsandboxed /Applications bundles without this entitlement
"${LDID}" -S"${ROOT}/app/entitlements.plist" "${ROOT}/build/Rewind.app/Rewind"

file "${ROOT}/build/Rewind.app/Rewind"
"${LIPO}" -info "${ROOT}/build/Rewind.app/Rewind"
echo "built fat app ${ROOT}/build/Rewind.app"
