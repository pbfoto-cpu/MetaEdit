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
///
/// Doubles as a *partial* change set for writes: `nil` means "leave this
/// field unchanged"; an empty string / empty array means "clear the tag".
nonisolated struct MetadataFields: Equatable, Sendable, Codable {
    enum Field: String, CaseIterable, Sendable, Codable {
        case headline, caption, keywords, byline, credit, source
        case copyrightNotice, copyrightStatus
        case city, state, country, location
        case category, specialInstructions, dateCreated
    }

    var headline: String?
    var caption: String?
    var keywords: [String]?
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

    /// True when no field carries a change (all nil).
    var isEmpty: Bool {
        headline == nil && caption == nil && keywords == nil && byline == nil
            && credit == nil && source == nil && copyrightNotice == nil
            && copyrightStatus == nil && city == nil && state == nil
            && country == nil && location == nil && category == nil
            && specialInstructions == nil && dateCreated == nil
    }

    /// A change set containing only the fields where `draft` differs from
    /// `original`. Cleared fields come through as "" / [] so the write layer
    /// deletes the tags.
    static func delta(from original: MetadataFields, to draft: MetadataFields) -> MetadataFields {
        var d = MetadataFields()
        func norm(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        func diff(_ keyPath: WritableKeyPath<MetadataFields, String?>) {
            if norm(original[keyPath: keyPath]) != norm(draft[keyPath: keyPath]) {
                d[keyPath: keyPath] = norm(draft[keyPath: keyPath]) ?? ""
            }
        }
        diff(\.headline); diff(\.caption); diff(\.byline); diff(\.credit)
        diff(\.source); diff(\.copyrightNotice); diff(\.copyrightStatus)
        diff(\.city); diff(\.state); diff(\.country); diff(\.location)
        diff(\.category); diff(\.specialInstructions); diff(\.dateCreated)

        let originalKeywords = original.keywords ?? []
        let draftKeywords = (draft.keywords ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if originalKeywords != draftKeywords {
            d.keywords = draftKeywords
        }
        return d
    }
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
