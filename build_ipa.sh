#!/usr/bin/env bash
# keep the ipa layout compatible with jailbreak installers
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
STAGE="$ROOT/.ipa-stage"
OUT="$ROOT/rewind-v1.0.0-stable.ipa"

bash "$ROOT/build_fat.sh"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$ROOT/build/Rewind.app" "$STAGE/Payload/"
find "$STAGE/Payload/Rewind.app" -type f -exec chmod 644 {} +
chmod 755 "$STAGE/Payload/Rewind.app/Rewind"
# an ipa installs into /var/containers, and there the no-sandbox entitlement of the /Applications build makes
# the kernel kill the app at exec ("outside of container && !i_can_has_debugger", seen on a tester's iphone)
LDID="${REWIND_LDID:-${REWIND_TC:-${THEOS:?set THEOS to theos root}/toolchain/linux/iphone/bin}/ldid}"
"$LDID" -S "$STAGE/Payload/Rewind.app/Rewind"
if "$LDID" -e "$STAGE/Payload/Rewind.app/Rewind" | grep -q no-sandbox; then
    echo "ipa binary still carries the no-sandbox entitlement" >&2
    exit 1
fi
rm -f "$OUT"

(cd "$STAGE" && zip -qry "$OUT" Payload)
rm -rf "$STAGE"

unzip -l "$OUT"
echo "built $OUT"
