// ProvenanceRecorder.swift - Captures and persists workflow provenance
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

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

    /// Optional signer used after JSON sidecars are written.
    private var signingProvider: (any ProvenanceSigningProvider)?

    public init(signingProvider: (any ProvenanceSigningProvider)? = ProvenanceSigningConfiguration.defaultProvider()) {
        self.signingProvider = signingProvider
    }

    /// Overrides the signing provider for tests or app-managed settings.
    public func setSigningProvider(_ provider: (any ProvenanceSigningProvider)?) {
        signingProvider = provider
    }

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
    ///   - peakMemoryBytes: Peak resident memory in bytes, when available
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
        peakMemoryBytes: UInt64? = nil,
        stderr: String? = nil,
        dependsOn: [UUID] = []
    ) -> UUID? {
        guard runs[runID] != nil else {
            logger.warning("Provenance: no active run \(runID) — step not recorded")
            return nil
        }

        let truncatedStderr = ProvenanceStderr.truncated(stderr)

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
            peakMemoryBytes: peakMemoryBytes,
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
        let envelope = run.canonicalEnvelope()
        let url = try ProvenanceWriter(signingProvider: signingProvider).write(envelope, to: directory)
        logger.info("Provenance: saved canonical run \(runID) to \(url.path)")
    }

    /// Loads a canonical provenance envelope from a directory's sidecar file.
    ///
    /// - Parameter directory: Directory containing `.lungfish-provenance.json`
    /// - Returns: The decoded canonical envelope, or nil if no readable sidecar exists
    public static func loadEnvelope(from directory: URL) -> ProvenanceEnvelope? {
        try? ProvenanceEnvelopeReader.load(from: directory)
    }

    /// Loads a canonical provenance envelope from a specific sidecar file.
    ///
    /// File-producing CLI commands may write `output.ext.lungfish-provenance.json`
    /// beside the output to avoid one directory-level sidecar overwriting
    /// another output's provenance.
    public static func loadEnvelope(fromSidecar sidecarURL: URL) -> ProvenanceEnvelope? {
        try? ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL)
    }

    /// Loads a provenance record from a directory's sidecar file.
    ///
    /// - Parameter directory: Directory containing `.lungfish-provenance.json`
    /// - Returns: The decoded workflow run, or nil if no sidecar exists
    public static func load(from directory: URL) -> WorkflowRun? {
        loadEnvelope(from: directory)?.legacyWorkflowRun()
    }

    /// Searches for a provenance record by walking up from a file path.
    ///
    /// Looks for `.lungfish-provenance.json` in the file's directory,
    /// then parent, up to 5 levels.
    ///
    /// - Parameter filePath: Path to a derivative file
    /// - Returns: The workflow run that produced it, or nil
    public static func findProvenance(forFile filePath: URL) -> WorkflowRun? {
        findProvenanceEnvelope(for: filePath)?.envelope.legacyWorkflowRun()
    }

    /// Finds the canonical provenance sidecar that applies to a selected file or bundle directory.
    ///
    /// GUI menu actions often operate on a selected `.lungfish*` bundle directory rather than an
    /// individual payload file. This lookup checks bundle roots, documented `provenance/` roll-ups,
    /// exact file sidecars, and nearby parent-directory sidecars while still rejecting unrelated
    /// parent provenance for regular files.
    public static func findProvenanceEnvelope(
        for url: URL
    ) -> (sidecarURL: URL, envelope: ProvenanceEnvelope)? {
        let standardizedURL = url.standardizedFileURL
        let selectedIsDirectory = isDirectory(standardizedURL)

        if selectedIsDirectory {
            for candidate in directorySidecarCandidates(for: standardizedURL) {
                if let envelope = loadEnvelope(fromSidecar: candidate) {
                    return (candidate, envelope)
                }
            }
            if let mappingProvenance = mappingProvenanceCandidate(for: standardizedURL) {
                return mappingProvenance
            }
        } else if standardizedURL.lastPathComponent == MappingProvenance.filename,
                  let mappingProvenance = mappingProvenanceCandidate(
                    for: standardizedURL.deletingLastPathComponent()
                  ) {
            return mappingProvenance
        } else {
            for candidate in fileSidecarCandidates(for: standardizedURL) {
                if let envelope = loadEnvelope(fromSidecar: candidate) {
                    return (candidate, envelope)
                }
            }
        }

        var dir = selectedIsDirectory ? standardizedURL : standardizedURL.deletingLastPathComponent()
        var checkedSelectedDirectory = false
        for _ in 0..<5 {
            if let bundleSidecar = ProvenanceWriter.bundleOutputSidecarURL(for: standardizedURL, inBundle: dir),
               let envelope = loadEnvelope(fromSidecar: bundleSidecar),
               provenanceEnvelope(envelope, produced: standardizedURL) {
                return (bundleSidecar, envelope)
            }

            for candidate in directorySidecarCandidates(for: dir) {
                guard let envelope = loadEnvelope(fromSidecar: candidate) else { continue }
                if selectedIsDirectory && !checkedSelectedDirectory {
                    return (candidate, envelope)
                }
                if provenanceEnvelope(envelope, produced: standardizedURL) {
                    return (candidate, envelope)
                }
            }
            if let mappingProvenance = mappingProvenanceCandidate(for: dir) {
                if selectedIsDirectory && !checkedSelectedDirectory {
                    return mappingProvenance
                }
                if provenanceEnvelope(mappingProvenance.envelope, produced: standardizedURL) {
                    return mappingProvenance
                }
            }
            checkedSelectedDirectory = checkedSelectedDirectory || selectedIsDirectory
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    private static func mappingProvenanceCandidate(
        for directory: URL
    ) -> (sidecarURL: URL, envelope: ProvenanceEnvelope)? {
        let sidecarURL = directory.appendingPathComponent(MappingProvenance.filename)
        guard FileManager.default.fileExists(atPath: sidecarURL.path),
              let provenance = MappingProvenance.load(from: directory) else {
            return nil
        }
        return (sidecarURL, provenance.canonicalEnvelope(sourceDirectory: directory))
    }

    private static func directorySidecarCandidates(for directory: URL) -> [URL] {
        let operationCandidates = [
            directory
                .appendingPathComponent("assembly", isDirectory: true)
                .appendingPathComponent("provenance.json"),
            directory
                .appendingPathComponent("metadata", isDirectory: true)
                .appendingPathComponent("annotation-edit-provenance.json"),
            directory
                .appendingPathComponent("annotations", isDirectory: true)
                .appendingPathComponent("manual-annotation-provenance.json"),
            directory.appendingPathComponent("extraction-metadata.json"),
        ] + nestedOperationSidecarCandidates(for: directory)

        let canonicalCandidates = [
            directory.appendingPathComponent(provenanceFilename),
            directory
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(ProvenanceWriter.bundleRollupFilename),
            directory.appendingPathComponent(ProvenanceWriter.bundleRollupFilename),
            directory
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(provenanceFilename),
        ]
        return operationCandidates + canonicalCandidates
    }

    private static func fileSidecarCandidates(for fileURL: URL) -> [URL] {
        [fileSidecarURL(for: fileURL)]
            + alignmentArtifactSidecarCandidates(for: fileURL)
            + variantTrackSidecarCandidates(for: fileURL)
    }

    private static func alignmentArtifactSidecarCandidates(for fileURL: URL) -> [URL] {
        let alignmentURL = primaryAlignmentArtifactURL(for: fileURL)
        return [
            alignmentURL.deletingPathExtension().appendingPathExtension("primer-trim-provenance.json"),
            alignmentURL.deletingPathExtension().appendingPathExtension("adopt-mapping-provenance.json"),
        ]
    }

    private static func primaryAlignmentArtifactURL(for fileURL: URL) -> URL {
        let filename = fileURL.lastPathComponent
        if filename.hasSuffix(".bam.bai")
            || filename.hasSuffix(".bam.csi")
            || filename.hasSuffix(".cram.crai") {
            return fileURL.deletingPathExtension()
        }
        return fileURL
    }

    private static func variantTrackSidecarCandidates(for fileURL: URL) -> [URL] {
        guard let trackID = variantTrackID(forArtifactFilename: fileURL.lastPathComponent) else {
            return []
        }
        return [
            fileURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(trackID).lungfish-provenance.json")
        ]
    }

    private static func variantTrackID(forArtifactFilename filename: String) -> String? {
        let suffixes = [
            ".vcf.gz.tbi",
            ".vcf.gz.csi",
            ".vcf.gz.idx",
            ".vcf.gz",
            ".vcf.tbi",
            ".vcf.idx",
            ".vcf",
            ".bcf.csi",
            ".bcf",
            ".db",
        ]
        for suffix in suffixes where filename.hasSuffix(suffix) {
            let trackID = String(filename.dropLast(suffix.count))
            return trackID.isEmpty ? nil : trackID
        }
        return nil
    }

    private static func nestedOperationSidecarCandidates(for directory: URL) -> [URL] {
        guard ProvenanceWriter.isBundleDirectory(directory) else {
            return []
        }
        let variantsURL = directory.appendingPathComponent("variants", isDirectory: true)
        let annotationsURL = directory.appendingPathComponent("annotations", isDirectory: true)
        let alignmentsURL = directory.appendingPathComponent("alignments", isDirectory: true)
        return operationSidecars(in: variantsURL)
            + operationSidecars(in: variantsURL.appendingPathComponent("gatk", isDirectory: true))
            + operationSidecars(in: annotationsURL, recursive: true)
            + operationSidecars(in: alignmentsURL, recursive: true)
    }

    private static func operationSidecars(in directory: URL, recursive: Bool = false) -> [URL] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let urls: [URL]
        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys
            ) else {
                return []
            }
            urls = contents
        }
        return urls
            .filter { url in
                guard isOperationProvenanceSidecarFilename(url.lastPathComponent) else { return false }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true
            }
            .sorted { $0.path < $1.path }
    }

    private static func isOperationProvenanceSidecarFilename(_ filename: String) -> Bool {
        filename == provenanceFilename
            || filename == MappingProvenance.filename
            || filename == "annotation-edit-provenance.json"
            || filename == "manual-annotation-provenance.json"
            || filename == "extraction-metadata.json"
            || filename.hasSuffix(".lungfish-provenance.json")
            || filename.hasSuffix("-provenance.json")
    }

    private static func provenanceEnvelope(_ envelope: ProvenanceEnvelope, produced url: URL) -> Bool {
        let selectedPath = url.standardizedFileURL.path
        return envelope.outputs.contains { descriptor in
            let outputURL = URL(fileURLWithPath: descriptor.path).standardizedFileURL
            return outputURL.path == selectedPath
                || selectedPath.hasPrefix(outputURL.path + "/")
        } || envelope.steps.flatMap(\.outputs).contains { descriptor in
            let outputURL = URL(fileURLWithPath: descriptor.path).standardizedFileURL
            return outputURL.path == selectedPath
                || selectedPath.hasPrefix(outputURL.path + "/")
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public static func fileSidecarURL(for outputURL: URL) -> URL {
        URL(fileURLWithPath: "\(outputURL.path).lungfish-provenance.json")
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
    public static func sha256(of url: URL) -> String? {
        try? ProvenanceFileHasher.sha256(of: url)
    }

    /// Creates a FileRecord with computed checksum and size.
    public static func fileRecord(
        url: URL,
        format: FileFormat? = nil,
        role: FileRole = .input
    ) -> FileRecord {
        let size = try? ProvenanceFileHasher.fileSize(of: url)
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
