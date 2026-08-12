// MappingSummaryBuilder.swift - Per-contig mapping summary construction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
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

    /// Historical threshold retained for source compatibility with callers that use
    /// it to construct fixtures. It is deliberately not a processing limit: SAM
    /// metrics are streamed regardless of compressed BAM size.
    public static let sortedBAMMemoryGuardBytes: UInt64 = 2_147_483_648

    public static func build(
        sortedBAMURL: URL,
        totalReads: Int,
        readGroupIDs: Set<String> = [],
        runner: NativeToolRunner = .shared,
        timeout: TimeInterval = 3_600,
        includeUnmappedReferenceRows: Bool = true,
        reportWarning: (@Sendable (String) -> Void)? = nil
    ) async throws -> [MappingContigSummary] {
        let effectiveTotalReads: Int
        let coverageOutput: String
        if readGroupIDs.isEmpty {
            effectiveTotalReads = totalReads
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
                runner: runner,
                timeout: timeout
            )
            effectiveTotalReads = try await filteredReadCount(
                sortedBAMURL: sortedBAMURL,
                readGroupIDs: readGroupIDs,
                runner: runner,
                timeout: timeout
            )
        }

        let identities = try await streamSAMViewMetrics(
            sortedBAMURL: sortedBAMURL,
            runner: runner,
            timeout: timeout,
            readGroupIDs: readGroupIDs
        )

        return try buildSummaries(
            coverageOutput: coverageOutput,
            identities: identities,
            totalReads: effectiveTotalReads,
            includeUnmappedReferenceRows: includeUnmappedReferenceRows
        )
    }

    public static func buildSummaries(
        coverageOutput: String,
        viewOutput: String,
        totalReads: Int,
        includeUnmappedReferenceRows: Bool = true
    ) throws -> [MappingContigSummary] {
        let identities = accumulateViewMetrics(viewOutput)
        return try buildSummaries(
            coverageOutput: coverageOutput,
            identities: identities,
            totalReads: totalReads,
            includeUnmappedReferenceRows: includeUnmappedReferenceRows
        )
    }

    private static func buildSummaries(
        coverageOutput: String,
        identities: [String: ViewMetrics],
        totalReads: Int,
        includeUnmappedReferenceRows: Bool
    ) throws -> [MappingContigSummary] {
        let rows = parseCoverageRows(coverageOutput)
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
            appendViewMetrics(for: line, accumulators: &accumulators)
        }

        return accumulators.mapValues { $0.finalize() }
    }

    private static func streamSAMViewMetrics(
        sortedBAMURL: URL,
        runner: NativeToolRunner,
        timeout: TimeInterval,
        readGroupIDs: Set<String> = []
    ) async throws -> [String: ViewMetrics] {
        let samtoolsPath = try await runner.findTool(.samtools)
        let workingDirectory = sortedBAMURL.deletingLastPathComponent()
        let metrics = StreamingSAMMetricsAccumulator()
        if readGroupIDs.isEmpty {
            try await runProcessStreamingOutput(
                executableURL: samtoolsPath,
                arguments: ["view", sortedBAMURL.path],
                workingDirectory: workingDirectory,
                timeout: timeout,
                consumeStdout: { metrics.consume($0) }
            )
            return metrics.finalize()
        }
        return try await withReadGroupList(readGroupIDs) { listURL in
            try await runProcessStreamingOutput(
                executableURL: samtoolsPath,
                arguments: ["view", "-R", listURL.path, sortedBAMURL.path],
                workingDirectory: workingDirectory,
                timeout: timeout,
                consumeStdout: { metrics.consume($0) }
            )
            return metrics.finalize()
        }
    }

    /// `samtools coverage` has no read-group option.  Feed it the exact
    /// `samtools view -R` stream instead, keeping multiple RGs for one SM in
    /// one unioned calculation (not a sum of separately-covered regions).
    private static func filteredCoverageOutput(
        sortedBAMURL: URL,
        readGroupIDs: Set<String>,
        runner: NativeToolRunner,
        timeout: TimeInterval
    ) async throws -> String {
        let samtoolsPath = try await runner.findTool(.samtools)
        let viewCancellationHandle = NativeProcessCancellationHandle()
        let coverageCancellationHandle = NativeProcessCancellationHandle()
        let runState = NativeProcessRunState()
        return try await withReadGroupList(readGroupIDs) { listURL in
            try await withTaskCancellationHandler {
                try await Task.detached {
                    try runFilteredCoverageSynchronously(
                        samtoolsPath: samtoolsPath,
                        sortedBAMURL: sortedBAMURL,
                        listURL: listURL,
                        timeout: timeout,
                        viewCancellationHandle: viewCancellationHandle,
                        coverageCancellationHandle: coverageCancellationHandle,
                        runState: runState
                    )
                }.value
            } onCancel: {
                runState.markCancelled()
                viewCancellationHandle.requestProcessTreeTermination()
                coverageCancellationHandle.requestProcessTreeTermination()
            }
        }
    }

    private static func runFilteredCoverageSynchronously(
        samtoolsPath: URL,
        sortedBAMURL: URL,
        listURL: URL,
        timeout: TimeInterval,
        viewCancellationHandle: NativeProcessCancellationHandle,
        coverageCancellationHandle: NativeProcessCancellationHandle,
        runState: NativeProcessRunState
    ) throws -> String {
        let coverage = Process()
        coverage.executableURL = samtoolsPath
        coverage.arguments = ["coverage", "-"]
        coverage.currentDirectoryURL = sortedBAMURL.deletingLastPathComponent()
        let output = Pipe()
        let error = Pipe()
        let input = Pipe()
        coverage.standardOutput = output
        coverage.standardError = error
        coverage.standardInput = input

        let view = Process()
        view.executableURL = samtoolsPath
        view.arguments = ["view", "-h", "-R", listURL.path, sortedBAMURL.path]
        view.currentDirectoryURL = sortedBAMURL.deletingLastPathComponent()
        // This is an actual pipeline, not an assignment to a nil default stdin.
        view.standardOutput = input

        coverageCancellationHandle.store(coverage)
        viewCancellationHandle.store(view)
        defer {
            coverageCancellationHandle.clear(coverage)
            viewCancellationHandle.clear(view)
        }

        let stdoutBox = MappingSummaryDataBox()
        let stderrBox = MappingSummaryDataBox()
        let drainGroup = DispatchGroup()
        for (handle, box) in [(output.fileHandleForReading, stdoutBox), (error.fileHandleForReading, stderrBox)] {
            drainGroup.enter()
            DispatchQueue.global().async {
                box.value = handle.readDataToEndOfFile()
                drainGroup.leave()
            }
        }
        let timeoutItem = DispatchWorkItem {
            runState.markTimedOut()
            viewCancellationHandle.requestProcessTreeTermination()
            coverageCancellationHandle.requestProcessTreeTermination()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        defer { timeoutItem.cancel() }
        try coverage.run()
        coverageCancellationHandle.terminateIfRequested()
        do {
            try view.run()
            viewCancellationHandle.terminateIfRequested()
        } catch {
            input.fileHandleForWriting.closeFile()
            coverageCancellationHandle.requestProcessTreeTermination()
            coverage.waitUntilExit()
            drainGroup.wait()
            if runState.isCancelled { throw CancellationError() }
            throw error
        }
        view.waitUntilExit()
        input.fileHandleForWriting.closeFile()
        coverage.waitUntilExit()
        drainGroup.wait()
        let stdout = String(data: stdoutBox.value, encoding: .utf8) ?? ""
        let stderr = String(data: stderrBox.value, encoding: .utf8) ?? ""
        if runState.isCancelled { throw CancellationError() }
        guard view.terminationStatus == 0, coverage.terminationStatus == 0 else {
            throw MappingSummaryBuilderError.samtoolsCoverageFailed(stderr)
        }
        return stdout
    }

    private static func filteredReadCount(
        sortedBAMURL: URL,
        readGroupIDs: Set<String>,
        runner: NativeToolRunner,
        timeout: TimeInterval
    ) async throws -> Int {
        let samtoolsPath = try await runner.findTool(.samtools)
        return try await withReadGroupList(readGroupIDs) { listURL in
            let output = try await runProcessCapturingOutput(
                executableURL: samtoolsPath,
                arguments: ["view", "-c", "-R", listURL.path, sortedBAMURL.path],
                workingDirectory: sortedBAMURL.deletingLastPathComponent(),
                timeout: timeout
            )
            return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
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

    /// Runs a process without retaining stdout. Chunks are delivered in order
    /// to the caller while stderr remains concurrently drained for diagnostics.
    private static func runProcessStreamingOutput(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        consumeStdout: @escaping @Sendable (Data) -> Void
    ) async throws {
        let cancellationHandle = NativeProcessCancellationHandle()
        let runState = NativeProcessRunState()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let stderrBox = MappingSummaryDataBox()
                let group = DispatchGroup()
                let startOutputDrain: @Sendable () -> Void = {
                    group.enter()
                    DispatchQueue.global().async {
                        while true {
                            let chunk = stdoutPipe.fileHandleForReading.availableData
                            guard !chunk.isEmpty else { break }
                            consumeStdout(chunk)
                        }
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global().async {
                        stderrBox.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                }
                cancellationHandle.store(process)

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
                                guard terminatedProcess.terminationStatus == 0 else {
                                    let stderr = String(data: stderrBox.value, encoding: .utf8) ?? ""
                                    continuation.resume(throwing: MappingSummaryBuilderError.samtoolsViewFailed(stderr))
                                    return
                                }
                                continuation.resume()
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

/// Bounded incremental SAM accumulator. It retains only an incomplete final
/// line plus compact per-contig statistics, never the full samtools stream.
private final class StreamingSAMMetricsAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var accumulators: [String: ViewAccumulator] = [:]

    func consume(_ chunk: Data) {
        lock.lock()
        pending.append(chunk)
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            let line = String(decoding: pending[start..<newline], as: UTF8.self)
            appendViewMetrics(for: Substring(line), accumulators: &accumulators)
            start = pending.index(after: newline)
        }
        if start != pending.startIndex {
            pending.removeSubrange(..<start)
        }
        lock.unlock()
    }

    func finalize() -> [String: ViewMetrics] {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty {
            let line = String(decoding: pending, as: UTF8.self)
            appendViewMetrics(for: Substring(line), accumulators: &accumulators)
            pending.removeAll(keepingCapacity: false)
        }
        return accumulators.mapValues { $0.finalize() }
    }
}

private func appendViewMetrics(
    for line: Substring,
    accumulators: inout [String: ViewAccumulator]
) {
    guard let read = SAMParser.parseLine(line) else { return }
    let alignedQueryBases = read.cigar.reduce(into: 0) { partial, op in
        guard op.consumesQuery, op.op != .softClip else { return }
        partial += op.length
    }
    guard alignedQueryBases > 0 else { return }
    let editDistance = max(0, read.editDistance ?? 0)
    var accumulator = accumulators[read.chromosome, default: ViewAccumulator()]
    accumulator.record(
        mapQ: Int(read.mapq),
        alignedQueryBases: alignedQueryBases,
        matchedBases: max(0, alignedQueryBases - editDistance)
    )
    accumulators[read.chromosome] = accumulator
}

private struct CoverageRow: Sendable, Equatable {
    let name: String
    let length: Int
    let mappedReads: Int
    let coverageBreadth: Double
    let meanDepth: Double
}

private struct ViewAccumulator: Sendable, Equatable {
    private var mapqCounts = Array(repeating: 0, count: 256)
    private var mapqTotal = 0
    var alignedQueryBases = 0
    var matchedBases = 0

    mutating func record(mapQ: Int, alignedQueryBases: Int, matchedBases: Int) {
        mapqCounts[min(max(0, mapQ), mapqCounts.count - 1)] += 1
        mapqTotal += 1
        self.alignedQueryBases += alignedQueryBases
        self.matchedBases += matchedBases
    }

    func finalize() -> ViewMetrics {
        let medianMapQ: Double
        if mapqTotal == 0 {
            medianMapQ = 0
        } else {
            let lowerRank = (mapqTotal - 1) / 2
            let upperRank = mapqTotal / 2
            var seen = 0
            var lower: Int?
            var upper: Int?
            for (mapQ, count) in mapqCounts.enumerated() where count > 0 {
                let next = seen + count
                if lower == nil, lowerRank < next { lower = mapQ }
                if upperRank < next {
                    upper = mapQ
                    break
                }
                seen = next
            }
            medianMapQ = Double((lower ?? 0) + (upper ?? 0)) / 2
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
