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
            } else if let record = appState.selectedRecord, let file = appState.selectedFile {
                MetadataEditorView(record: record, file: file)
                    .id(file.url)
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

struct MetadataEditorView: View {
    @Environment(AppState.self) private var appState
    let record: MetadataRecord
    let file: ImageFileRef
    @State private var draft: MetadataFields

    init(record: MetadataRecord, file: ImageFileRef) {
        self.record = record
        self.file = file
        _draft = State(initialValue: record.fields)
    }

    private var isDirty: Bool {
        !MetadataFields.delta(from: record.fields, to: draft).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Camera") {
                    cameraRow("Camera", record.camera.camera)
                    cameraRow("Lens", record.camera.lens)
                    cameraRow("Exposure", record.camera.exposure)
                    cameraRow("Focal Length", record.camera.focalLength)
                    cameraRow("ISO", record.camera.iso)
                    cameraRow("Captured", record.camera.captureDate)
                    cameraRow("Dimensions", record.camera.dimensions)
                }
                Section("IPTC") {
                    TextField("Headline", text: field(\.headline))
                    TextField("Caption", text: field(\.caption), axis: .vertical)
                        .lineLimit(2...6)
                    TextField("Keywords", text: keywordsBinding, prompt: Text("comma, separated"))
                    TextField("Byline / Creator", text: field(\.byline))
                    TextField("Credit", text: field(\.credit))
                    TextField("Source", text: field(\.source))
                    TextField("Copyright Notice", text: field(\.copyrightNotice))
                    Picker("Copyright Status", selection: copyrightStatusBinding) {
                        Text("Unknown").tag("")
                        Text("Copyrighted").tag("True")
                        Text("Public Domain").tag("False")
                    }
                    TextField("City", text: field(\.city))
                    TextField("State / Province", text: field(\.state))
                    TextField("Country", text: field(\.country))
                    TextField("Location", text: field(\.location))
                    TextField("Category", text: field(\.category))
                    TextField("Special Instructions", text: field(\.specialInstructions), axis: .vertical)
                        .lineLimit(1...4)
                    TextField("Date Created", text: field(\.dateCreated), prompt: Text("YYYY:MM:DD"))
                }
            }
            .formStyle(.grouped)
            .disabled(appState.isSaving)

            Divider()
            saveBar
        }
        .onChange(of: record.fields) { _, refreshed in
            // Selection changes and post-save re-reads both reset the draft.
            draft = refreshed
        }
    }

    private var saveBar: some View {
        HStack {
            Label(
                appState.writeMode(for: file.kind) == .sidecar
                    ? "Saves to .xmp sidecar"
                    : "Saves into file",
                systemImage: appState.writeMode(for: file.kind) == .sidecar
                    ? "doc.badge.plus" : "doc.badge.gearshape"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Where metadata is written for this file type. RAW files default to sidecars; change in Settings.")

            Spacer()

            if appState.isSaving {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Revert") { draft = record.fields }
                .disabled(!isDirty || appState.isSaving)
            Button("Save") { appState.save(draft: draft) }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty || appState.isSaving)
        }
        .padding(10)
    }

    @ViewBuilder
    private func cameraRow(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            Text(value ?? "\u{2014}")
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    private func field(_ keyPath: WritableKeyPath<MetadataFields, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private var keywordsBinding: Binding<String> {
        Binding(
            get: { (draft.keywords ?? []).joined(separator: ", ") },
            set: { text in
                let parsed = text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                draft.keywords = parsed.isEmpty ? nil : parsed
            }
        )
    }

    private var copyrightStatusBinding: Binding<String> {
        Binding(
            get: { draft.copyrightStatus ?? "" },
            set: { draft.copyrightStatus = $0.isEmpty ? nil : $0 }
        )
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
