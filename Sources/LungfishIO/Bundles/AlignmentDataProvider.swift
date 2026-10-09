// AlignmentDataProvider.swift - Fetches aligned reads from BAM/CRAM via samtools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

/// Logger for alignment data operations
private let alignmentLogger = Logger(subsystem: LogSubsystem.io, category: "AlignmentDataProvider")

/// Keeps complete SAM records from raw samtools output until a record or
/// byte budget is reached.
private struct BudgetedSamtoolsState: Sendable {
    private var retained = Data(), pending = Data()
    private var records = 0, budgetReached = false
    private let maxRecords: Int, maxBytes: Int
    init(maxRecords: Int, maxBytes: Int) { self.maxRecords = maxRecords; self.maxBytes = maxBytes }
    /// Returns true exactly once when the process must be stopped.
    mutating func consumeStdout(_ chunk: Data) -> Bool {
        guard !budgetReached else { return false }
        pending.append(chunk)
        if retained.count + pending.count > maxBytes { budgetReached = true; pending.removeAll(); return true }
        while let newline = pending.firstIndex(of: 0x0A) {
            let end = pending.index(after: newline)
            guard records < maxRecords else { budgetReached = true; pending.removeAll(); return true }
            retained.append(pending.prefix(upTo: end)); records += 1; pending.removeSubrange(..<end)
        }
        return false
    }
    func result(exitCode: Int32, stderr: Data) -> BudgetedSamtoolsResult { .init(exitCode: exitCode, stdout: String(data: retained, encoding: .utf8) ?? "", stderr: String(data: stderr, encoding: .utf8) ?? "", terminatedForBudget: budgetReached, retainedRecordCount: records) }
}

// MARK: - AlignmentDataProvider

/// Provides read alignment data by shelling out to samtools for region queries.
///
/// BAM/CRAM files are accessed via `samtools view` for indexed random-access region
/// queries. This avoids the need for a native BAM parser while providing efficient
/// access to reads in any genomic region.
///
/// ## Access Pattern
///
/// For a typical genome browser viewport of 10,000 bp at 30x coverage:
/// - ~2,000 reads are returned
/// - samtools view completes in 50-200ms (disk I/O dominated)
/// - SAM text parsing takes <10ms
///
/// ## Thread Safety
///
/// `AlignmentDataProvider` is `Sendable` and safe to use from any context.
/// Each fetch spawns an independent samtools process.
public final class AlignmentDataProvider: @unchecked Sendable {

    // MARK: - Properties

    /// Path to the BAM/CRAM file.
    public let alignmentPath: String

    /// Path to the index file (.bai/.csi/.crai).
    public let indexPath: String

    /// Alignment format.
    public let format: AlignmentFormat

    /// Path to the reference FASTA (needed for CRAM only).
    public let referenceFastaPath: String?

    private let samtoolsPathOverride: String?

    // MARK: - Initialization

    /// Creates a provider for the given alignment file.
    ///
    /// - Parameters:
    ///   - alignmentPath: Absolute path to the BAM/CRAM file
    ///   - indexPath: Absolute path to the index file
    ///   - format: File format (.bam, .cram, .sam)
    ///   - referenceFastaPath: Path to reference FASTA (required for CRAM)
    public init(
        alignmentPath: String,
        indexPath: String,
        format: AlignmentFormat = .bam,
        referenceFastaPath: String? = nil
    ) {
        self.alignmentPath = alignmentPath
        self.indexPath = indexPath
        self.format = format
        self.referenceFastaPath = referenceFastaPath
        self.samtoolsPathOverride = nil
    }

    init(
        alignmentPath: String,
        indexPath: String,
        format: AlignmentFormat = .bam,
        referenceFastaPath: String? = nil,
        samtoolsPath: String?
    ) {
        self.alignmentPath = alignmentPath
        self.indexPath = indexPath
        self.format = format
        self.referenceFastaPath = referenceFastaPath
        self.samtoolsPathOverride = samtoolsPath
    }

    // MARK: - Fetch Reads

    /// Fetches aligned reads for a genomic region.
    ///
    /// Uses `samtools view` via Process for indexed random access.
    /// Returns parsed `AlignedRead` structs suitable for rendering.
    ///
    /// - Parameters:
    ///   - chromosome: Chromosome name
    ///   - start: 0-based start position
    ///   - end: 0-based exclusive end position
    ///   - excludeFlags: SAM flag filter to exclude (default: unmapped | secondary | supplementary = 0x904)
    ///   - minMapQ: Minimum mapping quality (default: 0)
    ///   - maxReads: Cap on returned reads (default: 10,000)
    /// - Returns: Array of parsed alignment records
    /// - Throws: AlignmentFetchError on failure
    public func fetchReads(
        chromosome: String,
        start: Int,
        end: Int,
        excludeFlags: UInt16 = 0x904,
        minMapQ: Int = 0,
        maxReads: Int = 100_000,
        readGroups: Set<String> = [],
        subsampleFraction: Double? = nil,
        subsampleSeed: Int = 19
    ) async throws -> [AlignedRead] {
        guard !chromosome.isEmpty, start >= 0, end > start else {
            throw AlignmentFetchError.invalidRegion("\(chromosome):\(start)-\(end)")
        }
        guard maxReads > 0 else { return [] }

        var arguments = viewArguments(
            excludeFlags: excludeFlags,
            minMapQ: minMapQ,
            readGroups: readGroups,
            subsampleFraction: subsampleFraction,
            subsampleSeed: subsampleSeed
        )
        let regionStr = "\(chromosome):\(start + 1)-\(end)"
        // `-X` makes the caller-supplied BAI/CSI authoritative instead of
        // silently discovering a neighbouring index beside the BAM.
        arguments += ["-X", alignmentPath, indexPath, regionStr]

        alignmentLogger.debug("Fetching reads: samtools \(arguments.joined(separator: " "))")

        let result = try await runSamtools(arguments: arguments, timeout: 30)

        guard result.exitCode == 0 else {
            let errorMsg = result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr
            throw AlignmentFetchError.samtoolsFailed(errorMsg)
        }

        let reads = SAMParser.parse(result.stdout, maxReads: maxReads)
        alignmentLogger.debug("Fetched \(reads.count) reads for \(chromosome):\(start)-\(end)")
        return reads
    }

