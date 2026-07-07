//
//  MetaEditApp.swift
//  MetaEdit
//

import SwiftUI

@main
struct MetaEditApp: App {
    @State private var appState = AppState()

    init() {
        Self.runSelfTestIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
    }

    /// `MetaEdit.app/Contents/MacOS/MetaEdit --selftest <file>` exercises the
    /// bundled-ExifTool-from-Task.detached path end to end from the command
    /// line: prints the parsed record and exits 0, or the error and exits 1.
    private static func runSelfTestIfRequested() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--selftest") else { return }
        guard arguments.count > flagIndex + 1 else {
            FileHandle.standardError.write(Data("usage: MetaEdit --selftest <image-file>\n".utf8))
            exit(64)
        }
        let fileURL = URL(fileURLWithPath: arguments[flagIndex + 1])
        let service = ExifToolService()

        Task.detached {
            do {
                let version = try await service.exifToolVersion()
                let record = try await service.readMetadata(fileURL: fileURL)
                let thumbnail = await ThumbnailCache.shared.thumbnail(for: fileURL)
                print("SELFTEST OK exiftool=\(version)")
                print("camera: \(record.camera)")
                print("fields: \(record.fields)")
                if let thumbnail {
                    print("thumbnail: \(thumbnail.width)x\(thumbnail.height)")
                } else {
                    FileHandle.standardError.write(Data("SELFTEST FAIL: no thumbnail generated\n".utf8))
                    exit(1)
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("SELFTEST FAIL: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        // Park the main thread; the detached task terminates the process.
        while true { RunLoop.main.run(until: .distantFuture) }
    }
}
