// ReferenceSequenceFolder.swift - Manage Reference Sequences project folder
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.browser", category: "ReferenceSequenceFolder")

/// Manages the "Reference Sequences" folder within a project directory.
///
/// This folder stores `.lungfishref` bundles containing reference FASTA files
/// used for orientation, mapping, and other operations that need a reference.
/// When a user selects an external reference file, it is imported into this
/// folder so the project remains self-contained.
public enum ReferenceSequenceFolder {

    /// The folder name within the project directory.
    public static let folderName = "Reference Sequences"

    // MARK: - Folder Management

    /// Returns the URL to the Reference Sequences folder within a project directory.
    /// Creates the folder if it doesn't exist.
    public static func ensureFolder(in projectURL: URL) throws -> URL {
        let folderURL = projectURL.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: folderURL.path) {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            logger.info("Created Reference Sequences folder at \(folderURL.path)")
        }
        return folderURL
    }

    /// Returns the URL to the Reference Sequences folder, or nil if it doesn't exist.
    public static func folderURL(in projectURL: URL) -> URL? {
        let folderURL = projectURL.appendingPathComponent(folderName, isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue {
            return folderURL
        }
        return nil
    }

    // MARK: - Import

    /// Imports a reference FASTA file into the Reference Sequences folder.
    ///
    /// Creates a `.lungfishref` bundle containing:
    /// - `manifest.json` — minimal manifest with name and creation date
    /// - `sequence.fasta` — copy of the source FASTA
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the source FASTA file (`.fasta`, `.fa`, `.fna`)
    ///   - projectURL: Path to the project directory
    ///   - displayName: Optional display name (defaults to source filename without extension)
    /// - Returns: URL to the created `.lungfishref` bundle
    @discardableResult
    public static func importReference(
        from sourceURL: URL,
        into projectURL: URL,
        displayName: String? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let refFolder = try ensureFolder(in: projectURL)

        let name = displayName ?? sourceURL.deletingPathExtension().lastPathComponent
        let safeName = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let bundleName = "\(safeName).lungfishref"
        let bundleURL = refFolder.appendingPathComponent(bundleName, isDirectory: true)

        // If bundle already exists, return it
        if fm.fileExists(atPath: bundleURL.path) {
            logger.info("Reference bundle already exists: \(bundleName)")
            return bundleURL
        }

        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Copy the FASTA file
        let destFASTA = bundleURL.appendingPathComponent("sequence.fasta")
        try fm.copyItem(at: sourceURL, to: destFASTA)

        // Write a minimal manifest
        let manifest = ReferenceSequenceManifest(
            name: name,
            createdAt: Date(),
            sourceFilename: sourceURL.lastPathComponent,
            fastaFilename: "sequence.fasta"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: bundleURL.appendingPathComponent("manifest.json"))

        logger.info("Imported reference: \(name) from \(sourceURL.lastPathComponent)")
        return bundleURL
    }

    // MARK: - Listing

    /// Lists all `.lungfishref` bundles in the Reference Sequences folder.
    ///
    /// - Parameter projectURL: Path to the project directory
    /// - Returns: Array of (bundleURL, manifest) tuples, sorted by name
    public static func listReferences(in projectURL: URL) -> [(url: URL, manifest: ReferenceSequenceManifest)] {
        guard let folder = folderURL(in: projectURL) else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [(url: URL, manifest: ReferenceSequenceManifest)] = []
        for url in contents where url.pathExtension == "lungfishref" {
            let manifestURL = url.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder.iso8601Decoder.decode(
                      ReferenceSequenceManifest.self, from: data
                  ) else { continue }
            results.append((url, manifest))
        }
        return results.sorted { $0.manifest.name < $1.manifest.name }
    }

    /// Returns the FASTA file URL within a reference bundle.
    public static func fastaURL(in bundleURL: URL) -> URL? {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder.iso8601Decoder.decode(
                  ReferenceSequenceManifest.self, from: data
              ) else { return nil }
        let fastaURL = bundleURL.appendingPathComponent(manifest.fastaFilename)
        return FileManager.default.fileExists(atPath: fastaURL.path) ? fastaURL : nil
    }

    /// Checks if a FASTA URL is already within the Reference Sequences folder.
    public static func isProjectReference(_ url: URL, in projectURL: URL) -> Bool {
        guard let folder = folderURL(in: projectURL) else { return false }
        return url.path.hasPrefix(folder.path)
    }
}

// MARK: - Manifest

/// Minimal manifest for reference sequence bundles in the Reference Sequences folder.
///
/// This is simpler than the full `BundleManifest` used by genome reference bundles,
/// since these are just FASTA files for orientation/mapping (not full genome bundles).
public struct ReferenceSequenceManifest: Codable, Sendable {
    public let name: String
    public let createdAt: Date
    public let sourceFilename: String
    public let fastaFilename: String

    public init(name: String, createdAt: Date, sourceFilename: String, fastaFilename: String) {
        self.name = name
        self.createdAt = createdAt
        self.sourceFilename = sourceFilename
        self.fastaFilename = fastaFilename
    }
}

// MARK: - JSONDecoder extension

extension JSONDecoder {
    /// A decoder configured for ISO 8601 date decoding. Scoped to this file.
    fileprivate static let iso8601Decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
