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
    public static func build(
        sortedBAMURL: URL,
        totalReads: Int,
        runner: NativeToolRunner = .shared,
        timeout: TimeInterval = 3_600,
        includeUnmappedReferenceRows: Bool = true
    ) async throws -> [MappingContigSummary] {
        let coverageResult = try await runner.run(
            .samtools,
            arguments: ["coverage", sortedBAMURL.path],
            workingDirectory: sortedBAMURL.deletingLastPathComponent(),
            timeout: timeout
        )
        guard coverageResult.isSuccess else {
            throw MappingSummaryBuilderError.samtoolsCoverageFailed(coverageResult.stderr)
        }

        let viewOutput = try await streamSAMView(
            sortedBAMURL: sortedBAMURL,
            runner: runner,
            timeout: timeout
        )

        return try buildSummaries(
            coverageOutput: coverageResult.stdout,
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
        timeout: TimeInterval
    ) async throws -> String {
        let samtoolsPath = try await runner.findTool(.samtools)
        let workingDirectory = sortedBAMURL.deletingLastPathComponent()

        return try await runProcessCapturingOutput(
            executableURL: samtoolsPath,
            arguments: ["view", sortedBAMURL.path],
            workingDirectory: workingDirectory,
            timeout: timeout
        )
    }

    /// Runs a process and captures stdout, draining stdout and stderr concurrently on
    /// background queues so that a child process which fills the ~64KB stderr pipe buffer
    /// while stdout is still being read cannot deadlock against this caller (F36).
    static func runProcessCapturingOutput(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL?,
        timeout: TimeInterval
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            do {
                try process.run()

                let stdoutBox = MappingSummaryDataBox()
                let stderrBox = MappingSummaryDataBox()
                let group = DispatchGroup()

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

                process.waitUntilExit()
                group.wait()
                timeoutWorkItem.cancel()

                let stdout = String(data: stdoutBox.value, encoding: .utf8) ?? ""
                let stderr = String(data: stderrBox.value, encoding: .utf8) ?? ""
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: MappingSummaryBuilderError.samtoolsViewFailed(stderr))
                    return
                }
                continuation.resume(returning: stdout)
            } catch {
                timeoutWorkItem.cancel()
                continuation.resume(throwing: error)
            }
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
