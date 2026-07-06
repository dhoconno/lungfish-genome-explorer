// BundleAttachmentManager.swift - File attachment management for FASTQ bundles
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "BundleAttachmentManager")

// MARK: - BundleAttachmentManager

/// Manages file attachments stored in the `attachments/` subdirectory of a
/// `.lungfishfastq` bundle.
///
/// Attachments are arbitrary files (lab reports, sample photos, etc.) that
/// users associate with a FASTQ bundle. Files are copied into the bundle
/// to keep it self-contained.
public struct BundleAttachmentManager: Sendable {

    /// Subdirectory name within the bundle.
    public static let attachmentsDirectoryName = "attachments"

    /// The bundle URL this manager operates on.
    public let bundleURL: URL

    /// URL of the attachments directory inside the bundle.
    public var attachmentsDirectory: URL {
        bundleURL.appendingPathComponent(Self.attachmentsDirectoryName)
    }

    /// Creates a manager for the given bundle.
    public init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    // MARK: - Query

    /// Lists all attachment filenames in the bundle.
    public func listAttachments() -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: attachmentsDirectory.path) else { return [] }
        do {
            let contents = try fm.contentsOfDirectory(
                at: attachmentsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            return contents
                .map(\.lastPathComponent)
                .filter(BundleAttachmentFilenamePolicy.isUserVisibleAttachmentFilename)
                .sorted()
        } catch {
            logger.warning("Failed to list attachments: \(error.localizedDescription)")
            return []
        }
    }

    /// Returns the full URL for an attachment by filename.
    public func urlForAttachment(_ filename: String) -> URL {
        attachmentsDirectory.appendingPathComponent(filename)
    }

    // MARK: - Mutating

    /// Copies a file into the bundle's attachments directory.
    ///
    /// If a file with the same name already exists, a numeric suffix is added
    /// (e.g., `report-2.pdf`).
    ///
    /// - Parameter sourceURL: The file to attach.
    /// - Returns: The filename as stored in the bundle.
    @discardableResult
    public func addAttachment(from sourceURL: URL) throws -> String {
        let fm = FileManager.default

        // Ensure attachments directory exists
        if !fm.fileExists(atPath: attachmentsDirectory.path) {
            try fm.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        }

        // Determine destination filename (avoid collisions)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var filename = sourceURL.lastPathComponent
        var destURL = attachmentsDirectory.appendingPathComponent(filename)
        var counter = 2

        while fm.fileExists(atPath: destURL.path) {
            if ext.isEmpty {
                filename = "\(baseName)-\(counter)"
            } else {
                filename = "\(baseName)-\(counter).\(ext)"
            }
            destURL = attachmentsDirectory.appendingPathComponent(filename)
            counter += 1
        }

        try fm.copyItem(at: sourceURL, to: destURL)
        logger.info("Added attachment '\(filename)' to bundle at \(self.bundleURL.lastPathComponent)")
        return filename
    }

    /// Removes an attachment from the bundle.
    ///
    /// - Parameter filename: The attachment filename to remove.
    public func removeAttachment(_ filename: String) throws {
        let url = urlForAttachment(filename)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
        try? fm.removeItem(at: BundleAttachmentFilenamePolicy.provenanceSidecarURL(forAttachmentURL: url))
        logger.info("Removed attachment '\(filename)' from bundle at \(self.bundleURL.lastPathComponent)")

        // Remove the attachments directory if empty
        let remaining = listAttachments()
        if remaining.isEmpty {
            try? fm.removeItem(at: attachmentsDirectory)
        }
    }
}
