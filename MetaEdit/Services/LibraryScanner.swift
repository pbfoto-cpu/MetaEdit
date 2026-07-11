//
//  LibraryScanner.swift
//  MetaEdit
//

import Foundation
import ImageIO

nonisolated enum LibraryScanner {

    private static let jpegExtensions: Set<String> = ["jpg", "jpeg"]
    private static let tiffExtensions: Set<String> = ["tif", "tiff"]
    private static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw",        // Canon
        "nef", "nrw",               // Nikon
        "arw", "sr2", "srf",        // Sony
        "dng",                      // Adobe/universal (Leica, Pentax, phones)
        "raf",                      // Fujifilm
        "orf",                      // Olympus / OM System
        "rw2",                      // Panasonic
        "pef",                      // Pentax
        "rwl",                      // Leica
        "srw",                      // Samsung
        "iiq",                      // Phase One
        "3fr", "fff",               // Hasselblad
        "x3f",                      // Sigma
        "mef",                      // Mamiya
        "dcr",                      // Kodak
        "erf",                      // Epson
        "gpr",                      // GoPro
    ]

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

    /// Downsampled preview via ImageIO, embedded-preview first: `IfAbsent`
    /// returns the file's embedded thumbnail/preview when there is one and
    /// only falls back to decoding the image when there isn't. (`Always`
    /// forces a full decode — for RAW that's seconds per frame through
    /// RawCamera and it starves the thread pool on big folders.)
    static func generateThumbnail(for fileURL: URL, maxDimension: CGFloat) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
                throw MetaEditError.malformedMetadata("Could not open \(fileURL.lastPathComponent) as an image")
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
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
