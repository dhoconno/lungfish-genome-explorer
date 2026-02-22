// AlignmentDataProvider.swift - Fetches aligned reads from BAM/CRAM via samtools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

/// Logger for alignment data operations
private let alignmentLogger = Logger(subsystem: "com.lungfish.browser", category: "AlignmentDataProvider")

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
        maxReads: Int = 10_000,
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

        // Region string (samtools uses 1-based coordinates)
        let regionStr = "\(chromosome):\(start + 1)-\(end)"
        arguments += [alignmentPath, regionStr]

        alignmentLogger.debug("Fetching reads: samtools \(arguments.joined(separator: " "))")

        let result = try await runSamtools(arguments: arguments)

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
        let result = try await runSamtools(arguments: ["idxstats", alignmentPath])
        guard result.exitCode == 0 else {
            throw AlignmentFetchError.samtoolsFailed(result.stderr)
        }
        return result.stdout
    }

    /// Runs samtools flagstat on the alignment file.
    ///
    /// Returns human-readable flag statistics.
    public func fetchFlagstat() async throws -> String {
        let result = try await runSamtools(arguments: ["flagstat", alignmentPath])
        guard result.exitCode == 0 else {
            throw AlignmentFetchError.samtoolsFailed(result.stderr)
        }
        return result.stdout
    }

    // MARK: - Process Execution

    /// Runs samtools with the given arguments using Process.
    ///
    /// This uses Process directly rather than NativeToolRunner to keep
    /// LungfishIO independent of LungfishWorkflow. The samtools binary
    /// is discovered from common locations.
    private func runSamtools(arguments: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
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

            // Read output asynchronously
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            continuation.resume(returning: (process.terminationStatus, stdout, stderr))
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
