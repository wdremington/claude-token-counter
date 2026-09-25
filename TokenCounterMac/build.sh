#!/bin/bash
# Builds TokenCounter.app.
#
#   ./build.sh                 ad-hoc signed, for local development
#   ./build.sh --install       also copy it into /Applications
#   ./build.sh --release       Developer ID signed, notarized, stapled, + .dmg
#
# --release needs two things set up once (see README):
#   DEVELOPER_ID_APP   e.g. "Developer ID Application: Your Name (TEAMID)"
#                      omitted, the only Developer ID cert in the keychain is used
#   NOTARY_PROFILE     a profile name stored with `xcrun notarytool store-credentials`
#                      (defaults to "tokencounter-notary")
#
# Everything here works with the Xcode Command Line Tools alone - notarytool and
# stapler both ship in that package, so a full Xcode install is not required.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TokenCounter"
BUNDLE_ID="com.tokencounter.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_DIR="build"
BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"
INSTALL=false
RELEASE=false
NOTARY_PROFILE="${NOTARY_PROFILE:-tokencounter-notary}"

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --release) RELEASE=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- compile ---------------------------------------------------------------
# Prefer a universal binary; fall back to this machine's architecture if the
# x86_64 slice can't be built (Command Line Tools without the extra SDK).
echo "==> Building (release)"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  echo "    universal (arm64 + x86_64)"
  BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
else
  echo "    single-architecture ($(uname -m))"
  if $RELEASE; then
    echo "    warning: a release built here will not run on Intel Macs" >&2
  fi
  swift build -c release
  BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
fi

if [[ ! -f "$BIN_PATH" ]]; then
  echo "build produced no binary at $BIN_PATH" >&2
  exit 1
fi

# --- self-test -------------------------------------------------------------
# A release must never ship with the suite red.
if $RELEASE; then
  echo "==> Running self-test"
  if ! "$BIN_PATH" --test > "${BUILD_DIR}/selftest.log" 2>&1; then
    echo "self-test FAILED — see ${BUILD_DIR}/selftest.log" >&2
    tail -20 "${BUILD_DIR}/selftest.log" >&2
    exit 1
  fi
  echo "    $(tail -1 "${BUILD_DIR}/selftest.log")"
fi

# --- assemble bundle -------------------------------------------------------
echo "==> Assembling ${BUNDLE}"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "$BIN_PATH" "${BUNDLE}/Contents/MacOS/${APP_NAME}"

# --- icon ------------------------------------------------------------------
# Non-fatal: a missing icon shouldn't fail the build.
ICON_SET="${BUILD_DIR}/${APP_NAME}.iconset"
if swift Tools/MakeIcon.swift "$ICON_SET" >/dev/null 2>&1 \
   && iconutil -c icns "$ICON_SET" -o "${BUNDLE}/Contents/Resources/${APP_NAME}.icns" 2>/dev/null; then
  ICON_KEY="<key>CFBundleIconFile</key><string>${APP_NAME}</string>"
  echo "    icon generated"
else
  ICON_KEY=""
  echo "    icon skipped"
fi

cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>Token Counter</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  ${ICON_KEY}
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# --- sign ------------------------------------------------------------------
if $RELEASE; then
  if [[ -z "${DEVELOPER_ID_APP:-}" ]]; then
    DEVELOPER_ID_APP="$(security find-identity -v -p codesigning \
      | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  fi
  if [[ -z "$DEVELOPER_ID_APP" ]]; then
    echo "no Developer ID Application certificate found in the keychain." >&2
    echo "Install one from developer.apple.com, or set DEVELOPER_ID_APP." >&2
    exit 1
  fi

  # Hardened runtime, and deliberately no entitlements file: hardened-runtime
  # entitlements are opt-*outs* from hardening (JIT, unsigned memory, library
  # validation), none of which this app needs. Network access and reading
  # ~/.claude need no entitlement outside the App Sandbox, and the app is
  # deliberately not sandboxed.
  echo "==> Signing (${DEVELOPER_ID_APP})"
  codesign --force --timestamp --options runtime \
    --sign "$DEVELOPER_ID_APP" "$BUNDLE"

  echo "==> Notarizing the app"
  ZIP="${BUILD_DIR}/${APP_NAME}-notarize.zip"
  rm -f "$ZIP"
  # notarytool will not accept a bare .app, so submit it zipped.
  ditto -c -k --keepParent "$BUNDLE" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$ZIP"

  # Staple the .app itself, not just the disk image. A cask copies the app out
  # of the dmg, so without its own ticket it would be checked online - or
  # refused when offline.
  echo "==> Stapling the app"
  xcrun stapler staple "$BUNDLE"

  echo "==> Building ${DMG}"
  rm -f "$DMG"
  STAGE="${BUILD_DIR}/dmg-stage"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$BUNDLE" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG"
  rm -rf "$STAGE"

  echo "==> Notarizing the disk image"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"

  echo "==> Verifying"
  codesign -dvv "$BUNDLE" 2>&1 | grep -E 'Authority=Developer ID|flags=' || true
  spctl -a -vv "$BUNDLE" 2>&1 || true
  xcrun stapler validate "$BUNDLE" 2>&1 | tail -1 || true
  echo ""
  echo "    dmg:    ${DMG}"
  echo "    sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
  echo "    Paste that sha256 and version ${VERSION} into Casks/tokencounter.rb"
else
  # Ad-hoc signature: enough to launch locally. The app is deliberately not
  # sandboxed, because it reads ~/.claude/projects.
  echo "==> Signing (ad-hoc)"
  codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1 \
    || echo "    warning: codesign failed; the app may not launch"
fi

echo "==> Built ${BUNDLE}"

if $INSTALL; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$BUNDLE" /Applications/
  echo "==> Installed /Applications/${APP_NAME}.app"
fi
