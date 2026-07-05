// ProvenancePublicationSnapshot.swift - rollback support for provenance-gated payload writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Captures payload and provenance artifacts before a workflow publishes new
/// scientific data. Restore the snapshot if provenance publication fails.
public struct ProvenancePublicationSnapshot {
    private struct Entry {
        let originalURL: URL
        let backupURL: URL?
    }

    private let fileManager: FileManager
    private let backupDirectory: URL
    private let entries: [Entry]

    public init(
        urls: [URL],
        backupNamePrefix: String = "lungfish-provenance-publication",
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        backupDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("\(backupNamePrefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        var seen = Set<String>()
        var capturedEntries: [Entry] = []
        for (index, url) in urls.enumerated() {
            let standardizedURL = url.standardizedFileURL
            guard seen.insert(standardizedURL.path).inserted else { continue }
            guard fileManager.fileExists(atPath: standardizedURL.path) else {
                capturedEntries.append(Entry(originalURL: standardizedURL, backupURL: nil))
                continue
            }
            let backupURL = backupDirectory.appendingPathComponent("artifact-\(index)")
            try fileManager.copyItem(at: standardizedURL, to: backupURL)
            capturedEntries.append(Entry(originalURL: standardizedURL, backupURL: backupURL))
        }
        entries = capturedEntries
    }

    public func restore() throws {
        for entry in entries.reversed() {
            if fileManager.fileExists(atPath: entry.originalURL.path) {
                try fileManager.removeItem(at: entry.originalURL)
            }
            guard let backupURL = entry.backupURL else { continue }
            try fileManager.createDirectory(
                at: entry.originalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: backupURL, to: entry.originalURL)
        }
    }

    public func discard() {
        try? fileManager.removeItem(at: backupDirectory)
    }
}

public enum ProvenancePublicationArtifacts {
    public static func bundleRootArtifacts(for rootURL: URL) -> [URL] {
        sidecarArtifacts(for: rootURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
            + [rootURL.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)]
    }

    public static func fileSidecarArtifacts(for outputURL: URL) -> [URL] {
        sidecarArtifacts(for: ProvenanceRecorder.fileSidecarURL(for: outputURL))
    }

    public static func sidecarArtifacts(for sidecarURL: URL) -> [URL] {
        [
            sidecarURL,
            ProvenanceSigningConfiguration.signatureURL(for: sidecarURL),
            ProvenanceSigningConfiguration.publicKeyURL(for: sidecarURL),
        ]
    }
}