    /// Counts aligned reads for a genomic region using `samtools view -c`.
    public func countReads(
        chromosome: String,
        start: Int,
        end: Int,
        excludeFlags: UInt16 = 0x904,
        minMapQ: Int = 0,
        readGroups: Set<String> = []
    ) async throws -> Int {
        guard !chromosome.isEmpty, start >= 0, end > start else {
            throw AlignmentFetchError.invalidRegion("\(chromosome):\(start)-\(end)")
        }

        var arguments = viewArguments(
            excludeFlags: excludeFlags,
            minMapQ: minMapQ,
            readGroups: readGroups,
            countOnly: true
        )
        let regionStr = "\(chromosome):\(start + 1)-\(end)"
        arguments += ["-X", alignmentPath, indexPath, regionStr]

        alignmentLogger.debug("Counting reads: samtools \(arguments.joined(separator: " "))")
        let result = try await runSamtools(arguments: arguments, timeout: 30)
        guard result.exitCode == 0 else {
            let errorMsg = result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr
            throw AlignmentFetchError.samtoolsFailed(errorMsg)
        }

        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Counts unique aligned reads in a genomic region by streaming
    /// `samtools view` output through `UniqueReadStartCounter`, without a
    /// read cap and without buffering the SAM text in memory.
    ///
    /// This exists because `fetchReads(maxReads:)` (used previously for this
    /// purpose by TaxTriage and EsViritu's "Unique Reads" figure) parses at
    /// most `maxReads` (100,000 by default) reads and buffers up to 500 MB
    /// of raw SAM text before returning, so any contig with more than
    /// 100,000 mapped reads silently under-reports its unique-read count.
    /// The dedup key here is identical to
    /// `AlignedRead.deduplicatedReadCount(from:)` in `AlignedReadDedup.swift`:
    /// a read's 0-based start, its reference-consuming alignment end, and
    /// its strand. Two reads sharing all three count as one.
    ///
    /// - Parameters:
    ///   - chromosome: Chromosome name.
    ///   - start: 0-based region start.
    ///   - end: 0-based exclusive region end.
    ///   - excludeFlags: SAM flag filter to exclude (default matches
    ///     `fetchReads`: unmapped | secondary | supplementary = 0x904).
    ///   - minMapQ: Minimum mapping quality.
    /// - Returns: The number of distinct (position, alignmentEnd, strand)
    ///   keys among reads passing the flag/quality filters, with no upper
    ///   bound.
    public func countUniqueReads(
        chromosome: String,
        start: Int,
        end: Int,
        excludeFlags: UInt16 = 0x904,
        minMapQ: Int = 0,
        readGroups: Set<String> = []
    ) async throws -> Int {
        guard !chromosome.isEmpty, start >= 0, end > start else {
            throw AlignmentFetchError.invalidRegion("\(chromosome):\(start)-\(end)")
        }

        let regionStr = "\(chromosome):\(start + 1)-\(end)"
        let arguments = viewArguments(
            excludeFlags: excludeFlags,
            minMapQ: minMapQ,
            readGroups: readGroups
        ) + ["-X", alignmentPath, indexPath, regionStr]

        alignmentLogger.debug("Counting unique reads (streaming): samtools \(arguments.joined(separator: " "))")

        return try await Self.streamUniqueReadCount(samtoolsPath: try findSamtools(), arguments: arguments, timeout: 300)
    }

    /// Runs `samtools view` and feeds its stdout, 64 KB at a time, into a
    /// `UniqueReadStartCounter`, never materializing the full SAM text.
    static func streamUniqueReadCount(
        samtoolsPath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Int {
        let run = try await streamSamtools(
            samtoolsPath: samtoolsPath, arguments: arguments, timeout: timeout,
            initial: (counter: UniqueReadStartCounter(), leftover: "")
        ) { state, chunk in
            // Lossy decoding: a strict UTF-8 decode returns nil when a
            // multi-byte character straddles the 64 KB boundary, which
            // would silently drop a whole chunk of reads. The fields the
            // counter reads (FLAG, POS, CIGAR) are ASCII either way.
            state.counter.ingest(chunk: String(decoding: chunk, as: UTF8.self), leftover: &state.leftover)
            return true
        }
        var (counter, leftover) = run.state
        if !leftover.isEmpty {
            counter.ingest(chunk: "", leftover: &leftover, isFinal: true)
        }
        guard run.result.status == 0 else {
            let stderrText = String(data: run.result.stderr, encoding: .utf8) ?? ""
            throw AlignmentFetchError.samtoolsFailed(stderrText.isEmpty ? "exit code \(run.result.status)" : stderrText)
        }
        return counter.uniqueCount
    }

    /// Fetches a bounded deterministic read sketch for fast overview rendering.
    ///
    /// When the region has more reads than `targetReads`, this uses `samtools view`
    /// subsampling so the first-pass read set is distributed across the contig
    /// instead of taking only the first alignments in coordinate order.
    public func fetchReadSketch(
        chromosome: String,
        start: Int,
        end: Int,
        excludeFlags: UInt16 = 0x904,
        minMapQ: Int = 0,
        targetReads: Int = 2_500,
        readGroups: Set<String> = [],
        subsampleSeed: Int = 19
    ) async throws -> AlignmentReadSketch {
        guard !chromosome.isEmpty, start >= 0, end > start else {
            throw AlignmentFetchError.invalidRegion("\(chromosome):\(start)-\(end)")
        }
        guard targetReads > 0 else {
            return AlignmentReadSketch(reads: [], estimatedTotalReads: 0, targetReads: targetReads, isSubsampled: false)
        }

        let totalReads = try await countReads(
            chromosome: chromosome,
            start: start,
            end: end,
            excludeFlags: excludeFlags,
            minMapQ: minMapQ,
            readGroups: readGroups
        )

        guard let fraction = Self.readSketchSubsampleFraction(totalReads: totalReads, targetReads: targetReads) else {
            let bounded = try await fetchReadsBounded(
                chromosome: chromosome,
                start: start,
                end: end,
                excludeFlags: excludeFlags,
                minMapQ: minMapQ,
                maxReads: targetReads,
                readGroups: readGroups,
                subsampleFraction: nil,
                subsampleSeed: subsampleSeed,
                byteBudget: 64 * 1024 * 1024
            )
            return AlignmentReadSketch(
                reads: bounded.reads,
                estimatedTotalReads: totalReads,
                targetReads: targetReads,
                isSubsampled: false,
                transportTruncated: bounded.transportTruncated
            )
        }

        let parseLimit = targetReads > Int.max / 2 ? Int.max : targetReads * 2
        let bounded = try await fetchReadsBounded(
            chromosome: chromosome, start: start, end: end,
            excludeFlags: excludeFlags, minMapQ: minMapQ,
            maxReads: parseLimit, readGroups: readGroups,
            subsampleFraction: fraction, subsampleSeed: subsampleSeed,
            byteBudget: 64 * 1024 * 1024
        )
        return AlignmentReadSketch(
            reads: bounded.reads,
            estimatedTotalReads: totalReads,
            targetReads: targetReads,
            isSubsampled: true,
            transportTruncated: bounded.transportTruncated
        )
    }

    /// Default absolute read ceiling for a depth-capped fetch.
    public static let depthCappedReadCeiling = 250_000

    /// Default transport budget, in aligned bases, for a depth-capped fetch.
    /// About 25 Mb of sequence is roughly 60 MB of SAM text.
    public static let depthCappedBaseBudget = 25_000_000

    /// Fetches reads for a window with displayed depth capped at
    /// `maxDisplayedDepth`, keeping every read wherever the window is at or
    /// under the cap.
    ///
    /// Steps: one depth query with the same read filters as the fetch, a
    /// ``ReadDepthCapPlan`` over ~1 kb bins, then one `samtools view -M` per
    /// distinct keep fraction over that fraction's merged regions (with
    /// `--subsample` below 1). A read is kept only by the call whose regions
    /// own its start position, so boundary-spanning reads appear exactly once.
    /// `--subsample` hashes QNAME with a fixed seed, so the result is
    /// deterministic and mates stay together within a fraction.
    ///
    /// No `samtools view -c` pass is made. The total is a Horvitz-Thompson
    /// estimate (kept reads / fraction, summed over calls) and is exact when
    /// nothing was sampled.
    public func fetchDepthCappedReads(
        chromosome: String,
        start: Int,
        end: Int,
        excludeFlags: UInt16 = 0x904,
        minMapQ: Int = 0,
        readGroups: Set<String> = [],
        maxDisplayedDepth: Int,
        maxReads: Int = AlignmentDataProvider.depthCappedReadCeiling,
        maxDisplayedBases: Int = AlignmentDataProvider.depthCappedBaseBudget,
        subsampleSeed: Int = 19
    ) async throws -> DepthCappedReadSketch {
        guard !chromosome.isEmpty, start >= 0, end > start else {
            throw AlignmentFetchError.invalidRegion("\(chromosome):\(start)-\(end)")
        }
        let depth = try await fetchReadFilterDepth(
            chromosome: chromosome, start: start, end: end,
            excludeFlags: excludeFlags, minMapQ: minMapQ, readGroups: readGroups
        )
        let plan = ReadDepthCapPlan.make(
            depth: depth.map { (position: $0.position, depth: $0.depth) },
            windowStart: start,
            windowEnd: end,
            maxDisplayedDepth: maxDisplayedDepth,
            maxDisplayedBases: maxDisplayedBases
        )
        guard plan.totalBases > 0 else {
            return DepthCappedReadSketch(
                reads: [], estimatedTotalReads: 0, isEstimated: false, plan: plan,
                transportTruncated: false, samtoolsCalls: 1
            )
        }

        var kept: [AlignedRead] = []
        var estimatedTotal = 0.0
        var truncated = false
        var calls = 1
        var remainingReads = max(1, maxReads)
        // Two bytes per base (SEQ + QUAL) plus a per-record allowance.
        var remainingBytes = max(1 << 20, maxDisplayedBases * 2 + maxReads * 200)
        for group in plan.groups {
            guard remainingReads > 0, remainingBytes > 0 else { truncated = true; break }
            var arguments = viewArguments(
                excludeFlags: excludeFlags, minMapQ: minMapQ, readGroups: readGroups,
                subsampleFraction: group.fraction < 1 ? group.fraction : nil, subsampleSeed: subsampleSeed
            )
            arguments += ["-M", "-X", alignmentPath, indexPath]
            arguments += group.regions.map { "\(chromosome):\($0.lowerBound + 1)-\($0.upperBound)" }
            let result = try await runSamtoolsBudgeted(
                arguments: arguments, maxRecords: remainingReads, maxBytes: remainingBytes
            )
            calls += 1
            remainingBytes -= result.stdout.utf8.count
            let parsed = SAMParser.parse(result.stdout, maxReads: remainingReads)
            var groupKept = 0
            for read in parsed where plan.fraction(forReadStart: read.position) == group.fraction {
                kept.append(read)
                groupKept += 1
            }
            remainingReads -= groupKept
            estimatedTotal += Double(groupKept) / group.fraction
            if result.terminatedForBudget { truncated = true; break }
        }
        return DepthCappedReadSketch(
            reads: kept,
            estimatedTotalReads: Int(estimatedTotal.rounded()),
            isEstimated: plan.isSampled || truncated,
            plan: plan,
            transportTruncated: truncated,
            samtoolsCalls: calls
        )
    }

    /// Per-position depth under exactly the read-fetch filters (flags, MAPQ,
    /// read groups; no base-quality filter). `samtools depth` cannot filter by
    /// read group, so with read groups the filtered reads are piped from
    /// `samtools view -u` into `samtools depth -`.
    func fetchReadFilterDepth(
        chromosome: String, start: Int, end: Int,
        excludeFlags: UInt16, minMapQ: Int, readGroups: Set<String>
    ) async throws -> [DepthPoint] {
        guard !readGroups.isEmpty else {
            return try await fetchDepth(
                chromosome: chromosome, start: start, end: end,
                minMapQ: minMapQ, minBaseQ: 0, excludeFlags: excludeFlags
            )
        }
        let viewArgs = viewArguments(excludeFlags: excludeFlags, minMapQ: minMapQ, readGroups: readGroups)
            + ["-u", "-X", alignmentPath, indexPath, "\(chromosome):\(start + 1)-\(end)"]
        // The view stage already applied the flag mask; clear depth's own
        // implicit UNMAP|SECONDARY|QCFAIL|DUP filter so it counts what view kept.
        let depthArgs = ["depth", "-g", "1796", "-"]
        let output = try await Self.runSamtoolsPipeline(
            samtoolsPath: try findSamtools(), producer: viewArgs, consumer: depthArgs, timeout: 60
        )
        return Self.parseDepthOutput(output).filter { $0.position >= start && $0.position < end }
    }

    /// Runs `samtools <producer> | samtools <consumer>` and returns the
    /// consumer's stdout. Both stages run to their own end, so each reports
    /// its own exit code.
    static func runSamtoolsPipeline(
        samtoolsPath: String,
        producer: [String],
        consumer: [String],
        timeout: TimeInterval
    ) async throws -> String {
        let result: ToolPipelineResult
        do {
            result = try await ToolProcess.runPipeline(
                [samtoolsSpec(samtoolsPath, producer), samtoolsSpec(samtoolsPath, consumer)],
                timeout: .seconds(timeout),
                failurePolicy: .runToCompletion
            )
        } catch {
            throw samtoolsError(error)
        }
        for stage in result.stages { try requireCompleteOutput(stage) }
        let (first, second) = (result.stages[0], result.stages[1])
        guard first.status == 0, second.status == 0 else {
            let stderrText = String(decoding: first.stderr + second.stderr, as: UTF8.self)
            throw AlignmentFetchError.samtoolsFailed(
                stderrText.isEmpty ? "exit codes \(first.status)/\(second.status)" : stderrText
            )
        }
        return String(data: second.stdout, encoding: .utf8) ?? ""
    }

    private func runSamtoolsBudgeted(
        arguments: [String], maxRecords: Int, maxBytes: Int
    ) async throws -> BudgetedSamtoolsResult {
        let result = try await Self.runSamtoolsProcessBudgeted(
            samtoolsPath: try findSamtools(), arguments: arguments, timeout: 30,
            maxRecords: maxRecords, maxBytes: maxBytes
        )
        guard result.exitCode == 0 || result.terminatedForBudget else {
            throw AlignmentFetchError.samtoolsFailed(result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr)
        }
        return result
    }

    private func fetchReadsBounded(
        chromosome: String, start: Int, end: Int,
        excludeFlags: UInt16, minMapQ: Int, maxReads: Int,
        readGroups: Set<String>, subsampleFraction: Double?, subsampleSeed: Int,
        byteBudget: Int
    ) async throws -> (reads: [AlignedRead], transportTruncated: Bool) {
        var arguments = viewArguments(
            excludeFlags: excludeFlags, minMapQ: minMapQ, readGroups: readGroups,
            subsampleFraction: subsampleFraction, subsampleSeed: subsampleSeed
        )
        arguments += ["-X", alignmentPath, indexPath, "\(chromosome):\(start + 1)-\(end)"]
        let result = try await runSamtoolsBudgeted(arguments: arguments, maxRecords: maxReads, maxBytes: byteBudget)
        return (SAMParser.parse(result.stdout, maxReads: maxReads), result.terminatedForBudget)
    }

    static func readSketchSubsampleFraction(totalReads: Int, targetReads: Int) -> Double? {
        guard totalReads > targetReads, targetReads > 0 else { return nil }
        return max(0.000_001, min(1.0, Double(targetReads) / Double(totalReads)))
    }

    private func viewArguments(
        excludeFlags: UInt16,
        minMapQ: Int,
        readGroups: Set<String>,
        countOnly: Bool = false,
        subsampleFraction: Double? = nil,
        subsampleSeed: Int = 19
    ) -> [String] {
        var arguments = ["view"]
        if countOnly {
            arguments.append("-c")
        }
        arguments += ["-F", String(excludeFlags)]
        if minMapQ > 0 {
            arguments += ["-q", String(minMapQ)]
        }

        for rg in readGroups.sorted() {
            arguments += ["-r", rg]
        }

        if let subsampleFraction, subsampleFraction > 0, subsampleFraction < 1 {
            arguments += [
                "--subsample",
                Self.samtoolsFractionString(subsampleFraction),
                "--subsample-seed",
                String(subsampleSeed),
            ]
        }

        if format == .cram, let refPath = referenceFastaPath {
            arguments += ["--reference", refPath]
        }
        return arguments
    }

    private static func samtoolsFractionString(_ fraction: Double) -> String {
        String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), fraction)
    }

