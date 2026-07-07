//
//  AppState.swift
//  MetaEdit
//
//  @Observable only — ObservableObject/@Published is banned in this project
//  (AttributeGraph TypeDescriptorCache deadlock on this stack).
//

import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    let exifTool = ExifToolService()

    var files: [ImageFileRef] = []
    var selection: ImageFileRef.ID?
    var selectedRecord: MetadataRecord?
    var isLoadingMetadata = false
    var currentFolder: URL?
    var errorMessage: String?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var selectedFile: ImageFileRef? {
        guard let selection else { return nil }
        return files.first { $0.id == selection }
    }

    func openFolder(_ url: URL) {
        scanTask?.cancel()
        currentFolder = url
        files = []
        selection = nil
        selectedRecord = nil
        errorMessage = nil

        scanTask = Task {
            var batch: [ImageFileRef] = []
            for await ref in LibraryScanner.scanFolder(url, recursive: false) {
                batch.append(ref)
                // Flush in chunks so thousands of files don't mean thousands
                // of view updates.
                if batch.count >= 64 {
                    files.append(contentsOf: batch)
                    batch = []
                }
            }
            files.append(contentsOf: batch)
        }
    }

    func open(urls: [URL]) {
        // A dropped folder replaces the list (new browsing root); dropped
        // loose files are added to whatever is already showing.
        if urls.count == 1,
           (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            openFolder(urls[0])
            return
        }
        errorMessage = nil
        let existing = Set(files.map(\.id))
        let added = urls
            .filter { LibraryScanner.fileKind(for: $0) != .unsupported }
            .map { ImageFileRef(url: $0) }
            .filter { !existing.contains($0.id) }
        files.append(contentsOf: added)
        if selection == nil {
            selection = added.first?.id
        }
    }

    /// Removes entries from the list only — never touches files on disk.
    func remove(_ ids: Set<ImageFileRef.ID>) {
        files.removeAll { ids.contains($0.id) }
        if let selection, ids.contains(selection) {
            select(nil)
        }
    }

    func select(_ id: ImageFileRef.ID?) {
        selection = id
        loadTask?.cancel()
        selectedRecord = nil
        errorMessage = nil
        guard let id else { return }

        isLoadingMetadata = true
        loadTask = Task {
            do {
                let record = try await exifTool.readMetadata(fileURL: id)
                guard !Task.isCancelled, selection == id else { return }
                selectedRecord = record
                isLoadingMetadata = false
            } catch is CancellationError {
                // superseded by a newer selection
            } catch {
                guard !Task.isCancelled, selection == id else { return }
                errorMessage = error.localizedDescription
                isLoadingMetadata = false
            }
        }
    }
}
