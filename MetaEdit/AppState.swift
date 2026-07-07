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
    let templateStore = TemplateStore.shared

    static let rawEmbeddedWritesKey = "rawEmbeddedWrites"

    var files: [ImageFileRef] = []
    var selection: Set<ImageFileRef.ID> = []
    var selectedRecord: MetadataRecord?
    var batchSummary: BatchFieldSummary?
    var isLoadingMetadata = false
    var isSaving = false
    var currentFolder: URL?
    var errorMessage: String?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// The single selected file, when exactly one is selected.
    var selectedFile: ImageFileRef? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return files.first { $0.id == id }
    }

    /// Selected files in list order.
    var selectedFiles: [ImageFileRef] {
        files.filter { selection.contains($0.id) }
    }

    func openFolder(_ url: URL) {
        scanTask?.cancel()
        currentFolder = url
        files = []
        selection = []
        selectedRecord = nil
        batchSummary = nil
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
        if selection.isEmpty, let first = added.first {
            select([first.id])
        }
    }

    /// Where a save for this file kind will land, honoring the RAW
    /// embedded-writes setting. The UI surfaces this before every save.
    func writeMode(for kind: FileKind) -> WriteMode {
        guard kind == .raw else { return .embedded }
        return UserDefaults.standard.bool(forKey: Self.rawEmbeddedWritesKey) ? .embedded : .sidecar
    }

    /// Commits the edited fields for the selected file: writes only the
    /// changed fields, verifies the write by re-reading, then refreshes the
    /// panel from disk.
    func save(draft: MetadataFields) {
        guard let file = selectedFile, let original = selectedRecord?.fields else { return }
        let delta = MetadataFields.delta(from: original, to: draft)
        guard !delta.isEmpty, !isSaving else { return }

        isSaving = true
        errorMessage = nil
        Task {
            do {
                let mode = writeMode(for: file.kind)
                try await exifTool.writeMetadata(fileURL: file.url, fields: delta, mode: mode)
                guard try await exifTool.verifyWrite(fileURL: file.url, expected: delta, mode: mode) else {
                    throw MetaEditError.writeVerificationFailed(path: file.fileName)
                }
                let refreshed = try await exifTool.readMetadata(fileURL: file.url)
                if selection == [file.id] {
                    selectedRecord = refreshed
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    /// Applies a batch change set to every selected file, honoring the
    /// keyword policy, then refreshes the conflict summary from disk.
    func applyBatch(fields: MetadataFields, policy: FieldWritePolicy) {
        let targets = selectedFiles
        guard !fields.isEmpty, targets.count > 1, !isSaving else { return }

        isSaving = true
        errorMessage = nil
        let rawEmbedded = UserDefaults.standard.bool(forKey: Self.rawEmbeddedWritesKey)
        Task {
            do {
                let result = try await exifTool.writeMetadataBatch(
                    fileURLs: targets.map(\.url),
                    fields: fields,
                    policy: policy,
                    modeFor: { url in
                        guard LibraryScanner.fileKind(for: url) == .raw else { return .embedded }
                        return rawEmbedded ? .embedded : .sidecar
                    }
                )
                if !result.failures.isEmpty {
                    let details = result.failures.prefix(5)
                        .map { "\($0.url.lastPathComponent): \($0.message)" }
                        .joined(separator: "\n")
                    let more = result.failures.count > 5 ? "\n…and \(result.failures.count - 5) more" : ""
                    errorMessage = "\(result.written.count) of \(targets.count) images updated. Failed:\n\(details)\(more)"
                }
                if selection == Set(targets.map(\.id)) {
                    batchSummary = try await exifTool.diffFields(across: targets.map(\.url))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    /// Removes entries from the list only — never touches files on disk.
    func remove(_ ids: Set<ImageFileRef.ID>) {
        files.removeAll { ids.contains($0.id) }
        if !selection.isDisjoint(with: ids) {
            select(selection.subtracting(ids))
        }
    }

    func select(_ ids: Set<ImageFileRef.ID>) {
        selection = ids
        loadTask?.cancel()
        selectedRecord = nil
        batchSummary = nil
        errorMessage = nil

        if ids.count == 1, let id = ids.first {
            isLoadingMetadata = true
            loadTask = Task {
                do {
                    let record = try await exifTool.readMetadata(fileURL: id)
                    guard !Task.isCancelled, selection == ids else { return }
                    selectedRecord = record
                    isLoadingMetadata = false
                } catch is CancellationError {
                    // superseded by a newer selection
                } catch {
                    guard !Task.isCancelled, selection == ids else { return }
                    errorMessage = error.localizedDescription
                    isLoadingMetadata = false
                }
            }
        } else if ids.count > 1 {
            let urls = selectedFiles.map(\.url)
            isLoadingMetadata = true
            loadTask = Task {
                do {
                    let summary = try await exifTool.diffFields(across: urls)
                    guard !Task.isCancelled, selection == ids else { return }
                    batchSummary = summary
                    isLoadingMetadata = false
                } catch is CancellationError {
                    // superseded by a newer selection
                } catch {
                    guard !Task.isCancelled, selection == ids else { return }
                    errorMessage = error.localizedDescription
                    isLoadingMetadata = false
                }
            }
        }
    }
}
