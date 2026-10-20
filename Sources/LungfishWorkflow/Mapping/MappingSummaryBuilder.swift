// MappingSummaryBuilder.swift - Per-contig mapping summary construction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

public enum MappingSummaryBuilderError: Error, LocalizedError, Sendable {
    case samtoolsCoverageFailed(String)
    case samtoolsViewFailed(String)
    /// The step ran past its time limit and its processes were stopped.
    case samtoolsTimedOut(step: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .samtoolsCoverageFailed(let detail):
            return "samtools coverage failed: \(detail)"
        case .samtoolsViewFailed(let detail):
            return "samtools view failed: \(detail)"
        case .samtoolsTimedOut(let step, let seconds):
            return "\(step) did not finish within \(Int(seconds.rounded(.up))) seconds and was stopped"
        }
    }
}

/// The per-reference rows of one mapping summary, with how many reference
/// sequences the coverage report listed and how many of them the rows leave
/// out (BIO ruling Q-S3). `rows.count + unalignedReferenceCount` always
/// equals `referenceCount`.
public struct MappingContigSummaryTable: Sendable, Equatable {
    /// The rows kept, in the order `samtools coverage` listed them.
    public let rows: [MappingContigSummary]
    /// Every reference sequence `samtools coverage` reported, one per `@SQ` line of the BAM.
    public let referenceCount: Int
    /// The reference sequences left out because no alignment record of any kind names them.
    public let unalignedReferenceCount: Int
}

public enum MappingSummaryBuilder {

    /// Historical threshold retained for source compatibility with callers that use
    /// it to construct fixtures. It is deliberately not a processing limit: SAM
    /// metrics are streamed regardless of compressed BAM size.
    public static let sortedBAMMemoryGuardBytes: UInt64 = 2_147_483_648

    /// samtools filter flags used everywhere LGE counts *mapped* reads rather
    /// than alignment records: excludes unmapped, secondary and supplementary
    /// alignments (as well as QC-fail and duplicate records, samtools
    /// coverage's own defaults) so per-contig mapped-read counts share one
    /// consistent primary-read numerator with the flagstat-derived
    /// `mappedReads`.
    static let primaryMappedReadExclusionFlags = "UNMAP,SECONDARY,SUPPLEMENTARY,QCFAIL,DUP"

    /// samtools filter flags used to count primary *records* regardless of
    /// mapped status (excludes only secondary and supplementary alignments).
    /// This is the correct denominator for a mapped-read percentage: it
    /// should equal flagstat's "primary" count. Previously this denominator
    /// counted every alignment record, including unmapped, secondary and
    /// supplementary ones.
    static let primaryRecordExclusionFlags = "SECONDARY,SUPPLEMENTARY,QCFAIL,DUP"

    /// Builds the rows of `sortedBAMURL`, one per reference sequence. With
    /// `includeUnmappedReferenceRows` false, a reference that no alignment
    /// record of any kind names is left out and counted, and one with only
    /// secondary or supplementary records keeps its row with 0 primary reads.
    public static func build(
        sortedBAMURL: URL,
        totalReads: Int,
        readGroupIDs: Set<String> = [],
        runner: NativeToolRunner = .shared,
        timeout: TimeInterval = 3_600,
        includeUnmappedReferenceRows: Bool = true,
        reportWarning: (@Sendable (String) -> Void)? = nil
    ) async throws -> MappingContigSummaryTable {
        try await summarize(
            sortedBAMURL: sortedBAMURL, totalReads: totalReads, readGroupIDs: readGroupIDs, runner: runner,
            timeout: timeout, includeUnmappedReferenceRows: includeUnmappedReferenceRows, recording: nil
        ).table
    }

    /// The rows of `build` with the two samtools passes that made them as steps of the mapping
    /// record, coverage first and then view (Phase 2.13 lane 13.16, Q-B3). Each step's command is
    /// the argv its spawn ran, its inputs are the BAM and `indexURL`, and it records no output,
    /// since the app reads the stdout. The omission rule stays in `mapping-result.json`.
    public static func buildRecordingSteps(
        sortedBAMURL: URL,
        indexURL: URL,
        totalReads: Int,
        toolVersion: String,
        runner: NativeToolRunner = .shared,
        timeout: TimeInterval = 3_600,
        includeUnmappedReferenceRows: Bool = true
    ) async throws -> MappingSummaryWithSteps {
        let inputs = [
            ProvenanceRecorder.fileRecord(url: sortedBAMURL, format: .bam, role: .input),
            ProvenanceRecorder.fileRecord(url: indexURL, role: .index),
        ]
        return try await summarize(
            sortedBAMURL: sortedBAMURL, totalReads: totalReads, readGroupIDs: [], runner: runner, timeout: timeout,
            includeUnmappedReferenceRows: includeUnmappedReferenceRows,
            recording: SamtoolsPassRecording(toolVersion: toolVersion, inputs: inputs)
        )
    }

