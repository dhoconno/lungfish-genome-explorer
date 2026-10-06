// ClassificationPipeline+ReadSets.swift - How the Kraken2 pipeline shapes its read inputs for kraken2
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension ClassificationPipeline {

    /// Scratch directory (inside the run's output directory) holding the two
    /// mate files split from a strictly interleaved input for the kraken2 run.
    static let interleavedSplitDirectoryName = ".lungfish-interleaved-split"

    /// Re-checks a request to split one input as interleaved pairs against
    /// the records, through the shared layout resolver.
    ///
    /// kraken2 pairs the split halves by position, so only a strictly
    /// interleaved file may be split. When the file mixes merged reads with
    /// pairs, or holds no adjacent mates at all, the returned config runs
    /// the file unpaired and `warning` says why. A config that did not ask
    /// for interleaved handling is returned unchanged with no warning.
    static func reconcileInterleavedRequest(
        _ config: ClassificationConfig
    ) -> (config: ClassificationConfig, resolution: FASTQInputLayoutResolution?, warning: String?) {
        guard config.interleavedInput, config.inputFiles.count == 1, let source = config.inputFiles.first else {
            return (config, nil, nil)
        }
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [source])
        guard resolution.layout != .strictlyInterleaved else {
            return (config, resolution, nil)
        }
        var adjusted = config
        adjusted.interleavedInput = false
        adjusted.isPairedEnd = false
        adjusted.inputLayout = resolution.classification ?? config.inputLayout
        let warning = "\(source.lastPathComponent) was requested as interleaved pairs, but \(resolution.reason) "
            + "kraken2 pairs split halves by position, so the reads run as single-end instead."
        return (adjusted, resolution, warning)
    }

    /// Splits a strictly interleaved FASTQ into `<stem>_R1.fastq` and
    /// `<stem>_R2.fastq` under `directory`, replacing any earlier split.
    ///
    /// The halves are plain FASTQ (kraken2 reads them directly) and live only
    /// for the kraken2 step; `runPipeline` removes the directory afterwards.
    static func splitInterleavedInput(
        _ source: URL,
        into directory: URL
    ) async throws -> (r1: URL, r2: URL, counts: FASTQPairInterleaver.Counts) {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var stem = source.lastPathComponent
        for suffix in [".gz", ".fastq", ".fq"] where stem.lowercased().hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
        }
        let r1 = directory.appendingPathComponent("\(stem)_R1.fastq")
        let r2 = directory.appendingPathComponent("\(stem)_R2.fastq")

        let worker = Task.detached(priority: .utility) { () throws -> FASTQPairInterleaver.Counts in
            let fm = FileManager.default
            fm.createFile(atPath: r1.path, contents: nil)
            fm.createFile(atPath: r2.path, contents: nil)
            guard let handle1 = FileHandle(forWritingAtPath: r1.path),
                  let handle2 = FileHandle(forWritingAtPath: r2.path) else {
                throw ClassificationPipelineError.interleavedSplitFailed(
                    "cannot open mate files for writing in \(directory.path)"
                )
            }
            defer {
                try? handle1.close()
                try? handle2.close()
            }
            return try FASTQPairInterleaver.deinterleave(interleaved: source, r1: handle1, r2: handle2)
        }
        do {
            let counts = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            return (r1, r2, counts)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }
}

// MARK: - Kraken2 Progress Parsing

/// Parses a Kraken2 stderr progress line and reports it via the progress callback.
///
/// Kraken2 writes lines like:
/// ```
///   12345 sequences (1.2 Mbp) processed
/// ```
///
/// This function extracts the sequence count and reports it in the 0.30--0.80
/// progress range used by the classification pipeline. Since we don't know the
/// total sequence count upfront, we use the count itself as an informational
/// message without computing a fraction.
///
/// - Parameters:
///   - line: A single line from kraken2's stderr output.
///   - progress: The pipeline's progress callback.
func parseKraken2ProgressLine(
    _ line: String,
    progress: @Sendable (Double, String) -> Void
) {
    // Match lines like "  12345 sequences (1.2 Mbp) processed"
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("sequences") && trimmed.contains("processed") else { return }

    // Extract the sequence count (first number in the line)
    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
    guard let countStr = parts.first, let count = Int(countStr) else { return }

    // Report in the kraken2 execution progress range (0.30 -- 0.80).
    // We can't compute a true fraction since we don't know total reads,
    // so report a fixed 0.50 progress with a descriptive message.
    let formattedCount: String
    if count >= 1_000_000 {
        formattedCount = String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        formattedCount = String(format: "%.1fK", Double(count) / 1_000)
    } else {
        formattedCount = String(count)
    }

    progress(0.50, "Classifying: \(formattedCount) sequences processed...")
}

// MARK: - Read sets with pairs and single reads (decisions 1 and 2)

