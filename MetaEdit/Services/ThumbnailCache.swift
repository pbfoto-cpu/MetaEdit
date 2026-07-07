//
//  ThumbnailCache.swift
//  MetaEdit
//

import Foundation
import CoreGraphics

/// Small-thumbnail cache for the file list. Deduplicates concurrent requests
/// for the same file and evicts oldest entries so scrolling a folder with
/// thousands of images doesn't grow memory unbounded.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    /// 120 px maps 1:1 to a 60 pt row thumbnail on Retina.
    static let listThumbnailMaxDimension: CGFloat = 120

    private var cache: [URL: CGImage] = [:]
    private var insertionOrder: [URL] = []
    private var inFlight: [URL: Task<CGImage?, Never>] = [:]

    /// ~2048 thumbs at 120 px ≈ 118 MB worst case.
    private let capacity = 2048

    func thumbnail(for url: URL) async -> CGImage? {
        if let cached = cache[url] { return cached }

        if let running = inFlight[url] {
            return await running.value
        }

        let task = Task<CGImage?, Never> {
            try? await LibraryScanner.generateThumbnail(
                for: url,
                maxDimension: Self.listThumbnailMaxDimension
            )
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil

        if let image {
            cache[url] = image
            insertionOrder.append(url)
            if insertionOrder.count > capacity {
                let overflow = insertionOrder.count - capacity
                for evicted in insertionOrder.prefix(overflow) {
                    cache[evicted] = nil
                }
                insertionOrder.removeFirst(overflow)
            }
        }
        return image
    }
}
