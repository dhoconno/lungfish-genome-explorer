// FASTQPairInterleaver.swift - Verbatim R1/R2 interleaving for paired FASTQ imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension FASTQPairInterleaver {

    /// ``interleave(r1:r2:to:requireMates:launcher:)`` with the launcher that
    /// starts `gzip -dc` through ``ToolProcess``.
    public static func interleave(
        r1: URL,
        r2: URL,
        to sink: FileHandle,
        requireMates: Bool = false
    ) throws -> Counts {
        try interleave(r1: r1, r2: r2, to: sink, requireMates: requireMates, launcher: ToolProcessChildLauncher())
    }

    /// ``interleave(r1:r2:to:requireMates:)`` into the stage file of a
    /// ``DurableReplace`` publication, so a failed write is a thrown error and
    /// the name holds the interleaved file only when it is whole and synced
    /// (Phase 2.10 lane S31).
    static func interleave(
        r1: URL,
        r2: URL,
        to stage: DurableReplace.StageWriter,
        requireMates: Bool = false
    ) throws -> Counts {
        var output = BufferedSink(stage: stage)
        return try interleave(
            r1: r1, r2: r2, into: &output, requireMates: requireMates, launcher: ToolProcessChildLauncher()
        )
    }

    /// ``interleaveRecordedPair(r1:r2:to:launcher:)`` with the launcher that
    /// starts `gzip -dc` through ``ToolProcess``.
    public static func interleaveRecordedPair(r1: URL, r2: URL, to sink: FileHandle) throws -> RecordedPairCounts {
        try interleaveRecordedPair(r1: r1, r2: r2, to: sink, launcher: ToolProcessChildLauncher())
    }

    /// `interleaveRecordedPair(r1:r2:to:)` with a file handle, into the stage
    /// file of a ``DurableReplace`` publication (Phase 2.10 lane S31).
    static func interleaveRecordedPair(
        r1: URL,
        r2: URL,
        to stage: DurableReplace.StageWriter
    ) throws -> RecordedPairCounts {
        var output = BufferedSink(stage: stage)
        return try interleaveRecordedPair(r1: r1, r2: r2, into: &output, launcher: ToolProcessChildLauncher())
    }

    /// ``writeMergedThenPairs(merged:unmergedR1:unmergedR2:to:launcher:)``
    /// with the launcher that starts `gzip -dc` through ``ToolProcess``.
    public static func writeMergedThenPairs(
        merged: URL,
        unmergedR1: URL?,
        unmergedR2: URL?,
        to sink: FileHandle
    ) throws -> MergedThenPairsCounts {
        try writeMergedThenPairs(
            merged: merged, unmergedR1: unmergedR1, unmergedR2: unmergedR2, to: sink,
            launcher: ToolProcessChildLauncher()
        )
    }

    /// ``copyRecords(of:to:launcher:inspecting:)`` with the launcher that
    /// starts `gzip -dc` through ``ToolProcess``.
    static func copyRecords(
        of file: URL,
        to sink: FileHandle,
        inspecting inspect: (_ header: String, _ recordNumber: Int) throws -> Void
    ) throws -> Int {
        try copyRecords(of: file, to: sink, launcher: ToolProcessChildLauncher(), inspecting: inspect)
    }

    /// `copyRecords(of:to:inspecting:)` with a file handle, into the stage
    /// file of a ``DurableReplace`` publication (Phase 2.10 lane S31).
    static func copyRecords(
        of file: URL,
        to stage: DurableReplace.StageWriter,
        inspecting inspect: (_ header: String, _ recordNumber: Int) throws -> Void
    ) throws -> Int {
        var output = BufferedSink(stage: stage)
        return try copyRecords(of: file, into: &output, launcher: ToolProcessChildLauncher(), inspecting: inspect)
    }

    /// ``deinterleave(interleaved:r1:r2:launcher:)`` with the launcher that
    /// starts `gzip -dc` through ``ToolProcess``.
    public static func deinterleave(interleaved: URL, r1 sink1: FileHandle, r2 sink2: FileHandle) throws -> Counts {
        try deinterleave(interleaved: interleaved, r1: sink1, r2: sink2, launcher: ToolProcessChildLauncher())
    }

    /// ``partitionMixed(interleaved:r1:r2:unpaired:launcher:)`` with the
    /// launcher that starts `gzip -dc` through ``ToolProcess``.
    public static func partitionMixed(
        interleaved: URL,
        r1 sink1: FileHandle,
        r2 sink2: FileHandle,
        unpaired sinkUnpaired: FileHandle
    ) throws -> MixedCounts {
        try partitionMixed(
            interleaved: interleaved, r1: sink1, r2: sink2, unpaired: sinkUnpaired,
            launcher: ToolProcessChildLauncher()
        )
    }

    /// ``partitionMixed(interleaved:pairs:unpaired:launcher:)`` with the
    /// launcher that starts `gzip -dc` through ``ToolProcess``.
    public static func partitionMixed(
        interleaved: URL,
        pairs sinkPairs: FileHandle,
        unpaired sinkUnpaired: FileHandle
    ) throws -> MixedCounts {
        try partitionMixed(
            interleaved: interleaved, pairs: sinkPairs, unpaired: sinkUnpaired, launcher: ToolProcessChildLauncher()
        )
    }

    /// ``countMixed(interleaved:launcher:)`` with the launcher that starts
    /// `gzip -dc` through ``ToolProcess``.
    public static func countMixed(interleaved: URL) throws -> MixedCounts {
        try countMixed(interleaved: interleaved, launcher: ToolProcessChildLauncher())
    }

    /// ``countRecords(in:launcher:)`` with the launcher that starts `gzip -dc`
    /// through ``ToolProcess``.
    public static func countRecords(in url: URL) throws -> Int {
        try countRecords(in: url, launcher: ToolProcessChildLauncher())
    }
}

extension FASTQPairInterleaver.BufferedSink {
    /// A sink into the stage file of a ``DurableReplace`` publication,
    /// which reports a failed write as a thrown error.
    init(stage: DurableReplace.StageWriter) {
        self.init(emit: { bytes in try bytes.withUnsafeBytes { try stage.write($0) } })
    }
}

extension FASTQRawLineReader {
    /// A reader that starts `gzip -dc` through ``ToolProcess`` for a gzip file.
    convenience init(url: URL) throws {
        try self.init(url: url, launcher: ToolProcessChildLauncher())
    }
}
