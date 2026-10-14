#!/bin/bash
# Builds Clipnotch.app without Xcode: SwiftPM for the binary, then a
# hand-assembled bundle. Ad-hoc signed, which is enough for local use.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="Clipnotch"
SIGN_IDENTITY_NAME="Clipnotch Local Signing"
APP="build/${APP_NAME}.app"
CONTENTS="${APP}/Contents"

echo "==> swift build (${CONFIG})"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"

echo "==> assembling ${APP}"
rm -rf "$APP"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "$BIN" "${CONTENTS}/MacOS/${APP_NAME}"
# Run by Claude Code hooks; Clipnotch copies it out of the bundle on install.
mkdir -p "${CONTENTS}/Helpers"
cp "$(dirname "$BIN")/clipnotch-hook" "${CONTENTS}/Helpers/clipnotch-hook"
cp Resources/Info.plist "${CONTENTS}/Info.plist"
cp Resources/mediaremote-adapter.pl "${CONTENTS}/Resources/"
cp -R Resources/MediaRemoteAdapter.framework "${CONTENTS}/Resources/"
# UI strings; the system picks the language from the user's preferred ones.
cp -R Resources/Localization/*.lproj "${CONTENTS}/Resources/"
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# TCC ties the Accessibility grant to the signature. An ad-hoc signature is
# identified by the binary's hash, so every rebuild looks like a different app
# and the grant has to be given again. A stable local certificate makes the
# designated requirement `identifier ... and certificate leaf = H"..."`, which
# survives rebuilds — so the grant is given once.
#
# See "Accessibility permission" in README.md for how to create it.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY_NAME"; then
  SIGN="$SIGN_IDENTITY_NAME"
  echo "==> signing (${SIGN_IDENTITY_NAME})"
else
  SIGN="-"
  echo "==> signing (ad-hoc — Accessibility access will need re-granting after this build)"
fi

# The helper is a separate executable, so it is signed on its own first; the
# bundle pass below then seals it as-is.
codesign --force --sign "$SIGN" --options runtime "${CONTENTS}/Helpers/clipnotch-hook"

# One pass over the bundle. Signing the executable and then the wrapper looks
# like two steps but is not: the second pass rewrites the executable's
# signature, silently dropping the entitlements and the hardened-runtime flag
# the first one set. The bundled framework keeps its upstream signature — no
# --deep — and gets sealed into our resources as-is.
codesign --force --sign "$SIGN" \
  --entitlements Resources/Clipnotch.entitlements \
  --options runtime \
  "$APP"

echo "==> done: ${APP}"