/// A Kraken2 run whose fragment counts disagree with the read set it was
/// given. kraken2 classifies a staged single read as a pair whose second
/// mate is empty, so a kraken2 that handled empty mates differently would
/// show here first.
public enum KrakenFragmentGuardError: LocalizedError, Sendable, Equatable {
    case processedCountDiffers(expected: Int, reported: Int)
    case perReadLineCountDiffers(expected: Int, lines: Int)

    public var errorDescription: String? {
        switch self {
        case .processedCountDiffers(let expected, let reported):
            return "kraken2 reported \(reported) sequences processed, but the read set holds \(expected) fragments (pairs plus single reads)."
        case .perReadLineCountDiffers(let expected, let lines):
            return "The kraken2 per-read output has \(lines) lines, but the read set holds \(expected) fragments (pairs plus single reads)."
        }
    }
}

extension ClassificationPipeline {

    /// The provenance step that writes each header-only mate.
    static let singleReadMateStagingToolName = "Lungfish Classification Single-Read Mate Staging"

    /// The provenance step that copies an input into the compression of R1.
    static let inputCompressionStagingToolName = "Lungfish Classification Input Compression Staging"

    /// Records the splits the read-set plan wrote and stages a header-only
    /// mate for each file of single reads, as provenance steps. Returns the
    /// step IDs kraken2 depends on. A run of single reads or pairs only
    /// records nothing.
    func recordReadSetInputSteps(
        config: ClassificationConfig,
        runID: UUID,
        recorder: ProvenanceRecorder,
        dependsOn: [UUID]
    ) async throws -> [UUID] {
        var stepIDs: [UUID] = []
        for step in config.readSetPlan?.steps ?? [] {
            let execution = try step.stepExecution(toolVersion: WorkflowRun.currentAppVersion)
            let stepID = await recorder.recordStep(
                runID: runID,
                toolName: execution.toolName,
                toolVersion: execution.toolVersion,
                command: execution.command,
                resolvedOptions: execution.resolvedOptions,
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                inputs: execution.inputs,
                outputs: execution.outputs,
                exitCode: 0,
                wallTime: execution.wallTime ?? 0,
                dependsOn: dependsOn
            )
            if let stepID { stepIDs.append(stepID) }
        }
        guard !config.singleReadFiles.isEmpty else { return stepIDs }

        let startedAt = Date()
        let staged = try Self.stageEmptyMates(for: config)
        let command = ["LungfishWorkflow", "stage-empty-mates"] + staged.flatMap { item in
            ["--in", item.single.path] + (item.copy.map { ["--copy", $0.path] } ?? []) + ["--out", item.mate.path]
        }
        let stepID = await recorder.recordStep(
            runID: runID,
            toolName: Self.singleReadMateStagingToolName,
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            resolvedOptions: [
                "singleReadFiles": .integer(staged.count),
                "records": .integer(staged.reduce(0) { $0 + $1.records }),
                "recordsPerFile": .array(staged.map { .integer($0.records) }),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: staged.map { ProvenanceRecorder.fileRecord(url: $0.single, format: .fastq, role: .input) },
            outputs: staged.flatMap { [$0.copy, $0.mate].compactMap { $0 } }
                .map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) },
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            dependsOn: dependsOn + stepIDs
        )
        if let stepID { stepIDs.append(stepID) }
        return stepIDs
    }

    /// The single-read files and their staged mates kraken2 reads beside the
    /// pair, for the kraken2 step's inputs.
    static func readSetExtraInputs(_ config: ClassificationConfig) -> [URL] {
        config.singleReadFiles.flatMap { [config.kraken2SingleReadURL(for: $0), config.emptyMateURL(for: $0)] }
    }

    /// Writes the header-only mate of every file of single reads, and a copy
    /// of the file in the compression of R1 when it has the other one.
    static func stageEmptyMates(
        for config: ClassificationConfig
    ) throws -> [(single: URL, copy: URL?, mate: URL, records: Int)] {
        var staged: [(single: URL, copy: URL?, mate: URL, records: Int)] = []
        do {
            for single in config.singleReadFiles {
                let mate = config.emptyMateURL(for: single)
                try FileManager.default.createDirectory(
                    at: mate.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let copy = config.stagedSingleReadCopyURL(for: single)
                if let copy { try writeCopy(of: single, to: copy) }
                let records = try writeEmptyMate(of: single, to: mate)
                staged.append((single, copy, mate, records))
            }
        } catch {
            removeStagedMates(for: config)
            throw error
        }
        return staged
    }

    /// Writes `copy` with the records of `single`, gzip-compressed when
    /// `copy` ends in `.gz` and decompressed otherwise.
    static func writeCopy(of single: URL, to copy: URL) throws {
        if copy.pathExtension.lowercased() == "gz" {
            _ = try gzipCompressFASTQ(sourceURL: single, outputURL: copy, failureDescription: "the single reads")
            return
        }
        let reader = try FASTQRawLineReader(url: single)
        defer { reader.close() }
        FileManager.default.createFile(atPath: copy.path, contents: nil)
        let handle = try FileHandle(forWritingTo: copy)
        defer { try? handle.close() }
        while let chunk = try reader.readChunk() {
            try handle.write(contentsOf: chunk)
        }
    }

    /// Writes `mate` with each header of `single`, in order, followed by an
    /// empty sequence line, `+` and an empty quality line, gzip-compressed
    /// when `mate` ends in `.gz`. Returns the number of records.
    static func writeEmptyMate(of single: URL, to mate: URL) throws -> Int {
        guard mate.pathExtension.lowercased() == "gz" else { return try writeHeaders(of: single, to: mate) }
        let plain = mate.deletingPathExtension()
        defer { try? FileManager.default.removeItem(at: plain) }
        let records = try writeHeaders(of: single, to: plain)
        _ = try gzipCompressFASTQ(sourceURL: plain, outputURL: mate, failureDescription: "the empty mate")
        return records
    }

    /// The plain form of ``writeEmptyMate(of:to:)``.
    private static func writeHeaders(of single: URL, to mate: URL) throws -> Int {
        let reader = try FASTQRawLineReader(url: single)
        defer { reader.close() }
        FileManager.default.createFile(atPath: mate.path, contents: nil)
        let handle = try FileHandle(forWritingTo: mate)
        defer { try? handle.close() }
        var buffer: [UInt8] = []
        var lineNumber = 0
        var records = 0
        while let line = try reader.nextLine() {
            if lineNumber % 4 == 0 {
                guard line.first == UInt8(ascii: "@") else {
                    throw FASTQPairInterleaver.InterleaveError.malformedRecord(
                        file: single.lastPathComponent,
                        recordNumber: records + 1,
                        reason: "header line does not start with '@'"
                    )
                }
                buffer.append(contentsOf: line)
                buffer.append(contentsOf: Array("\n\n+\n\n".utf8))
                records += 1
                if buffer.count >= 4 * 1_048_576 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            lineNumber += 1
        }
        guard lineNumber % 4 == 0 else {
            throw FASTQPairInterleaver.InterleaveError.malformedRecord(
                file: single.lastPathComponent,
                recordNumber: records,
                reason: "file ends inside the record"
            )
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        return records
    }

    /// Removes the staged mates and copies once kraken2 has read them.
    static func removeStagedMates(for config: ClassificationConfig) {
        let fm = FileManager.default
        for single in config.singleReadFiles {
            try? fm.removeItem(at: config.emptyMateURL(for: single))
            if let copy = config.stagedSingleReadCopyURL(for: single) { try? fm.removeItem(at: copy) }
        }
        // The inputs folder goes too when the staged mates were all it held.
        if let mate = config.singleReadFiles.first.map(config.emptyMateURL(for:)) {
            let folder = mate.deletingLastPathComponent()
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// Checks that kraken2 classified exactly the fragments of the read set.
    /// Its "N sequences processed" count and the per-read output's line count
    /// must both equal pairs plus single reads. A run whose plan held no pairs
    /// is not checked. kraken2 run with `--quiet` prints no summary, and then
    /// the line count is checked alone and the returned note says so.
    @discardableResult
    static func verifyFragmentCount(config: ClassificationConfig, kraken2Stderr: String) throws -> String? {
        guard let expected = config.fragmentComposition?.fragmentCount else { return nil }
        let reported = sequencesProcessed(in: kraken2Stderr)
        if let reported, reported != expected {
            throw KrakenFragmentGuardError.processedCountDiffers(expected: expected, reported: reported)
        }
        let lines = try lineCount(of: config.outputURL)
        guard lines == expected else {
            throw KrakenFragmentGuardError.perReadLineCountDiffers(expected: expected, lines: lines)
        }
        return reported == nil
            ? "kraken2 printed no processed-sequence count, so only its \(lines) per-read lines were checked against the \(expected) fragments."
            : nil
    }

    /// The count in kraken2's "N sequences (X Mbp) processed in ..." line.
    static func sequencesProcessed(in stderr: String) -> Int? {
        for line in stderr.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("sequences ("), trimmed.contains("processed") else { continue }
            if let first = trimmed.split(separator: " ").first, let count = Int(first) {
                return count
            }
        }
        return nil
    }

    /// The lines of a text file, the last counted even without a newline.
    static func lineCount(of url: URL) throws -> Int {
        let reader = try FASTQRawLineReader(url: url)
        defer { reader.close() }
        var lines = 0
        var lastByte: UInt8 = 0x0A
        while let chunk = try reader.readChunk() {
            if chunk.isEmpty { continue }
            for byte in chunk where byte == 0x0A { lines += 1 }
            lastByte = chunk[chunk.count - 1]
        }
        return lastByte == 0x0A ? lines : lines + 1
    }
}
