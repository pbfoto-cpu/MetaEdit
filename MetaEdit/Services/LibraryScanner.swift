//
//  LibraryScanner.swift
//  MetaEdit
//

import Foundation
import ImageIO

nonisolated enum LibraryScanner {

    private static let jpegExtensions: Set<String> = ["jpg", "jpeg"]
    private static let tiffExtensions: Set<String> = ["tif", "tiff"]
    private static let rawExtensions: Set<String> = ["cr2", "cr3", "nef", "arw", "dng"]

    static func fileKind(for url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if jpegExtensions.contains(ext) { return .jpeg }
        if tiffExtensions.contains(ext) { return .tiff }
        if rawExtensions.contains(ext) { return .raw }
        return .unsupported
    }

    /// Streams supported image files out of a folder lazily so huge folders
    /// never block the UI waiting for a full listing.
    static func scanFolder(_ url: URL, recursive: Bool) -> AsyncStream<ImageFileRef> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                defer { continuation.finish() }
                let options: FileManager.DirectoryEnumerationOptions = recursive
                    ? [.skipsHiddenFiles, .skipsPackageDescendants]
                    : [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: options
                ) else { return }

                while let fileURL = enumerator.nextObject() as? URL {
                    if Task.isCancelled { return }
                    guard fileKind(for: fileURL) != .unsupported,
                          (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    else { continue }
                    continuation.yield(ImageFileRef(url: fileURL))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Downsampled preview via ImageIO. For RAW this pulls the embedded
    /// preview (`kCGImageSourceCreateThumbnailFromImageAlways` on the source)
    /// rather than doing a full RAW decode.
    static func generateThumbnail(for fileURL: URL, maxDimension: CGFloat) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
                throw MetaEditError.malformedMetadata("Could not open \(fileURL.lastPathComponent) as an image")
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw MetaEditError.malformedMetadata("No decodable preview in \(fileURL.lastPathComponent)")
            }
            return image
        }.value
    }
}
