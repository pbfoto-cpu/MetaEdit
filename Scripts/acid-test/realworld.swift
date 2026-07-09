// Real-world run of setFileDatesFromCaptureDate against a copied archive.
// Usage: realworld <folder>. Verifies: (1) every file's content bytes are
// unchanged (only filesystem dates may move), (2) updated+skipped == inputs,
// (3) each updated file's disk dates equal its capture date.

import Foundation
import CryptoKit

nonisolated func hashFile(_ url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "unreadable" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

nonisolated func mainEntry() {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1])
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let fm = FileManager.default
        let all = (fm.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }) ?? []
        let imageExts: Set<String> = ["cr2", "jpg", "jpeg"]
        let images = all.filter { imageExts.contains($0.pathExtension.lowercased()) }
        let bystanders = all.filter { !imageExts.contains($0.pathExtension.lowercased()) }
        print("files=\(all.count) images=\(images.count) bystanders=\(bystanders.count)")

        var before: [String: String] = [:]
        for url in all { before[url.path] = hashFile(url) }

        let service = ExifToolService()
        let start = Date()
        do {
            let result = try await service.setFileDatesFromCaptureDate(fileURLs: images)
            print(String(format: "RESULT updated=%d skipped=%d in %.1fs",
                         result.updated, result.skipped.count, Date().timeIntervalSince(start)))
            if !result.skipped.isEmpty { print("skipped: \(result.skipped)") }
            if result.updated + result.skipped.count != images.count {
                print("FAIL: counts don't add up (\(result.updated)+\(result.skipped.count) != \(images.count))")
                exit(1)
            }
        } catch {
            print("FAIL: threw \(error)"); exit(1)
        }

        var corrupted: [String] = []
        for url in all where before[url.path] != hashFile(url) {
            corrupted.append(url.lastPathComponent)
        }
        if corrupted.isEmpty {
            print("BYTES OK: all \(all.count) files (incl. \(bystanders.count) sidecars/bystanders) byte-identical")
        } else {
            print("FAIL: content changed in \(corrupted)"); exit(1)
        }

        // Cross-check disk dates against exiftool's view of capture dates.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var mismatches = 0, checked = 0
        for url in images {
            guard let record = try? await service.readMetadata(fileURL: url),
                  let capture = record.camera.captureDate else { continue }
            let a = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            guard let mod = a[.modificationDate] as? Date else { continue }
            checked += 1
            if f.string(from: mod) != String(capture.prefix(19)) {
                mismatches += 1
                print("MISMATCH \(url.lastPathComponent): disk=\(f.string(from: mod)) capture=\(capture)")
            }
        }
        print("CROSS-CHECK: \(checked) files with capture dates, \(mismatches) mismatches")
        exit(mismatches == 0 ? 0 : 1)
    }
    sem.wait()
}
mainEntry()
