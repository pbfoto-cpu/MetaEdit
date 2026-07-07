//
//  MetadataModels.swift
//  MetaEdit
//

import Foundation

/// How metadata gets written for a given file.
nonisolated enum WriteMode: Sendable {
    /// Write IPTC IIM + XMP directly into the image file (JPEG/TIFF default).
    case embedded
    /// Write XMP to an adjacent .xmp sidecar (RAW default, matches
    /// Lightroom/Photo Mechanic/Camera Raw convention).
    case sidecar
}

/// Per-field policy for batch writes.
nonisolated enum FieldPolicy: Sendable {
    case skip
    case overwrite
    /// Only meaningful for list fields (keywords).
    case append
}

/// Maps each editable field to its batch-write policy.
nonisolated struct FieldWritePolicy: Sendable {
    var defaultPolicy: FieldPolicy = .overwrite
    var perField: [MetadataFields.Field: FieldPolicy] = [:]

    func policy(for field: MetadataFields.Field) -> FieldPolicy {
        perField[field] ?? defaultPolicy
    }
}

/// The editable IPTC Core/Extension subset. All writes go out as IPTC IIM +
/// XMP dual-write so Lightroom, Photo Mechanic, Bridge, and Capture One read
/// them identically.
nonisolated struct MetadataFields: Equatable, Sendable, Codable {
    enum Field: String, CaseIterable, Sendable, Codable {
        case headline, caption, keywords, byline, credit, source
        case copyrightNotice, copyrightStatus
        case city, state, country, location
        case category, specialInstructions, dateCreated
    }

    var headline: String?
    var caption: String?
    var keywords: [String] = []
    var byline: String?
    var credit: String?
    var source: String?
    var copyrightNotice: String?
    var copyrightStatus: String?
    var city: String?
    var state: String?
    var country: String?
    var location: String?
    var category: String?
    var specialInstructions: String?
    var dateCreated: String?
}

/// Read-only camera EXIF shown in the panel alongside the editable fields.
nonisolated struct CameraInfo: Equatable, Sendable {
    var camera: String?
    var lens: String?
    var exposure: String?
    var focalLength: String?
    var iso: String?
    var captureDate: String?
    var dimensions: String?
}

/// Everything read from one file: read-only EXIF plus the editable subset.
nonisolated struct MetadataRecord: Equatable, Sendable {
    var camera: CameraInfo
    var fields: MetadataFields
    /// Version of the exiftool that produced this record, for diagnostics.
    var exifToolVersion: String?
}

nonisolated enum FileKind: Sendable {
    case jpeg
    case tiff
    case raw
    case unsupported
}

/// A lightweight reference to an image file in the browser list.
nonisolated struct ImageFileRef: Identifiable, Hashable, Sendable {
    var url: URL
    var kind: FileKind {
        LibraryScanner.fileKind(for: url)
    }

    var id: URL { url }
    var fileName: String { url.lastPathComponent }
}
