#!/usr/bin/env bash
# render the svg glyphs into the white masks the app tints at runtime
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RSVG="${REWIND_RSVG:-rsvg-convert}"
command -v "${RSVG}" >/dev/null || { echo "rsvg-convert not found, set REWIND_RSVG" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

for svg in "${ROOT}"/art/icons/*.svg; do
    name="$(basename "${svg}" .svg)"
    sed 's/<path /<path fill="#ffffff" /g' "${svg}" > "${TMP}/${name}.svg"
    # one 96px master per glyph; the app scales it to the exact point size it draws
    "${RSVG}" -w 96 -h 96 "${TMP}/${name}.svg" -o "${ROOT}/app/icons/ic-${name}.png"
done
echo "rendered $(ls "${ROOT}"/art/icons/*.svg | wc -l) icons"
