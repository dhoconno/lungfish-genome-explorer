// SidebarImportPlanner.swift - Normalizes dropped sidebar imports into bounded batches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Normalized import batch metadata for sidebar drag/drop and similar flows.
public struct SidebarImportPlan: Sendable, Equatable {
    /// Concrete sources to process sequentially.
    public let sourceURLs: [URL]
    /// Whether the import pipeline should immediately display the imported content.
    ///
    /// For batches, preserving the current selection avoids spawning one viewport load
    /// per imported item.
    public let shouldAutoDisplayImportedContent: Bool

    public init(sourceURLs: [URL], shouldAutoDisplayImportedContent: Bool) {
        self.sourceURLs = sourceURLs
        self.shouldAutoDisplayImportedContent = shouldAutoDisplayImportedContent
    }
}

/// Expands dropped directories into individual import sources while preserving atomic
/// directory imports that have dedicated import flows.
public enum SidebarImportPlanner {
    public static func makePlan(
        for droppedURLs: [URL],
        fileManager: FileManager = .default,
        ontDirectoryDetector: (URL) -> Bool = { _ in false }
    ) -> SidebarImportPlan {
        let sourceURLs = expandSources(
            from: droppedURLs,
            fileManager: fileManager,
            ontDirectoryDetector: ontDirectoryDetector
        )
        return SidebarImportPlan(
            sourceURLs: sourceURLs,
            shouldAutoDisplayImportedContent: sourceURLs.count == 1
        )
    }

    static func expandSources(
        from urls: [URL],
        fileManager: FileManager = .default,
        ontDirectoryDetector: (URL) -> Bool = { _ in false }
    ) -> [URL] {
        var expanded: [URL] = []
        var seenPaths = Set<String>()

        for url in urls {
            appendSources(
                from: url,
                isTopLevel: true,
                fileManager: fileManager,
                ontDirectoryDetector: ontDirectoryDetector,
                seenPaths: &seenPaths,
                expanded: &expanded
            )
        }

        return expanded
    }

    private static func appendSources(
        from url: URL,
        isTopLevel: Bool,
        fileManager: FileManager,
        ontDirectoryDetector: (URL) -> Bool,
        seenPaths: inout Set<String>,
        expanded: inout [URL]
    ) {
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) else {
            return
        }

        if isDirectory.boolValue {
            if ontDirectoryDetector(standardizedURL) {
                appendAtomicSource(standardizedURL, seenPaths: &seenPaths, expanded: &expanded)
                return
            }

            let ext = standardizedURL.pathExtension.lowercased()
            if ext == "lungfishref" || ext == FASTQBundle.directoryExtension {
                if isTopLevel {
                    appendAtomicSource(standardizedURL, seenPaths: &seenPaths, expanded: &expanded)
                }
                return
            }

            guard let contents = try? fileManager.contentsOfDirectory(
                at: standardizedURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            for childURL in contents.sorted(by: childURLSort) {
                appendSources(
                    from: childURL,
                    isTopLevel: false,
                    fileManager: fileManager,
                    ontDirectoryDetector: ontDirectoryDetector,
                    seenPaths: &seenPaths,
                    expanded: &expanded
                )
            }
            return
        }

        guard shouldImportRegularFile(standardizedURL) else { return }
        appendAtomicSource(standardizedURL, seenPaths: &seenPaths, expanded: &expanded)
    }

    private static func appendAtomicSource(
        _ url: URL,
        seenPaths: inout Set<String>,
        expanded: inout [URL]
    ) {
        let normalized = url.standardizedFileURL
        guard seenPaths.insert(normalized.path).inserted else { return }
        expanded.append(normalized)
    }

    private static func shouldImportRegularFile(_ url: URL) -> Bool {
        !url.pathExtension.isEmpty
    }

    private static func childURLSort(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
    }
}
