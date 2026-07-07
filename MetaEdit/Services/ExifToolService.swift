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

    /// Reads EXIF + IPTC/XMP from one file into a `MetadataRecord`. For RAW
    /// files with an existing `.xmp` sidecar, the sidecar is authoritative
    /// for the editable fields (Lightroom/Camera Raw convention); camera
    /// EXIF still comes from the image itself.
    func readMetadata(fileURL: URL) async throws -> MetadataRecord {
        var record = try await readSingleFile(fileURL)
        if LibraryScanner.fileKind(for: fileURL) == .raw {
            let sidecar = sidecarURL(for: fileURL)
            if FileManager.default.fileExists(atPath: sidecar.path),
               let sidecarRecord = try? await readSingleFile(sidecar) {
                record.fields = sidecarRecord.fields
            }
        }
        return record
    }

    private func readSingleFile(_ fileURL: URL) async throws -> MetadataRecord {
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

    // MARK: - Writing

    /// Writes the non-nil fields of `fields` to the file (or its sidecar).
    /// Empty string / empty array clears the tag. Untouched tags are always
    /// preserved — ExifTool only rewrites what's named.
    ///
    /// Embedded JPEG/TIFF writes go to IPTC IIM and XMP together, kept in
    /// sync. Embedded RAW writes and sidecars are XMP-only (IIM inside
    /// proprietary RAW containers is not a convention other DAMs expect).
    func writeMetadata(fileURL: URL, fields: MetadataFields, mode: WriteMode) async throws {
        guard !fields.isEmpty else { return }
        switch mode {
        case .embedded:
            try preflightWrite(target: fileURL)
            let includeIPTC = LibraryScanner.fileKind(for: fileURL) != .raw
            let args = assignmentArguments(for: fields, includeIPTC: includeIPTC)
            try await runWrite(["-overwrite_original"] + args + [fileURL.path], target: fileURL)
        case .sidecar:
            let sidecar = sidecarURL(for: fileURL)
            try preflightWrite(target: sidecar)
            let args = assignmentArguments(for: fields, includeIPTC: false)
            if !FileManager.default.fileExists(atPath: sidecar.path) {
                // Seed a new sidecar from the image's existing metadata
                // first. (Can't be combined with the assignments below:
                // with -o, copied source metadata overrides assignments.)
                try await runWrite(["-o", sidecar.path, fileURL.path], target: sidecar)
            }
            try await runWrite(["-overwrite_original"] + args + [sidecar.path], target: sidecar)
        }
    }

    /// Re-reads after a write and confirms every written field stuck —
    /// catches silent ExifTool failures.
    func verifyWrite(fileURL: URL, expected: MetadataFields, mode: WriteMode) async throws -> Bool {
        let target = mode == .sidecar ? sidecarURL(for: fileURL) : fileURL
        let actual = try await readSingleFile(target).fields

        func norm(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        func matches(_ keyPath: KeyPath<MetadataFields, String?>) -> Bool {
            guard let expectedValue = expected[keyPath: keyPath] else { return true }
            return norm(expectedValue) == norm(actual[keyPath: keyPath])
        }
        let scalarFieldsMatch = matches(\.headline) && matches(\.caption)
            && matches(\.byline) && matches(\.credit) && matches(\.source)
            && matches(\.copyrightNotice) && matches(\.copyrightStatus)
            && matches(\.city) && matches(\.state) && matches(\.country)
            && matches(\.location) && matches(\.category)
            && matches(\.specialInstructions) && matches(\.dateCreated)

        if let expectedKeywords = expected.keywords {
            return scalarFieldsMatch && expectedKeywords == (actual.keywords ?? [])
        }
        return scalarFieldsMatch
    }

    /// Builds `-TAG=value` assignment arguments, IPTC IIM + XMP in sync.
    /// List tags (keywords) are cleared then re-added item by item.
    private func assignmentArguments(for fields: MetadataFields, includeIPTC: Bool) -> [String] {
        var args: [String] = []

        func assign(_ value: String?, iptc: String?, xmp: String) {
            guard let value else { return }
            let sanitized = sanitizeArgument(value)
            if includeIPTC, let iptc {
                args.append("-IPTC:\(iptc)=\(sanitized)")
            }
            args.append("-XMP-\(xmp)=\(sanitized)")
        }

        assign(fields.headline, iptc: "Headline", xmp: "photoshop:Headline")
        assign(fields.caption, iptc: "Caption-Abstract", xmp: "dc:Description")
        assign(fields.byline, iptc: "By-line", xmp: "dc:Creator")
        assign(fields.credit, iptc: "Credit", xmp: "photoshop:Credit")
        assign(fields.source, iptc: "Source", xmp: "photoshop:Source")
        assign(fields.copyrightNotice, iptc: "CopyrightNotice", xmp: "dc:Rights")
        assign(fields.copyrightStatus, iptc: nil, xmp: "xmpRights:Marked")
        assign(fields.city, iptc: "City", xmp: "photoshop:City")
        assign(fields.state, iptc: "Province-State", xmp: "photoshop:State")
        assign(fields.country, iptc: "Country-PrimaryLocationName", xmp: "photoshop:Country")
        assign(fields.location, iptc: "Sub-location", xmp: "iptcCore:Location")
        assign(fields.category, iptc: "Category", xmp: "photoshop:Category")
        assign(fields.specialInstructions, iptc: "SpecialInstructions", xmp: "photoshop:Instructions")
        assign(fields.dateCreated, iptc: "DateCreated", xmp: "photoshop:DateCreated")

        if let keywords = fields.keywords {
            // Replace-list pattern: a bare `=` clears, then repeated `=`
            // assignments accumulate the new items. (`+=` would add to the
            // file's existing list and skip the clear.)
            if includeIPTC { args.append("-IPTC:Keywords=") }
            args.append("-XMP-dc:Subject=")
            for keyword in keywords {
                let sanitized = sanitizeArgument(keyword)
                if includeIPTC { args.append("-IPTC:Keywords=\(sanitized)") }
                args.append("-XMP-dc:Subject=\(sanitized)")
            }
        }

        // Any IPTC IIM write must mark the block as UTF-8, or other apps
        // fall back to Latin-1 and mangle non-ASCII text.
        if args.contains(where: { $0.hasPrefix("-IPTC:") }) {
            args.insert("-IPTC:CodedCharacterSet=UTF8", at: 0)
        }
        return args
    }

    /// Checks the destination before invoking ExifTool so failures surface
    /// as specific, actionable errors instead of subprocess stderr.
    private func preflightWrite(target: URL) throws {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()

        guard fm.fileExists(atPath: directory.path) else {
            throw MetaEditError.volumeEjected(path: directory.path)
        }
        if let values = try? directory.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeNameKey]),
           values.volumeIsReadOnly == true {
            throw MetaEditError.volumeReadOnly(volume: values.volumeName ?? directory.path)
        }
        if fm.fileExists(atPath: target.path) {
            guard fm.isWritableFile(atPath: target.path) else {
                throw MetaEditError.permissionDenied(path: target.path)
            }
        } else {
            guard fm.isWritableFile(atPath: directory.path) else {
                throw MetaEditError.permissionDenied(path: directory.path)
            }
        }
    }

    /// Runs a write invocation and reclassifies ExifTool failures into
    /// specific errors where the stderr makes the cause clear.
    private func runWrite(_ arguments: [String], target: URL) async throws {
        do {
            _ = try await runExifTool(arguments: arguments)
        } catch let MetaEditError.exifToolFailed(exitCode, stderr) {
            let message = stderr.lowercased()
            if message.contains("read-only file system") {
                throw MetaEditError.volumeReadOnly(volume: target.deletingLastPathComponent().path)
            }
            if message.contains("permission denied") || message.contains("operation not permitted") {
                throw MetaEditError.permissionDenied(path: target.path)
            }
            if message.contains("no such file or directory"),
               !FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) {
                throw MetaEditError.volumeEjected(path: target.path)
            }
            throw MetaEditError.exifToolFailed(exitCode: exitCode, stderr: stderr)
        }
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
        let keywords = stringArray(tags["XMP:Subject"] ?? tags["IPTC:Keywords"])
        fields.keywords = keywords.isEmpty ? nil : keywords
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
            // ExifTool emits some tags (e.g. XMP:Marked) as JSON booleans;
            // map to the same strings its print conversion uses.
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
                return n.boolValue ? "True" : "False"
            }
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
