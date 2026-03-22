// ProvenanceRecorder.swift - Captures and persists workflow provenance
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import CryptoKit

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "ProvenanceRecorder")

// MARK: - ProvenanceRecorder

/// Singleton actor that records tool execution provenance.
///
/// Every `NativeToolRunner` invocation calls `recordStep()` to capture
/// the exact command, tool version, inputs, outputs, and timing. Steps
/// are grouped into `WorkflowRun` records, which are persisted as JSON
/// sidecar files alongside output directories.
///
/// ## Usage
///
/// ```swift
/// // Start a new run
/// let runID = await ProvenanceRecorder.shared.beginRun(name: "VCF Import")
///
/// // Record a step
/// await ProvenanceRecorder.shared.recordStep(
///     runID: runID,
///     toolName: "bcftools",
///     toolVersion: "1.21",
///     command: ["bcftools", "view", "-Oz", "input.vcf"],
///     inputs: [FileRecord(path: "input.vcf")],
///     outputs: [FileRecord(path: "output.vcf.gz")],
///     exitCode: 0,
///     wallTime: 12.5
/// )
///
/// // Complete the run
/// await ProvenanceRecorder.shared.completeRun(runID, status: .completed)
///
/// // Persist to disk
/// try await ProvenanceRecorder.shared.save(runID: runID, to: outputDirectory)
/// ```
public actor ProvenanceRecorder {

    // MARK: - Shared Instance

    public static let shared = ProvenanceRecorder()

    // MARK: - Properties

    /// Active and recently completed workflow runs, keyed by run ID.
    private var runs: [UUID: WorkflowRun] = [:]

    /// Maps output file paths to the run ID that produced them.
    private var outputIndex: [String: UUID] = [:]

    /// Maximum stderr length to store per step (10 KB).
    private static let maxStderrLength = 10_240

    // MARK: - Run Lifecycle

    /// Begins a new workflow run and returns its ID.
    ///
    /// - Parameters:
    ///   - name: Human-readable name for the run
    ///   - parameters: Top-level workflow parameters
    /// - Returns: The run ID for use in subsequent `recordStep` calls
    public func beginRun(
        name: String,
        parameters: [String: ParameterValue] = [:]
    ) -> UUID {
        let run = WorkflowRun(name: name, parameters: parameters)
        runs[run.id] = run
        logger.info("Provenance: began run '\(name)' [\(run.id)]")
        return run.id
    }

    /// Records a completed step execution in the given run.
    ///
    /// - Parameters:
    ///   - runID: The run this step belongs to (from `beginRun`)
    ///   - toolName: Name of the tool (e.g., "samtools")
    ///   - toolVersion: Version string
    ///   - containerImage: OCI image reference, if containerized
    ///   - containerDigest: SHA256 digest of the image
    ///   - command: Full argv as executed
    ///   - inputs: Input file records
    ///   - outputs: Output file records
    ///   - exitCode: Process exit code
    ///   - wallTime: Execution time in seconds
    ///   - stderr: Standard error output (truncated to 10 KB)
    ///   - dependsOn: IDs of upstream steps
    /// - Returns: The step ID
    @discardableResult
    public func recordStep(
        runID: UUID,
        toolName: String,
        toolVersion: String,
        containerImage: String? = nil,
        containerDigest: String? = nil,
        command: [String],
        inputs: [FileRecord],
        outputs: [FileRecord],
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String? = nil,
        dependsOn: [UUID] = []
    ) -> UUID? {
        guard runs[runID] != nil else {
            logger.warning("Provenance: no active run \(runID) — step not recorded")
            return nil
        }

        let truncatedStderr: String?
        if let stderr, stderr.count > Self.maxStderrLength {
            truncatedStderr = String(stderr.prefix(Self.maxStderrLength)) + "\n... [truncated]"
        } else {
            truncatedStderr = stderr
        }

        let step = StepExecution(
            toolName: toolName,
            toolVersion: toolVersion,
            containerImage: containerImage,
            containerDigest: containerDigest,
            command: command,
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: truncatedStderr,
            dependsOn: dependsOn,
            endTime: Date()
        )

        runs[runID]?.steps.append(step)

        // Index output files for lookup
        for output in outputs {
            outputIndex[output.path] = runID
        }

        logger.info("Provenance: recorded \(toolName) step in run \(runID) (exit \(exitCode))")
        return step.id
    }

    /// Marks a run as completed, failed, or cancelled.
    public func completeRun(_ runID: UUID, status: RunStatus) {
        guard runs[runID] != nil else { return }
        runs[runID]?.status = status
        runs[runID]?.endTime = Date()
        logger.info("Provenance: run \(runID) → \(status.rawValue)")
    }

    // MARK: - Queries

    /// Returns the workflow run with the given ID.
    public func getRun(_ runID: UUID) -> WorkflowRun? {
        runs[runID]
    }

    /// Finds the run that produced the given output file path.
    public func findRun(forOutputPath path: String) -> WorkflowRun? {
        guard let runID = outputIndex[path] else { return nil }
        return runs[runID]
    }

    /// Returns all runs, most recent first.
    public func allRuns() -> [WorkflowRun] {
        runs.values.sorted { $0.startTime > $1.startTime }
    }

    /// Returns runs that are still in progress.
    public func activeRuns() -> [WorkflowRun] {
        runs.values.filter { $0.status == .running }
    }

    // MARK: - Persistence

    /// Provenance filename written alongside outputs.
    public static let provenanceFilename = ".lungfish-provenance.json"

    /// Saves a run's provenance record as a JSON sidecar file.
    ///
    /// - Parameters:
    ///   - runID: The run to save
    ///   - directory: The output directory to write the sidecar into
    public func save(runID: UUID, to directory: URL) throws {
        guard let run = runs[runID] else {
            throw ProvenanceError.runNotFound(runID)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        let url = directory.appendingPathComponent(Self.provenanceFilename)
        try data.write(to: url, options: .atomic)
        logger.info("Provenance: saved run \(runID) to \(url.path)")
    }

    /// Loads a provenance record from a directory's sidecar file.
    ///
    /// - Parameter directory: Directory containing `.lungfish-provenance.json`
    /// - Returns: The decoded workflow run, or nil if no sidecar exists
    public static func load(from directory: URL) -> WorkflowRun? {
        let url = directory.appendingPathComponent(provenanceFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WorkflowRun.self, from: data)
    }

    /// Searches for a provenance record by walking up from a file path.
    ///
    /// Looks for `.lungfish-provenance.json` in the file's directory,
    /// then parent, up to 5 levels.
    ///
    /// - Parameter filePath: Path to a derivative file
    /// - Returns: The workflow run that produced it, or nil
    public static func findProvenance(forFile filePath: URL) -> WorkflowRun? {
        var dir = filePath.deletingLastPathComponent()
        for _ in 0..<5 {
            if let run = load(from: dir) {
                // Verify this run actually produced the file
                let filename = filePath.lastPathComponent
                let producedThis = run.allOutputFiles.contains { record in
                    record.path.hasSuffix(filename) || URL(fileURLWithPath: record.path).lastPathComponent == filename
                }
                if producedThis { return run }
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// Imports a previously saved provenance record into memory.
    public func importRun(_ run: WorkflowRun) {
        runs[run.id] = run
        for step in run.steps {
            for output in step.outputs {
                outputIndex[output.path] = run.id
            }
        }
    }

    // MARK: - Checksum Helpers

    /// Computes SHA-256 checksum of a file.
    ///
    /// For files larger than 100 MB, only the first and last 50 MB are hashed
    /// (with the file size mixed in) to avoid blocking on multi-GB genomes.
    public static func sha256(of url: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? UInt64) ?? 0
        let threshold: UInt64 = 100 * 1024 * 1024 // 100 MB

        if fileSize <= threshold {
            // Hash the entire file in chunks
            var hasher = SHA256()
            while autoreleasepool(invoking: {
                let chunk = fileHandle.readData(ofLength: 1_048_576) // 1 MB
                if chunk.isEmpty { return false }
                hasher.update(data: chunk)
                return true
            }) {}
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        } else {
            // Partial hash for large files: first 50 MB + size + last 50 MB
            var hasher = SHA256()
            let partialSize = 50 * 1024 * 1024

            // First 50 MB
            let head = fileHandle.readData(ofLength: partialSize)
            hasher.update(data: head)

            // Mix in file size
            var size = fileSize
            withUnsafeBytes(of: &size) { hasher.update(bufferPointer: $0) }

            // Last 50 MB
            fileHandle.seek(toFileOffset: fileSize - UInt64(partialSize))
            let tail = fileHandle.readData(ofLength: partialSize)
            hasher.update(data: tail)

            let digest = hasher.finalize()
            return "partial:" + digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Creates a FileRecord with computed checksum and size.
    public static func fileRecord(
        url: URL,
        format: FileFormat? = nil,
        role: FileRole = .input
    ) -> FileRecord {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? UInt64
        let checksum = sha256(of: url)
        let detectedFormat = format ?? detectFormat(url: url)

        return FileRecord(
            path: url.path,
            sha256: checksum,
            sizeBytes: size,
            format: detectedFormat,
            role: role
        )
    }

    /// Detects file format from extension.
    private static func detectFormat(url: URL) -> FileFormat {
        var ext = url.pathExtension.lowercased()
        if ext == "gz" {
            ext = url.deletingPathExtension().pathExtension.lowercased()
        }
        switch ext {
        case "fa", "fasta", "fna": return .fasta
        case "fq", "fastq": return .fastq
        case "bam": return .bam
        case "cram": return .cram
        case "sam": return .sam
        case "vcf": return .vcf
        case "bcf": return .bcf
        case "gff", "gff3": return .gff3
        case "bed": return .bed
        case "bb", "bigbed": return .bigBed
        case "bw", "bigwig": return .bigWig
        case "gb", "gbk", "genbank": return .genBank
        case "html": return .html
        case "json": return .json
        case "txt", "tsv", "csv", "log": return .text
        default: return .unknown
        }
    }
}

// MARK: - ProvenanceError

/// Errors related to provenance recording and retrieval.
public enum ProvenanceError: Error, LocalizedError, Sendable {
    case runNotFound(UUID)
    case noProvenanceAvailable(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runNotFound(let id):
            return "Provenance run '\(id)' not found"
        case .noProvenanceAvailable(let path):
            return "No provenance record found for '\(path)'"
        case .exportFailed(let reason):
            return "Provenance export failed: \(reason)"
        }
    }
}
