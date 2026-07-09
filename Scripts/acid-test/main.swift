// Acid test for ExifToolService.setFileDatesFromCaptureDate.
// Compiles against the real service sources; exercises edge cases the
// selftest doesn't. Exit 0 = all pass.

import Foundation

nonisolated func sh(_ cmd: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    try? p.run()
    p.waitUntilExit()
}

nonisolated final class Acid {
    let service = ExifToolService()
    let exiftool: String
    let dir: URL
    let fm = FileManager.default
    var failures: [String] = []

    init() throws {
        exiftool = try ExifToolService.bundledExifToolURL().path
        dir = fm.temporaryDirectory.appendingPathComponent("metaedit-acid-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func makeJPEG(_ name: String, tags: [String]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try baseJPEGData.write(to: url)
        if !tags.isEmpty {
            sh("'\(exiftool)' -overwrite_original " + tags.map { "'\($0)'" }.joined(separator: " ") + " '\(url.path)'")
        }
        // Backdate both attributes to a sentinel so any change is detectable.
        try fm.setAttributes([.modificationDate: sentinel, .creationDate: sentinel], ofItemAtPath: url.path)
        return url
    }

    let sentinel = Date(timeIntervalSince1970: 1_000_000_000) // 2001-09-09

    func diskDates(_ url: URL) -> (mod: String, created: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let a = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        return (
            (a[.modificationDate] as? Date).map(f.string(from:)) ?? "missing",
            (a[.creationDate] as? Date).map(f.string(from:)) ?? "missing"
        )
    }

    func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String) {
        if condition {
            print("PASS  \(label)")
        } else {
            print("FAIL  \(label): \(detail())")
            failures.append(label)
        }
    }

    func run() async throws {
        // 1. DateTimeOriginal wins over CreateDate when both present.
        let both = try makeJPEG("both.jpg", tags: [
            "-EXIF:DateTimeOriginal=2020:06:15 12:00:00", "-EXIF:CreateDate=1999:01:01 00:00:00"])
        // 2. CreateDate-only fallback.
        let createOnly = try makeJPEG("create-only.jpg", tags: ["-EXIF:CreateDate=2018:03:03 08:30:00"])
        // 3. No capture date at all -> must be skipped, dates untouched.
        let noDate = try makeJPEG("no-date.jpg", tags: [])
        // 4. DST-transition timestamp (Europe: nonexistent local hour on some zones; still must round-trip).
        let dst = try makeJPEG("dst.jpg", tags: ["-EXIF:DateTimeOriginal=2025:03:30 02:30:00"])
        // 5. Unicode + spaces in filename.
        let unicode = try makeJPEG("björk photo ünïcode.jpg", tags: ["-EXIF:DateTimeOriginal=2021:11:07 01:30:00"])
        // 6. Read-only file -> exiftool cannot set dates; must be skipped, not counted updated.
        let readOnly = try makeJPEG("readonly.jpg", tags: ["-EXIF:DateTimeOriginal=2017:07:07 07:07:07"])
        try fm.setAttributes([.immutable: true], ofItemAtPath: readOnly.path)
        // 7. Nonexistent file in the batch.
        let ghost = dir.appendingPathComponent("ghost.jpg")

        let batch1 = [both, createOnly, noDate, dst, unicode, readOnly, ghost]
        let r1 = try await service.setFileDatesFromCaptureDate(fileURLs: batch1)
        print("batch1: updated=\(r1.updated) skipped=\(r1.skipped)")

        check("DateTimeOriginal wins", diskDates(both).mod == "2020:06:15 12:00:00" && diskDates(both).created == "2020:06:15 12:00:00", "\(diskDates(both))")
        check("CreateDate fallback", diskDates(createOnly).mod == "2018:03:03 08:30:00", "\(diskDates(createOnly))")
        check("no-capture skipped + untouched", r1.skipped.contains("no-date.jpg") && diskDates(noDate).mod == "2001:09:09 01:46:40".replacingOccurrences(of: "2001:09:09 01:46:40", with: diskDates(noDate).mod), "skipped=\(r1.skipped)")
        // stronger: sentinel must be unchanged
        let sentinelStr: String = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"; return f.string(from: sentinel)
        }()
        check("no-capture dates untouched", diskDates(noDate).mod == sentinelStr, "\(diskDates(noDate)) vs \(sentinelStr)")
        check("DST timestamp round-trips", diskDates(dst).mod == "2025:03:30 02:30:00", "\(diskDates(dst))")
        check("unicode filename", diskDates(unicode).mod == "2021:11:07 01:30:00", "\(diskDates(unicode))")
        check("read-only not counted updated", r1.skipped.contains("readonly.jpg") && diskDates(readOnly).mod == sentinelStr, "skipped=\(r1.skipped) dates=\(diskDates(readOnly))")
        check("ghost file skipped", r1.skipped.contains("ghost.jpg"), "skipped=\(r1.skipped)")
        check("updated count exact", r1.updated == 4, "updated=\(r1.updated), expected 4")

        try? fm.setAttributes([.immutable: false], ofItemAtPath: readOnly.path)

        // 8. Idempotence: second run must still verify (dates already correct).
        let r2 = try await service.setFileDatesFromCaptureDate(fileURLs: [both, createOnly, dst, unicode])
        check("idempotent rerun", r2.updated == 4 && r2.skipped.isEmpty, "updated=\(r2.updated) skipped=\(r2.skipped)")

        // 9. Chunking: 120 files crosses the 100-file chunk boundary.
        var many: [URL] = []
        for i in 0..<120 {
            many.append(try makeJPEG("bulk-\(i).jpg", tags: ["-EXIF:DateTimeOriginal=2015:04:0\(1 + i % 9) 10:00:00"]))
        }
        let r3 = try await service.setFileDatesFromCaptureDate(fileURLs: many)
        check("120-file chunked batch", r3.updated == 120 && r3.skipped.isEmpty, "updated=\(r3.updated) skipped=\(r3.skipped.count)")
        check("last chunked file correct", diskDates(many[119]).mod.hasPrefix("2015:04:"), "\(diskDates(many[119]))")

        try? fm.removeItem(at: dir)
        print(failures.isEmpty ? "\nACID TEST: ALL PASS" : "\nACID TEST: \(failures.count) FAILURE(S): \(failures)")
        exit(failures.isEmpty ? 0 : 1)
    }
}

// Minimal valid 1x1 JPEG, scaled up via sips at runtime not needed —
// exiftool only needs a valid JPEG container to write EXIF.
nonisolated let baseJPEGData = Data(base64Encoded:
    "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a" +
    "HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA" +
    "AAAAAAAAAAAACv/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q==")!

nonisolated func mainEntry() {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let acid = try Acid()
            try await acid.run()
        } catch {
            print("ACID TEST: threw \(error)")
            exit(2)
        }
        sem.signal()
    }
    sem.wait()
}
mainEntry()
