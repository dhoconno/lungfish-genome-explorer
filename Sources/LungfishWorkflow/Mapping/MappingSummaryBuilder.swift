// MappingSummaryBuilder.swift - Per-contig mapping summary construction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

public enum MappingSummaryBuilderError: Error, LocalizedError, Sendable {
    case samtoolsCoverageFailed(String)
    case samtoolsViewFailed(String)

    public var errorDescription: String? {
        switch self {
        case .samtoolsCoverageFailed(let detail):
            return "samtools coverage failed: \(detail)"
        case .samtoolsViewFailed(let detail):
            return "samtools view failed: \(detail)"
        }
    }
}

public enum MappingSummaryBuilder {
    /// Above this sortedBAM size, `streamSAMView`'s `samtools view` output (roughly
    /// proportional to file size, and buffered entirely into a single in-memory `String`
    /// by `runProcessCapturingOutput`) is skipped rather than materialized, to avoid an
    /// unbounded memory spike while building what is ultimately a summary/display artifact.
    /// TODO: replace this guard with a streaming parse of `samtools view` output (accumulate
    /// per-contig `ViewMetrics` incrementally instead of buffering the full text) so summaries
    /// for large BAMs can still be computed instead of skipped.
    public static let sortedBAMMemoryGuardBytes: UInt64 = 2_147_483_648 // 2 GiB

    public static func build(
        sortedBAMURL: URL,
        totalReads: Int,
        readGroupIDs: Set<String> = [],
        runner: NativeToolRunner = .shared,
        timeout: TimeInterval = 3_600,
        includeUnmappedReferenceRows: Bool = true,
        reportWarning: (@Sendable (String) -> Void)? = nil
    ) async throws -> [MappingContigSummary] {
        let coverageOutput: String
        if readGroupIDs.isEmpty {
            let coverageResult = try await runner.run(
                .samtools,
                arguments: ["coverage", sortedBAMURL.path],
                workingDirectory: sortedBAMURL.deletingLastPathComponent(),
                timeout: timeout
            )
            guard coverageResult.isSuccess else {
                throw MappingSummaryBuilderError.samtoolsCoverageFailed(coverageResult.stderr)
            }
            coverageOutput = coverageResult.stdout
        } else {
            coverageOutput = try await filteredCoverageOutput(
                sortedBAMURL: sortedBAMURL,
                readGroupIDs: readGroupIDs,
                runner: runner
            )
        }

        let sortedBAMSizeBytes = (try? ProvenanceFileHasher.fileSize(of: sortedBAMURL)) ?? 0
        guard sortedBAMSizeBytes <= sortedBAMMemoryGuardBytes else {
            reportWarning?(
                "Skipping per-contig identity/MAPQ summary for \(sortedBAMURL.lastPathComponent): " +
                "sorted BAM is \(sortedBAMSizeBytes) bytes, over the \(sortedBAMMemoryGuardBytes)-byte " +
                "(2 GB) in-memory samtools-view guard. Coverage/depth rows are still reported below; " +
                "identity and MAPQ columns are omitted for this file."
            )
            return try buildSummaries(
                coverageOutput: coverageOutput,
                viewOutput: "",
                totalReads: totalReads,
                includeUnmappedReferenceRows: includeUnmappedReferenceRows
            )
        }

        let viewOutput = try await streamSAMView(
            sortedBAMURL: sortedBAMURL,
            runner: runner,
            timeout: timeout,
            readGroupIDs: readGroupIDs
        )

        return try buildSummaries(
            coverageOutput: coverageOutput,
            viewOutput: viewOutput,
            totalReads: totalReads,
            includeUnmappedReferenceRows: includeUnmappedReferenceRows
        )
    }

    public static func buildSummaries(
        coverageOutput: String,
        viewOutput: String,
        totalReads: Int,
        includeUnmappedReferenceRows: Bool = true
    ) throws -> [MappingContigSummary] {
        let rows = parseCoverageRows(coverageOutput)
        let identities = accumulateViewMetrics(viewOutput)
        let displayedRows = includeUnmappedReferenceRows ? rows : rows.filter { $0.mappedReads > 0 }

        return displayedRows.map { row in
            let metrics = identities[row.name] ?? ViewMetrics()
            return MappingContigSummary(
                contigName: row.name,
                contigLength: row.length,
                mappedReads: row.mappedReads,
                mappedReadPercent: totalReads > 0
                    ? (Double(row.mappedReads) / Double(totalReads) * 100)
                    : 0,
                meanDepth: row.meanDepth,
                coverageBreadth: row.coverageBreadth,
                medianMAPQ: metrics.medianMapQ,
                meanIdentity: metrics.meanIdentity
            )
        }
    }

