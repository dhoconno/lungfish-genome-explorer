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

private final class PipeReadBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

final class SamtoolsCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let onInstall: (@Sendable () -> Void)?
    init(onInstall: (@Sendable () -> Void)? = nil) { self.onInstall = onInstall }
    func install(_ process: Process) { lock.lock(); self.process = process; let cancel = cancelled; lock.unlock(); onInstall?(); if cancel { process.terminate() } }
    func cancel() { lock.lock(); cancelled = true; let process = process; lock.unlock(); process?.terminate() }
}

// MARK: - DepthPoint

/// Per-position read depth from `samtools depth`.
public struct DepthPoint: Sendable, Equatable {
    /// Chromosome/contig name.
    public let chromosome: String
    /// 0-based reference position.
    public let position: Int
    /// Depth at the position.
    public let depth: Int

    public init(chromosome: String, position: Int, depth: Int) {
        self.chromosome = chromosome
        self.position = position
        self.depth = depth
    }
}

/// Consensus caller mode for `samtools consensus`.
public enum AlignmentConsensusMode: String, Sendable, CaseIterable {
    case bayesian
    case simple
}

/// The effective read filters applied to both consensus calling and depth.
public struct AlignmentConsensusFilters: Sendable, Equatable {
    public let minimumDepth: Int
    public let minimumMapQ: Int
    public let minimumBaseQuality: Int
    public let excludedFlags: UInt16
    public let readGroups: Set<String>

    public init(
        minimumDepth: Int,
        minimumMapQ: Int,
        minimumBaseQuality: Int,
        excludedFlags: UInt16,
        readGroups: Set<String>
    ) {
        self.minimumDepth = minimumDepth
        self.minimumMapQ = minimumMapQ
        self.minimumBaseQuality = minimumBaseQuality
        self.excludedFlags = excludedFlags
        self.readGroups = readGroups
    }
}

/// A reference-coordinate consensus request and its evidence filters.
public struct AlignmentConsensusRequest: Sendable, Equatable {
    public enum InsertionPolicy: String, Sendable {
        case omit
        case include
    }

    public enum DeletionPolicy: String, Sendable {
        case n
        case omit
    }

    public let chromosome: String
    public let start: Int
    public let end: Int
    public let filters: AlignmentConsensusFilters
    public let mode: AlignmentConsensusMode
    public let useAmbiguity: Bool
    public let insertionPolicy: InsertionPolicy
    public let deletionPolicy: DeletionPolicy

    public init(
        chromosome: String,
        start: Int,
        end: Int,
        filters: AlignmentConsensusFilters,
        mode: AlignmentConsensusMode,
        useAmbiguity: Bool,
        insertionPolicy: InsertionPolicy,
        deletionPolicy: DeletionPolicy
    ) {
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.filters = filters
        self.mode = mode
        self.useAmbiguity = useAmbiguity
        self.insertionPolicy = insertionPolicy
        self.deletionPolicy = deletionPolicy
    }
}

/// An evidence-derived consensus projected onto the requested reference range.
public struct AlignmentConsensusResult: Sendable, Equatable {
    public let sequence: String
    public let referenceLength: Int
    public let allLowDepth: Bool
    /// Staging-only subprocess evidence for a consensus request. Durable output
    /// provenance must copy these records while replacing staging paths.
    public let executionRecords: [AlignmentConsensusExecutionRecord]

    public init(
        sequence: String,
        referenceLength: Int,
        allLowDepth: Bool,
        executionRecords: [AlignmentConsensusExecutionRecord] = []
    ) {
        self.sequence = sequence
        self.referenceLength = referenceLength
        self.allLowDepth = allLowDepth
        self.executionRecords = executionRecords
    }
}

/// A checksummed input or staging artifact involved in consensus execution.
public struct AlignmentConsensusFileDescriptor: Sendable, Equatable {
    public let path: String
    public let checksumSHA256: String?
    public let fileSize: UInt64?

    public init(path: String, checksumSHA256: String?, fileSize: UInt64?) {
        self.path = path
        self.checksumSHA256 = checksumSHA256
        self.fileSize = fileSize
    }
}

/// The contents and checksum of the deterministic read-group selection file.
public struct AlignmentConsensusReadGroupFile: Sendable, Equatable {
    public let path: String
    public let contents: String
    public let checksumSHA256: String

    public init(path: String, contents: String, checksumSHA256: String) {
        self.path = path
        self.contents = contents
        self.checksumSHA256 = checksumSHA256
    }
}

