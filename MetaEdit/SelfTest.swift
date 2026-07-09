//
//  SelfTest.swift
//  MetaEdit
//
//  `MetaEdit --selftest <image-file>` exercises the bundled-ExifTool
//  pipeline end to end from the command line: read, thumbnail, and both
//  write modes (on temp copies — the input file is never modified).
//  Prints results and exits 0 on success, 1 on failure.
//

import CoreGraphics
import Foundation

nonisolated enum SelfTest {

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--selftest") else { return }
        guard arguments.count > flagIndex + 1 else {
            fail("usage: MetaEdit --selftest <image-file>", code: 64)
        }
        let fileURL = URL(fileURLWithPath: arguments[flagIndex + 1])

        Task.detached {
            do {
                try await run(on: fileURL)
                exit(0)
            } catch {
                fail("SELFTEST FAIL: \(error.localizedDescription)")
            }
        }
        // Park the main thread; the detached task terminates the process.
        while true { RunLoop.main.run(until: .distantFuture) }
    }

    private static func run(on fileURL: URL) async throws {
        let service = ExifToolService()

        // 1. Read + thumbnail
        let version = try await service.exifToolVersion()
        let record = try await service.readMetadata(fileURL: fileURL)
        print("SELFTEST READ OK exiftool=\(version)")
        print("camera: \(record.camera)")
        print("fields: \(record.fields)")
        guard let thumbnail = await ThumbnailCache.shared.thumbnail(for: fileURL) else {
            fail("SELFTEST FAIL: no thumbnail generated")
        }
        print("thumbnail: \(thumbnail.width)x\(thumbnail.height)")

        // 2. Write round-trips on temp copies
        var testFields = MetadataFields()
        testFields.headline = "Selftest Headline"
        testFields.caption = "Round-trip \"quotes\" & ünïcode — dash"
        testFields.keywords = ["selftest", "round trip", "çheck"]
        testFields.byline = "Selftest Byline"
        testFields.city = "Reykjavík"
        testFields.copyrightStatus = "True"
        testFields.usageTerms = "Editorial use only; no third-party sales"
        testFields.creatorEmail = "selftest@example.com"
        testFields.creatorURL = "https://example.com"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetaEditSelfTest-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for mode in [WriteMode.embedded, .sidecar] {
            let copy = tempDir.appendingPathComponent("write-\(mode == .embedded ? "embedded" : "sidecar").\(fileURL.pathExtension)")
            try FileManager.default.copyItem(at: fileURL, to: copy)
            try await service.writeMetadata(fileURL: copy, fields: testFields, mode: mode)
            guard try await service.verifyWrite(fileURL: copy, expected: testFields, mode: mode) else {
                fail("SELFTEST FAIL: \(mode) write did not verify")
            }
            print("SELFTEST WRITE \(mode) OK")
        }

        // 3. Batch write across copies: scalar overwrite + keyword append
        let batchCopies: [URL] = try (1...3).map { index in
            let copy = tempDir.appendingPathComponent("batch-\(index).\(fileURL.pathExtension)")
            try FileManager.default.copyItem(at: fileURL, to: copy)
            return copy
        }
        var batchFields = MetadataFields()
        batchFields.credit = "Batch Credit"
        batchFields.keywords = ["batch-added"]
        var policy = FieldWritePolicy()
        policy.perField[.keywords] = .append

        let result = try await service.writeMetadataBatch(
            fileURLs: batchCopies, fields: batchFields, policy: policy,
            modeFor: { _ in .embedded }
        )
        guard result.failures.isEmpty, result.written.count == batchCopies.count else {
            fail("SELFTEST FAIL: batch write \(result.written.count)/\(batchCopies.count) verified, failures: \(result.failures.map(\.message))")
        }
        // Appended keywords must coexist with the originals.
        let readBack = try await service.readMetadataBatch(fileURLs: batchCopies)
        for url in batchCopies {
            let keywords = readBack[url]?.fields.keywords ?? []
            guard keywords.contains("batch-added"), Set(keywords).count == keywords.count,
                  readBack[url]?.fields.headline != nil else {
                fail("SELFTEST FAIL: batch append produced \(keywords) for \(url.lastPathComponent)")
            }
        }
        print("SELFTEST BATCH OK (\(result.written.count) files, keyword append verified)")

        // 4. Template apply semantics + JSON round-trip
        var boilerplate = MetadataFields()
        boilerplate.byline = "Template Byline"
        boilerplate.copyrightNotice = "© 2026 Template"
        boilerplate.usageTerms = "No use without permission"
        boilerplate.keywords = ["archive"]
        let template = MetadataTemplate(name: "Selftest", fields: boilerplate, appendKeywords: true)

        var existing = MetadataFields()
        existing.caption = "Keep me"
        existing.keywords = ["existing"]
        let applied = template.apply(to: existing)
        guard applied.caption == "Keep me",
              applied.byline == "Template Byline",
              applied.usageTerms == "No use without permission",
              applied.keywords == ["existing", "archive"] else {
            fail("SELFTEST FAIL: template apply produced \(applied)")
        }
        let encoded = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(MetadataTemplate.self, from: encoded)
        guard decoded == template else {
            fail("SELFTEST FAIL: template JSON round-trip mismatch")
        }
        print("SELFTEST TEMPLATE OK")

        // 5. File dates from capture date: backdated copy gets its
        // filesystem dates restored to a known DateTimeOriginal.
        let dateCopy = tempDir.appendingPathComponent("dates.\(fileURL.pathExtension)")
        try FileManager.default.copyItem(at: fileURL, to: dateCopy)
        _ = try await service.runExifTool(arguments: [
            "-overwrite_original", "-EXIF:DateTimeOriginal=2020:01:02 03:04:05", dateCopy.path,
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(), .creationDate: Date()], ofItemAtPath: dateCopy.path)
        let dateResult = try await service.setFileDatesFromCaptureDate(fileURLs: [dateCopy])
        guard dateResult.updated == 1, dateResult.skipped.isEmpty else {
            fail("SELFTEST FAIL: file-date fix updated \(dateResult.updated), skipped \(dateResult.skipped)")
        }
        // Independent disk check: both dates must equal the capture date.
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let diskAttributes = try FileManager.default.attributesOfItem(atPath: dateCopy.path)
        for (label, key) in [("modified", FileAttributeKey.modificationDate), ("created", .creationDate)] {
            let onDisk = (diskAttributes[key] as? Date).map(dateFormatter.string(from:)) ?? "missing"
            guard onDisk == "2020:01:02 03:04:05" else {
                fail("SELFTEST FAIL: file \(label) date is \(onDisk), expected 2020:01:02 03:04:05")
            }
        }
        print("SELFTEST FILE DATES OK")
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
