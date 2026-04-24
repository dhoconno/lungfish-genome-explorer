// PrimerSchemesFolder.swift - Manage Primer Schemes project folder
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "PrimerSchemesFolder")

/// Manages the "Primer Schemes" folder within a project directory.
///
/// This folder stores `.lungfishprimers` bundles containing BED-based primer
/// panels used for amplicon workflows such as primer trimming on aligned reads.
/// Parallels `ReferenceSequenceFolder` — projects import primer schemes into
/// this folder so they remain self-contained.
public enum PrimerSchemesFolder {

    /// The folder name within the project directory.
    public static let folderName = "Primer Schemes"

    // MARK: - Folder Management

    /// Returns the URL to the Primer Schemes folder within a project directory.
    /// Creates the folder if it doesn't exist.
    public static func ensureFolder(in projectURL: URL) throws -> URL {
        let folderURL = projectURL.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: folderURL.path) {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            logger.info("Created Primer Schemes folder at \(folderURL.path)")
        }
        return folderURL
    }

    /// Returns the URL to the Primer Schemes folder, or nil if it doesn't exist.
    public static func folderURL(in projectURL: URL) -> URL? {
        let folderURL = projectURL.appendingPathComponent(folderName, isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue {
            return folderURL
        }
        return nil
    }

    // MARK: - Bundle Listing

    /// Lists all `.lungfishprimers` bundles in the Primer Schemes folder.
    ///
    /// Bundles that fail to load are silently skipped. Returns an empty array
    /// if the folder does not exist or cannot be read.
    ///
    /// - Parameter projectURL: Path to the project directory
    /// - Returns: Array of loaded `PrimerSchemeBundle` values, sorted by bundle filename
    public static func listBundles(in projectURL: URL) -> [PrimerSchemeBundle] {
        guard let folder = folderURL(in: projectURL) else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "lungfishprimers" }
            .compactMap { try? PrimerSchemeBundle.load(from: $0) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }
}
