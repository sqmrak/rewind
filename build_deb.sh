#!/usr/bin/env bash
# keep the package layout compatible with jailbreak installers
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
STAGE="${ROOT}/package"
OUT="${ROOT}/tunetube_1.0.4-stable_iphoneos-arm.deb"

bash "${ROOT}/build_fat.sh"
rm -rf "${STAGE}/Applications/TuneTube.app"
mkdir -p "${STAGE}/Applications/TuneTube.app"
cp "${ROOT}/build/TuneTube.app/TuneTube" "${STAGE}/Applications/TuneTube.app/"
cp "${ROOT}/build/TuneTube.app/Info.plist" "${STAGE}/Applications/TuneTube.app/"
cp "${ROOT}/build/TuneTube.app/"TuneTubeIcon*.png "${STAGE}/Applications/TuneTube.app/"
cp "${ROOT}/build/TuneTube.app/"Default*.png "${STAGE}/Applications/TuneTube.app/"
cp "${ROOT}/build/TuneTube.app/icon-settings.png" "${STAGE}/Applications/TuneTube.app/"
cp "${ROOT}/build/TuneTube.app/sqmrak.jpg" "${STAGE}/Applications/TuneTube.app/"
cp "${ROOT}/build/TuneTube.app/"player-*.png "${STAGE}/Applications/TuneTube.app/"
chmod 755 "${STAGE}/Applications/TuneTube.app/TuneTube"
chmod 644 "${STAGE}/Applications/TuneTube.app/Info.plist"
chmod 644 "${STAGE}/Applications/TuneTube.app/"TuneTubeIcon*.png
chmod 644 "${STAGE}/Applications/TuneTube.app/"Default*.png
chmod 644 "${STAGE}/Applications/TuneTube.app/icon-settings.png"
chmod 644 "${STAGE}/Applications/TuneTube.app/sqmrak.jpg"
chmod 644 "${STAGE}/Applications/TuneTube.app/"player-*.png
rm -f "${OUT}"

if dpkg-deb -Zgzip --build --root-owner-group "${STAGE}" "${OUT}" >/dev/null 2>&1; then
    :
else
    dpkg-deb -Zgzip --build "${STAGE}" "${OUT}"
fi

file "${OUT}"
echo "built ${OUT}"
