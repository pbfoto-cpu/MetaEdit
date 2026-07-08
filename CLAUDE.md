# MetaEdit — project instructions

Fast, standalone EXIF/IPTC metadata editor for macOS (photojournalist
audience). Public repo: https://github.com/pbfoto-cpu/MetaEdit — licensed
FSL-1.1-MIT (source-available; converts to MIT 2 years per release). The
owner may sell the app; keep the CONTRIBUTING.md license grant intact.

## Hard rules (violating these has broken things before)

1. **State management is `@Observable` only.** Never use `ObservableObject`
   / `@Published` — it caused an AttributeGraph TypeDescriptorCache
   deadlock on this exact stack in a prior project (FotoArch).
2. **All metadata I/O goes through the bundled ExifTool subprocess**
   (`ExifToolService`). No second metadata path (no ImageIO writes, no
   CoreGraphics metadata APIs). Reads for display, thumbnails via ImageIO
   are fine.
3. **App Sandbox stays OFF** (`ENABLE_APP_SANDBOX = NO`) — required for the
   subprocess. Distribution is Developer ID + notarization, never App Store.
4. **Never strip or rewrite metadata the user didn't edit.** ExifTool
   tag-level writes preserve everything else; keep it that way.
5. **No network calls, no telemetry, no AI in the app.** (Build-time
   ExifTool fetch is the only permitted network use.)
6. The project builds with Swift 6 + `SWIFT_DEFAULT_ACTOR_ISOLATION =
   MainActor`: every service/model type must be explicitly `nonisolated`
   (including private extensions — they inherit MainActor too).

## Architecture map

- `MetaEdit/Services/ExifToolService.swift` — all ExifTool subprocess work:
  read/write/verify/batch, arg building, error classification. Every call
  runs in `Task.detached` with explicit `-charset utf8 -charset iptc=utf8
  -charset filename=utf8`.
- `MetaEdit/Services/LibraryScanner.swift` — folder streaming, file-kind
  detection (RAW extension list lives here), ImageIO thumbnails (embedded
  RAW previews, never full decode).
- `MetaEdit/Services/ThumbnailCache.swift` — actor cache for list thumbs.
- `MetaEdit/Models/MetadataModels.swift` — `MetadataFields` doubles as a
  partial change set: nil = leave unchanged, ""/[] = clear the tag.
- `MetaEdit/AppState.swift` — single `@Observable @MainActor` app state.
- `MetaEdit/ContentView.swift` — 3-pane UI + single-image and batch editors.
- `MetaEdit/SelfTest.swift` — `--selftest <image>` CLI mode (see Verify).
- `Scripts/fetch-exiftool.sh` — THE single source of truth for the pinned
  ExifTool version + SHA256. Pin **even-numbered** releases only (odd =
  dev). Fetch from github.com/exiftool/exiftool (exiftool.org is
  unreachable from this machine). Bump requires re-checking its LICENSE
  (see THIRD_PARTY_LICENSES).

## Write-path invariants (verified empirically — don't re-litigate)

- JPEG/TIFF embedded writes: IPTC IIM + XMP dual-write, kept in sync, and
  **always `-IPTC:CodedCharacterSet=UTF8`** or other apps decode IIM as
  Latin-1.
- RAW writes default to `.xmp` sidecars (Lightroom convention; sidecar is
  authoritative for reads too). Embedded RAW writes (opt-in setting) are
  XMP-only — no IIM inside proprietary RAW containers.
- Replace a list tag with `-TAG=` then repeated `-TAG=item`. `+=` appends
  to the file's existing list and bypasses the queued clear.
- Sidecar creation must be two calls (seed via `-o`, then apply edits):
  with `-o`, copied source metadata OVERRIDES explicit assignments.
- `exiftool -json` emits booleans for some tags (XMP:Marked) — the JSON
  mapper converts to "True"/"False" strings.
- Reads must NOT use `-struct`: XMP structures (CreatorContactInfo) need to
  come back flattened (CreatorWorkEmail/CreatorWorkURL) for field mapping.
- Every write is verified by re-reading (`verifyWrite` / batch verify).

## Build & verify

```sh
xcodebuild -project MetaEdit.xcodeproj -scheme MetaEdit \
  -configuration Debug -derivedDataPath build/DerivedData build

# End-to-end check (read, thumbnail, embedded+sidecar+batch write round-trips):
build/DerivedData/Build/Products/Debug/MetaEdit.app/Contents/MacOS/MetaEdit \
  --selftest <some.jpg>   # exit 0 = pass
```

Run the selftest after touching ExifToolService, models, or the write path.
First build needs network (ExifTool fetch). No test target yet — the
selftest is the regression net.

## Status (2026-07-07)

Shipped and pushed: 3-pane browser with thumbnails, single-image editing
with Save/verify, batch editing (multi-select, conflict detection, keyword
append/replace policy, chunked writes), sidecars, RAW support for all
mainstream makers, Settings toggle for embedded RAW writes, templates
(TemplateStore, JSON in Application Support, apply-to-draft in both
editors), usage rights + creator contact fields, USER_GUIDE.md.

## Roadmap / recommendations (rough priority order)

1. **⌘O / File → Open + Open Recent** — the open action is currently
   toolbar-only; make it feel like a real Mac app.
2. **XCTest target** — move selftest assertions into real unit tests
   (service-level tests can run against temp files without the GUI).
3. **GitHub Actions CI** — macOS runner: build + selftest per push;
   becomes important once outside PRs arrive.
4. **First release** — archive → Developer ID export → `notarytool` →
   staple → tag `v0.1.0` + GitHub Release. A `Scripts/release.sh` should
   automate everything except credential entry. Release tags also document
   each version's FSL→MIT 2-year conversion date.
5. Later: Sparkle updates, Homebrew cask, recursive folder scan toggle,
   token-field keywords UI, HEIC read support (browse/caption phone shots).
6. Later (v2, shared design with FotoArch): preview viewing aids —
   zoom/pan + 100% toggle, session-only exposure/shadow inspection
   sliders, histogram; rotation via EXIF Orientation tag write (the one
   persistent non-destructive "edit"). No pixel editing, ever; XMP crs:
   develop fields deliberately parked.

## Working conventions

- Commit messages explain the *why* of metadata-correctness decisions
  (future contributors can't re-derive them from the diff).
- The user prefers small, verifiable increments: build + selftest + GUI
  smoke test before declaring anything done, commit when the user confirms.
- Don't edit files via the GitHub web UI while local work is in flight —
  it forked history once already.