    /// The read-group path (`readGroupIDs` not empty) records no step.
    private static func summarize(
        sortedBAMURL: URL,
        totalReads: Int,
        readGroupIDs: Set<String>,
        runner: NativeToolRunner,
        timeout: TimeInterval,
        includeUnmappedReferenceRows: Bool,
        recording: SamtoolsPassRecording?
    ) async throws -> MappingSummaryWithSteps {
        var steps: [StepExecution] = []
        let effectiveTotalReads: Int
        let coverageOutput: String
        if readGroupIDs.isEmpty {
            effectiveTotalReads = totalReads
            // Exclude supplementary alignments in addition to samtools coverage's
            // own default filter (UNMAP, SECONDARY, QCFAIL, DUP), so `numreads`
            // counts primary reads only and is comparable to `totalReads`
            // (primary reads from flagstat).
            let coverageArguments = ["coverage", "--ff", Self.primaryMappedReadExclusionFlags, sortedBAMURL.path]
            let start = Date()
            let coverageResult = try await runner.run(
                .samtools,
                arguments: coverageArguments,
                workingDirectory: sortedBAMURL.deletingLastPathComponent(),
                timeout: timeout
            )
            let end = Date()
            guard coverageResult.isSuccess else {
                throw MappingSummaryBuilderError.samtoolsCoverageFailed(coverageResult.stderr)
            }
            coverageOutput = coverageResult.stdout
            if let recording {
                // The executable as the normalization steps write theirs: the found tool, else its name.
                let executable = (try? await runner.findTool(.samtools))?.path ?? NativeTool.samtools.executableName
                steps.append(recording.step(
                    command: [executable] + coverageArguments, exitCode: coverageResult.exitCode,
                    stderr: coverageResult.stderr, start: start, end: end
                ))
            }
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

        let (identities, viewPass) = try await streamSAMViewMetrics(
            sortedBAMURL: sortedBAMURL,
            runner: runner,
            timeout: timeout,
            readGroupIDs: readGroupIDs
        )
        if let recording, let viewPass {
            steps.append(recording.step(
                command: viewPass.command, exitCode: viewPass.result.status, stderr: stderrText(viewPass.result),
                start: viewPass.start, end: viewPass.end
            ))
        }

        let table = try buildSummaries(
            coverageOutput: coverageOutput,
            identities: identities,
            totalReads: effectiveTotalReads,
            includeUnmappedReferenceRows: includeUnmappedReferenceRows
        )
        return MappingSummaryWithSteps(table: table, steps: steps)
    }

    /// The rows and, from `buildRecordingSteps`, the samtools passes that made them.
    public struct MappingSummaryWithSteps {
        public let table: MappingContigSummaryTable
        public let steps: [StepExecution]
    }

    /// The facts of one recorded samtools pass that the run does not give.
    private struct SamtoolsPassRecording {
        let toolVersion: String
        let inputs: [FileRecord]

        func step(command: [String], exitCode: Int32, stderr: String, start: Date, end: Date) -> StepExecution {
            StepExecution(
                toolName: NativeTool.samtools.executableName,
                toolVersion: toolVersion,
                command: command,
                inputs: inputs,
                outputs: [],
                exitCode: exitCode,
                wallTime: end.timeIntervalSince(start),
                stderr: stderr.isEmpty ? nil : stderr,
                stdoutReadInProcess: true,
                startTime: start,
                endTime: end
            )
        }
    }

    /// The unfiltered `samtools view` run, with the argv its spawn ran.
    private struct SAMViewPass {
        let command: [String]
        let result: ToolProcessResult
        let start: Date
        let end: Date
    }

    public static func buildSummaries(
        coverageOutput: String,
        viewOutput: String,
        totalReads: Int,
        includeUnmappedReferenceRows: Bool = true
    ) throws -> MappingContigSummaryTable {
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
    ) throws -> MappingContigSummaryTable {
        let rows = parseCoverageRows(coverageOutput)
        // Only a reference that no alignment record names is left out. One with
        // only secondary or supplementary records keeps its measured MAPQ and
        // identity, which a filter on primary reads would drop (BIO 4).
        let displayedRows = includeUnmappedReferenceRows
            ? rows
            : rows.filter { $0.mappedReads > 0 || identities[$0.name] != nil }

        let summaries = displayedRows.map { row in
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
        return MappingContigSummaryTable(
            rows: summaries,
            referenceCount: rows.count,
            unalignedReferenceCount: rows.count - displayedRows.count
        )
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
    ) async throws -> ([String: ViewMetrics], SAMViewPass?) {
        let samtoolsPath = try await runner.findTool(.samtools)
        let workingDirectory = sortedBAMURL.deletingLastPathComponent()
        let metrics = StreamingSAMMetricsAccumulator()
        if readGroupIDs.isEmpty {
            let arguments = ["view", sortedBAMURL.path]
            let start = Date()
            let result = try await runProcessStreamingOutput(
                executableURL: samtoolsPath,
                arguments: arguments,
                workingDirectory: workingDirectory,
                timeout: timeout,
                consumeStdout: { metrics.consume($0) }
            )
            let pass = SAMViewPass(command: [samtoolsPath.path] + arguments, result: result, start: start, end: Date())
            return (metrics.finalize(), pass)
        }
        return try await withReadGroupList(readGroupIDs) { listURL in
            try await runProcessStreamingOutput(
                executableURL: samtoolsPath,
                arguments: ["view", "-R", listURL.path, sortedBAMURL.path],
                workingDirectory: workingDirectory,
                timeout: timeout,
                consumeStdout: { metrics.consume($0) }
            )
            return (metrics.finalize(), nil)
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
        return try await withReadGroupList(readGroupIDs) { listURL in
            try await runFilteredCoverage(
                samtoolsPath: samtoolsPath,
                sortedBAMURL: sortedBAMURL,
                listURL: listURL,
                timeout: timeout
            )
        }
    }

    /// `samtools view` into `samtools coverage` as one `ToolProcess` pipeline, both stages in the BAM's folder.
    /// Each stage keeps its own stderr, so a failing view names its own error, and every stage runs to its end,
    /// as the stages of the Process pipe did, so a failure carries the words of its own stage. The view is
    /// checked first, then the coverage. A cancelled task ends as a `CancellationError`, and a run past
    /// `timeout` as a timeout of the whole step, since a limit stops both processes and their exit status
    /// says nothing about samtools.
    private static func runFilteredCoverage(
        samtoolsPath: URL,
        sortedBAMURL: URL,
        listURL: URL,
        timeout: TimeInterval
    ) async throws -> String {
        let folder = sortedBAMURL.deletingLastPathComponent()
        // Exclude supplementary alignments here too, matching the
        // unfiltered path's `coverage --ff` so numreads means primary reads
        // on both the read-group-filtered and unfiltered paths.
        let viewArguments = ["view", "-h", "-F", Self.primaryMappedReadExclusionFlags, "-R", listURL.path, sortedBAMURL.path]
        let coverageArguments = ["coverage", "-"]
        let stages = [
            ToolProcessSpec(
                executableURL: samtoolsPath,
                arguments: viewArguments,
                environment: ToolProcessSpec.inheritedEnvironment(),
                workingDirectory: folder,
                label: "samtools view"
            ),
            ToolProcessSpec(
                executableURL: samtoolsPath,
                arguments: coverageArguments,
                environment: ToolProcessSpec.inheritedEnvironment(),
                workingDirectory: folder,
                label: "samtools coverage"
            ),
        ]
        let result: ToolPipelineResult
        do {
            result = try await ToolProcess.runPipeline(
                stages,
                timeout: CondaFamilyProcess.limit(seconds: timeout),
                failurePolicy: .runToCompletion
            )
        } catch ToolProcessError.cancelled {
            throw CancellationError()
        } catch ToolProcessError.timedOut {
            throw MappingSummaryBuilderError.samtoolsTimedOut(step: "samtools view | samtools coverage", seconds: timeout)
        }
        let view = result.stages[0]
        let coverage = result.stages[1]
        guard view.status == 0 else {
            throw MappingSummaryBuilderError.samtoolsViewFailed(stderrText(view))
        }
        guard coverage.status == 0 else {
            throw MappingSummaryBuilderError.samtoolsCoverageFailed(stderrText(coverage))
        }
        if let reason = coverage.incompleteOutputReason ?? view.incompleteOutputReason {
            throw MappingSummaryBuilderError.samtoolsCoverageFailed(reason)
        }
        return String(data: coverage.stdout, encoding: .utf8) ?? ""
    }

    private static func filteredReadCount(
        sortedBAMURL: URL,
        readGroupIDs: Set<String>,
        runner: NativeToolRunner,
        timeout: TimeInterval
    ) async throws -> Int {
        let samtoolsPath = try await runner.findTool(.samtools)
        return try await withReadGroupList(readGroupIDs) { listURL in
            // Count primary reads only (exclude unmapped, secondary and
            // supplementary), so this denominator is consistent with the
            // unfiltered path's flagstat-derived `totalReads` and with the
            // numerator produced by `runFilteredCoverageSynchronously` above.
            // Previously this counted every alignment record.
            let output = try await runProcessCapturingOutput(
                executableURL: samtoolsPath,
                arguments: ["view", "-c", "-F", Self.primaryRecordExclusionFlags, "-R", listURL.path, sortedBAMURL.path],
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
    /// to the caller while stderr is captured for diagnostics. A timeout and a
    /// cancelled task both end as a `CancellationError`, and a nonzero exit as
    /// a view failure with the process's stderr.
    @discardableResult
    static func runProcessStreamingOutput(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        consumeStdout: @escaping @Sendable (Data) -> Void
    ) async throws -> ToolProcessResult {
        let spec = ToolProcessSpec(
            executableURL: executableURL,
            arguments: arguments,
            environment: ToolProcessSpec.inheritedEnvironment(),
            workingDirectory: workingDirectory,
            stdout: .stream,
            timeout: CondaFamilyProcess.limit(seconds: timeout),
            label: "samtools view"
        )
        let run = try ToolProcess.start(spec)
        let result: ToolProcessResult
        do {
            result = try await withTaskCancellationHandler {
                // A waiting drain does not watch the task, so the cancel handler stops the run, which ends the stream.
                await run.stdout.drain(()) { _, chunk in
                    consumeStdout(chunk)
                    return true
                }
                return try await run.result()
            } onCancel: {
                run.cancel()
            }
        } catch ToolProcessError.timedOut, ToolProcessError.cancelled {
            throw CancellationError()
        }
        try requireSuccess(result)
        return result
    }

    /// Runs a process and captures stdout. `ToolProcess` drains stdout and stderr together, so a child process
    /// which fills the ~64KB stderr pipe buffer while stdout is still being read cannot deadlock against this
    /// caller (F36). Cancelling the enclosing Task terminates the underlying `samtools view` process tree
    /// instead of leaking it to run to completion (or to the timeout) unattended, and both a cancel and a
    /// timeout end as a `CancellationError`.
    static func runProcessCapturingOutput(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL?,
        timeout: TimeInterval
    ) async throws -> String {
        let spec = ToolProcessSpec(
            executableURL: executableURL,
            arguments: arguments,
            environment: ToolProcessSpec.inheritedEnvironment(),
            workingDirectory: workingDirectory,
            timeout: CondaFamilyProcess.limit(seconds: timeout),
            label: "samtools view"
        )
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(spec)
        } catch ToolProcessError.timedOut, ToolProcessError.cancelled {
            throw CancellationError()
        }
        try requireSuccess(result)
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }

    /// Throws the view failure of a run that exited nonzero, or whose output is incomplete.
    private static func requireSuccess(_ result: ToolProcessResult) throws {
        guard result.status == 0 else {
            throw MappingSummaryBuilderError.samtoolsViewFailed(stderrText(result))
        }
        if let reason = result.incompleteOutputReason {
            throw MappingSummaryBuilderError.samtoolsViewFailed(reason)
        }
    }

    /// A process's stderr, or nothing when it is not valid UTF-8, as the pipe readers it replaces gave.
    private static func stderrText(_ result: ToolProcessResult) -> String {
        String(data: result.stderr, encoding: .utf8) ?? ""
    }
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
