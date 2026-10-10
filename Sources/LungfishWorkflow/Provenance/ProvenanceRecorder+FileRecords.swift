// ProvenanceRecorder+FileRecords.swift - Builds provenance file records with checksums and sizes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit

extension ProvenanceRecorder {

    // MARK: - Checksum Helpers

    /// Computes SHA-256 checksum of a file.
    public static func sha256(of url: URL) -> String? {
        try? ProvenanceFileHasher.sha256(of: url)
    }

    /// Creates a FileRecord with computed checksum and size.
    public static func fileRecord(
        url: URL,
        format: FileFormat? = nil,
        role: FileRole = .input
    ) -> FileRecord {
        let size = try? ProvenanceFileHasher.fileSize(of: url)
        let checksum = sha256(of: url)
        let detectedFormat = format ?? detectFormat(url: url)

        return FileRecord(
            path: url.path,
            sha256: checksum,
            sizeBytes: size,
            format: detectedFormat,
            role: role
        )
    }

    /// Creates a record for a regular file or directory.
    ///
    /// Directory records use a stable manifest hash and aggregate byte size so
    /// collection and bundle outputs do not appear as checksum-less files.
    public static func fileOrDirectoryRecord(
        url: URL,
        format: FileFormat? = nil,
        role: FileRole = .input
    ) -> FileRecord {
        var isDirectory: ObjCBool = false
        let standardizedURL = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           let manifest = try? ProvenanceFileHasher.directoryManifest(for: standardizedURL, role: role) {
            return FileRecord(
                path: standardizedURL.path,
                sha256: directoryChecksum(from: manifest),
                sizeBytes: directorySize(from: manifest),
                format: format ?? .unknown,
                role: role
            )
        }

        return fileRecord(url: standardizedURL, format: format, role: role)
    }

    private static func directoryChecksum(from manifest: ProvenanceDirectoryManifest) -> String {
        let canonical = manifest.files
            .sorted { $0.path < $1.path }
            .map { descriptor in
                [
                    descriptor.path,
                    descriptor.checksumSHA256 ?? "",
                    descriptor.fileSize.map(String.init) ?? "0",
                ].joined(separator: "\t")
            }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func directorySize(from manifest: ProvenanceDirectoryManifest) -> UInt64 {
        manifest.files.reduce(UInt64(0)) { total, descriptor in
            total + (descriptor.fileSize ?? 0)
        }
    }

    /// Detects file format from extension.
    private static func detectFormat(url: URL) -> FileFormat {
        FileFormat.inferred(fromPath: url.path)
    }
}
