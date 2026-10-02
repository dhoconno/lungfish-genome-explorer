// ReadManifest.swift - Standalone manifest file (read-manifest.json) for multi-file bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

// MARK: - Read Manifest

/// Standalone manifest file (`read-manifest.json`) for multi-file bundles.
///
/// This is saved as a separate file in the bundle root when the bundle contains
/// multiple FASTQ files with different roles.
public struct ReadManifest: Codable, Sendable, Equatable {
    public static let filename = "read-manifest.json"

    public let version: Int
    public let classification: ReadClassification
    public let sourceOperation: String?

    public init(classification: ReadClassification, sourceOperation: String? = nil) {
        self.version = 1
        self.classification = classification
        self.sourceOperation = sourceOperation
    }

    /// Loads a read manifest from a bundle directory, if present.
    public static func load(from bundleURL: URL) -> ReadManifest? {
        let url = bundleURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ReadManifest.self, from: data)
        } catch {
            return nil
        }
    }

    /// Saves the manifest to a bundle directory.
    public func save(to bundleURL: URL) throws {
        let url = bundleURL.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
