#!/bin/zsh
# Acid test for ExifToolService.setFileDatesFromCaptureDate — edge cases the
# --selftest doesn't cover (skips, locked files, unicode names, DST dates,
# chunking, missing files). Compiles the real service sources into a CLI
# harness and points it at the built app's bundled ExifTool.
#
# Prereq: a Debug build (build/DerivedData/...). Usage: Scripts/acid-test/run.sh
# Interim regression net until these cases move into an XCTest target.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RES="$ROOT/build/DerivedData/Build/Products/Debug/MetaEdit.app/Contents/Resources"
[[ -x "$RES/exiftool/exiftool" ]] || { echo "Build the app first (bundled exiftool not found)"; exit 1; }

WORK="$(mktemp -d /tmp/metaedit-acid.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

swiftc -swift-version 6 -default-isolation MainActor -o "$WORK/acid" \
  "$ROOT/Scripts/acid-test/main.swift" \
  "$ROOT/MetaEdit/Services/ExifToolService.swift" \
  "$ROOT/MetaEdit/Services/MetaEditError.swift" \
  "$ROOT/MetaEdit/Services/LibraryScanner.swift" \
  "$ROOT/MetaEdit/Models/MetadataModels.swift"

ln -s "$RES/exiftool" "$WORK/exiftool"   # Bundle.main.resourceURL = binary's dir
"$WORK/acid"
