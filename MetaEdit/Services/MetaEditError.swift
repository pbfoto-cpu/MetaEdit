//
//  MetaEditError.swift
//  MetaEdit
//

import Foundation

/// Every failure mode maps to a specific, actionable user-facing message —
/// never a generic "operation failed".
nonisolated enum MetaEditError: LocalizedError, Sendable {
    case exifToolNotFound
    case volumeReadOnly(volume: String)
    case volumeEjected(path: String)
    case permissionDenied(path: String)
    case malformedMetadata(String)
    case writeVerificationFailed(path: String)
    case exifToolFailed(exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .exifToolNotFound:
            return "The bundled ExifTool could not be found inside the app. Reinstalling MetaEdit should fix this."
        case .volumeReadOnly(let volume):
            return "The volume \u{201C}\(volume)\u{201D} is read-only, so metadata can\u{2019}t be written there. Copy the files to a writable location or remount the volume with write access."
        case .volumeEjected(let path):
            return "The volume containing \u{201C}\(path)\u{201D} was ejected or disconnected mid-operation. Reconnect it and try again."
        case .permissionDenied(let path):
            return "MetaEdit doesn\u{2019}t have permission to write to \u{201C}\(path)\u{201D}. Check the file\u{2019}s permissions in Finder (Get Info \u{2192} Sharing & Permissions)."
        case .malformedMetadata(let detail):
            return "The file\u{2019}s existing metadata couldn\u{2019}t be parsed: \(detail)"
        case .writeVerificationFailed(let path):
            return "Metadata was written to \u{201C}\(path)\u{201D} but re-reading it did not return the expected values. The file has not been corrupted, but the save may not have taken effect."
        case .exifToolFailed(let exitCode, let stderr):
            return "ExifTool exited with code \(exitCode): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
