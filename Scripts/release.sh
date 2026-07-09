#!/bin/zsh
# MetaEdit release: archive → Developer ID export → notarize → staple → zip.
# Automates everything except the one-time credential setup:
#
#   xcrun notarytool store-credentials metaedit \
#     --apple-id <your-apple-id> --team-id 4NUU5GX869 \
#     --password <app-specific password from account.apple.com>
#
# Usage: Scripts/release.sh            (uses keychain profile "metaedit")
# Output: build/release/MetaEdit-<version>.zip — notarized, stapled,
# ready to attach to a GitHub Release. Release tags (v<version>) also
# document each version's FSL→MIT 2-year conversion date.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
PROFILE="${NOTARY_PROFILE:-metaedit}"
rm -rf "$OUT" && mkdir -p "$OUT"

echo "==> Archiving (Release)"
xcodebuild -project "$ROOT/MetaEdit.xcodeproj" -scheme MetaEdit \
  -configuration Release -archivePath "$OUT/MetaEdit.xcarchive" archive | tail -2

echo "==> Exporting with Developer ID signing"
cat > "$OUT/export-options.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>4NUU5GX869</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/MetaEdit.xcarchive" \
  -exportOptionsPlist "$OUT/export-options.plist" -exportPath "$OUT/export" | tail -2

APP="$OUT/export/MetaEdit.app"
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
ZIP="$OUT/MetaEdit-$VERSION.zip"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarizing (profile: $PROFILE)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket and re-zipping"
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper check"
spctl --assess --type execute --verbose "$APP"

echo "==> Done: $ZIP"
echo "Next: run the app once, run --selftest, then tag v$VERSION and create the GitHub Release."
