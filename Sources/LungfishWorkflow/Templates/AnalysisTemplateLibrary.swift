// AnalysisTemplateLibrary.swift - App-wide store of workflow templates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Lists, saves and deletes templates in the app-wide library.
///
/// The library lives in the app identity's Application Support directory,
/// beside user recipes (`RecipeRegistryV2.userRecipesDirectoryURL`), in a
/// `Workflow Templates` folder. Scientists often start a new project for each
/// sequencing run, so templates are not stored per project.
public struct AnalysisTemplateLibrary: Sendable {

    public static let directoryName = "Workflow Templates"

    /// One file in the library. `template` is nil when the file could not be
    /// read; `loadError` says why (for example a newer schema version).
    public struct Entry: Sendable, Equatable, Identifiable {
        public let url: URL
        public let template: AnalysisTemplate?
        public let loadError: String?

        public var id: String { url.path }

        /// The template name, or the file name when the file could not be read.
        public var name: String {
            template?.name ?? url.deletingPathExtension().lastPathComponent
        }
    }

    public let directoryURL: URL
    private var fileManager: FileManager { .default }

    /// The library folder for an app identity.
    public static func defaultDirectoryURL(
        appIdentity: LungfishAppIdentity = .current,
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let appSupport = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return appSupport
            .appendingPathComponent(appIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    public init(directoryURL: URL = AnalysisTemplateLibrary.defaultDirectoryURL()) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    /// Every `.lungfishtemplate` file, sorted by name.
    public func list() -> [Entry] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents
            .filter { $0.pathExtension.lowercased() == AnalysisTemplate.fileExtension }
            .map { url in
                do {
                    return Entry(url: url.standardizedFileURL, template: try AnalysisTemplate.load(from: url), loadError: nil)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    return Entry(url: url.standardizedFileURL, template: nil, loadError: message)
                }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves a template under a file name derived from its name, never
    /// overwriting an existing file (a `-2`, `-3`, … suffix is appended).
    @discardableResult
    public func save(_ template: AnalysisTemplate) throws -> URL {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let base = Self.fileStem(for: template.name)
        for attempt in 0..<1_000 {
            let stem = attempt == 0 ? base : "\(base)-\(attempt + 1)"
            let url = directoryURL.appendingPathComponent("\(stem).\(AnalysisTemplate.fileExtension)")
            if fileManager.fileExists(atPath: url.path) { continue }
            try template.save(to: url)
            return url
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [
            NSFilePathErrorKey: directoryURL.appendingPathComponent(base).path,
            NSLocalizedDescriptionKey: "Could not find a free file name for template \(template.name)",
        ])
    }

    public func delete(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    /// Resolves a CLI reference: an existing file path, or a library entry
    /// by template name or file stem (case-insensitive).
    public func resolve(_ reference: String) -> URL? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let asPath = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
        if fileManager.fileExists(atPath: asPath.path) {
            return asPath
        }
        let entries = list()
        let lowered = trimmed.lowercased()
        if let byName = entries.first(where: { $0.name.lowercased() == lowered }) {
            return byName.url
        }
        if let byStem = entries.first(where: { $0.url.deletingPathExtension().lastPathComponent.lowercased() == lowered }) {
            return byStem.url
        }
        let stemWithExtension = lowered.hasSuffix(".\(AnalysisTemplate.fileExtension)")
            ? lowered
            : "\(lowered).\(AnalysisTemplate.fileExtension)"
        return entries.first(where: { $0.url.lastPathComponent.lowercased() == stemWithExtension })?.url
    }

    /// A file-system-safe stem for a template name.
    static func fileStem(for name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        var stem = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { forbidden.contains($0) ? "-" : Character($0) }
            .map(String.init)
            .joined()
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return stem.isEmpty ? "Workflow Template" : stem
    }
}
