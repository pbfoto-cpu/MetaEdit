//
//  ExifToolService.swift
//  MetaEdit
//
//  All metadata I/O goes through the bundled ExifTool as an external
//  subprocess — the de facto standard for cross-app IPTC/XMP compatibility.
//  Every call runs off the main thread and forces UTF-8 charsets explicitly.
//

import Foundation

nonisolated final class ExifToolService: Sendable {

    // MARK: - Locating the bundled ExifTool

    /// The bundled perl script at Contents/Resources/exiftool/exiftool.
    /// Never falls back to a system install — the pinned version is part of
    /// the app's compatibility contract.
    static func bundledExifToolURL() throws -> URL {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw MetaEditError.exifToolNotFound
        }
        let url = resourceURL.appendingPathComponent("exiftool/exiftool")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetaEditError.exifToolNotFound
        }
        return url
    }

    // MARK: - Low-level subprocess call

    /// Runs the bundled ExifTool with the given arguments, always off the
    /// main thread, always with explicit UTF-8 charsets prepended.
    /// Returns captured stdout; throws `MetaEditError.exifToolFailed` on a
    /// nonzero exit.
    func runExifTool(arguments: [String]) async throws -> String {
        let exifToolURL = try Self.bundledExifToolURL()

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            // Invoke via the system perl rather than relying on the script's
            // shebang + executable bit surviving every copy step.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [exifToolURL.path,
                                 "-charset", "utf8",
                                 "-charset", "iptc=utf8",
                                 "-charset", "filename=utf8"]
                + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["LANG"] = "en_US.UTF-8"
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                throw MetaEditError.exifToolFailed(exitCode: -1, stderr: error.localizedDescription)
            }

            // Drain both pipes before waiting, or a large output fills the
            // pipe buffer and deadlocks the child.
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw MetaEditError.exifToolFailed(exitCode: process.terminationStatus,
                                                   stderr: stderr.isEmpty ? stdout : stderr)
            }
            return stdout
        }.value
    }

    /// Version of the bundled ExifTool, e.g. "13.58".
    func exifToolVersion() async throws -> String {
        try await runExifTool(arguments: ["-ver"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Argument sanitizing

    /// Values are passed as argv entries (no shell), so quotes can't break
    /// the command line — but NUL and stray control characters can corrupt
    /// argv or the written IPTC. Newlines and tabs are legitimate in
    /// captions and are kept.
    func sanitizeArgument(_ value: String) -> String {
        let allowed: Set<Unicode.Scalar> = ["\n", "\t"]
        let scalars = value.unicodeScalars.filter {
            allowed.contains($0) || !CharacterSet.controlCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    // MARK: - Sidecar convention

    /// IMG_1234.CR3 → IMG_1234.xmp, matching Lightroom/Photo Mechanic/
    /// Camera Raw convention (extension replaced, not appended).
    func sidecarURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    // MARK: - Reading

    /// Reads EXIF + IPTC/XMP from one file into a `MetadataRecord`.
    func readMetadata(fileURL: URL) async throws -> MetadataRecord {
        let output = try await runExifTool(arguments: [
            "-json", "-G0", "-struct", fileURL.path,
        ])
        guard
            let data = output.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let tags = array.first
        else {
            throw MetaEditError.malformedMetadata("ExifTool returned unparseable JSON for \(fileURL.lastPathComponent)")
        }
        return Self.record(fromTags: tags)
    }

    // MARK: - JSON → model mapping

    /// Builds a record from one file's `-json -G0` tag dictionary. Editable
    /// fields prefer XMP and fall back to IPTC IIM (MWG reading order).
    private static func record(fromTags tags: [String: Any]) -> MetadataRecord {
        func str(_ keys: String...) -> String? {
            for key in keys {
                if let value = stringValue(tags[key]) { return value }
            }
            return nil
        }

        var fields = MetadataFields()
        fields.headline = str("XMP:Headline", "IPTC:Headline")
        fields.caption = str("XMP:Description", "IPTC:Caption-Abstract")
        fields.keywords = stringArray(tags["XMP:Subject"] ?? tags["IPTC:Keywords"])
        fields.byline = str("XMP:Creator", "IPTC:By-line")
        fields.credit = str("XMP:Credit", "IPTC:Credit")
        fields.source = str("XMP:Source", "IPTC:Source")
        fields.copyrightNotice = str("XMP:Rights", "IPTC:CopyrightNotice")
        fields.copyrightStatus = str("XMP:Marked")
        fields.city = str("XMP:City", "IPTC:City")
        fields.state = str("XMP:State", "IPTC:Province-State")
        fields.country = str("XMP:Country", "IPTC:Country-PrimaryLocationName")
        fields.location = str("XMP:Location", "IPTC:Sub-location")
        fields.category = str("XMP:Category", "IPTC:Category")
        fields.specialInstructions = str("XMP:Instructions", "IPTC:SpecialInstructions")
        fields.dateCreated = str("XMP:DateCreated", "IPTC:DateCreated")

        var camera = CameraInfo()
        let make = str("EXIF:Make") ?? ""
        let model = str("EXIF:Model") ?? ""
        // Many makers repeat the make inside the model string.
        let cameraName = model.hasPrefix(make) ? model : [make, model]
            .filter { !$0.isEmpty }.joined(separator: " ")
        camera.camera = cameraName.isEmpty ? nil : cameraName
        camera.lens = str("EXIF:LensModel", "Composite:LensID", "XMP:Lens")
        if let shutter = str("EXIF:ExposureTime"), let fNumber = str("EXIF:FNumber") {
            camera.exposure = "\(shutter) s at f/\(fNumber)"
        } else {
            camera.exposure = str("EXIF:ExposureTime")
        }
        camera.focalLength = str("EXIF:FocalLength")
        camera.iso = str("EXIF:ISO")
        camera.captureDate = str("EXIF:DateTimeOriginal", "EXIF:CreateDate")
        camera.dimensions = str("Composite:ImageSize")

        return MetadataRecord(camera: camera, fields: fields)
    }

    /// ExifTool JSON values are strings, numbers, or arrays depending on the
    /// tag — normalize to a display string.
    private static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : s
        case let n as NSNumber:
            return n.stringValue
        case let a as [Any]:
            let parts = a.compactMap { stringValue($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default:
            return nil
        }
    }

    private static func stringArray(_ any: Any?) -> [String] {
        switch any {
        case let s as String:
            return s.isEmpty ? [] : [s]
        case let n as NSNumber:
            return [n.stringValue]
        case let a as [Any]:
            return a.compactMap { stringValue($0) }
        default:
            return []
        }
    }
}
