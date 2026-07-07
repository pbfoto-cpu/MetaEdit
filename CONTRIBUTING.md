# Contributing to MetaEdit

Thanks for your interest. MetaEdit is a small, focused tool — a fast EXIF/IPTC
metadata viewer and editor for photojournalists. Contributions that keep it
small and correct are very welcome.

## Building

1. Requirements: macOS 14+, Xcode 16 or later.
2. Clone the repo and open `MetaEdit.xcodeproj`.
3. Build. The first build downloads the pinned ExifTool release into
   `Tools/exiftool/` (see `Scripts/fetch-exiftool.sh`) and copies it into the
   app bundle — network access is needed for that first build only.

## Ground rules

- **Metadata correctness over features.** Writes must follow IPTC IIM + XMP
  dual-write conventions so files round-trip cleanly with Lightroom, Photo
  Mechanic, Bridge, and Capture One. Never strip metadata the user didn't
  edit. RAW files default to `.xmp` sidecars.
- **All metadata I/O goes through the bundled ExifTool** subprocess
  (`ExifToolService`). Don't add a second metadata-writing path.
- **State management is `@Observable` only.** `ObservableObject`/`@Published`
  is banned in this codebase (it triggered an AttributeGraph deadlock on this
  stack in a prior project).
- **No network calls, no telemetry, no AI.** This is a local tool.
- ExifTool subprocess calls run off the main thread; every call passes
  explicit UTF-8 charset arguments; user-entered values are sanitized before
  reaching the argument list.
- The App Sandbox stays off (`ENABLE_APP_SANDBOX = NO`) — the ExifTool
  subprocess requires it. Distribution is Developer ID + notarization, not
  the App Store.

## Bumping the bundled ExifTool

Edit the version and SHA256 in `Scripts/fetch-exiftool.sh` (one place, both
values), pin **even-numbered** releases only (odd = development), and check
the new version's LICENSE for changes (see `THIRD_PARTY_LICENSES`).

## Pull requests

- Keep PRs focused on one change.
- Verify metadata round-trips: write with MetaEdit, read with `exiftool`,
  Lightroom, or Photo Mechanic, and confirm the values match.
- Match the existing code style; no new dependencies without discussion
  (SPM only if one is ever justified).

## License

MetaEdit is licensed under the Functional Source License, FSL-1.1-MIT (see
`LICENSE`): use, modify, and redistribute freely for anything except a
competing commercial product, with each release converting to plain MIT two
years after publication.

By contributing you agree that your contributions are provided under the
same license, and you grant the project maintainer the right to license the
project (including your contributions) under other terms — this keeps
future relicensing and commercial distribution possible.