    /// Fetches the SAM header from the alignment file.
    ///
    /// - Returns: Header text (lines starting with @)
    /// - Throws: AlignmentFetchError on failure
    public func fetchHeader() async throws -> String {
        var arguments = ["view", "-H"]

        if format == .cram, let refPath = referenceFastaPath {
            arguments += ["--reference", refPath]
        }

        arguments.append(alignmentPath)

        let result = try await runSamtools(arguments: arguments)
        guard result.exitCode == 0 else {
            throw AlignmentFetchError.samtoolsFailed(result.stderr)
        }
        return result.stdout
    }

    /// Runs samtools idxstats on the alignment file.
    ///
    /// Returns tab-delimited lines: refName\tseqLength\tmappedReads\tunmappedReads
    public func fetchIdxstats() async throws -> String {
        let result = try await runSamtools(arguments: ["idxstats", alignmentPath], timeout: 120)
        guard result.exitCode == 0 else {
            throw AlignmentFetchError.samtoolsFailed(result.stderr)
        }
        return result.stdout
    }

    /// Runs samtools flagstat on the alignment file.
    ///
    /// Prefers `flagstat -O json`, whose field names are stable across samtools
    /// releases, and falls back to the human-readable text form when the JSON
    /// form is unavailable (samtools < 1.10) or does not produce JSON.
    ///
    /// Returns either JSON or human-readable flag statistics; both forms are
    /// accepted by ``AlignmentMetadataDatabase/populateFromFlagstat(_:)``.
    public func fetchFlagstat() async throws -> String {
        let jsonResult = try await runSamtools(
            arguments: ["flagstat", "-O", "json", alignmentPath],
            timeout: 120
        )
        if jsonResult.exitCode == 0, Self.looksLikeJSON(jsonResult.stdout) {
            return jsonResult.stdout
        }

        let result = try await runSamtools(arguments: ["flagstat", alignmentPath], timeout: 120)
        guard result.exitCode == 0 else {
            throw AlignmentFetchError.samtoolsFailed(result.stderr)
        }
        return result.stdout
    }

