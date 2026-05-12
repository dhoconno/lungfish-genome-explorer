// ProvenanceFileHasher.swift - Full-file checksums for provenance records
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public enum ProvenanceFileHasherError: Error, LocalizedError, Sendable {
    case fileSizeUnavailable(String)
    case notDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .fileSizeUnavailable(let path):
            return "Could not determine file size for '\(path)'"
        case .notDirectory(let path):
            return "'\(path)' is not a directory"
        }
    }
}

public enum ProvenanceFileHasher {
    private static let chunkSize = 1_048_576

    public static func sha256(of url: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = fileHandle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func fileSize(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = fileSize(from: attributes[.size]) {
            return size
        }
        throw ProvenanceFileHasherError.fileSizeUnavailable(url.path)
    }

    public static func directoryManifest(for root: URL) throws -> ProvenanceDirectoryManifest {
        let fileManager = FileManager.default
        let rootURL = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProvenanceFileHasherError.notDirectory(rootURL.path)
        }

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            throw ProvenanceFileHasherError.notDirectory(rootURL.path)
        }

        var entries: [(relativePath: String, url: URL)] = []
        for case let fileURL as URL in enumerator {
            let relativePath = relativePath(for: fileURL, relativeTo: rootURL)
            guard !relativePath.isEmpty, !hasHiddenPathComponent(relativePath) else { continue }

            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            entries.append((relativePath, fileURL))
        }

        let files = try entries
            .sorted { $0.relativePath < $1.relativePath }
            .map { entry in
                ProvenanceFileDescriptor(
                    path: entry.relativePath,
                    checksumSHA256: try sha256(of: entry.url),
                    fileSize: try fileSize(of: entry.url)
                )
            }

        return ProvenanceDirectoryManifest(rootPath: rootURL.path, files: files)
    }

    private static func fileSize(from value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? NSNumber {
            return value.uint64Value
        }
        if let value = value as? Int64, value >= 0 {
            return UInt64(value)
        }
        if let value = value as? Int, value >= 0 {
            return UInt64(value)
        }
        return nil
    }

    private static func relativePath(for url: URL, relativeTo root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func hasHiddenPathComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}
