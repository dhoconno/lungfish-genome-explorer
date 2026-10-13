// KrakenRecordRemovalSupport.swift - What the Kraken2 record tests share about files a run removed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B34, rows 268 and 271 of docs/plans/2026-10-11-phase-2-8.md. A Kraken2 record keeps naming
// the files a run removed, so each of them needs a step that says why it is gone (P1 of Phase 2.8, ARCH 5).

import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

enum KrakenRecordRemoval {
    /// Whether `step` is a removal step (`operation` `remove` in its resolved options).
    static func isRemoval(_ step: ProvenanceStep) -> Bool {
        step.resolvedOptions["operation"] == .string(RecordedRemovalStep.operation)
    }

    /// The step of `toolName` in `envelope`, the first when the run holds several.
    static func step(
        _ toolName: String, in envelope: ProvenanceEnvelope, file: StaticString = #filePath, line: UInt = #line
    ) throws -> ProvenanceStep {
        try XCTUnwrap(envelope.steps.first { $0.toolName == toolName }, "no step \(toolName)", file: file, line: line)
    }

    /// What is wrong with the files the steps of `envelope` name. A file the run left must exist, with the digest
    /// the step states unless it is a folder. A file the run removed must be named by a removal step, which is how
    /// `assertEveryNamedFileIsKeptOrRemoved` of `KrakenReadSetPipelineTests` reads a record, here on the envelope.
    static func problems(in envelope: ProvenanceEnvelope) -> [String] {
        let removed = Set(envelope.steps.filter(isRemoval).flatMap { $0.inputs.map(\.path) })
        var found: [String] = []
        for step in envelope.steps {
            for named in step.inputs + step.outputs where !removed.contains(named.path) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: named.path, isDirectory: &isDirectory) else {
                    found.append("\(step.toolName) names \(named.path), which is gone")
                    continue
                }
                guard !isDirectory.boolValue, let recorded = named.checksumSHA256 else { continue }
                if ProvenanceRecorder.sha256(of: URL(fileURLWithPath: named.path)) != recorded {
                    found.append("\(step.toolName) names \(named.path) with a digest it no longer has")
                }
            }
        }
        return found
    }

    /// A strictly interleaved FASTQ of two pairs at `url`, which kraken2 reads as a split into two mate files.
    static func writeInterleavedReads(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@i1/1\nACGTACGTAC\n+\nIIIIIIIIII\n@i1/2\nACGTACGTAC\n+\nIIIIIIIIII\n"
            .appending("@i2/1\nACGTACGTAC\n+\nIIIIIIIIII\n@i2/2\nACGTACGTAC\n+\nIIIIIIIIII\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
