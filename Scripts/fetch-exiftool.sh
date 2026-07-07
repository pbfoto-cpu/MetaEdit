#!/bin/bash
# Fetches the pinned ExifTool release into Tools/exiftool/.
# The single source of truth for the bundled ExifTool version and its checksum.
# Idempotent: exits immediately if the pinned version is already in place.
set -euo pipefail

EXIFTOOL_VERSION="13.58"
# SHA256 of https://github.com/exiftool/exiftool/archive/refs/tags/13.58.tar.gz
EXIFTOOL_SHA256="34f8e52f5b11806eba1174601bf38801508d4f05f3fef2265b3ce8e1079007b5"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_ROOT/Tools/exiftool"

if [[ -f "$DEST/VERSION" && "$(cat "$DEST/VERSION")" == "$EXIFTOOL_VERSION" && -x "$DEST/exiftool" ]]; then
    exit 0
fi

echo "Fetching ExifTool $EXIFTOOL_VERSION..."
TMPDIR_FETCH="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FETCH"' EXIT

TARBALL="$TMPDIR_FETCH/exiftool.tar.gz"
curl -fsSL --retry 3 -o "$TARBALL" \
    "https://github.com/exiftool/exiftool/archive/refs/tags/$EXIFTOOL_VERSION.tar.gz"

ACTUAL_SHA256="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
if [[ "$ACTUAL_SHA256" != "$EXIFTOOL_SHA256" ]]; then
    echo "error: ExifTool tarball SHA256 mismatch" >&2
    echo "  expected: $EXIFTOOL_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA256" >&2
    exit 1
fi

tar -xzf "$TARBALL" -C "$TMPDIR_FETCH"
SRC="$TMPDIR_FETCH/exiftool-$EXIFTOOL_VERSION"

rm -rf "$DEST"
mkdir -p "$DEST"
# Only what the app needs at runtime, plus license/attribution files.
cp "$SRC/exiftool" "$DEST/exiftool"
cp -R "$SRC/lib" "$DEST/lib"
cp "$SRC/LICENSE" "$DEST/LICENSE"
cp "$SRC/README" "$DEST/README"
chmod +x "$DEST/exiftool"
echo "$EXIFTOOL_VERSION" > "$DEST/VERSION"

echo "ExifTool $EXIFTOOL_VERSION ready at $DEST"
