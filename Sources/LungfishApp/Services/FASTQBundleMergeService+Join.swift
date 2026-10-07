// FASTQBundleMergeService+Join.swift - How a combined FASTQ bundle joins its inputs into one file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension FASTQBundleMergeService {

    /// Appends the bytes of `inputURL` to `outputHandle`. A plain input whose
    /// last byte is not a newline gets one, so its last record and the next
    /// input's first stay apart, the rule `ResolvedSequenceInputs` joins the
    /// files of one bundle by. Before, the two lines ran together and every
    /// record after them fell out of step (Phase 2.1 lane L3). A gzip input is
    /// one member of a multi-member stream, whose last line its own
    /// compressor ended.
    static func appendFile(at inputURL: URL, to outputHandle: FileHandle) throws {
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inputHandle.close() }

        var lastByte: UInt8?
        while true {
            let chunk = inputHandle.readData(ofLength: 1_048_576)
            if chunk.isEmpty { break }
            outputHandle.write(chunk)
            lastByte = chunk.last
        }
        if inputURL.pathExtension.lowercased() != "gz", let lastByte, lastByte != UInt8(ascii: "\n") {
            outputHandle.write(Data([UInt8(ascii: "\n")]))
        }
    }

    /// Interleaves the R1 and R2 files of one paired input with reformat.sh
    /// and returns the provenance step that did it.
    ///
    /// reformat.sh pairs records by position and never reads their names, so
    /// the two files are first read in step by the rule the materializer
    /// applies to the files of one recorded pair
    /// (`FASTQPairInterleaver.interleaveRecordedPair`). Names that carry mate
    /// numbers must be mates, names that carry none pair by position, and the
    /// files must hold as many records each, or the merge stops with that
    /// error. Before, an R2 file out of step with its R1 gave mis-paired reads
    /// without a word (Phase 2.1 lane L3).
    static func interleavePairedInputs(
        r1: URL,
        r2: URL,
        outputURL: URL
    ) async throws -> ProvenanceStep {
        try checkMates(r1: r1, r2: r2)
        let startedAt = Date()
        let runner = NativeToolRunner.shared
        let result = try await runner.run(
            .reformat,
            arguments: [
                "in1=\(r1.path)",
                "in2=\(r2.path)",
                "out=\(outputURL.path)",
                "interleaved=t",
            ],
            environment: await bbToolsEnvironment(),
            timeout: 1800
        )
        guard result.isSuccess else {
            throw FASTQBundleMergeServiceError.toolFailed(
                "reformat.sh interleave failed: \(result.stderr)"
            )
        }
        return ProvenanceStep(
            toolName: NativeTool.reformat.executableName,
            toolVersion: NativeToolRunner.bundledVersions[NativeTool.reformat.rawValue] ?? "unknown",
            argv: result.arguments,
            durableReplayArgv: result.arguments,
            inputs: try [
                ProvenanceFileDescriptor.file(url: r1, format: .fastq, role: .input),
                ProvenanceFileDescriptor.file(url: r2, format: .fastq, role: .input),
            ],
            outputs: [
                try ProvenanceFileDescriptor.file(url: outputURL, format: .fastq, role: .output),
            ],
            exitStatus: Int(result.exitCode),
            wallTimeSeconds: max(0, Date().timeIntervalSince(startedAt)),
            stderr: result.stderr,
            startedAt: startedAt,
            completedAt: Date()
        )
    }

    /// Reads `r1` and `r2` in step by the recorded-pair rule and discards
    /// what it would write, throwing ``FASTQPairInterleaver/InterleaveError``
    /// for a pair of names that are not mates or for files of different
    /// record counts.
    static func checkMates(r1: URL, r2: URL) throws {
        guard let sink = FileHandle(forWritingAtPath: "/dev/null") else {
            throw FASTQBundleMergeServiceError.toolFailed("cannot open /dev/null to check the mates of \(r1.lastPathComponent)")
        }
        defer { try? sink.close() }
        _ = try FASTQPairInterleaver.interleaveRecordedPair(r1: r1, r2: r2, to: sink)
    }

    static func bbToolsEnvironment() async -> [String: String] {
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: existingPath
        )
    }
}
