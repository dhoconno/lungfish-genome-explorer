// FASTQStatisticsService.swift - Shared FASTQ dashboard statistics computation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

public struct FASTQStatisticsComputationResult: Sendable {
    public let statistics: FASTQDatasetStatistics
    public let seqkitMetadata: SeqkitStatsMetadata
    public let scannedReadCount: Int
}

public enum FASTQStatisticsServiceError: Error, LocalizedError {
    case seqkitFailed(String)
    case invalidSeqkitOutput
    case noFASTQInputs

    public var errorDescription: String? {
        switch self {
        case .seqkitFailed(let stderr):
            return "seqkit stats failed: \(stderr)"
        case .invalidSeqkitOutput:
            return "seqkit stats returned invalid or incomplete output"
        case .noFASTQInputs:
            return "No FASTQ inputs were provided for statistics computation"
        }
    }
}

/// Computes and caches lightweight dashboard FASTQ statistics.
///
/// The dashboard uses this summary on first load to avoid the heavier
/// quality-report pass (`FASTQReader.computeStatistics(sampleLimit: 0)`).
public enum FASTQStatisticsService {

    private struct SeqkitSummary: Sendable {
        let numSeqs: Int
        let sumLen: Int64
        let minLen: Int
        let avgLen: Double
        let maxLen: Int
        let q20Percentage: Double
        let q30Percentage: Double
        let averageQuality: Double
        let gcPercentage: Double

        func asMetadata() -> SeqkitStatsMetadata {
            SeqkitStatsMetadata(
                numSeqs: numSeqs,
                sumLen: sumLen,
                minLen: minLen,
                avgLen: avgLen,
                maxLen: maxLen,
                q20Percentage: q20Percentage,
                q30Percentage: q30Percentage,
                averageQuality: averageQuality,
                gcPercentage: gcPercentage
            )
        }
    }