    /// Returns `true` when text begins with a JSON object, so the JSON flagstat
    /// path is only taken when samtools actually emitted JSON.
    static func looksLikeJSON(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    // MARK: - Fetch Depth

    /// Fetches per-position read depth for a genomic region.
    ///
    /// Uses `samtools depth` so coverage rendering does not require full SAM read parsing.
    ///
    /// - Parameters:
    ///   - chromosome: Chromosome name.
    ///   - start: 0-based start position.
    ///   - end: 0-based exclusive end position.
    ///   - minMapQ: Minimum mapping quality (`samtools depth -q`).
    ///   - minBaseQ: Minimum base quality (`samtools depth -Q`).
    ///   - excludeFlags: Flags to exclude (`samtools depth -G`).
    /// - Returns: Sparse depth points (positions with depth > 0 by default samtools behavior).
    public func fetchDepth(
        chromosome: String,
        start: Int,
        end: Int,
        minMapQ: Int = 0,
        minBaseQ: Int = 0,
        excludeFlags: UInt16 = 0x904
    ) async throws -> [DepthPoint] {
        guard !chromosome.isEmpty, start >= 0, end > start else {
            throw AlignmentFetchError.invalidRegion("\(chromosome):\(start)-\(end)")
        }

        var arguments = ["depth"]
        // samtools depth: -q is base quality and -Q is mapping quality.
        if minBaseQ > 0 { arguments += ["-q", String(minBaseQ)] }
        if minMapQ > 0 { arguments += ["-Q", String(minMapQ)] }
        // Clear depth's implicit UNMAP|SECONDARY|QCFAIL|DUP mask (0x704),
        // then apply precisely the viewer's effective read exclusion mask.
        arguments += ["-g", "1796"]
        if excludeFlags != 0 { arguments += ["-G", String(excludeFlags)] }
        if format == .cram, let refPath = referenceFastaPath {
            arguments += ["--reference", refPath]
        }

        let regionStr = "\(chromosome):\(start + 1)-\(end)"
        arguments += ["-r", regionStr, "-X", alignmentPath, indexPath]

        alignmentLogger.debug("Fetching depth: samtools \(arguments.joined(separator: " "))")
        let result = try await runSamtools(arguments: arguments, timeout: 30)
        guard result.exitCode == 0 else {
            let errorMsg = result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr
            throw AlignmentFetchError.samtoolsFailed(errorMsg)
        }
        return Self.parseDepthOutput(result.stdout)
    }

    /// Fetches a consensus that is guaranteed to contain only caller evidence
    /// at adequately covered reference coordinates.
    public func fetchConsensus(_ request: AlignmentConsensusRequest) async throws -> AlignmentConsensusResult {
        guard !request.chromosome.isEmpty, request.start >= 0, request.end > request.start else {
            throw AlignmentFetchError.invalidRegion("\(request.chromosome):\(request.start)-\(request.end)")
        }

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-consensus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let filteredBAM = stagingDirectory.appendingPathComponent("filtered.bam")
        let filteredIndex = stagingDirectory.appendingPathComponent("filtered.bam.bai")
        let consensusOutput = stagingDirectory.appendingPathComponent("consensus.fasta")
        let depthOutput = stagingDirectory.appendingPathComponent("depth.tsv")
        let readGroupFile = try writeReadGroupFile(filters: request.filters, in: stagingDirectory)
        let region = Self.regionString(chromosome: request.chromosome, start: request.start, end: request.end)
        let defaults = consensusResolvedDefaults(request: request)
        let samtoolsPath = try findSamtools()
        let samtoolsVersion = try await resolvedSamtoolsVersion()
        var records: [AlignmentConsensusExecutionRecord] = []

        var viewArguments = ["view", "-b", "-h", "-o", filteredBAM.path]
        viewArguments += sourceDecodingArguments()
        if request.filters.minimumMapQ > 0 {
            viewArguments += ["-q", String(request.filters.minimumMapQ)]
        }
        if request.filters.excludedFlags != 0 {
            viewArguments += ["-F", String(request.filters.excludedFlags)]
        }
        if let readGroupFile {
            viewArguments += ["-R", readGroupFile.path, "-n"]
        }
        viewArguments += ["-X", alignmentPath, indexPath, region]
        _ = try await executeConsensusStage(
            .view,
            arguments: viewArguments,
            timeout: 45,
            samtoolsPath: samtoolsPath, samtoolsVersion: samtoolsVersion,
            inputs: [URL(fileURLWithPath: alignmentPath), URL(fileURLWithPath: indexPath)] + (referenceFastaPath.map { [URL(fileURLWithPath: $0)] } ?? []),
            outputs: [filteredBAM],
            readGroupFile: readGroupFile,
            defaults: defaults,
            records: &records
        )

        _ = try await executeConsensusStage(
            .index,
            arguments: ["index", filteredBAM.path, filteredIndex.path],
            timeout: 45,
            samtoolsPath: samtoolsPath, samtoolsVersion: samtoolsVersion,
            inputs: [filteredBAM],
            outputs: [filteredIndex],
            readGroupFile: readGroupFile,
            defaults: defaults,
            records: &records
        )

        var callerArguments = ["consensus", "-r", region, "-a", "-f", "FASTA", "-m", request.mode.rawValue]
        callerArguments += ["--min-BQ", String(max(0, request.filters.minimumBaseQuality))]
        // The snapshot owns MAPQ, flag, and read-group selection. Clear the
        // caller's implicit flag filter so it cannot silently change evidence.
        callerArguments += ["--ff", "0", "-d", String(max(1, request.filters.minimumDepth))]
        callerArguments += ["--show-del", "yes", "--show-ins", "no"]
        if request.useAmbiguity {
            callerArguments.append("-A")
        }
        callerArguments.append(filteredBAM.path)
        let callerRun = try await executeConsensusStage(
            .consensus,
            arguments: callerArguments,
            timeout: 45,
            samtoolsPath: samtoolsPath, samtoolsVersion: samtoolsVersion,
            inputs: [filteredBAM, filteredIndex],
            outputs: [consensusOutput],
            capturedStdoutURL: consensusOutput,
            readGroupFile: readGroupFile,
            defaults: defaults,
            records: &records
        )

        var depthArguments = ["depth", "-q", String(max(0, request.filters.minimumBaseQuality))]
        // Clear depth's implicit exclusion flags; it must observe precisely the
        // same immutable filtered snapshot as consensus.
        depthArguments += ["-g", "1796", "-r", region, "-X", filteredBAM.path, filteredIndex.path]
        let depthRun = try await executeConsensusStage(
            .depth,
            arguments: depthArguments,
            timeout: 30,
            samtoolsPath: samtoolsPath, samtoolsVersion: samtoolsVersion,
            inputs: [filteredBAM, filteredIndex],
            outputs: [depthOutput],
            capturedStdoutURL: depthOutput,
            readGroupFile: readGroupFile,
            defaults: defaults,
            records: &records
        )

        let normalized: AlignmentConsensusResult
        do {
            normalized = try AlignmentConsensusNormalizer.normalize(
                caller: Self.parseConsensusFASTA(callerRun.stdout),
                depth: Self.parseDepthOutput(depthRun.stdout),
                request: request
            )
        } catch AlignmentFetchError.consensusCoordinateMismatch {
            throw AlignmentFetchError.consensusCoordinateMismatchWithRecords(records)
        }
        return AlignmentConsensusResult(
            sequence: normalized.sequence,
            referenceLength: normalized.referenceLength,
            allLowDepth: normalized.allLowDepth,
            executionRecords: records
        )
    }

    private func sourceDecodingArguments() -> [String] {
        guard format == .cram, let referenceFastaPath else { return [] }
        return ["-T", referenceFastaPath]
    }

    private func resolvedSamtoolsVersion() async throws -> String {
        let result = try await runSamtools(arguments: ["--version"], timeout: 15)
        guard result.exitCode == 0,
              let firstLine = result.stdout.split(separator: "\n").first,
              !firstLine.isEmpty else {
            throw AlignmentFetchError.samtoolsFailed(
                result.stderr.isEmpty ? "samtools --version failed" : result.stderr
            )
        }
        return String(firstLine)
    }

    private func writeReadGroupFile(
        filters: AlignmentConsensusFilters,
        in stagingDirectory: URL
    ) throws -> AlignmentConsensusReadGroupFile? {
        guard !filters.readGroups.isEmpty else { return nil }
        let contents = filters.readGroups.sorted().joined(separator: "\n") + "\n"
        let url = stagingDirectory.appendingPathComponent("read-groups.txt")
        try Data(contents.utf8).write(to: url, options: .atomic)
        return AlignmentConsensusReadGroupFile(
            path: url.path,
            contents: contents,
            checksumSHA256: Self.sha256(of: Data(contents.utf8))
        )
    }

    private func consensusResolvedDefaults(request: AlignmentConsensusRequest) -> [String: String] {
        [
            "lowDepthPolicy": "N",
            "referenceFillPolicy": "never",
            "sourceMAPQ": String(max(0, request.filters.minimumMapQ)),
            "sourceExcludedFlags": String(request.filters.excludedFlags),
            "remainingBaseQuality": String(max(0, request.filters.minimumBaseQuality)),
            "readGroupSelection": request.filters.readGroups.isEmpty ? "all-including-ungrouped" : "listed-only-excluding-ungrouped",
            "insertionPolicy": request.insertionPolicy.rawValue,
            "deletionPolicy": request.deletionPolicy.rawValue,
        ]
    }

    private func executeConsensusStage(
        _ stage: AlignmentConsensusExecutionRecord.Stage,
        arguments: [String],
        timeout: TimeInterval,
        samtoolsPath: String,
        samtoolsVersion: String,
        inputs: [URL],
        outputs: [URL],
        capturedStdoutURL: URL? = nil,
        readGroupFile: AlignmentConsensusReadGroupFile?,
        defaults: [String: String],
        records: inout [AlignmentConsensusExecutionRecord]
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let stageClock = ProvenanceRunClock()
        do {
            let result = try await runSamtools(arguments: arguments, timeout: timeout)
            if let capturedStdoutURL {
                try Data(result.stdout.utf8).write(to: capturedStdoutURL, options: .atomic)
            }
            let endedAt = stageClock.now
            let record = consensusExecutionRecord(
                stage: stage, samtoolsPath: samtoolsPath, samtoolsVersion: samtoolsVersion, arguments: arguments,
                inputs: inputs, outputs: outputs, readGroupFile: readGroupFile,
                defaults: defaults, exitStatus: result.exitCode,
                startedAt: stageClock.startedAt, endedAt: endedAt, stderr: result.stderr
            )
            records.append(record)
            guard result.exitCode == 0 else {
                throw AlignmentFetchError.consensusExecutionFailed(records)
            }
            return result
        } catch let error as AlignmentFetchError {
            if case .consensusExecutionFailed = error { throw error }
            let endedAt = stageClock.now
            records.append(consensusExecutionRecord(
                stage: stage, samtoolsPath: samtoolsPath, samtoolsVersion: samtoolsVersion, arguments: arguments,
                inputs: inputs, outputs: outputs, readGroupFile: readGroupFile,
                defaults: defaults, exitStatus: nil,
                startedAt: stageClock.startedAt, endedAt: endedAt,
                stderr: error.localizedDescription
            ))
            throw AlignmentFetchError.consensusExecutionFailed(records)
        } catch {
            let endedAt = stageClock.now
            records.append(consensusExecutionRecord(
                stage: stage, samtoolsPath: samtoolsPath, samtoolsVersion: samtoolsVersion, arguments: arguments,
                inputs: inputs, outputs: outputs, readGroupFile: readGroupFile,
                defaults: defaults, exitStatus: nil,
                startedAt: stageClock.startedAt, endedAt: endedAt,
                stderr: error.localizedDescription
            ))
            throw AlignmentFetchError.consensusExecutionFailed(records)
        }
    }

    private func consensusExecutionRecord(
        stage: AlignmentConsensusExecutionRecord.Stage,
        samtoolsPath: String,
        samtoolsVersion: String,
        arguments: [String],
        inputs: [URL],
        outputs: [URL],
        readGroupFile: AlignmentConsensusReadGroupFile?,
        defaults: [String: String],
        exitStatus: Int32?,
        startedAt: Date,
        endedAt: Date,
        stderr: String
    ) -> AlignmentConsensusExecutionRecord {
        AlignmentConsensusExecutionRecord(
            stage: stage,
            executablePath: samtoolsPath,
            executableVersion: samtoolsVersion,
            runtimeIdentity: ProcessInfo.processInfo.operatingSystemVersionString,
            argv: arguments,
            reproducibleCommand: ([samtoolsPath] + arguments).map(Self.shellEscape).joined(separator: " "),
            inputs: inputs.map(Self.consensusFileDescriptor),
            outputs: outputs.map(Self.consensusFileDescriptor),
            readGroupFile: readGroupFile,
            resolvedDefaults: defaults,
            exitStatus: exitStatus,
            startedAt: startedAt,
            endedAt: endedAt,
            wallTimeSeconds: endedAt.timeIntervalSince(startedAt),
            stderr: stderr.isEmpty ? nil : stderr
        )
    }

    private static func consensusFileDescriptor(_ url: URL) -> AlignmentConsensusFileDescriptor {
        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              let data = try? Data(contentsOf: url) else {
            return AlignmentConsensusFileDescriptor(path: path, checksumSHA256: nil, fileSize: nil)
        }
        return AlignmentConsensusFileDescriptor(
            path: path,
            checksumSHA256: sha256(of: data),
            fileSize: size.uint64Value
        )
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func shellEscape(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_/:=-.,+")
        guard !value.unicodeScalars.allSatisfy(safe.contains) else { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\\\''"))'"
    }

    private static func regionString(chromosome: String, start: Int, end: Int) -> String {
        "\(chromosome):\(start + 1)-\(end)"
    }

    /// Fetches a consensus sequence for a region using `samtools consensus`.
    ///
    /// - Parameters:
    ///   - chromosome: Chromosome/contig name.
    ///   - start: 0-based start position.
    ///   - end: 0-based exclusive end position.
    ///   - mode: Consensus model (`bayesian` or `simple`).
    ///   - minMapQ: Minimum mapping quality.
    ///   - minBaseQ: Minimum base quality.
    ///   - minDepth: Minimum depth threshold.
    ///   - excludeFlags: Flag bits to exclude.
    ///   - useAmbiguity: Whether to emit IUPAC ambiguity codes.
    ///   - showDeletions: Whether to include deleted reference columns (`*`) in output.
    ///   - showInsertions: Whether to include inserted bases in output.
    /// - Returns: Consensus sequence in uppercase letters.
    public func fetchConsensus(
        chromosome: String,
        start: Int,
        end: Int,
        mode: AlignmentConsensusMode = .bayesian,
        minMapQ: Int = 0,
        minBaseQ: Int = 0,
        minDepth: Int = 1,
        excludeFlags: UInt16 = 0x904,
        useAmbiguity: Bool = false,
        showDeletions: Bool = true,
        showInsertions: Bool = false
    ) async throws -> ConsensusFASTAResult {
        let request = AlignmentConsensusRequest(
            chromosome: chromosome,
            start: start,
            end: end,
            filters: AlignmentConsensusFilters(
                minimumDepth: minDepth,
                minimumMapQ: minMapQ,
                minimumBaseQuality: minBaseQ,
                excludedFlags: excludeFlags,
                readGroups: []
            ),
            mode: mode,
            useAmbiguity: useAmbiguity,
            insertionPolicy: showInsertions ? .include : .omit,
            deletionPolicy: showDeletions ? .n : .omit
        )
        let result = try await fetchConsensus(request)
        return ConsensusFASTAResult(sequence: result.sequence, headerStart: start)
    }

    /// Parses `samtools depth` output into typed depth points.
    ///
    /// Expected line format: `<chrom>\t<1-based-pos>\t<depth>`.
    static func parseDepthOutput(_ output: String) -> [DepthPoint] {
        guard !output.isEmpty else { return [] }
        var points: [DepthPoint] = []
        points.reserveCapacity(max(128, output.count / 20))

        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            let fields = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return }

            let chrom = String(fields[0])
            guard let pos1 = Int(fields[1]), pos1 > 0,
                  let depth = Int(fields[2]), depth >= 0 else { return }

            points.append(DepthPoint(chromosome: chrom, position: pos1 - 1, depth: depth))
        }

        return points
    }

    /// Result from parsing a consensus FASTA output.
    public struct ConsensusFASTAResult: Sendable {
        /// The consensus sequence (uppercased, concatenated from all non-header lines).
        public let sequence: String
        /// 0-based start position parsed from the FASTA header region (e.g., `>chr:101-200` → 100).
        /// `nil` if the header doesn't contain parseable coordinates.
        public let headerStart: Int?

        public init(sequence: String, headerStart: Int?) {
            self.sequence = sequence
            self.headerStart = headerStart
        }
    }

    /// Parses FASTA produced by `samtools consensus` and returns sequence letters
    /// along with the 0-based start position extracted from the FASTA header.
    ///
    /// The header has the format `>chrom:start-end` (1-based inclusive) for a
    /// sub-region, but `samtools consensus` emits a bare `>chrom` when the
    /// requested region spans the whole contig. A bare header therefore denotes
    /// the contig origin, not an absent coordinate: reporting `nil` there would
    /// fail the normalizer's projection guard for every whole-contig request.
    static func parseConsensusFASTA(_ output: String) -> ConsensusFASTAResult {
        guard !output.isEmpty else { return ConsensusFASTAResult(sequence: "", headerStart: nil) }
        var sequence = String()
        sequence.reserveCapacity(max(256, output.count))
        var headerStart: Int?
        var sawHeader = false
        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            if trimmed.hasPrefix(">") {
                if !sawHeader {
                    sawHeader = true
                    headerStart = Self.parseConsensusHeaderStart(trimmed) ?? 0
                }
                return
            }
            sequence.append(trimmed.uppercased())
        }
        return ConsensusFASTAResult(sequence: sequence, headerStart: headerStart)
    }

