#!/usr/bin/env bash
# turn the vector icons of a decoded youtube music apk into art/ytm/*.svg masks
# usage: REWIND_YTM_RES=/path/to/decoded-res art/import_ytm_icons.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="${REWIND_YTM_RES:-}"
[ -n "${RES}" ] && [ -d "${RES}/drawable" ] || { echo "set REWIND_YTM_RES to the decoded-res directory of the apk" >&2; exit 1; }

rm -rf "${ROOT}/art/ytm"
mkdir -p "${ROOT}/art/ytm"
python3 -I - "${RES}/drawable" "${ROOT}/art/ytm" "${ROOT}/art" <<'PY'
import glob, os, re, sys
res, out, tools = sys.argv[1:4]
sys.path.insert(0, tools)
import vd2svg

kept = skipped = 0
for path in sorted(glob.glob(os.path.join(res, '*.xml'))):
    stem = os.path.basename(path)[:-4]
    if not re.match(r'^(yt_(outline|fill)|quantum_(ic|gm))_', stem): continue
    svg = vd2svg.convert(path)
    if svg is None:
        skipped += 1
        continue
    name = re.sub(r'_vd_theme_\d+$', '', stem)
    name = re.sub(r'^yt_', '', name).replace('quantum_', 'quantum-', 1)
    name = name.replace('_', '-')
    with open(os.path.join(out, name + '.svg'), 'w') as handle:
        handle.write(svg + '\n')
    kept += 1
print('imported %d icons, skipped %d (clip paths or real colours)' % (kept, skipped))
PY
