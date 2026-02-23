// AlignmentDataProvider.swift - Fetches aligned reads from BAM/CRAM via samtools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

/// Logger for alignment data operations
private let alignmentLogger = Logger(subsystem: "com.lungfish.browser", category: "AlignmentDataProvider")

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
        readGroups: Set<String> = []
    ) async throws -> [AlignedRead] {
        guard !chromosome.isEmpty, start >= 0, end > start else {
            throw AlignmentFetchError.invalidRegion("\(chromosome):\(start)-\(end)")
        }
        guard maxReads > 0 else { return [] }

        // Build samtools view command
        var arguments = ["view"]
        arguments += ["-F", String(excludeFlags)]
        if minMapQ > 0 {
            arguments += ["-q", String(minMapQ)]
        }

        // Read group filter: -r includes reads from specific read groups
        for rg in readGroups.sorted() {
            arguments += ["-r", rg]
        }

        // CRAM needs reference
        if format == .cram, let refPath = referenceFastaPath {
            arguments += ["--reference", refPath]
        }

        // Cap output at source to avoid reading excessive data from deep-coverage regions.
        // samtools -c/--subsample is not a read limit; use head-based limit via maxReads in parser.
        // However, we still want to limit what samtools emits. Use -s for subsampling isn't right either.
        // The real limit is applied at parse time, but we avoid piping 100MB+ for deep coverage.

        // Region string (samtools uses 1-based coordinates)
        let regionStr = "\(chromosome):\(start + 1)-\(end)"
        arguments += [alignmentPath, regionStr]

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
    /// Returns human-readable flag statistics.
    public func fetchFlagstat() async throws -> String {
        let result = try await runSamtools(arguments: ["flagstat", alignmentPath], timeout: 120)
        guard result.exitCode == 0 else {
            throw AlignmentFetchError.samtoolsFailed(result.stderr)
        }
        return result.stdout
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
        if minMapQ > 0 {
            arguments += ["-q", String(minMapQ)]
        }
        if minBaseQ > 0 {
            arguments += ["-Q", String(minBaseQ)]
        }
        if excludeFlags != 0 {
            arguments += ["-G", String(excludeFlags)]
        }
        if format == .cram, let refPath = referenceFastaPath {
            arguments += ["--reference", refPath]
        }

        let regionStr = "\(chromosome):\(start + 1)-\(end)"
        arguments += ["-r", regionStr, alignmentPath]

        alignmentLogger.debug("Fetching depth: samtools \(arguments.joined(separator: " "))")
        let result = try await runSamtools(arguments: arguments, timeout: 30)
        guard result.exitCode == 0 else {
            let errorMsg = result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr
            throw AlignmentFetchError.samtoolsFailed(errorMsg)
        }
        return Self.parseDepthOutput(result.stdout)
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
        guard !chromosome.isEmpty, start >= 0, end > start else {
            throw AlignmentFetchError.invalidRegion("\(chromosome):\(start)-\(end)")
        }

        var arguments = ["consensus"]
        let regionStr = "\(chromosome):\(start + 1)-\(end)"
        arguments += ["-r", regionStr]
        // -a: output ALL positions including those with no coverage.
        // Without this flag, samtools 1.22+ drops uncovered positions from
        // region queries, shifting the output string relative to the requested
        // coordinates and causing consensus bases to render at wrong positions.
        arguments += ["-a"]
        arguments += ["-f", "FASTA"]
        arguments += ["-m", mode.rawValue]
        arguments += ["--min-MQ", String(max(0, minMapQ))]
        arguments += ["--min-BQ", String(max(0, minBaseQ))]
        arguments += ["-d", String(max(1, minDepth))]
        if excludeFlags != 0 {
            arguments += ["--ff", String(excludeFlags)]
        }
        // Keep deleted reference columns so consensus coordinates remain 1:1 with
        // reference coordinates across the full region (prevents progressive drift).
        arguments += ["--show-del", showDeletions ? "yes" : "no"]
        arguments += ["--show-ins", showInsertions ? "yes" : "no"]
        if useAmbiguity {
            arguments.append("-A")
        }
        if format == .cram, let refPath = referenceFastaPath {
            arguments += ["--reference", refPath]
        }
        arguments.append(alignmentPath)

        alignmentLogger.debug("Fetching consensus: samtools \(arguments.joined(separator: " "))")
        let result = try await runSamtools(arguments: arguments, timeout: 45)
        guard result.exitCode == 0 else {
            let errorMsg = result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr
            throw AlignmentFetchError.samtoolsFailed(errorMsg)
        }
        return Self.parseConsensusFASTA(result.stdout)
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
    /// The header typically has the format `>chrom:start-end` (1-based inclusive).
    /// Parsing it allows us to determine the actual start position of the consensus
    /// output, which may differ from the requested region when samtools clips to
    /// the data range or when the `-a` flag is unsupported.
    static func parseConsensusFASTA(_ output: String) -> ConsensusFASTAResult {
        guard !output.isEmpty else { return ConsensusFASTAResult(sequence: "", headerStart: nil) }
        var sequence = String()
        sequence.reserveCapacity(max(256, output.count))
        var headerStart: Int?
        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            if trimmed.hasPrefix(">") {
                // Parse region from header: >chrom:start-end (1-based inclusive)
                if headerStart == nil, let colonIdx = trimmed.firstIndex(of: ":") {
                    let afterColon = trimmed[trimmed.index(after: colonIdx)...]
                    if let dashIdx = afterColon.firstIndex(of: "-") {
                        let startStr = afterColon[afterColon.startIndex..<dashIdx]
                        if let start1based = Int(startStr), start1based > 0 {
                            headerStart = start1based - 1  // Convert to 0-based
                        }
                    }
                }
                return
            }
            sequence.append(trimmed.uppercased())
        }
        return ConsensusFASTAResult(sequence: sequence, headerStart: headerStart)
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

        return try await withCheckedThrowingContinuation { continuation in
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
                continuation.resume(throwing: AlignmentFetchError.samtoolsNotFound)
                return
            }

            // Read stdout and stderr CONCURRENTLY to prevent pipe deadlock.
            // If we read sequentially, filling one pipe's buffer (64 KB) blocks
            // the child process, which prevents it from writing to the other pipe,
            // which prevents us from finishing our read — classic deadlock.
            var stdoutData = Data()
            var stderrData = Data()
            let group = DispatchGroup()

            // Guard against double-resume: only the first path to set this resumes the continuation.
            // The timeout path and the normal completion path race; an unfair lock ensures exactly one wins.
            var resumed = false
            let lock = NSLock()

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                // Truncate if excessively large to prevent memory exhaustion
                if stdoutData.count > AlignmentDataProvider.maxStdoutSize {
                    stdoutData = stdoutData.prefix(AlignmentDataProvider.maxStdoutSize)
                }
                group.leave()
            }

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            // Timeout: if the process doesn't finish, terminate it
            let timeoutResult = group.wait(timeout: .now() + timeout)
            if timeoutResult == .timedOut {
                process.terminate()
                // Close pipe read ends to unblock the GCD reader blocks
                stdoutPipe.fileHandleForReading.closeFile()
                stderrPipe.fileHandleForReading.closeFile()
                // Wait for GCD blocks to complete (they will now return quickly since pipes are closed)
                group.wait(timeout: .now() + 5)

                lock.lock()
                let shouldResume = !resumed
                resumed = true
                lock.unlock()
                if shouldResume {
                    continuation.resume(throwing: AlignmentFetchError.timeout)
                }
                return
            }

            process.waitUntilExit()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            lock.lock()
            let shouldResume = !resumed
            resumed = true
            lock.unlock()
            if shouldResume {
                continuation.resume(returning: (process.terminationStatus, stdout, stderr))
            }
        }
    }

    /// Finds the samtools binary from standard locations.
    private func findSamtools() throws -> String {
        // 1. Check app bundle Resources/Tools
        if let bundlePath = Bundle.main.resourceURL?
            .appendingPathComponent("Tools/samtools").path,
           FileManager.default.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }

        // 2. Check adjacent Tools directory (development/testing)
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let devPath = execDir?.appendingPathComponent("Tools/samtools").path,
           FileManager.default.isExecutableFile(atPath: devPath) {
            return devPath
        }

        // 3. Check common system paths
        let systemPaths = [
            "/usr/local/bin/samtools",
            "/opt/homebrew/bin/samtools",
            "/usr/bin/samtools"
        ]
        for path in systemPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 4. Search PATH from environment
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = String(dir) + "/samtools"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        throw AlignmentFetchError.samtoolsNotFound
    }
}

// MARK: - AlignmentFetchError

/// Errors from alignment data fetching.
public enum AlignmentFetchError: Error, LocalizedError, Sendable {
    case samtoolsNotFound
    case samtoolsFailed(String)
    case invalidRegion(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .samtoolsNotFound:
            return "samtools not found. Ensure it is installed or bundled with the app."
        case .samtoolsFailed(let msg):
            return "samtools failed: \(msg)"
        case .invalidRegion(let region):
            return "Invalid region: \(region)"
        case .timeout:
            return "samtools timed out"
        }
    }
}
