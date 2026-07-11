# MetaEdit User Guide

*MetaEdit by [FotoArch](https://fotoarch.app)*

MetaEdit is a fast, lightweight EXIF/IPTC metadata viewer and editor for
macOS, built for photojournalists and working photographers. It does one
thing: read and write image metadata to industry standards, so your files
round-trip cleanly with Lightroom, Photo Mechanic, Bridge, and Capture One.

It is a local tool. No network access, no accounts, no AI, no telemetry.
It is also the free companion to [FotoArch](https://fotoarch.app), the
archiving and AI-captioning tool from the same maker — same metadata
engine, same write-path guarantees.

---

## The window at a glance

MetaEdit is a single window with three panes:

| Pane | What it does |
|---|---|
| **Left — file browser** | Thumbnails and filenames for the folder or files you opened |
| **Center — preview** | A large preview of the selected image |
| **Right — metadata panel** | Camera EXIF (read-only) and editable IPTC fields |

There is no setup, no import step, and no catalog. Your files stay where
they are.

**Tabs:** File → New Window (⌘N) opens an independent session as a tab —
its own folder, selection, and editor — so you can compare two folders or
work separate projects at once. Each tab is named by its open folder; drag
a tab out to make it a separate window. Templates are shared across all
tabs and windows.

## Opening images

Two ways:

- **Open Folder…** (toolbar button) — pick a folder; its images fill the
  browser list, **including everything in its subfolders** — a shoot
  folder that holds only day or card subfolders shows the whole take,
  grouped by folder with a section header per subfolder. (Only image
  files are listed — sidecars like `.xmp`/`.on1` and system files don't
  count, so the list can be shorter than Finder's item count.)
- **Drag and drop** anywhere on the window:
  - Dropping a **folder** replaces the list with that folder's contents
    (subfolders included).
  - Dropping **individual files** *adds* them to the current list
    (duplicates are skipped).

To remove entries from the list, select them and press **Delete**, or
right-click → **Remove from List**. This only affects the list — files on
disk are never touched. Right-click → **Show in Finder** jumps to the file.

Folders with thousands of images are fine: the list streams in and
thumbnails load lazily as you scroll.

## Reading metadata

Select an image and the right panel shows:

- **Camera** (read-only): camera and lens, exposure, focal length, ISO,
  capture date, pixel dimensions.
- **IPTC** (editable): Headline, Caption, Keywords, Byline/Creator, Credit,
  Source, Copyright Notice, Copyright Status, Usage Rights, Creator Email,
  Creator Website, City, State/Province, Country, Location, Category,
  Special Instructions, Date Created.

Where a file carries both XMP and legacy IPTC IIM values, XMP is preferred
(the same reading order Lightroom and Photo Mechanic use). For RAW files
that have an `.xmp` sidecar, the sidecar's values are shown — it is the
authoritative source, matching Lightroom/Camera Raw behavior.

## Editing one image

Type into any IPTC field. Keywords are comma-separated. Copyright Status is
a three-way choice (Unknown / Copyrighted / Public Domain). Date Created
expects `YYYY:MM:DD`.

Nothing is written until you press **Save** (or **⌘S**). **Revert**
discards your unsaved edits. After every save, MetaEdit re-reads the file
and confirms the values actually stuck before reporting success.

The bar at the bottom of the panel always tells you where the save will
land — see *Where metadata is written* below.

## Batch editing

Select multiple images (⌘-click or ⇧-click) and the right panel switches to
the batch editor:

- Fields where **every selected file agrees** are prefilled with that value.
  Leave them alone and they aren't rewritten.
- Fields that **differ across the selection** show a *multiple values*
  placeholder and a warning at the top. They are only overwritten if you
  type into them — you can add a credit line to 200 images without
  flattening 200 different captions.
- **Keywords** have their own switch:
  - **Add to existing** (default) — your keywords are appended to each
    file's own list, without duplicates.
  - **Replace all** — every file gets exactly the list you typed.

Nothing is written until you press **Apply to N Images** (or **⌘S**). Every
file is verified after writing. If some files fail — a read-only card, an
ejected drive — you get a list of exactly which files failed and why; the
successful ones stand.

## Templates

Templates are for the boilerplate that never changes — a solo creator's
copyright notice, byline, usage rights, and contact details, identical
across thousands of archive images.

**To create one:** fill in the fields the way you always do (on any image,
or in the batch editor), then **Templates → Save Draft as Template…**. Give
it a name. The template captures the fields that are currently filled;
empty fields stay untouched when it's applied. You choose whether the
template's keywords *add to* each image's existing keywords (default) or
*replace* them.

**To apply one:** pick it from the **Templates** menu in the editor panel —
single image or batch, same menu. Applying a template fills in the fields
on screen; **nothing is written until you press Save / Apply**, so you can
review and tweak first (add today's city, adjust the caption) before
committing. With a large selection, that's the whole archive workflow:
select all, apply template, Apply to N Images, done.

Templates are stored as plain JSON files in
`~/Library/Application Support/MetaEdit/Templates/` — copy them to another
Mac (or a colleague) and they just work.

## Fixing file dates (archive repair)

If an export or transfer once mangled your files' created/modified dates
on disk (a common Lightroom/PhotoShelter artifact), select the affected
files, right-click → **Set File Dates from Capture Date…**. Each file's
filesystem dates become its EXIF capture date, so Finder and other tools
sort the archive chronologically again.

Only the filesystem dates change — image data and metadata are untouched.
You'll be asked to confirm first, because the current file dates can't be
restored afterward. Files with no capture date in their EXIF are skipped
and listed.

## Where metadata is written

This is the part most metadata tools get wrong, so MetaEdit is explicit
about it:

- **JPEG and TIFF** — metadata is embedded in the file, written to *both*
  the legacy IPTC IIM block and the XMP packet, kept in sync, with the
  correct UTF-8 charset marker. This is what Photo Mechanic and Lightroom
  both expect. Image pixels are never re-encoded.
- **RAW files** — by default, edits go to an adjacent `.xmp` **sidecar**
  (`IMG_1234.CR3` → `IMG_1234.xmp`), the same convention as Lightroom,
  Photo Mechanic, and Camera Raw. The RAW file itself is never modified.
  New sidecars are seeded from the image's existing metadata so nothing is
  lost.
- Fields you didn't edit are always preserved — MetaEdit never strips or
  rewrites unrelated metadata on save.

If you specifically want edits embedded inside RAW files instead of
sidecars, turn on **Settings (⌘,) → Write metadata into RAW files**. Only
do this if you know your other tools read embedded XMP from RAW — sidecars
are the safer, more interoperable default. The save bar badge always shows
which mode is active.

## Supported formats

- **Editable images:** JPEG (`.jpg`, `.jpeg`), TIFF (`.tif`, `.tiff`)
- **RAW (sidecar by default):** Canon CR2/CR3/CRW · Nikon NEF/NRW · Sony
  ARW/SR2/SRF · Adobe DNG · Fujifilm RAF · Olympus/OM ORF · Panasonic RW2 ·
  Pentax PEF · Leica RWL · Samsung SRW · Phase One IIQ · Hasselblad 3FR/FFF ·
  Sigma X3F · Mamiya MEF · Kodak DCR · Epson ERF · GoPro GPR

RAW previews come from the image's embedded preview — no slow full RAW
decode. A rare format without a decodable preview shows a placeholder icon
but can still be edited.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘S | Save (single image) / Apply to N Images (batch) |
| Delete | Remove selected entries from the list |
| ⌘, | Settings |

## When something goes wrong

Errors are specific, not generic: a read-only volume, an ejected drive
mid-write, a permissions problem, or a write that didn't verify each get
their own message telling you what happened and what to do. A failed or
partial batch names each affected file.

If a save reports a verification failure, the file has not been corrupted —
the message means MetaEdit re-read the file and the values didn't match
what it wrote, so you should check the file and try again.

## Under the hood (the one-paragraph version)

All metadata reads and writes go through a bundled, pinned copy of
[ExifTool](https://exiftool.org) — the industry-standard metadata engine —
so behavior matches the wider professional ecosystem exactly. MetaEdit
never depends on whatever ExifTool version may or may not be installed on
your Mac. See `THIRD_PARTY_LICENSES` for attribution.
