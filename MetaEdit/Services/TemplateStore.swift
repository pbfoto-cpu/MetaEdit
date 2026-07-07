//
//  TemplateStore.swift
//  MetaEdit
//

import Foundation
import Observation

/// A named metadata boilerplate — e.g. a solo creator's standard copyright,
/// byline, usage rights, and contact block, applied unchanged across
/// thousands of archive images. Uses the change-set convention: nil fields
/// are left alone when the template is applied.
nonisolated struct MetadataTemplate: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var fields: MetadataFields
    /// How the template's keywords combine with an image's existing ones.
    var appendKeywords = true

    /// Overlays the template onto existing fields. Non-nil template values
    /// win; keywords merge or replace per `appendKeywords`.
    func apply(to existing: MetadataFields) -> MetadataFields {
        var result = existing
        for (_, keyPath) in MetadataFields.scalarFieldKeyPaths {
            if let value = fields[keyPath: keyPath] {
                result[keyPath: keyPath] = value
            }
        }
        if let templateKeywords = fields.keywords {
            if appendKeywords {
                var merged = existing.keywords ?? []
                merged.append(contentsOf: templateKeywords.filter { !merged.contains($0) })
                result.keywords = merged
            } else {
                result.keywords = templateKeywords
            }
        }
        return result
    }
}

/// Loads and saves templates as individual JSON files in
/// ~/Library/Application Support/MetaEdit/Templates/ — human-readable and
/// trivially shareable between machines or colleagues.
@Observable
@MainActor
final class TemplateStore {
    private(set) var templates: [MetadataTemplate] = []
    var lastError: String?

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetaEdit/Templates", isDirectory: true)
    }

    init() {
        load()
    }

    func load() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil))
            ?? []
        templates = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(MetadataTemplate.self, from: data)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves (or updates, matched by id) a template and reloads.
    func save(_ template: MetadataTemplate) {
        lastError = nil
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(template)
            try data.write(to: fileURL(for: template), options: .atomic)
            load()
        } catch {
            lastError = "Couldn\u{2019}t save template: \(error.localizedDescription)"
        }
    }

    func delete(_ template: MetadataTemplate) {
        lastError = nil
        do {
            try FileManager.default.removeItem(at: fileURL(for: template))
            load()
        } catch {
            lastError = "Couldn\u{2019}t delete template: \(error.localizedDescription)"
        }
    }

    private func fileURL(for template: MetadataTemplate) -> URL {
        Self.directory.appendingPathComponent("\(template.id.uuidString).json")
    }
}