    private static func parseCoverageRows(_ output: String) -> [CoverageRow] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 9 else { return nil }
            let first = String(fields[0])
            guard !first.hasPrefix("#"), first != "rname" else { return nil }
            guard
                let startPos = Int(fields[1]),
                let endPos = Int(fields[2]),
                let mappedReads = Int(fields[3]),
                let coverageRaw = Double(fields[5]),
                let meanDepth = Double(fields[6])
            else {
                return nil
            }
            return CoverageRow(
                name: first,
                length: max(0, endPos - startPos + 1),
                mappedReads: mappedReads,
                coverageBreadth: normalizeCoverage(coverageRaw),
                meanDepth: meanDepth
            )
        }
    }

    private static func normalizeCoverage(_ raw: Double) -> Double {
        raw > 1 ? raw / 100 : raw
    }

    private static func accumulateViewMetrics(_ viewOutput: String) -> [String: ViewMetrics] {
        var accumulators: [String: ViewAccumulator] = [:]

        for line in viewOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let read = SAMParser.parseLine(line) else { continue }
            let alignedQueryBases = read.cigar.reduce(into: 0) { partial, op in
                guard op.consumesQuery, op.op != .softClip else { return }
                partial += op.length
            }
            guard alignedQueryBases > 0 else { continue }
            let editDistance = max(0, read.editDistance ?? 0)
            var accumulator = accumulators[read.chromosome, default: ViewAccumulator()]
            accumulator.mapqs.append(Int(read.mapq))
            accumulator.alignedQueryBases += alignedQueryBases
            accumulator.matchedBases += max(0, alignedQueryBases - editDistance)
            accumulators[read.chromosome] = accumulator
        }

        return accumulators.mapValues { $0.finalize() }
    }

    private static func streamSAMView(
        sortedBAMURL: URL,
        runner: NativeToolRunner,
        timeout: TimeInterval,
        readGroupIDs: Set<String> = []
    ) async throws -> String {
        let samtoolsPath = try await runner.findTool(.samtools)
        let workingDirectory = sortedBAMURL.deletingLastPathComponent()
        if readGroupIDs.isEmpty {
            return try await runProcessCapturingOutput(
                executableURL: samtoolsPath,
                arguments: ["view", sortedBAMURL.path],
                workingDirectory: workingDirectory,
                timeout: timeout
            )
        }
        return try await withReadGroupList(readGroupIDs) { listURL in
            try await runProcessCapturingOutput(
                executableURL: samtoolsPath,
                arguments: ["view", "-R", listURL.path, sortedBAMURL.path],
                workingDirectory: workingDirectory,
                timeout: timeout
            )
        }
    }

    /// `samtools coverage` has no read-group option.  Feed it the exact
    /// `samtools view -R` stream instead, keeping multiple RGs for one SM in
    /// one unioned calculation (not a sum of separately-covered regions).
    private static func filteredCoverageOutput(
        sortedBAMURL: URL,
        readGroupIDs: Set<String>,
        runner: NativeToolRunner
    ) async throws -> String {
        let samtoolsPath = try await runner.findTool(.samtools)
        return try await withReadGroupList(readGroupIDs) { listURL in
            try await Task.detached {
                let coverage = Process()
                coverage.executableURL = samtoolsPath
                coverage.arguments = ["coverage", "-"]
                coverage.currentDirectoryURL = sortedBAMURL.deletingLastPathComponent()
                let output = Pipe()
                let error = Pipe()
                coverage.standardOutput = output
                coverage.standardError = error

                let view = Process()
                view.executableURL = samtoolsPath
                view.arguments = ["view", "-h", "-R", listURL.path, sortedBAMURL.path]
                view.currentDirectoryURL = sortedBAMURL.deletingLastPathComponent()
                view.standardOutput = coverage.standardInput

                try coverage.run()
                try view.run()
                view.waitUntilExit()
                (coverage.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
                coverage.waitUntilExit()
                let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                guard view.terminationStatus == 0, coverage.terminationStatus == 0 else {
                    throw MappingSummaryBuilderError.samtoolsCoverageFailed(stderr)
                }
                return stdout
            }.value
        }
    }

    private static func withReadGroupList<T: Sendable>(
        _ readGroupIDs: Set<String>,
        operation: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-read-groups-\(UUID().uuidString).txt")
        try readGroupIDs.sorted().joined(separator: "\n").appending("\n")
            .write(to: listURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: listURL) }
        return try await operation(listURL)
    }

    /// Runs a process and captures stdout, draining stdout and stderr concurrently on
    /// background queues so that a child process which fills the ~64KB stderr pipe buffer
    /// while stdout is still being read cannot deadlock against this caller (F36).
    ///
    /// Wired to `withTaskCancellationHandler` + `NativeProcessCancellationHandle` /
    /// `NativeProcessRunState` (matching `PBAAClusteringPipeline.runProcess`) so that
    /// cancelling the enclosing Task terminates the underlying `samtools view` process tree
    /// instead of leaking it to run to completion (or to the timeout) unattended.
    static func runProcessCapturingOutput(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL?,
        timeout: TimeInterval
    ) async throws -> String {
        let cancellationHandle = NativeProcessCancellationHandle()
        let runState = NativeProcessRunState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let stdoutBox = MappingSummaryDataBox()
                let stderrBox = MappingSummaryDataBox()
                let group = DispatchGroup()
                let startOutputDrain: @Sendable () -> Void = {
                    group.enter()
                    DispatchQueue.global().async {
                        stdoutBox.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global().async {
                        stderrBox.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                }
                cancellationHandle.store(process)

                // DispatchWorkItem is not Sendable, but it is only ever cancelled from
                // process.terminationHandler/the process.run() catch block below, never
                // concurrently with its own execution (mirrors CondaManager.runTool's
                // timeoutItem, same rationale).
                nonisolated(unsafe) let timeoutWorkItem = DispatchWorkItem {
                    runState.markTimedOut()
                    cancellationHandle.requestProcessTreeTermination()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

                process.terminationHandler = { terminatedProcess in
                    group.notify(queue: .global(qos: .userInitiated)) {
                        timeoutWorkItem.cancel()
                        cancellationHandle.clear(terminatedProcess)
                        runState.resumeOnce { reason in
                            switch reason {
                            case .cancelled, .timedOut:
                                continuation.resume(throwing: CancellationError())
                            case .completed:
                                let stdout = String(data: stdoutBox.value, encoding: .utf8) ?? ""
                                let stderr = String(data: stderrBox.value, encoding: .utf8) ?? ""
                                guard terminatedProcess.terminationStatus == 0 else {
                                    continuation.resume(throwing: MappingSummaryBuilderError.samtoolsViewFailed(stderr))
                                    return
                                }
                                continuation.resume(returning: stdout)
                            }
                        }
                    }
                }

                do {
                    startOutputDrain()
                    try process.run()
                    cancellationHandle.terminateIfRequested()
                    if runState.isCancelled {
                        cancellationHandle.requestProcessTreeTermination()
                    }
                } catch {
                    timeoutWorkItem.cancel()
                    cancellationHandle.clear(process)
                    stdoutPipe.fileHandleForWriting.closeFile()
                    stderrPipe.fileHandleForWriting.closeFile()
                    runState.resumeOnce { reason in
                        switch reason {
                        case .cancelled, .timedOut:
                            continuation.resume(throwing: CancellationError())
                        case .completed:
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            runState.markCancelled()
            cancellationHandle.requestProcessTreeTermination()
        }
    }
}

/// Mutable box used to hand pipe-read results back from a background `DispatchQueue.global()`
/// block. Access is synchronized externally via `DispatchGroup.wait()` before the value is read,
/// so no two threads ever touch `value` concurrently.
private final class MappingSummaryDataBox: @unchecked Sendable {
    var value = Data()
}

private struct CoverageRow: Sendable, Equatable {
    let name: String
    let length: Int
    let mappedReads: Int
    let coverageBreadth: Double
    let meanDepth: Double
}

private struct ViewAccumulator: Sendable, Equatable {
    var mapqs: [Int] = []
    var alignedQueryBases = 0
    var matchedBases = 0

    func finalize() -> ViewMetrics {
        let sortedMapqs = mapqs.sorted()
        let medianMapQ: Double
        if sortedMapqs.isEmpty {
            medianMapQ = 0
        } else if sortedMapqs.count.isMultiple(of: 2) {
            let upper = sortedMapqs.count / 2
            medianMapQ = Double(sortedMapqs[upper - 1] + sortedMapqs[upper]) / 2
        } else {
            medianMapQ = Double(sortedMapqs[sortedMapqs.count / 2])
        }
        let meanIdentity = alignedQueryBases > 0
            ? Double(matchedBases) / Double(alignedQueryBases)
            : 0
        return ViewMetrics(
            medianMapQ: medianMapQ,
            meanIdentity: meanIdentity
        )
    }
}

private struct ViewMetrics: Sendable, Equatable {
    var medianMapQ: Double = 0
    var meanIdentity: Double = 0
}