/// A reproducible execution record for one request-scoped samtools stage.
public struct AlignmentConsensusExecutionRecord: Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable {
        case view
        case index
        case consensus
        case depth
    }

    public let stage: Stage
    public let executablePath: String
    /// The provider deliberately avoids a fifth scientific subprocess solely to
    /// probe a version; Task 7 can replace this provenance hint with its tool
    /// registry's resolved version when publishing a durable output.
    public let executableVersion: String
    public let runtimeIdentity: String
    public let argv: [String]
    public let reproducibleCommand: String
    public let inputs: [AlignmentConsensusFileDescriptor]
    public let outputs: [AlignmentConsensusFileDescriptor]
    public let readGroupFile: AlignmentConsensusReadGroupFile?
    public let resolvedDefaults: [String: String]
    public let exitStatus: Int32?
    public let startedAt: Date
    public let endedAt: Date
    public let wallTimeSeconds: TimeInterval
    public let stderr: String?

    public init(
        stage: Stage,
        executablePath: String,
        executableVersion: String,
        runtimeIdentity: String,
        argv: [String],
        reproducibleCommand: String,
        inputs: [AlignmentConsensusFileDescriptor],
        outputs: [AlignmentConsensusFileDescriptor],
        readGroupFile: AlignmentConsensusReadGroupFile?,
        resolvedDefaults: [String: String],
        exitStatus: Int32?,
        startedAt: Date,
        endedAt: Date,
        wallTimeSeconds: TimeInterval,
        stderr: String?
    ) {
        self.stage = stage
        self.executablePath = executablePath
        self.executableVersion = executableVersion
        self.runtimeIdentity = runtimeIdentity
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand
        self.inputs = inputs
        self.outputs = outputs
        self.readGroupFile = readGroupFile
        self.resolvedDefaults = resolvedDefaults
        self.exitStatus = exitStatus
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.wallTimeSeconds = wallTimeSeconds
        self.stderr = stderr
    }
}

/// Enforces the evidence-only postcondition for a caller's reference projection.
public enum AlignmentConsensusNormalizer {
    /// Aligns caller bases to the request and masks every coordinate below the
    /// effective depth threshold. This operation never accepts reference bases.
    public static func normalize(
        caller: AlignmentDataProvider.ConsensusFASTAResult,
        depth: [DepthPoint],
        request: AlignmentConsensusRequest
    ) throws -> AlignmentConsensusResult {
        guard request.insertionPolicy == .omit,
              request.deletionPolicy == .n,
              let callerStart = caller.headerStart,
              !request.chromosome.isEmpty,
              request.start >= 0,
              request.end > request.start else {
            throw AlignmentFetchError.consensusCoordinateMismatch
        }

        let callerBases = Array(caller.sequence)
        let callerEnd = callerStart + callerBases.count
        guard callerStart <= request.start, callerEnd == request.end else {
            throw AlignmentFetchError.consensusCoordinateMismatch
        }

        let referenceLength = request.end - request.start
        let callerOffset = request.start - callerStart
        guard callerOffset >= 0, callerOffset + referenceLength == callerBases.count else {
            throw AlignmentFetchError.consensusCoordinateMismatch
        }

        var depths = Array(repeating: 0, count: referenceLength)
        for point in depth where point.chromosome == request.chromosome && point.position >= request.start && point.position < request.end {
            depths[point.position - request.start] = point.depth
        }

        // Keep the postcondition threshold identical to `samtools consensus`,
        // whose `-d` value is clamped to one at process construction.
        let minimumDepth = max(1, request.filters.minimumDepth)
        let normalizedBases = (0..<referenceLength).map { offset -> Character in
            guard depths[offset] >= minimumDepth else { return "N" }
            let callerBase = callerBases[callerOffset + offset]
            return callerBase == "*" ? "N" : callerBase
        }
        let sequence = String(normalizedBases)
        return AlignmentConsensusResult(
            sequence: sequence,
            referenceLength: referenceLength,
            allLowDepth: depths.allSatisfy { $0 < minimumDepth }
        )
    }
}

/// A bounded, representative read set for fast first-pass alignment rendering.
public struct AlignmentReadSketch: Sendable {
    public let reads: [AlignedRead]
    public let estimatedTotalReads: Int
    public let targetReads: Int
    public let isSubsampled: Bool
    public let transportTruncated: Bool

    public init(reads: [AlignedRead], estimatedTotalReads: Int, targetReads: Int, isSubsampled: Bool, transportTruncated: Bool = false) {
        self.reads = reads
        self.estimatedTotalReads = estimatedTotalReads
        self.targetReads = targetReads
        self.isSubsampled = isSubsampled
        self.transportTruncated = transportTruncated
    }
}

struct BudgetedSamtoolsResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let terminatedForBudget: Bool
    let retainedRecordCount: Int
}

