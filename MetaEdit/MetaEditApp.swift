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
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MetaEdit") { Self.showAboutPanel() }
            }
        }
        Settings {
            SettingsView()
        }
    }

    /// The standard About panel, with the family byline. The credits line
    /// is the one place the FotoArch connection appears inside the app.
    private static func showAboutPanel() {
        let credits = NSMutableAttributedString(
            string: "by FotoArch — fast, standards-correct photo metadata.\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        let link = NSAttributedString(
            string: "fotoarch.app",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .link: URL(string: "https://fotoarch.app")!,
            ])
        credits.append(link)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
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
                .background(PreferTabbing())
        }
    }

    /// Marks the hosting window as tab-preferring, so ⌘N opens new sessions
    /// as tabs in the same window by default (drag a tab out to split it
    /// into its own window).
    struct PreferTabbing: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async {
                view.window?.tabbingMode = .preferred
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
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
