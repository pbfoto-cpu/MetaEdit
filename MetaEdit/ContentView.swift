//
//  ContentView.swift
//  MetaEdit
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            FileListPane()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            PreviewPane()
                .navigationSplitViewColumnWidth(min: 300, ideal: 520)
        } detail: {
            MetadataPane()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        }
        .frame(minWidth: 900, minHeight: 520)
        .toolbar {
            ToolbarItem {
                Button("Open Folder\u{2026}", systemImage: "folder") {
                    openFolderPanel()
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            appState.open(urls: urls)
            return true
        }
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            appState.openFolder(url)
        }
    }
}

// MARK: - Left pane: file browser

struct FileListPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.files.isEmpty {
                ContentUnavailableView {
                    Label("No Images", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Open a folder or drop images here to begin.")
                }
            } else {
                List(appState.files, selection: selectionBinding) { file in
                    FileRowView(file: file)
                        .contextMenu {
                            Button("Remove from List") {
                                appState.remove([file.id])
                            }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }
                        }
                }
                .onDeleteCommand {
                    if let selection = appState.selection {
                        appState.remove([selection])
                    }
                }
            }
        }
        .navigationTitle(appState.currentFolder?.lastPathComponent ?? "MetaEdit")
    }

    private var selectionBinding: Binding<ImageFileRef.ID?> {
        Binding(
            get: { appState.selection },
            set: { appState.select($0) }
        )
    }
}

struct FileRowView: View {
    let file: ImageFileRef
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: iconName(for: file.kind))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary.opacity(0.5))
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(file.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .task(id: file.url) {
            if thumbnail == nil {
                thumbnail = await ThumbnailCache.shared.thumbnail(for: file.url)
            }
        }
    }

    private func iconName(for kind: FileKind) -> String {
        switch kind {
        case .jpeg, .tiff: "photo"
        case .raw: "camera.aperture"
        case .unsupported: "questionmark.square.dashed"
        }
    }
}

// MARK: - Center pane: preview

struct PreviewPane: View {
    @Environment(AppState.self) private var appState
    @State private var previewImage: CGImage?
    @State private var previewURL: URL?

    var body: some View {
        Group {
            if let selected = appState.selectedFile {
                if let previewImage, previewURL == selected.url {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                } else {
                    ProgressView()
                }
            } else {
                ContentUnavailableView {
                    Label("No Selection", systemImage: "photo")
                } description: {
                    Text("Select an image to preview it.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.05))
        .task(id: appState.selectedFile?.url) {
            guard let url = appState.selectedFile?.url else {
                previewImage = nil
                previewURL = nil
                return
            }
            previewImage = try? await LibraryScanner.generateThumbnail(for: url, maxDimension: 2048)
            previewURL = url
        }
    }
}

// MARK: - Right pane: metadata panel

struct MetadataPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isLoadingMetadata {
                ProgressView("Reading metadata\u{2026}")
            } else if let message = appState.errorMessage {
                ContentUnavailableView {
                    Label("Couldn\u{2019}t Read Metadata", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            } else if let record = appState.selectedRecord {
                MetadataDetailView(record: record)
            } else {
                ContentUnavailableView {
                    Label("No Metadata", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Select an image to see its metadata.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MetadataDetailView: View {
    let record: MetadataRecord

    var body: some View {
        Form {
            Section("Camera") {
                row("Camera", record.camera.camera)
                row("Lens", record.camera.lens)
                row("Exposure", record.camera.exposure)
                row("Focal Length", record.camera.focalLength)
                row("ISO", record.camera.iso)
                row("Captured", record.camera.captureDate)
                row("Dimensions", record.camera.dimensions)
            }
            Section("IPTC") {
                row("Headline", record.fields.headline)
                row("Caption", record.fields.caption)
                row("Keywords", record.fields.keywords.isEmpty
                    ? nil : record.fields.keywords.joined(separator: ", "))
                row("Byline", record.fields.byline)
                row("Credit", record.fields.credit)
                row("Source", record.fields.source)
                row("Copyright", record.fields.copyrightNotice)
                row("City", record.fields.city)
                row("State", record.fields.state)
                row("Country", record.fields.country)
                row("Location", record.fields.location)
                row("Category", record.fields.category)
                row("Instructions", record.fields.specialInstructions)
                row("Date Created", record.fields.dateCreated)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            Text(value ?? "\u{2014}")
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
