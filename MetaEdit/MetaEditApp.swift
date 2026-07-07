//
//  MetaEditApp.swift
//  MetaEdit
//

import SwiftUI

@main
struct MetaEditApp: App {
    init() {
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            WindowRoot()
        }
        Settings {
            SettingsView()
        }
    }

    /// Each window (or tab — ⌘N / the window tab bar) gets its own state:
    /// independent folder, selection, and editor, so separate projects can
    /// be browsed side by side. Templates and the thumbnail cache stay
    /// shared app-wide.
    struct WindowRoot: View {
        @State private var appState = AppState()

        var body: some View {
            ContentView()
                .environment(appState)
        }
    }

    struct SettingsView: View {
        @AppStorage(AppState.rawEmbeddedWritesKey) private var rawEmbeddedWrites = false

        var body: some View {
            Form {
                Toggle("Write metadata into RAW files", isOn: $rawEmbeddedWrites)
                Text(rawEmbeddedWrites
                    ? "Edits are embedded directly inside CR2/CR3/NEF/ARW/DNG files. Most workflows expect sidecars instead — only use this if you know your other tools read embedded XMP."
                    : "Edits to RAW files are written to an adjacent .xmp sidecar, matching Lightroom, Photo Mechanic, and Camera Raw. The RAW file itself is never modified. (Recommended)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(width: 440)
        }
    }

}
