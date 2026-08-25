#!/usr/bin/env bash
# keep the ipa layout compatible with jailbreak installers
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
STAGE="$ROOT/.ipa-stage"
OUT="$ROOT/Tunetube-v1.0.4-stable.ipa"

bash "$ROOT/build_fat.sh"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload/TuneTube.app"
cp "$ROOT/build/TuneTube.app/TuneTube" "$STAGE/Payload/TuneTube.app/"
cp "$ROOT/build/TuneTube.app/Info.plist" "$STAGE/Payload/TuneTube.app/"
cp "$ROOT/build/TuneTube.app/"TuneTubeIcon*.png "$STAGE/Payload/TuneTube.app/"
cp "$ROOT/build/TuneTube.app/"Default*.png "$STAGE/Payload/TuneTube.app/"
cp "$ROOT/build/TuneTube.app/icon-settings.png" "$STAGE/Payload/TuneTube.app/"
cp "$ROOT/build/TuneTube.app/sqmrak.jpg" "$STAGE/Payload/TuneTube.app/"
cp "$ROOT/build/TuneTube.app/"player-*.png "$STAGE/Payload/TuneTube.app/"
cp "$ROOT/build/TuneTube.app/"menu-*.png "$STAGE/Payload/TuneTube.app/"
chmod 755 "$STAGE/Payload/TuneTube.app/TuneTube"
chmod 644 "$STAGE/Payload/TuneTube.app/Info.plist"
chmod 644 "$STAGE/Payload/TuneTube.app/"TuneTubeIcon*.png
chmod 644 "$STAGE/Payload/TuneTube.app/"Default*.png
chmod 644 "$STAGE/Payload/TuneTube.app/icon-settings.png"
chmod 644 "$STAGE/Payload/TuneTube.app/sqmrak.jpg"
chmod 644 "$STAGE/Payload/TuneTube.app/"player-*.png
chmod 644 "$STAGE/Payload/TuneTube.app/"menu-*.png
rm -f "$OUT"

(cd "$STAGE" && zip -qry "$OUT" Payload)
rm -rf "$STAGE"

unzip -l "$OUT"
echo "built $OUT"
