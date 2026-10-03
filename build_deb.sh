#!/usr/bin/env bash
# one archive for ios 5 through 16: the payload sits in /var/jb, which rootless jailbreaks
# register directly and rootful ones copy into /Applications from postinst
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
STAGE="${ROOT}/package"
PKG_VERSION="$(awk -F': ' '$1 == "Version" { print $2; exit }' "${STAGE}/DEBIAN/control")"
PKG_ARCH="$(awk -F': ' '$1 == "Architecture" { print $2; exit }' "${STAGE}/DEBIAN/control")"
if [[ ! "${PKG_VERSION}" =~ ^[0-9][0-9A-Za-z.+:~-]*$ ]]; then
    echo "invalid Debian package version: ${PKG_VERSION:-<empty>}" >&2
    exit 1
fi
if [[ "${PKG_ARCH}" != "all" ]]; then
    echo "universal package must use Architecture: all" >&2
    exit 1
fi
OUT="${ROOT}/rewind_${PKG_VERSION}.deb"
PAYLOAD="${STAGE}/var/jb/Applications"

bash "${ROOT}/build_fat.sh"
# a stale app from an older layout or name would ship inside the new package
rm -rf "${STAGE}/Applications" "${STAGE}/var"
mkdir -p "${PAYLOAD}"
cp -R "${ROOT}/build/Rewind.app" "${PAYLOAD}/"
find "${PAYLOAD}/Rewind.app" -type f -exec chmod 644 {} +
chmod 755 "${PAYLOAD}/Rewind.app" "${PAYLOAD}/Rewind.app/Rewind"
chmod 755 "${STAGE}/DEBIAN/postinst" "${STAGE}/DEBIAN/postrm"
rm -f "${OUT}"

if dpkg-deb -Zgzip --build --root-owner-group "${STAGE}" "${OUT}" >/dev/null 2>&1; then
    :
else
    dpkg-deb -Zgzip --build "${STAGE}" "${OUT}"
fi

file "${OUT}"
echo "built ${OUT}"