private final class BudgetedSamtoolsState: @unchecked Sendable {
    private let lock = NSLock()
    private var retained = Data(), pending = Data(), stderr = Data()
    private var records = 0, budgetReached = false
    private let maxRecords: Int, maxBytes: Int, maxStderrBytes: Int
    init(maxRecords: Int, maxBytes: Int, maxStderrBytes: Int = 1 << 20) { self.maxRecords = maxRecords; self.maxBytes = maxBytes; self.maxStderrBytes = maxStderrBytes }
    /// Returns true exactly once when the process must be stopped.
    func consumeStdout(_ chunk: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
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
    func consumeStderr(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; if stderr.count < maxStderrBytes { stderr.append(chunk.prefix(maxStderrBytes - stderr.count)) } }
    func result(exitCode: Int32) -> BudgetedSamtoolsResult { lock.lock(); defer { lock.unlock() }; return .init(exitCode: exitCode, stdout: String(data: retained, encoding: .utf8) ?? "", stderr: String(data: stderr, encoding: .utf8) ?? "", terminatedForBudget: budgetReached, retainedRecordCount: records) }
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
    ///   - excludeFlags: SAM flag filter to exclude (default: unmapped | secondary | supplementary | dup = 0x904)
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
        let finalArguments = arguments
        let samtoolsPath = try findSamtools()
        let cancellation = SamtoolsCancellation()
        let result = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let value = try await Task.detached(priority: .userInitiated) {
                try Self.runSamtoolsProcessBudgeted(
                    samtoolsPath: samtoolsPath, arguments: finalArguments, timeout: 30,
                    maxRecords: maxReads, maxBytes: byteBudget, cancellation: cancellation
                )
            }.value
            try Task.checkCancellation()
            return value
        }, onCancel: { cancellation.cancel() })
        guard result.exitCode == 0 || result.terminatedForBudget else {
            throw AlignmentFetchError.samtoolsFailed(result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr)
        }
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
        let startedAt = Date()
        do {
            let result = try await runSamtools(arguments: arguments, timeout: timeout)
            if let capturedStdoutURL {
                try Data(result.stdout.utf8).write(to: capturedStdoutURL, options: .atomic)
            }
            let endedAt = Date()
            let record = consensusExecutionRecord(
                stage: stage, samtoolsPath: samtoolsPath, samtoolsVersion: samtoolsVersion, arguments: arguments,
                inputs: inputs, outputs: outputs, readGroupFile: readGroupFile,
                defaults: defaults, exitStatus: result.exitCode,
                startedAt: startedAt, endedAt: endedAt, stderr: result.stderr
            )
            records.append(record)
            guard result.exitCode == 0 else {
                throw AlignmentFetchError.consensusExecutionFailed(records)
            }
            return result
        } catch let error as AlignmentFetchError {
            if case .consensusExecutionFailed = error { throw error }
            let endedAt = Date()
            records.append(consensusExecutionRecord(
                stage: stage, samtoolsPath: samtoolsPath, samtoolsVersion: samtoolsVersion, arguments: arguments,
                inputs: inputs, outputs: outputs, readGroupFile: readGroupFile,
                defaults: defaults, exitStatus: nil,
                startedAt: startedAt, endedAt: endedAt,
                stderr: error.localizedDescription
            ))
            throw AlignmentFetchError.consensusExecutionFailed(records)
        } catch {
            let endedAt = Date()
            records.append(consensusExecutionRecord(
                stage: stage, samtoolsPath: samtoolsPath, samtoolsVersion: samtoolsVersion, arguments: arguments,
                inputs: inputs, outputs: outputs, readGroupFile: readGroupFile,
                defaults: defaults, exitStatus: nil,
                startedAt: startedAt, endedAt: endedAt,
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

    /// Runs samtools with the given arguments using Process.
    ///
    /// Reads stdout and stderr concurrently to prevent pipe deadlock when one
    /// buffer fills (typically 64 KB on macOS). Uses a timeout to prevent
    /// runaway processes.
    ///
    /// - Parameters:
    ///   - arguments: Arguments to pass to samtools
    ///   - timeout: Maximum execution time in seconds (default: 60)
    /// - Returns: Exit code, stdout string, stderr string
    /// - Throws: AlignmentFetchError on failure
    private func runSamtools(arguments: [String], timeout: TimeInterval = 60) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let samtoolsPath = try findSamtools()

        let cancellation = SamtoolsCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let value = try await Task.detached(priority: .userInitiated) {
                try Self.runSamtoolsProcess(samtoolsPath: samtoolsPath, arguments: arguments, timeout: timeout, cancellation: cancellation)
            }.value
            try Task.checkCancellation()
            return value
        }, onCancel: { cancellation.cancel() })
    }

    static func runSamtoolsProcess(
        samtoolsPath: String,
        arguments: [String],
        timeout: TimeInterval,
        cancellation: SamtoolsCancellation? = nil
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtoolsPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AlignmentFetchError.samtoolsNotFound
        }
        cancellation?.install(process)

        // Read stdout and stderr CONCURRENTLY to prevent pipe deadlock.
        // If we read sequentially, filling one pipe's buffer (64 KB) blocks
        // the child process, which prevents it from writing to the other pipe,
        // which prevents us from finishing our read — classic deadlock.
        let stdoutBuffer = PipeReadBuffer()
        let stderrBuffer = PipeReadBuffer()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            // Truncate if excessively large to prevent memory exhaustion
            if data.count > AlignmentDataProvider.maxStdoutSize {
                data = data.prefix(AlignmentDataProvider.maxStdoutSize)
            }
            stdoutBuffer.store(data)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBuffer.store(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        // Timeout: if the process doesn't finish, terminate it.
        let timeoutResult = group.wait(timeout: .now() + timeout)
        if timeoutResult == .timedOut {
            process.terminate()
            // Close pipe read ends to unblock the GCD reader blocks
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            // Wait for GCD blocks to complete (they will now return quickly since pipes are closed)
            _ = group.wait(timeout: .now() + 5)
            throw AlignmentFetchError.timeout
        }

        process.waitUntilExit()

        let stdout = String(data: stdoutBuffer.load(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrBuffer.load(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    /// Runs a sketch query without ever retaining an unbounded SAM stream. Stdout
    /// is consumed in a background reader, retaining complete records only until
    /// either budget is reached; the child is then terminated while both pipes are
    /// drained so a noisy stderr cannot deadlock the caller.
    static func runSamtoolsProcessBudgeted(
        samtoolsPath: String,
        arguments: [String],
        timeout: TimeInterval,
        maxRecords: Int,
        maxBytes: Int,
        cancellation: SamtoolsCancellation? = nil,
        processStarted: ((pid_t) -> Void)? = nil
    ) throws -> BudgetedSamtoolsResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtoolsPath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do { try process.run() } catch { throw AlignmentFetchError.samtoolsNotFound }
        processStarted?(process.processIdentifier)
        cancellation?.install(process)

        let state = BudgetedSamtoolsState(maxRecords: maxRecords, maxBytes: maxBytes)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            while true {
                let chunk = stdoutPipe.fileHandleForReading.readData(ofLength: 64 * 1024)
                guard !chunk.isEmpty else { return }
                if state.consumeStdout(chunk) { process.terminate() }
            }
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            while true {
                let chunk = stderrPipe.fileHandleForReading.readData(ofLength: 64 * 1024)
                guard !chunk.isEmpty else { return }
                state.consumeStderr(chunk)
            }
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = kill(process.processIdentifier, SIGKILL)
            // The owner, not either reader, owns process reaping. Waiting here
            // guarantees a timed-out child cannot remain as a zombie/orphan.
            process.waitUntilExit()
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = group.wait(timeout: .now() + 5)
            throw AlignmentFetchError.timeout
        }
        process.waitUntilExit()
        return state.result(exitCode: process.terminationStatus)
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

// MARK: - AlignmentFetchError

/// Errors from alignment data fetching.
public enum AlignmentFetchError: Error, LocalizedError, Sendable {
    case samtoolsNotFound
    case samtoolsFailed(String)
    case invalidRegion(String)
    case consensusCoordinateMismatch
    case consensusCoordinateMismatchWithRecords([AlignmentConsensusExecutionRecord])
    case consensusExecutionFailed([AlignmentConsensusExecutionRecord])
    case timeout

    public var errorDescription: String? {
        switch self {
        case .samtoolsNotFound:
            return "samtools not found in the managed Lungfish tool environment."
        case .samtoolsFailed(let msg):
            return "samtools failed: \(msg)"
        case .invalidRegion(let region):
            return "Invalid region: \(region)"
        case .consensusCoordinateMismatch:
            return "Consensus output does not project exactly onto the requested reference interval."
        case .consensusCoordinateMismatchWithRecords:
            return "Consensus output does not project exactly onto the requested reference interval; execution records are attached."
        case .consensusExecutionFailed(let records):
            let stage = records.last?.stage.rawValue ?? "unknown"
            let stderr = records.last?.stderr ?? ""
            return "Consensus \(stage) stage failed\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .timeout:
            return "samtools timed out"
        }
    }
}