    /// Extracts the 0-based start from a `>chrom:start-end` header, or `nil`
    /// when the header carries no region suffix. A contig name may itself
    /// contain colons (for example `HLA:A*01:01`), so only the final
    /// colon-delimited field is considered, and it must be a numeric range.
    private static func parseConsensusHeaderStart(_ header: String) -> Int? {
        guard let colonIdx = header.lastIndex(of: ":") else { return nil }
        let afterColon = header[header.index(after: colonIdx)...]
        guard let dashIdx = afterColon.firstIndex(of: "-") else { return nil }
        guard let start1based = Int(afterColon[afterColon.startIndex..<dashIdx]),
              start1based > 0,
              Int(afterColon[afterColon.index(after: dashIdx)...]) != nil else { return nil }
        return start1based - 1
    }

    // MARK: - Process Execution

    /// Maximum stdout data to buffer before truncating (500 MB).
    /// Coverage histograms need ALL reads — the 30s timeout is the real safety net.
    private static let maxStdoutSize = 500 * 1024 * 1024

    /// Runs samtools with the given arguments and returns its exit code, stdout
    /// and stderr. Cancelling the calling task stops samtools and its tree.
    private func runSamtools(arguments: [String], timeout: TimeInterval = 60) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try await Self.runSamtoolsProcess(samtoolsPath: try findSamtools(), arguments: arguments, timeout: timeout)
    }

    static func runSamtoolsProcess(
        samtoolsPath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(samtoolsSpec(samtoolsPath, arguments, timeout: timeout))
        } catch {
            throw samtoolsError(error)
        }
        try requireCompleteOutput(result)
        // Truncate if excessively large, keeping the first bytes as before.
        let stdout = result.stdout.count > maxStdoutSize ? result.stdout.prefix(maxStdoutSize) : result.stdout
        return (result.status, String(data: stdout, encoding: .utf8) ?? "", String(data: result.stderr, encoding: .utf8) ?? "")
    }

    /// Runs a sketch query without ever retaining an unbounded SAM stream.
    /// Stdout is read raw, retaining complete records only until either
    /// budget is reached, and then samtools and its tree are stopped.
    static func runSamtoolsProcessBudgeted(
        samtoolsPath: String,
        arguments: [String],
        timeout: TimeInterval,
        maxRecords: Int,
        maxBytes: Int,
        processStarted: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> BudgetedSamtoolsResult {
        let run = try await streamSamtools(
            samtoolsPath: samtoolsPath, arguments: arguments, timeout: timeout,
            stderrLimit: 1 << 20, initial: BudgetedSamtoolsState(maxRecords: maxRecords, maxBytes: maxBytes),
            onLaunch: processStarted
        ) { state, chunk in !state.consumeStdout(chunk) }
        return run.state.result(exitCode: run.result.status, stderr: run.result.stderr)
    }

    /// Runs samtools with its stdout read raw by `consume`, 64 KB at a time,
    /// until end of file or until `consume` returns false, which stops the
    /// run. Cancelling the calling task stops samtools and its tree promptly.
    private static func streamSamtools<State: Sendable>(
        samtoolsPath: String,
        arguments: [String],
        timeout: TimeInterval,
        stderrLimit: Int? = nil,
        initial: State,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil,
        consume: @escaping @Sendable (inout State, Data) -> Bool
    ) async throws -> (result: ToolProcessResult, state: State) {
        let run: ToolProcessRun
        do {
            run = try ToolProcess.start(
                samtoolsSpec(samtoolsPath, arguments, timeout: timeout, stdout: .stream, stderr: .capture(limit: stderrLimit)),
                onLaunch: onLaunch
            )
        } catch {
            throw samtoolsError(error)
        }
        let (state, stopped) = await withTaskCancellationHandler {
            let (state, stopped) = await run.stdout.drain((initial, false)) { drained, chunk in
                guard consume(&drained.0, chunk) else {
                    drained.1 = true
                    return false
                }
                return true
            }
            if stopped { run.cancel() }
            return (state, stopped)
        } onCancel: {
            run.cancel()
        }
        let result: ToolProcessResult
        do throws(ToolProcessError) {
            result = try await run.result()
        } catch .cancelled(let results) where stopped && !Task.isCancelled && !results.isEmpty {
            return (results[0], state)
        } catch {
            throw samtoolsError(error)
        }
        // The result carries a failed read of the stream as well.
        if !stopped { try requireCompleteOutput(result) }
        return (result, state)
    }

    /// samtools inherits the app's environment and working directory, as it
    /// did when it ran under Process.
    private static func samtoolsSpec(
        _ samtoolsPath: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        stdout: ToolProcessOutput = .capture(), stderr: ToolProcessOutput = .capture()
    ) -> ToolProcessSpec {
        ToolProcessSpec(
            executableURL: URL(fileURLWithPath: samtoolsPath),
            arguments: arguments,
            environment: ToolProcessSpec.inheritedEnvironment(),
            stdout: stdout, stderr: stderr,
            timeout: timeout.map { .seconds($0) },
            label: "samtools"
        )
    }

    /// The error the viewer has always seen for each way a run can fail to
    /// produce a result.
    private static func samtoolsError(_ error: ToolProcessError) -> Error {
        switch error {
        case .cancelled: return CancellationError()
        case .timedOut: return AlignmentFetchError.timeout
        case .invalidSpec, .launchFailed: return AlignmentFetchError.samtoolsNotFound
        }
    }

    /// Refuses output that a lingering descendant cut short or a read error
    /// lost, because a truncated read set must never pass as a complete one.
    private static func requireCompleteOutput(_ result: ToolProcessResult) throws {
        if let reason = result.incompleteOutputReason {
            throw AlignmentFetchError.samtoolsFailed(reason)
        }
    }

    /// Finds the samtools binary from standard locations.
    private func findSamtools() throws -> String {
        if let samtoolsPathOverride {
            return samtoolsPathOverride
        }
        guard let samtoolsPath = SamtoolsLocator.locate(searchPath: nil) else {
            throw AlignmentFetchError.samtoolsNotFound
        }
        return samtoolsPath
    }
}