    public static func computeAndCache(
        for fastqURL: URL,
        existingMetadata: PersistedFASTQMetadata? = nil,
        runner: NativeToolRunner = .shared,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> FASTQStatisticsComputationResult {
        let summary = try await fetchSeqkitSummary(for: [fastqURL], runner: runner)
        let (histogram, processedReads) = try await collectFASTQHistogram(
            from: [fastqURL],
            progress: progress
        )
        let statistics = buildFASTQStatistics(
            summary: summary,
            histogram: histogram,
            fallbackReadCount: processedReads
        )

        var metadata = existingMetadata ?? FASTQMetadataStore.load(for: fastqURL) ?? PersistedFASTQMetadata()
        metadata.computedStatistics = statistics
        metadata.seqkitStats = summary.asMetadata()
        FASTQMetadataStore.save(metadata, for: fastqURL)

        return FASTQStatisticsComputationResult(
            statistics: statistics,
            seqkitMetadata: summary.asMetadata(),
            scannedReadCount: processedReads
        )
    }

    public static func compute(
        for fastqURL: URL,
        runner: NativeToolRunner = .shared,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> FASTQStatisticsComputationResult {
        try await compute(for: [fastqURL], runner: runner, progress: progress)
    }

    public static func compute(
        for fastqURLs: [URL],
        runner: NativeToolRunner = .shared,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> FASTQStatisticsComputationResult {
        let summary = try await fetchSeqkitSummary(for: fastqURLs, runner: runner)
        let (histogram, processedReads) = try await collectFASTQHistogram(
            from: fastqURLs,
            progress: progress
        )
        let statistics = buildFASTQStatistics(
            summary: summary,
            histogram: histogram,
            fallbackReadCount: processedReads
        )

        return FASTQStatisticsComputationResult(
            statistics: statistics,
            seqkitMetadata: summary.asMetadata(),
            scannedReadCount: processedReads
        )
    }

    /// Number of reads sampled for the distribution histograms when computing
    /// sampled statistics. Aggregate metrics stay exact (they come from
    /// `seqkit stats` over the whole file); only the shape of the
    /// distributions is estimated from this prefix.
    public static let distributionSampleReadCount = 100_000

    /// Computes statistics for one FASTQ file without a full Swift-side parse.
    ///
    /// Exact aggregate metrics (read/base counts, min/avg/max length, Q20/Q30,
    /// mean quality, GC) come from `seqkit stats -a -T` over the whole file.
    /// The length/quality distributions come from only the first
    /// `distributionSampleReadCount` reads, extracted with `seqkit head`.
    /// That combination is orders of magnitude faster than parsing every
    /// record in Swift, which takes minutes per multi-GB file.
    ///
    /// Falls back to the pure-Swift `FASTQReader.computeStatistics` whenever
    /// seqkit cannot be resolved or either seqkit step fails, so callers keep
    /// working on machines without the managed toolchain.
    ///
    /// - Returns: statistics in the same `FASTQDatasetStatistics` shape the
    ///   Swift reader produces, so cached-metadata consumers are unaffected.
    public static func computeSampled(
        for fastqURL: URL,
        runner: NativeToolRunner = .shared,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> FASTQDatasetStatistics {
        do {
            let summary = try await fetchSeqkitSummary(for: [fastqURL], runner: runner)
            let sampled = try await collectSampledDistributions(
                from: fastqURL,
                runner: runner,
                progress: progress
            )
            return FASTQDatasetStatistics(
                readCount: summary.numSeqs,
                baseCount: summary.sumLen,
                meanReadLength: summary.avgLen,
                minReadLength: summary.minLen,
                maxReadLength: summary.maxLen,
                medianReadLength: medianLength(
                    histogram: sampled.readLengthHistogram,
                    readCount: sampled.sampledReadCount
                ),
                n50ReadLength: n50Length(histogram: sampled.readLengthHistogram),
                meanQuality: summary.averageQuality,
                q20Percentage: summary.q20Percentage,
                q30Percentage: summary.q30Percentage,
                gcContent: summary.gcPercentage / 100.0,
                readLengthHistogram: sampled.readLengthHistogram,
                qualityScoreHistogram: sampled.qualityScoreHistogram,
                perPositionQuality: sampled.perPositionQuality
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // seqkit unavailable or failed -- fall back to the exact, slower
            // pure-Swift parse rather than surfacing an error.
            let reader = FASTQReader(validateSequence: false)
            return try await reader.computeStatistics(
                from: fastqURL,
                sampleLimit: 0,
                progress: progress
            ).statistics
        }
    }

    private struct SampledDistributions: Sendable {
        let readLengthHistogram: [Int: Int]
        let qualityScoreHistogram: [UInt8: Int]
        let perPositionQuality: [PositionQualitySummary]
        let sampledReadCount: Int
    }

    /// Extracts the first `distributionSampleReadCount` reads with `seqkit
    /// head` and runs the shared collector over just that prefix.
    private static func collectSampledDistributions(
        from fastqURL: URL,
        runner: NativeToolRunner,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> SampledDistributions {
        let seqkitURL = try await runner.findTool(.seqkit)
        // Written beside the source so the sample lands on the same volume,
        // and always cleaned up.
        let sampleURL = fastqURL.deletingLastPathComponent()
            .appendingPathComponent(".lungfish-stats-sample-\(UUID().uuidString).fq.gz")
        defer { try? FileManager.default.removeItem(at: sampleURL) }

        let headResult = try await runner.runProcess(
            executableURL: seqkitURL,
            arguments: [
                "head", "-n", String(distributionSampleReadCount),
                "-o", sampleURL.path, fastqURL.path,
            ],
            timeout: 300
        )
        guard headResult.isSuccess else {
            throw FASTQStatisticsServiceError.seqkitFailed(headResult.stderr)
        }

        let collector = FASTQStatisticsCollector()
        let reader = FASTQReader(validateSequence: false)
        var sampledReadCount = 0
        for try await record in reader.records(from: sampleURL) {
            collector.process(record)
            sampledReadCount += 1
            if sampledReadCount % 10_000 == 0 {
                progress?(sampledReadCount)
                try Task.checkCancellation()
            }
        }
        progress?(sampledReadCount)
        let finalized = collector.finalize()
        return SampledDistributions(
            readLengthHistogram: finalized.readLengthHistogram,
            qualityScoreHistogram: finalized.qualityScoreHistogram,
            perPositionQuality: finalized.perPositionQuality,
            sampledReadCount: sampledReadCount
        )
    }

    private static func medianLength(histogram: [Int: Int], readCount: Int) -> Int {
        guard readCount > 0 else { return 0 }
        let target = (readCount + 1) / 2
        var cumulative = 0
        for (length, count) in histogram.sorted(by: { $0.key < $1.key }) {
            cumulative += count
            if cumulative >= target { return length }
        }
        return histogram.keys.max() ?? 0
    }

    private static func n50Length(histogram: [Int: Int]) -> Int {
        let totalBases = histogram.reduce(Int64(0)) { $0 + Int64($1.key * $1.value) }
        guard totalBases > 0 else { return 0 }
        let target = Double(totalBases) / 2.0
        var cumulative = 0.0
        for (length, count) in histogram.sorted(by: { $0.key > $1.key }) {
            cumulative += Double(length * count)
            if cumulative >= target { return length }
        }
        return histogram.keys.max() ?? 0
    }

    private static func fetchSeqkitSummary(
        for fastqURLs: [URL],
        runner: NativeToolRunner
    ) async throws -> SeqkitSummary {
        guard !fastqURLs.isEmpty else {
            throw FASTQStatisticsServiceError.noFASTQInputs
        }
        let result = try await runner.run(
            .seqkit,
            arguments: ["stats", "-a", "-T"] + fastqURLs.map(\.path),
            timeout: 900
        )
        guard result.isSuccess else {
            throw FASTQStatisticsServiceError.seqkitFailed(result.stderr)
        }

        let summaries = try parseSeqkitSummaries(from: result.stdout)
        guard !summaries.isEmpty else {
            throw FASTQStatisticsServiceError.invalidSeqkitOutput
        }
        guard summaries.count > 1 else {
            return summaries[0]
        }
        return aggregateSeqkitSummaries(summaries)
    }

    private static func parseSeqkitSummaries(from stdout: String) throws -> [SeqkitSummary] {
        let lines = stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw FASTQStatisticsServiceError.invalidSeqkitOutput
        }

        let headers = lines[0]
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)

        return try lines.dropFirst().map { line in
            let values = line
                .split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard headers.count == values.count else {
                throw FASTQStatisticsServiceError.invalidSeqkitOutput
            }

            var map: [String: String] = [:]
            for (header, value) in zip(headers, values) {
                map[header] = value
            }

            func int(_ key: String) -> Int { Int(map[key] ?? "") ?? 0 }
            func int64(_ key: String) -> Int64 { Int64(map[key] ?? "") ?? 0 }
            func dbl(_ key: String) -> Double { Double(map[key] ?? "") ?? 0 }

            return SeqkitSummary(
                numSeqs: int("num_seqs"),
                sumLen: int64("sum_len"),
                minLen: int("min_len"),
                avgLen: dbl("avg_len"),
                maxLen: int("max_len"),
                q20Percentage: dbl("Q20(%)"),
                q30Percentage: dbl("Q30(%)"),
                averageQuality: dbl("AvgQual"),
                gcPercentage: dbl("GC(%)")
            )
        }
    }

    private static func aggregateSeqkitSummaries(_ summaries: [SeqkitSummary]) -> SeqkitSummary {
        let numSeqs = summaries.reduce(0) { $0 + $1.numSeqs }
        let sumLen = summaries.reduce(Int64(0)) { $0 + $1.sumLen }
        let minLen = summaries
            .filter { $0.numSeqs > 0 || $0.minLen > 0 }
            .map(\.minLen)
            .min() ?? 0
        let maxLen = summaries.map(\.maxLen).max() ?? 0
        let avgLen = numSeqs > 0 ? Double(sumLen) / Double(numSeqs) : 0

        func weightedByBases(_ value: (SeqkitSummary) -> Double) -> Double {
            guard sumLen > 0 else { return 0 }
            let weightedTotal = summaries.reduce(0.0) { partial, summary in
                partial + value(summary) * Double(summary.sumLen)
            }
            return weightedTotal / Double(sumLen)
        }

        return SeqkitSummary(
            numSeqs: numSeqs,
            sumLen: sumLen,
            minLen: minLen,
            avgLen: avgLen,
            maxLen: maxLen,
            q20Percentage: weightedByBases(\.q20Percentage),
            q30Percentage: weightedByBases(\.q30Percentage),
            averageQuality: weightedByBases(\.averageQuality),
            gcPercentage: weightedByBases(\.gcPercentage)
        )
    }

    private static func collectFASTQHistogram(
        from fastqURLs: [URL],
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> (histogram: [Int: Int], readCount: Int) {
        guard !fastqURLs.isEmpty else {
            throw FASTQStatisticsServiceError.noFASTQInputs
        }
        let reader = FASTQReader(validateSequence: false)
        var histogram: [Int: Int] = [:]
        var readCount = 0

        for fastqURL in fastqURLs {
            for try await record in reader.records(from: fastqURL) {
                histogram[record.length, default: 0] += 1
                readCount += 1
                if readCount % 10_000 == 0 {
                    progress?(readCount)
                    try Task.checkCancellation()
                }
            }
            progress?(readCount)
            try Task.checkCancellation()
        }
        return (histogram, readCount)
    }

    private static func buildFASTQStatistics(
        summary: SeqkitSummary,
        histogram: [Int: Int],
        fallbackReadCount: Int
    ) -> FASTQDatasetStatistics {
        let readCount = summary.numSeqs > 0 ? summary.numSeqs : fallbackReadCount
        let baseCount = summary.sumLen > 0 ? summary.sumLen : histogram.reduce(Int64(0)) { total, item in
            total + Int64(item.key * item.value)
        }
        let minLength = summary.minLen > 0 ? summary.minLen : histogram.keys.min() ?? 0
        let maxLength = summary.maxLen > 0 ? summary.maxLen : histogram.keys.max() ?? 0
        let meanLength = summary.avgLen > 0 ? summary.avgLen : (readCount > 0 ? Double(baseCount) / Double(readCount) : 0)

        func medianLength() -> Int {
            guard readCount > 0 else { return 0 }
            let target = (readCount + 1) / 2
            var cumulative = 0
            for (length, count) in histogram.sorted(by: { $0.key < $1.key }) {
                cumulative += count
                if cumulative >= target { return length }
            }
            return histogram.keys.max() ?? 0
        }

        func n50Length() -> Int {
            guard baseCount > 0 else { return 0 }
            let target = Double(baseCount) / 2.0
            var cumulative = 0.0
            for (length, count) in histogram.sorted(by: { $0.key > $1.key }) {
                cumulative += Double(length * count)
                if cumulative >= target { return length }
            }
            return histogram.keys.max() ?? 0
        }

        return FASTQDatasetStatistics(
            readCount: readCount,
            baseCount: baseCount,
            meanReadLength: meanLength,
            minReadLength: minLength,
            maxReadLength: maxLength,
            medianReadLength: medianLength(),
            n50ReadLength: n50Length(),
            meanQuality: summary.averageQuality,
            q20Percentage: summary.q20Percentage,
            q30Percentage: summary.q30Percentage,
            gcContent: summary.gcPercentage / 100.0,
            readLengthHistogram: histogram,
            qualityScoreHistogram: [:],
            perPositionQuality: []
        )
    }
}
