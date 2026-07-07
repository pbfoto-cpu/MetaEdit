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
                                // Removing a row inside the selection removes
                                // the whole selection.
                                appState.remove(appState.selection.contains(file.id)
                                    ? appState.selection : [file.id])
                            }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }
                        }
                }
                .onDeleteCommand {
                    appState.remove(appState.selection)
                }
            }
        }
        .navigationTitle(appState.currentFolder?.lastPathComponent ?? "MetaEdit")
    }

    private var selectionBinding: Binding<Set<ImageFileRef.ID>> {
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
            } else if appState.selection.count > 1 {
                ContentUnavailableView {
                    Label("\(appState.selection.count) Images Selected", systemImage: "photo.stack")
                } description: {
                    Text("Batch edit their metadata in the panel on the right.")
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
            } else if let summary = appState.batchSummary, appState.selection.count > 1 {
                BatchEditorView(summary: summary)
                    .id(appState.selection)
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

/// Templates menu shared by the single-image and batch editors: apply a
/// saved boilerplate to the draft (never writes directly), save the current
/// draft as a new template, or delete one.
struct TemplateMenu: View {
    @Environment(AppState.self) private var appState
    @Binding var draft: MetadataFields
    /// Batch editor's keyword-mode toggle, driven by the applied template.
    var appendKeywords: Binding<Bool>?
    @State private var showingSaveSheet = false
    @State private var newTemplateName = ""
    @State private var newTemplateAppendsKeywords = true

    var body: some View {
        Menu("Templates") {
            let store = appState.templateStore
            if store.templates.isEmpty {
                Text("No templates yet")
            }
            ForEach(store.templates) { template in
                Button(template.name) {
                    draft = template.apply(to: draft)
                    if template.fields.keywords != nil {
                        appendKeywords?.wrappedValue = template.appendKeywords
                    }
                }
            }
            Divider()
            Button("Save Draft as Template\u{2026}") {
                newTemplateName = ""
                newTemplateAppendsKeywords = true
                showingSaveSheet = true
            }
            .disabled(draft.isEmpty)
            if !store.templates.isEmpty {
                Menu("Delete Template") {
                    ForEach(store.templates) { template in
                        Button(template.name, role: .destructive) {
                            store.delete(template)
                        }
                    }
                }
            }
        }
        .fixedSize()
        .sheet(isPresented: $showingSaveSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save Template")
                    .font(.headline)
                TextField("Template name", text: $newTemplateName)
                    .frame(width: 280)
                Toggle("Keywords add to each image\u{2019}s existing keywords", isOn: $newTemplateAppendsKeywords)
                    .font(.callout)
                Text("The template captures the fields currently filled in. Empty fields are left untouched when it\u{2019}s applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 280, alignment: .leading)
                HStack {
                    Spacer()
                    Button("Cancel") { showingSaveSheet = false }
                    Button("Save") {
                        appState.templateStore.save(MetadataTemplate(
                            name: newTemplateName.trimmingCharacters(in: .whitespaces),
                            fields: draft,
                            appendKeywords: newTemplateAppendsKeywords
                        ))
                        showingSaveSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newTemplateName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
    }
}

/// Batch editor for a multi-selection. Fields where every file agrees are
/// prefilled; fields that differ show a "multiple values" hint and are only
/// written if the user types into them. Keywords can replace or append.
struct BatchEditorView: View {
    @Environment(AppState.self) private var appState
    let summary: BatchFieldSummary
    @State private var draft: MetadataFields
    @State private var appendKeywords = true

    init(summary: BatchFieldSummary) {
        self.summary = summary
        var initial = summary.common
        // In append mode the keywords box is for *new* keywords only.
        initial.keywords = nil
        _draft = State(initialValue: initial)
    }

    private var pendingDelta: MetadataFields {
        var base = summary.common
        base.keywords = nil
        var delta = MetadataFields.delta(from: base, to: draft)
        if !appendKeywords, draft.keywords == nil, summary.conflicting.contains(.keywords) {
            // Replace mode with an untouched empty box on a conflicting
            // field means "leave keywords alone", not "clear them".
            delta.keywords = nil
        }
        return delta
    }

    private var isDirty: Bool { !pendingDelta.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Label("\(summary.count) images selected", systemImage: "photo.stack")
                        .font(.callout)
                    if !summary.conflicting.isEmpty {
                        Label("Fields marked \u{201C}multiple values\u{201D} differ across the selection and are only overwritten if you type into them.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("IPTC") {
                    batchRow("Headline", \.headline)
                    batchRow("Caption", \.caption, axis: .vertical)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Keywords")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $appendKeywords) {
                                Text("Add to existing").tag(true)
                                Text("Replace all").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.mini)
                            .fixedSize()
                            .labelsHidden()
                        }
                        TextField("Keywords", text: keywordsBinding,
                                  prompt: Text(keywordsPrompt))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                    }
                    batchRow("Byline / Creator", \.byline)
                    batchRow("Credit", \.credit)
                    batchRow("Source", \.source)
                    batchRow("Copyright Notice", \.copyrightNotice)
                    batchRow("Usage Rights", \.usageTerms, axis: .vertical)
                    batchRow("Creator Email", \.creatorEmail)
                    batchRow("Creator Website", \.creatorURL)
                    batchRow("City", \.city)
                    batchRow("State / Province", \.state)
                    batchRow("Country", \.country)
                    batchRow("Location", \.location)
                    batchRow("Category", \.category)
                    batchRow("Special Instructions", \.specialInstructions, axis: .vertical)
                    batchRow("Date Created", \.dateCreated)
                }
            }
            .formStyle(.grouped)
            .disabled(appState.isSaving)

            Divider()
            applyBar
        }
    }

    private var applyBar: some View {
        HStack {
            TemplateMenu(draft: $draft, appendKeywords: $appendKeywords)
            if appState.isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("Applying\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Apply to \(summary.count) Images") {
                var policy = FieldWritePolicy()
                policy.perField[.keywords] = appendKeywords ? .append : .overwrite
                appState.applyBatch(fields: pendingDelta, policy: policy)
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!isDirty || appState.isSaving)
        }
        .padding(10)
    }

    private var keywordsPrompt: String {
        if appendKeywords { return "keywords to add, comma separated" }
        return summary.conflicting.contains(.keywords) ? "multiple values" : "comma, separated"
    }

    @ViewBuilder
    private func batchRow(
        _ label: String,
        _ keyPath: WritableKeyPath<MetadataFields, String?>,
        axis: Axis = .horizontal
    ) -> some View {
        let field = MetadataFields.scalarFieldKeyPaths.first { $0.1 == keyPath }?.0
        let conflicting = field.map(summary.conflicting.contains) ?? false
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, text: binding(keyPath),
                      prompt: conflicting ? Text("multiple values") : nil, axis: axis)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<MetadataFields, String?>) -> Binding<String> {
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
                    editRow("Headline") {
                        TextField("Headline", text: field(\.headline))
                    }
                    editRow("Caption") {
                        TextField("Caption", text: field(\.caption), axis: .vertical)
                            .lineLimit(2...6)
                    }
                    editRow("Keywords") {
                        TextField("Keywords", text: keywordsBinding, prompt: Text("comma, separated"))
                    }
                    editRow("Byline / Creator") {
                        TextField("Byline / Creator", text: field(\.byline))
                    }
                    editRow("Credit") {
                        TextField("Credit", text: field(\.credit))
                    }
                    editRow("Source") {
                        TextField("Source", text: field(\.source))
                    }
                    editRow("Copyright Notice") {
                        TextField("Copyright Notice", text: field(\.copyrightNotice))
                    }
                    Picker("Copyright Status", selection: copyrightStatusBinding) {
                        Text("Unknown").tag("")
                        Text("Copyrighted").tag("True")
                        Text("Public Domain").tag("False")
                    }
                    editRow("Usage Rights") {
                        TextField("Usage Rights", text: field(\.usageTerms), axis: .vertical)
                            .lineLimit(1...4)
                    }
                    editRow("Creator Email") {
                        TextField("Creator Email", text: field(\.creatorEmail))
                    }
                    editRow("Creator Website") {
                        TextField("Creator Website", text: field(\.creatorURL))
                    }
                    editRow("City") {
                        TextField("City", text: field(\.city))
                    }
                    editRow("State / Province") {
                        TextField("State / Province", text: field(\.state))
                    }
                    editRow("Country") {
                        TextField("Country", text: field(\.country))
                    }
                    editRow("Location") {
                        TextField("Location", text: field(\.location))
                    }
                    editRow("Category") {
                        TextField("Category", text: field(\.category))
                    }
                    editRow("Special Instructions") {
                        TextField("Special Instructions", text: field(\.specialInstructions), axis: .vertical)
                            .lineLimit(1...4)
                    }
                    editRow("Date Created") {
                        TextField("Date Created", text: field(\.dateCreated), prompt: Text("YYYY:MM:DD"))
                    }
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
            TemplateMenu(draft: $draft)
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

    /// Label above a full-width field, so the cursor starts at the left
    /// edge instead of the grouped form's trailing-aligned value slot.
    @ViewBuilder
    private func editRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
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
