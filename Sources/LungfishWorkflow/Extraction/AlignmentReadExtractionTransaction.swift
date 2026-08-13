// AlignmentReadExtractionTransaction.swift - Owned staging lifecycle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Owns one isolated alignment-read extraction staging directory and the
/// scientific evidence accumulated there. The lock makes the deliberately
/// small mutable surface safe when App cancellation races a worker task.
public final class AlignmentReadExtractionTransaction: @unchecked Sendable {
    public let stagingDirectoryURL: URL
    public let stagedFiles: [AlignmentReadExtractionStagedFile]
    public let readCount: Int
    public let pairedEnd: Bool
    /// Selected records for which the originating workflow had no sequence
    /// payload. They are reported to the caller rather than silently omitted.
    public let recordsWithoutSequence: Int
    /// Human-readable explanation shown alongside ``recordsWithoutSequence``.
    public let missingSequenceMessage: String?
    public let startedAt: Date

    private let lock = NSLock()
    private var records: [AlignmentReadExtractionExecutionRecord]
    private var didCleanUp = false

    public init(
        stagingDirectoryURL: URL,
        stagedFiles: [AlignmentReadExtractionStagedFile],
        readCount: Int,
        pairedEnd: Bool,
        recordsWithoutSequence: Int = 0,
        missingSequenceMessage: String? = nil,
        executionRecords: [AlignmentReadExtractionExecutionRecord] = [],
        startedAt: Date = Date()
    ) throws {
        let directory = stagingDirectoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AlignmentReadExtractionFailure(
                kind: .missingInput,
                message: "Extraction staging directory is unavailable: \(directory.path)",
                executionRecords: executionRecords
            )
        }
        guard !stagedFiles.isEmpty else {
            throw AlignmentReadExtractionFailure(
                kind: .emptyExtraction,
                message: "Extraction staging completed without a payload.",
                executionRecords: executionRecords
            )
        }
        guard readCount > 0 else {
            throw AlignmentReadExtractionFailure(
                kind: .emptyExtraction,
                message: "The extraction produced zero reads.",
                executionRecords: executionRecords
            )
        }
        guard recordsWithoutSequence >= 0 else {
            throw AlignmentReadExtractionFailure(
                kind: .missingInput,
                message: "The missing-sequence count cannot be negative.",
                executionRecords: executionRecords
            )
        }

        for file in stagedFiles {
            let stagedURL = file.stagedURL.standardizedFileURL
            guard Self.isDescendant(stagedURL, of: directory),
                  FileManager.default.fileExists(atPath: stagedURL.path),
                  Self.isSafeRelativePath(file.relativeFinalPath) else {
                throw AlignmentReadExtractionFailure(
                    kind: .missingInput,
                    message: "Extraction staging payload is unavailable or unsafe: \(file.stagedURL.path)",
                    executionRecords: executionRecords
                )
            }
        }

        self.stagingDirectoryURL = directory
        self.stagedFiles = stagedFiles
        self.readCount = readCount
        self.pairedEnd = pairedEnd
        self.recordsWithoutSequence = recordsWithoutSequence
        self.missingSequenceMessage = missingSequenceMessage
        self.records = executionRecords
        self.startedAt = startedAt
    }

    public var executionRecords: [AlignmentReadExtractionExecutionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public var isCleanedUp: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCleanUp
    }

    public func appendExecutionRecord(_ record: AlignmentReadExtractionExecutionRecord) {
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    /// Removes the sole transaction directory. This is idempotent so every
    /// success, failure, cancellation, and stale-prepublication branch can
    /// call it without competing cleanup behavior.
    public func cleanup() {
        lock.lock()
        guard !didCleanUp else {
            lock.unlock()
            return
        }
        didCleanUp = true
        lock.unlock()
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
    }

    private static func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let root = directory.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        return path.hasPrefix(root + "/")
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0.isEmpty }
    }
}
