#!/bin/bash
# Builds a distributable Clipnotch.dmg: a universal .app, signed, in a disk
# image laid out for drag-and-drop into /Applications.
#
# `build.sh` is the development loop — thin binary, local signature, run in
# place. This is the handoff artefact for another machine, so it differs in
# two ways: the binary is universal, and the signature must be one that means
# something away from this Mac (see "signing" below).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Clipnotch"
VOLNAME="Clipnotch"
DEPLOYMENT_TARGET="14.0"
STAGE="dist/stage"
APP="${STAGE}/${APP_NAME}.app"
CONTENTS="${APP}/Contents"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/${APP_NAME}-${VERSION}.dmg"
DMG_RW="dist/.${APP_NAME}-rw.dmg"

# --- universal binary ---------------------------------------------------
# `swift build --arch arm64 --arch x86_64` would do this in one pass, but it
# routes through xcbuild, which only ships with Xcode. Two cross-builds and a
# lipo need nothing but the Command Line Tools.
SLICES=()
HOOK_SLICES=()
for arch in arm64 x86_64; do
  triple="${arch}-apple-macosx${DEPLOYMENT_TARGET}"
  echo "==> swift build (release, ${arch})"
  swift build -c release --triple "$triple"
  BIN_DIR="$(swift build -c release --triple "$triple" --show-bin-path)"
  SLICES+=("${BIN_DIR}/${APP_NAME}")
  HOOK_SLICES+=("${BIN_DIR}/clipnotch-hook")
done

echo "==> assembling ${APP}"
rm -rf "$STAGE" "$DMG_RW"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

lipo -create "${SLICES[@]}" -output "${CONTENTS}/MacOS/${APP_NAME}"
# Run by Claude Code hooks; Clipnotch copies it out of the bundle on install.
mkdir -p "${CONTENTS}/Helpers"
lipo -create "${HOOK_SLICES[@]}" -output "${CONTENTS}/Helpers/clipnotch-hook"
cp Resources/Info.plist "${CONTENTS}/Info.plist"
cp Resources/mediaremote-adapter.pl "${CONTENTS}/Resources/"
cp -R Resources/MediaRemoteAdapter.framework "${CONTENTS}/Resources/"
# UI strings; the system picks the language from the user's preferred ones.
cp -R Resources/Localization/*.lproj "${CONTENTS}/Resources/"
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# --- signing ------------------------------------------------------------
# Not the "Clipnotch Local Signing" certificate that build.sh uses: its root is
# trusted only in this machine's user trust settings, so on the receiving Mac
# it is a signature by an unknown authority — no better than ad-hoc, and it
# ties the artefact to one keychain. Ad-hoc is the honest choice for an
# unnotarised build, and its cdhash-based designated requirement is stable
# because the recipient never rebuilds the app, so the Accessibility grant is
# given once.
#
# A real Developer ID (paid Apple Developer account) is used when present, and
# NOTARY_PROFILE — a `notarytool store-credentials` profile name — gets the
# build notarised and stapled, which is what removes the Gatekeeper warning on
# first launch.
if IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Developer ID Application" \
    | sed -n 's/.*"\(.*\)".*/\1/p')" && [[ -n "$IDENTITY" ]]; then
  SIGN="$IDENTITY"
  echo "==> signing (${SIGN})"
else
  SIGN="-"
  echo "==> signing (ad-hoc — first launch on another Mac needs Open Anyway; see notes at the end)"
fi

# One pass over the bundle, as in build.sh: signing the executable first and
# the wrapper second rewrites the executable's signature and drops the
# entitlements and the hardened-runtime flag.
# A secure timestamp needs Apple's timestamp service, which refuses ad-hoc
# signatures; a Developer ID signature has to carry one to be notarisable.
TIMESTAMP=(--timestamp)
[[ $SIGN == - ]] && TIMESTAMP=(--timestamp=none)

# The helper is a separate executable, so it is signed on its own first; the
# bundle pass then seals it as-is.
codesign --force --sign "$SIGN" --options runtime "${TIMESTAMP[@]}" \
  "${CONTENTS}/Helpers/clipnotch-hook"

codesign --force --sign "$SIGN" \
  --entitlements Resources/Clipnotch.entitlements \
  --options runtime \
  "${TIMESTAMP[@]}" \
  "$APP"

if [[ $SIGN != - && -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> notarising (profile ${NOTARY_PROFILE})"
  ZIP="dist/${APP_NAME}-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

# --- disk image ---------------------------------------------------------
ln -s /Applications "${STAGE}/Applications"

echo "==> creating disk image"
rm -f "$DMG"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" \
  -fs HFS+ -format UDRW -ov -quiet "$DMG_RW"

# Icon placement is cosmetic and driven through Finder, which needs Automation
# access this script cannot grant itself. A refusal must not fail the build, so
# the layout pass is advisory: without it the image still mounts with the app
# and the Applications symlink side by side, just in whatever view Finder picks.
#
# Mounted at the default /Volumes path on purpose. Finder addresses a volume as
# `disk "<name>"`, and an image attached to a mountpoint elsewhere is a plain
# folder to it, which is why the layout has to be applied through the volume
# name rather than a path.
[[ -d "/Volumes/${VOLNAME}" ]] && hdiutil detach "/Volumes/${VOLNAME}" -quiet
MOUNT="$(hdiutil attach "$DMG_RW" -readwrite -noverify -noautoopen \
  | grep -o '/Volumes/.*' | tail -1)"
DISK="$(basename "$MOUNT")"

if osascript - "$DISK" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  tell application "Finder"
    tell disk (item 1 of argv)
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, 760, 460}
      tell the icon view options of container window
        set arrangement to not arranged
        set icon size to 96
        set text size to 12
      end tell
      set position of item "Clipnotch.app" to {150, 160}
      set position of item "Applications" to {410, 160}
      update without registering applications
      close
    end tell
  end tell
end run
APPLESCRIPT
then
  echo "==> window layout applied"
else
  echo "==> window layout skipped (Finder automation unavailable; image is still valid)"
fi
sync
hdiutil detach "$MOUNT" -quiet

ARCHS="$(lipo -archs "${CONTENTS}/MacOS/${APP_NAME}")"

hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG"
rm -f "$DMG_RW"
rm -rf "$STAGE"

echo "==> done: ${DMG} — $(du -h "$DMG" | cut -f1), ${ARCHS}"
if [[ $SIGN == - ]]; then
  cat <<'NOTES'

The image is ad-hoc signed, so macOS will not open it on first launch by
double-click. Either route works on the receiving Mac:

  * Right-click Clipnotch in /Applications -> Open, then Open in the dialog.
    On macOS 15+ the dialog may only appear under
    System Settings -> Privacy & Security -> "Open Anyway".
  * Or strip the quarantine flag: xattr -dr com.apple.quarantine /Applications/Clipnotch.app

A Developer ID signature plus notarisation removes this step entirely:
  NOTARY_PROFILE=<notarytool profile> ./package.sh
NOTES
fi
