// RNASeqResultBundle.swift - The reader of an RNA-seq result (Phase 5.1 lane RS-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reads a `.lungfishrnaseq` folder as `docs/formats/rnaseq-bundle.md` lays it out. It loads the manifest, `samples.tsv`,
// `genes.tsv` and each count table whole, checks the listed sha256 values on request, and writes nothing. It never opens
// a file under `source/`, so a single-cell matrix is never loaded. The one writer is `RNASeqResultWriter` in
// `Sources/LungfishWorkflow/RNASeq/`.

import CryptoKit
import Foundation

public enum RNASeqResultError: Error, Equatable, LocalizedError, Sendable {
    case newerSchema(Int)
    case noReadableManifest
    case unreadableFile(path: String, reason: String)
    case invalidTable(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .newerSchema(let version):
            return "This RNA-seq result was written by a newer LGE (schema \(version)). Open it with that version or a later one."
        case .noReadableManifest:
            return "The RNA-seq result has no readable manifest."
        case .unreadableFile(let path, let reason):
            return "The RNA-seq result's file \(path) could not be read: \(reason)"
        case .invalidTable(let path, let reason):
            return "The RNA-seq result's table \(path) is not valid: \(reason)"
        }
    }
}

/// A result as the reader returns it. The files under `source/` are listed in the manifest and never loaded.
public struct RNASeqResult: Equatable, Sendable {
    public struct CountTable: Equatable, Sendable {
        public var entry: RNASeqResultManifest.CountEntry
        public var table: RNASeqCountTable
    }

    /// A listed file whose sha256 differs. `actual` is nil when the file is missing or unreadable.
    public struct ChecksumMismatch: Equatable, Sendable {
        public var path: String
        public var expected: String
        public var actual: String?
    }

    public var manifest: RNASeqResultManifest
    public var samples: [RNASeqSampleRecord]
    public var genes: [RNASeqGeneRecord]
    public var counts: [CountTable]
    /// Nil when the result keeps no quality table, which a reader shows as Not recorded.
    public var quality: RNASeqQualityTable?
}

public enum RNASeqResultBundle {
    public static let directoryExtension = "lungfishrnaseq"
    /// What a reader shows for a fact the imported files do not state.
    public static let notRecordedText = "Not recorded"

    public static func isBundleURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == directoryExtension
    }

    public static func manifestURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(RNASeqResultManifest.filename)
    }

    /// Reads the manifest of schema 1. A higher schema is refused before anything else is decoded, so a later
    /// writer's changed keys never reach the decoder.
    public static func loadManifest(from bundleURL: URL) throws -> RNASeqResultManifest {
        struct Version: Decodable { let schemaVersion: Int }
        guard let data = try? Data(contentsOf: manifestURL(in: bundleURL)),
              let version = try? JSONDecoder().decode(Version.self, from: data) else {
            throw RNASeqResultError.noReadableManifest
        }
        if version.schemaVersion > RNASeqResultManifest.currentSchemaVersion {
            throw RNASeqResultError.newerSchema(version.schemaVersion)
        }
        guard version.schemaVersion == RNASeqResultManifest.currentSchemaVersion,
              let manifest = try? JSONDecoder().decode(RNASeqResultManifest.self, from: data),
              manifest.kind == RNASeqResultManifest.kindName else {
            throw RNASeqResultError.noReadableManifest
        }
        return manifest
    }

    /// The file a manifest path names. A path that is absolute or climbs out of the folder is refused.
    public static func resolve(_ relativePath: String, in bundleURL: URL) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw RNASeqResultError.unreadableFile(path: relativePath, reason: "the path leaves the result's folder")
        }
        return bundleURL.appendingPathComponent(relativePath)
    }

    public static func load(from bundleURL: URL) throws -> RNASeqResult {
        let manifest = try loadManifest(from: bundleURL)
        func read(_ path: String) throws -> Data {
            let url = try resolve(path, in: bundleURL)
            do { return try Data(contentsOf: url) } catch {
                throw RNASeqResultError.unreadableFile(path: path, reason: error.localizedDescription)
            }
        }
        return RNASeqResult(
            manifest: manifest,
            samples: try RNASeqSampleRecord.records(tsv: read(manifest.samples.path), path: manifest.samples.path),
            genes: try RNASeqGeneRecord.records(tsv: read(manifest.genes.path), path: manifest.genes.path),
            counts: try manifest.counts.map {
                RNASeqResult.CountTable(entry: $0, table: try RNASeqCountTable(tsv: read($0.path), path: $0.path))
            },
            quality: try manifest.quality.map { try RNASeqQualityTable(tsv: read($0.path), path: $0.path) })
    }

    /// Hashes every file the manifest lists and returns those that differ, which is none for a result as written.
    public static func verifyChecksums(of bundleURL: URL) throws -> [RNASeqResult.ChecksumMismatch] {
        let manifest = try loadManifest(from: bundleURL)
        var listed = [manifest.samples, manifest.genes].map { ($0.path, $0.sha256) }
        listed += manifest.counts.map { ($0.path, $0.sha256) }
        listed += manifest.sourceFiles.map { ($0.path, $0.sha256) }
        for matrix in manifest.matrices ?? [] { listed += [matrix.matrix, matrix.features, matrix.barcodes].map { ($0.path, $0.sha256) } }
        if let cells = manifest.cellsSummary { listed.append((cells.path, cells.sha256)) }
        if let quality = manifest.quality { listed.append((quality.path, quality.sha256)) }
        // A path the manifest lists twice, such as a matrix file under sourceFiles and under matrices, is hashed once.
        var order: [String] = []
        var expected: [String: [String]] = [:]
        for (path, sha) in listed {
            if expected[path] == nil { order.append(path) }
            if !(expected[path] ?? []).contains(sha) { expected[path, default: []].append(sha) }
        }
        return order.flatMap { path -> [RNASeqResult.ChecksumMismatch] in
            let actual = try? sha256Hex(fileAt: resolve(path, in: bundleURL))
            return (expected[path] ?? []).filter { $0 != actual }
                .map { RNASeqResult.ChecksumMismatch(path: path, expected: $0, actual: actual) }
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// The sha256 of a file read in 1 MiB chunks, each in its own autorelease pool so the hash holds one chunk and not
    /// the whole file.
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hex(hasher.finalize())
    }

    public static func hex<Bytes: Swift.Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
