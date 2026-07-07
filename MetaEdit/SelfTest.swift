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
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
