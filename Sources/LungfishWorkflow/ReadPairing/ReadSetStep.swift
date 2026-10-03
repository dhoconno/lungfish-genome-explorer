// ReadSetStep.swift - A split or interleave the read-set resolver wrote, as a provenance step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// A file the resolver wrote so a tool could take a sample's reads in the
/// form it needs. Runs in process, and the top-level `lungfish-cli` command
/// that resolved the sample writes it again.
public struct ReadSetStep: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A file mixing pairs and single reads split by fragment name into
        /// R1, R2 and single reads (``FASTQPairInterleaver/partitionMixed(interleaved:r1:r2:unpaired:)``).
        case splitByName = "split_by_name"
        /// R1 and R2 files interleaved with mate names checked record by
        /// record, then the single reads after them, as one stream.
        case interleaveByName = "interleave_by_name"
    }

    public let kind: Kind
    public let inputURLs: [URL]
    public let outputURLs: [URL]
    /// Pairs written.
    public let pairCount: Int
    /// Single reads written.
    public let singleReadCount: Int
    public let startedAt: Date
    public let endedAt: Date

    public init(
        kind: Kind,
        inputURLs: [URL],
        outputURLs: [URL],
        pairCount: Int,
        singleReadCount: Int,
        startedAt: Date,
        endedAt: Date
    ) {
        self.kind = kind
        self.inputURLs = inputURLs.map(\.standardizedFileURL)
        self.outputURLs = outputURLs.map(\.standardizedFileURL)
        self.pairCount = pairCount
        self.singleReadCount = singleReadCount
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// The tool name the provenance step records.
    public var toolName: String {
        switch kind {
        case .splitByName: return "Lungfish Read-Set Split"
        case .interleaveByName: return "Lungfish Read-Set Interleave"
        }
    }

    /// The step as an argument list naming its inputs and outputs. It runs
    /// in process, so the list describes the step and is not a shell command.
    public var command: [String] {
        [toolName, kind.rawValue]
            + inputURLs.flatMap { ["--in", $0.path] }
            + outputURLs.flatMap { ["--out", $0.path] }
    }

    /// The provenance step for this split or interleave, with its record
    /// counts as resolved options.
    public func stepExecution(toolVersion: String) throws -> StepExecution {
        func records(_ urls: [URL], role: FileRole) throws -> [FileRecord] {
            try urls.map { url in
                let descriptor = try ProvenanceFileDescriptor.file(url: url, format: .fastq, role: role)
                return FileRecord(
                    path: descriptor.path,
                    sha256: descriptor.checksumSHA256,
                    sizeBytes: descriptor.fileSize,
                    format: descriptor.format,
                    role: descriptor.role
                )
            }
        }
        return StepExecution(
            toolName: toolName,
            toolVersion: toolVersion,
            command: command,
            resolvedOptions: [
                "pairs": .integer(pairCount),
                "singleReads": .integer(singleReadCount),
            ],
            inputs: try records(inputURLs, role: .input),
            outputs: try records(outputURLs, role: .output),
            exitCode: 0,
            wallTime: max(0, endedAt.timeIntervalSince(startedAt)),
            startTime: startedAt,
            endTime: endedAt
        )
    }
}
