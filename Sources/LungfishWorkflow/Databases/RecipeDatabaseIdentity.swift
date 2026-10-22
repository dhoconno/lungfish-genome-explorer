// RecipeDatabaseIdentity.swift - The identity of the database file a recipe step reads, checked against the lock
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// A database file that does not match the bytes the bundled lock pins for it.
public enum RecipeDatabaseIdentityError: Error, LocalizedError, Sendable, Equatable {
    case lockMismatch(databaseID: String, path: String, field: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case let .lockMismatch(databaseID, path, field, expected, actual):
            return "The \(databaseID) database at \(path) does not match the bundled lock. Its \(field) is \(actual), "
                + "and the lock pins \(expected). Reinstall it with `lungfish-cli conda db install-managed "
                + "\(databaseID) --reinstall`."
        }
    }
}

/// Resolves the ``RecipeDatabaseRecord`` of a database file a recipe step reads, before the step's tool runs.
///
/// A lock entry that carries `sha256` pins the file, and its `sizeBytes` is then the file's exact size. A file that
/// does not match a pin throws ``RecipeDatabaseIdentityError``. An entry without `sha256`, such as
/// `deacon-ribokmers`, which each install builds on its own host, is recorded by its actual digest with the build
/// inputs its install record names. Each file is hashed once per process, keyed by its path, size and modification
/// date, so a command that imports many samples hashes each database once (CHTC lane L5-RECORDS M2).
public actor RecipeDatabaseIdentity {
    public static let shared = RecipeDatabaseIdentity()

    private struct FileKey: Hashable {
        let path: String
        let sizeBytes: Int64
        let modified: Date?
    }

    struct BuildInputs: Equatable {
        let sourceSHA256: String?
        let sourceSizeBytes: Int64?
        let toolVersion: String?
    }

    private var digests: [FileKey: String] = [:]
    private var buildInputsByFile: [FileKey: BuildInputs?] = [:]
    /// How many files this resolver has hashed.
    public private(set) var hashCount = 0

    public init() {}

    /// The record of the database `databaseID` at `url`, checked against the bundled lock's entry for it.
    public func record(databaseID: String, at url: URL) throws -> RecipeDatabaseRecord {
        let id = DatabaseRegistry.canonicalDatabaseID(for: databaseID)
        return try record(databaseID: id, spec: ManagedToolLock.bundled.database(id: id), at: url)
    }

    /// The record of the database at `url`, checked against `spec`.
    func record(databaseID: String, spec: DatabaseSpec?, at url: URL) throws -> RecipeDatabaseRecord {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let key = FileKey(
            path: url.standardizedFileURL.path,
            sizeBytes: size,
            modified: attributes[.modificationDate] as? Date
        )
        let pinnedSHA256 = spec?.sha256?.lowercased()
        func mismatch(_ field: String, _ expected: String, _ actual: String) -> RecipeDatabaseIdentityError {
            .lockMismatch(databaseID: databaseID, path: url.path, field: field, expected: expected, actual: actual)
        }
        if pinnedSHA256 != nil, let pinnedSize = spec?.sizeBytes, pinnedSize != size {
            throw mismatch("size", "\(pinnedSize) bytes", "\(size) bytes")
        }
        let digest = try digest(of: url, key: key)
        if let pinnedSHA256, pinnedSHA256 != digest {
            throw mismatch("SHA-256", pinnedSHA256, digest)
        }
        let header = Self.deaconIndexHeader(at: url, sizeBytes: size)
        let build = pinnedSHA256 == nil ? builtFrom(indexAt: url, key: key) : nil
        return RecipeDatabaseRecord(
            id: databaseID,
            version: spec?.version ?? "unknown",
            fileName: url.lastPathComponent,
            indexFormat: header?.format ?? spec?.indexFormat,
            kmerLength: header?.kmerLength,
            windowSize: header?.windowSize,
            sha256: digest,
            sizeBytes: size,
            path: url.path,
            lockPinned: pinnedSHA256 != nil,
            buildSourceSHA256: build?.sourceSHA256,
            buildSourceSizeBytes: build?.sourceSizeBytes,
            buildToolVersion: build?.toolVersion
        )
    }

    private func digest(of url: URL, key: FileKey) throws -> String {
        if let known = digests[key] { return known }
        let digest = try ProvenanceFileHasher.sha256(of: url)
        hashCount += 1
        digests[key] = digest
        return digest
    }

    private func builtFrom(indexAt url: URL, key: FileKey) -> BuildInputs? {
        if let known = buildInputsByFile[key] { return known }
        let inputs = Self.buildInputs(
            installRecordAt: url.deletingLastPathComponent()
                .appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            indexFileName: url.lastPathComponent
        )
        buildInputsByFile[key] = .some(inputs)
        return inputs
    }

    /// The header of a Deacon minimizer index: a format byte, the k-mer length, the window size and a little-endian
    /// count of 8-byte minimizers. It is read only when the file's size is exactly that header and its minimizers,
    /// so a file of another layout gives nil rather than a wrong format.
    static func deaconIndexHeader(
        at url: URL,
        sizeBytes: Int64
    ) -> (format: Int, kmerLength: Int, windowSize: Int)? {
        guard sizeBytes >= 11, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 11), bytes.count == 11 else { return nil }
        let header = [UInt8](bytes)
        let count = header[3...10].reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let (minimizerBytes, overflow) = count.multipliedReportingOverflow(by: 8)
        guard !overflow, minimizerBytes + 11 == UInt64(sizeBytes) else { return nil }
        return (Int(header[0]), Int(header[1]), Int(header[2]))
    }

    /// The source file and tool version of the step of an install record that wrote the index named
    /// `indexFileName`. It reads both the envelope an install writes now and the run an older install wrote.
    static func buildInputs(installRecordAt recordURL: URL, indexFileName: String) -> BuildInputs? {
        guard let data = try? Data(contentsOf: recordURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = root["steps"] as? [[String: Any]] else {
            return nil
        }
        for step in steps {
            let outputs = step["outputs"] as? [[String: Any]] ?? []
            let wroteIndex = outputs.contains { output in
                (output["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent == indexFileName }
                    ?? false
            }
            let inputs = step["inputs"] as? [[String: Any]] ?? []
            guard wroteIndex,
                  let source = inputs.first(where: { $0["role"] as? String == "reference" }) ?? inputs.first else {
                continue
            }
            return BuildInputs(
                sourceSHA256: (source["sha256"] ?? source["checksumSHA256"]) as? String,
                sourceSizeBytes: ((source["sizeBytes"] ?? source["fileSize"]) as? NSNumber)?.int64Value,
                toolVersion: step["toolVersion"] as? String
            )
        }
        return nil
    }
}
