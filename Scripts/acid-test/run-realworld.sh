#!/bin/zsh
# Real-world file-date test: copies the given folder to a temp dir, runs
# setFileDatesFromCaptureDate on every image in the COPY, and verifies
# (1) all file bytes unchanged incl. sidecars, (2) counts add up,
# (3) disk dates equal capture dates. Originals are never touched.
#
# Usage: Scripts/acid-test/run-realworld.sh <folder-with-photos>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RES="$ROOT/build/DerivedData/Build/Products/Debug/MetaEdit.app/Contents/Resources"
[[ -x "$RES/exiftool/exiftool" ]] || { echo "Build the app first (bundled exiftool not found)"; exit 1; }
[[ -d "${1:-}" ]] || { echo "Usage: $0 <folder-with-photos>"; exit 1; }

WORK="$(mktemp -d /tmp/metaedit-realworld.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cp -R "$1" "$WORK/photos"
cp "$ROOT/Scripts/acid-test/realworld.swift" "$WORK/main.swift"

swiftc -swift-version 6 -default-isolation MainActor -o "$WORK/realworld" \
  "$WORK/main.swift" \
  "$ROOT/MetaEdit/Services/ExifToolService.swift" \
  "$ROOT/MetaEdit/Services/MetaEditError.swift" \
  "$ROOT/MetaEdit/Services/LibraryScanner.swift" \
  "$ROOT/MetaEdit/Models/MetadataModels.swift"

ln -s "$RES/exiftool" "$WORK/exiftool"   # Bundle.main.resourceURL = binary's dir
"$WORK/realworld" "$WORK/photos"
