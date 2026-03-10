// DemultiplexingPipeline.swift - Cutadapt-based barcode demultiplexing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "DemultiplexingPipeline")

// MARK: - Demultiplex Configuration

/// Configuration for a cutadapt-based demultiplexing run.
public struct DemultiplexConfig: Sendable {
    /// Input FASTQ file URL (may be inside a .lungfishfastq bundle or standalone).
    public let inputURL: URL

    /// Barcode kit definition (built-in or custom).
    public let barcodeKit: BarcodeKitDefinition

    /// Output directory for per-barcode .lungfishfastq bundles.
    public let outputDirectory: URL

    /// Where barcodes are located in the reads.
    public let barcodeLocation: BarcodeLocation

    /// How barcode ends relate (symmetric, asymmetric, single-end).
    /// Defaults from kit's pairing mode but can be overridden.
    public let symmetryMode: BarcodeSymmetryMode

    /// Maximum error rate for barcode matching (cutadapt -e).
    /// Defaults from platform's recommended rate.
    public let errorRate: Double

    /// Minimum overlap between barcode and read (cutadapt --overlap).
    /// Defaults from platform's recommended overlap.
    public let minimumOverlap: Int

    /// Maximum bases from the 5' terminus where a barcode may begin.
    public let maxDistanceFrom5Prime: Int

    /// Maximum bases from the 3' terminus where a barcode may end.
    public let maxDistanceFrom3Prime: Int

    /// Whether to trim barcode sequences from output reads.
    public let trimBarcodes: Bool

    /// Whether to search both strand orientations (--revcomp).
    /// Defaults to true for long-read platforms (ONT, PacBio).
    public let searchReverseComplement: Bool

    /// What to do with reads that don't match any barcode.
    public let unassignedDisposition: UnassignedDisposition

    /// Poly-G trim quality threshold for two-color SBS platforms (cutadapt --nextseq-trim=N).
    ///
    /// Set to a quality score (e.g. 20) to enable poly-G trimming, or nil to disable.
    /// Defaults from platform: Illumina/Element = 20, others = nil (disabled).
    public let polyGTrimQuality: Int?

    /// Number of threads for cutadapt (--cores).
    public let threads: Int

    /// Optional adapter context override.
    ///
    /// When nil (the default), the adapter context is derived from the kit's
    /// platform and kit type. Set this to override the default context for
    /// custom adapter constructs.
    public let adapterContext: (any PlatformAdapterContext)?

    /// Optional explicit asymmetric sample assignments.
    ///
    /// When present, these are used to build linked 5'/3' adapters directly,
    /// avoiding cartesian expansion for combinatorial kits.
    public let sampleAssignments: [FASTQSampleBarcodeAssignment]

    /// The platform that generated the FASTQ reads (may differ from the barcode kit's platform).
    /// When set and different from the kit's platform, the effective error rate is
    /// max(config.errorRate, sourcePlatform.recommendedErrorRate).
    public var sourcePlatform: SequencingPlatform?

    /// Root bundle URL for writing derived manifests in virtual demux bundles.
    /// When set, each per-barcode bundle will contain a derived-manifest.json
    /// pointing back to this root for on-demand materialization.
    public let rootBundleURL: URL?

    /// Root FASTQ filename inside the root bundle (e.g., "reads.fastq.gz").
    public let rootFASTQFilename: String?

    /// Resolved adapter context (uses override if set, otherwise derives from kit).
    public var resolvedAdapterContext: any PlatformAdapterContext {
        adapterContext ?? barcodeKit.adapterContext
    }

    /// Effective error rate accounting for cross-platform scenarios.
    ///
    /// When the source platform differs from the kit's platform (e.g., PacBio kit on ONT reads),
    /// uses the higher of the configured error rate and the source platform's recommended rate.
    public var effectiveErrorRate: Double {
        guard let sourcePlatform, sourcePlatform != barcodeKit.platform else {
            return errorRate
        }
        return max(errorRate, sourcePlatform.recommendedErrorRate)
    }

    public init(
        inputURL: URL,
        barcodeKit: BarcodeKitDefinition,
        outputDirectory: URL,
        barcodeLocation: BarcodeLocation = .bothEnds,
        symmetryMode: BarcodeSymmetryMode? = nil,
        errorRate: Double? = nil,
        minimumOverlap: Int? = nil,
        maxDistanceFrom5Prime: Int = 0,
        maxDistanceFrom3Prime: Int = 0,
        trimBarcodes: Bool = true,
        searchReverseComplement: Bool? = nil,
        unassignedDisposition: UnassignedDisposition = .keep,
        polyGTrimQuality: Int? = nil,
        threads: Int = 4,
        adapterContext: (any PlatformAdapterContext)? = nil,
        sampleAssignments: [FASTQSampleBarcodeAssignment] = [],
        sourcePlatform: SequencingPlatform? = nil,
        rootBundleURL: URL? = nil,
        rootFASTQFilename: String? = nil
    ) {
        self.inputURL = inputURL
        self.barcodeKit = barcodeKit
        self.outputDirectory = outputDirectory
        self.barcodeLocation = barcodeLocation

        // Default symmetry from kit pairing mode
        self.symmetryMode = symmetryMode ?? {
            switch barcodeKit.pairingMode {
            case .singleEnd: return .singleEnd
            case .symmetric: return .symmetric
            case .fixedDual: return .asymmetric
            case .combinatorialDual: return .asymmetric
            }
        }()

        // Default error rate and overlap from platform
        self.errorRate = errorRate ?? barcodeKit.platform.recommendedErrorRate
        self.minimumOverlap = minimumOverlap ?? barcodeKit.platform.recommendedMinimumOverlap

        self.maxDistanceFrom5Prime = max(0, maxDistanceFrom5Prime)
        self.maxDistanceFrom3Prime = max(0, maxDistanceFrom3Prime)
        self.trimBarcodes = trimBarcodes
        self.adapterContext = adapterContext
        self.searchReverseComplement = searchReverseComplement
            ?? barcodeKit.platform.readsCanBeReverseComplemented
        self.unassignedDisposition = unassignedDisposition
        // Default poly-G trimming from platform (nil for non-two-color platforms)
        self.polyGTrimQuality = polyGTrimQuality ?? barcodeKit.platform.defaultPolyGTrimQuality
        self.threads = threads
        self.sampleAssignments = sampleAssignments
        self.sourcePlatform = sourcePlatform
        self.rootBundleURL = rootBundleURL
        self.rootFASTQFilename = rootFASTQFilename
    }
}

// MARK: - Demultiplex Result

/// Result of a demultiplexing pipeline run.
public struct DemultiplexResult: Sendable {
    /// Generated demultiplex manifest.
    public let manifest: DemultiplexManifest

    /// URLs of created per-barcode .lungfishfastq bundles.
    public let outputBundleURLs: [URL]

    /// URL of the unassigned reads bundle (nil if discarded or empty).
    public let unassignedBundleURL: URL?

    /// Wall clock time in seconds.
    public let wallClockSeconds: Double
}

// MARK: - Demultiplex Error

public enum DemultiplexError: Error, LocalizedError, Sendable {
    case inputFileNotFound(URL)
    case cutadaptFailed(exitCode: Int32, stderr: String)
    case noBarcodes
    case combinatorialRequiresSampleAssignments
    case outputParsingFailed(String)
    case bundleCreationFailed(barcode: String, underlying: String)
    case noOutputResults
    case emptyAdapterSequences(kitName: String)

    public var errorDescription: String? {
        switch self {
        case .inputFileNotFound(let url):
            return "Input FASTQ not found: \(url.lastPathComponent)"
        case .cutadaptFailed(let code, let stderr):
            return "cutadapt failed (exit \(code)): \(String(stderr.suffix(500)))"
        case .noBarcodes:
            return "Barcode kit has no barcodes defined"
        case .combinatorialRequiresSampleAssignments:
            return "Combinatorial kits require explicit sample barcode assignments."
        case .outputParsingFailed(let msg):
            return "Failed to parse cutadapt output: \(msg)"
        case .bundleCreationFailed(let barcode, let error):
            return "Failed to create bundle for \(barcode): \(error)"
        case .noOutputResults:
            return "Multi-step demultiplexing produced no output results."
        case .emptyAdapterSequences(let kitName):
            return "Adapter FASTA for kit '\(kitName)' contains no valid sequences. Check barcode definitions."
        }
    }
}

// MARK: - Demultiplexing Pipeline

/// Demultiplexes FASTQ reads using bundled cutadapt.
///
/// Pipeline steps:
/// 1. Generate adapter FASTA from barcode kit definition
/// 2. Run cutadapt with `{name}` output pattern for per-barcode files
/// 3. Create `.lungfishfastq` bundles from each output file
/// 4. Generate a `DemultiplexManifest` with per-barcode statistics
///
/// Supports both single-indexed and dual-indexed kits and terminally anchored
/// barcode matching with configurable 5'/3' search windows.
///
/// ```
/// input.lungfishfastq/
///   reads.fastq.gz
///   demux-manifest.json          <- written after demux
/// input-demux/
///   D701.lungfishfastq/          <- per-barcode bundles
///   D702.lungfishfastq/
///   unassigned.lungfishfastq/
/// ```
public final class DemultiplexingPipeline: @unchecked Sendable {

    private let runner = NativeToolRunner.shared

    public init() {}

    /// Runs the demultiplexing pipeline.
    ///
    /// - Parameters:
    ///   - config: Demultiplexing configuration.
    ///   - progress: Progress callback (fraction 0-1, status message).
    /// - Returns: Demultiplex result with manifest and bundle URLs.
    public func run(
        config: DemultiplexConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> DemultiplexResult {
        let startTime = Date()

        guard !config.barcodeKit.barcodes.isEmpty else {
            throw DemultiplexError.noBarcodes
        }

        // Resolve the input FASTQ
        let inputFASTQ = resolveInputFASTQ(config.inputURL)
        guard FileManager.default.fileExists(atPath: inputFASTQ.path) else {
            throw DemultiplexError.inputFileNotFound(inputFASTQ)
        }

        let fm = FileManager.default

        // Create working directories
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("lungfish-demux-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        // Step 1: Generate adapter FASTA (5% progress)
        progress(0.0, "Generating adapter sequences...")
        let adapterConfig = try await createAdapterConfiguration(
            for: config,
            workDirectory: workDir
        )

        // Validate adapter FASTA is non-empty (catches upstream bugs before cutadapt fails cryptically)
        let fastaContent = try String(contentsOf: adapterConfig.adapterFASTA, encoding: .utf8)
        let sequences = fastaContent.split(separator: "\n").filter { !$0.hasPrefix(">") && !$0.isEmpty }
        if sequences.isEmpty || sequences.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw DemultiplexError.emptyAdapterSequences(kitName: config.barcodeKit.displayName)
        }

        // Step 2: Build cutadapt command (5% progress)
        progress(0.05, "Configuring cutadapt...")

        let demuxOutputDir = workDir.appendingPathComponent("demux-output", isDirectory: true)
        try fm.createDirectory(at: demuxOutputDir, withIntermediateDirectories: true)

        let outputPattern = demuxOutputDir
            .appendingPathComponent("{name}.fastq.gz").path
        let unassignedPath = demuxOutputDir
            .appendingPathComponent("unassigned.fastq.gz").path
        let jsonReportPath = workDir
            .appendingPathComponent("cutadapt-report.json").path

        var args = buildCutadaptArguments(
            config: config,
            adapterFASTA: adapterConfig.adapterFASTA,
            adapterFlag: adapterConfig.adapterFlag,
            outputPattern: outputPattern,
            unassignedPath: unassignedPath,
            jsonReportPath: jsonReportPath
        )

        args.append(inputFASTQ.path)

        // Step 3: Run cutadapt (70% progress)
        progress(0.10, "Running cutadapt demultiplexing...")

        let inputSize = fileSize(inputFASTQ)
        let timeout = max(600.0, Double(inputSize) / 5_000_000)

        let result = try await runner.run(
            .cutadapt,
            arguments: args,
            workingDirectory: workDir,
            timeout: timeout
        )

        guard result.isSuccess else {
            throw DemultiplexError.cutadaptFailed(
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }

        progress(0.80, "cutadapt complete, creating bundles...")

        // Step 4: Create virtual per-barcode .lungfishfastq bundles (15% progress)
        // Each bundle contains a read ID list and a small preview (first 1000 reads),
        // NOT a full copy of the barcode's FASTQ. The full cutadapt output stays in
        // workDir and is cleaned up by the defer block.
        let demuxOutputContents = try fm.contentsOfDirectory(
            at: demuxOutputDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "gz" || $0.pathExtension == "fastq" }

        var barcodeResults: [BarcodeResult] = []
        var bundleURLs: [URL] = []
        var unassignedBundleURL: URL?
        var assignedReadCount = 0
        var unassignedReadCount = 0
        var unassignedBaseCount: Int64 = 0
        let progressPerFile = 0.15 / max(1.0, Double(demuxOutputContents.count))

        // Collect non-empty output files for parallel processing
        struct DemuxOutputFile: Sendable {
            let url: URL
            let baseName: String
            let isUnassigned: Bool
            let fileBytes: Int64
        }
        let filesToProcess: [DemuxOutputFile] = demuxOutputContents.compactMap { outputFile in
            let baseName = outputFile.deletingPathExtension().deletingPathExtension().lastPathComponent
            let fileBytes = fileSize(outputFile)
            guard fileBytes > 20 else { return nil }
            return DemuxOutputFile(
                url: outputFile,
                baseName: baseName,
                isUnassigned: baseName == "unassigned",
                fileBytes: fileBytes
            )
        }

        // Process files with bounded concurrency (8 at a time for seqkit calls)
        struct VirtualBundleResult: Sendable {
            let baseName: String
            let isUnassigned: Bool
            let bundleURL: URL
            let bundleName: String
            let readCount: Int
            let baseCount: Int64
        }

        let bundleResults: [VirtualBundleResult] = try await withThrowingTaskGroup(
            of: VirtualBundleResult?.self,
            returning: [VirtualBundleResult].self
        ) { group in
            var results: [VirtualBundleResult] = []
            var inFlight = 0
            var fileIndex = 0

            for file in filesToProcess {
                // Throttle to 8 concurrent
                if inFlight >= 8 {
                    if let result = try await group.next() {
                        if let r = result { results.append(r) }
                        inFlight -= 1
                    }
                }

                let bundleName = "\(file.baseName).\(FASTQBundle.directoryExtension)"
                let bundleURL = config.outputDirectory
                    .appendingPathComponent(bundleName, isDirectory: true)
                try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

                let capturedRunner = self.runner
                group.addTask {
                    try Task.checkCancellation()

                    // Extract read IDs
                    let readIDsURL = bundleURL.appendingPathComponent("read-ids.txt")
                    let readIDResult = try await capturedRunner.run(
                        .seqkit,
                        arguments: ["seq", "--name", "--only-id", file.url.path, "-o", readIDsURL.path],
                        timeout: 300
                    )
                    guard readIDResult.isSuccess else {
                        logger.error("seqkit seq failed for \(file.baseName): \(readIDResult.stderr)")
                        return nil
                    }

                    // Extract preview (first 1000 reads)
                    let previewURL = bundleURL.appendingPathComponent("preview.fastq.gz")
                    let previewResult = try await capturedRunner.run(
                        .seqkit,
                        arguments: ["head", "-n", "1000", file.url.path, "-o", previewURL.path],
                        timeout: 120
                    )
                    guard previewResult.isSuccess else {
                        logger.error("seqkit head failed for \(file.baseName): \(previewResult.stderr)")
                        return nil
                    }

                    // Get accurate read count and base count via seqkit stats
                    let statsResult = try await capturedRunner.run(
                        .seqkit,
                        arguments: ["stats", "-T", file.url.path],
                        timeout: 300
                    )
                    var readCount = 0
                    var baseCount: Int64 = 0
                    if statsResult.isSuccess {
                        // seqkit stats -T output: header line + data line, tab-separated
                        // Columns: file, format, type, num_seqs, sum_len, min_len, avg_len, max_len
                        let lines = statsResult.stdout.split(separator: "\n")
                        if lines.count >= 2 {
                            let fields = lines[1].split(separator: "\t")
                            if fields.count >= 5 {
                                readCount = Int(fields[3].replacingOccurrences(of: ",", with: "")) ?? 0
                                baseCount = Int64(fields[4].replacingOccurrences(of: ",", with: "")) ?? 0
                            }
                        }
                    }

                    return VirtualBundleResult(
                        baseName: file.baseName,
                        isUnassigned: file.isUnassigned,
                        bundleURL: bundleURL,
                        bundleName: bundleName,
                        readCount: readCount,
                        baseCount: baseCount
                    )
                }
                inFlight += 1
                fileIndex += 1
            }

            // Collect remaining results
            for try await result in group {
                if let r = result { results.append(r) }
            }
            return results
        }

        // Process results and write derived manifests
        for (i, result) in bundleResults.enumerated() {
            if result.isUnassigned {
                unassignedReadCount = result.readCount
                unassignedBaseCount = result.baseCount
                if config.unassignedDisposition == .keep {
                    unassignedBundleURL = result.bundleURL
                } else {
                    try? fm.removeItem(at: result.bundleURL)
                    continue
                }
            } else {
                assignedReadCount += result.readCount
                let sequenceInfo = barcodeSequenceInfo(
                    for: result.baseName,
                    kit: config.barcodeKit,
                    sampleAssignments: config.sampleAssignments
                )
                barcodeResults.append(BarcodeResult(
                    barcodeID: result.baseName,
                    sampleName: sequenceInfo.sampleName,
                    forwardSequence: sequenceInfo.forward,
                    reverseSequence: sequenceInfo.reverse,
                    readCount: result.readCount,
                    baseCount: result.baseCount,
                    bundleRelativePath: result.bundleName
                ))
                bundleURLs.append(result.bundleURL)
            }

            // Write derived manifest if root bundle info is available
            if let rootBundleURL = config.rootBundleURL,
               let rootFASTQFilename = config.rootFASTQFilename {
                let rootRelativePath = relativePath(from: result.bundleURL, to: rootBundleURL)
                // Parent is the root bundle for first-generation demux derivatives
                let parentRelativePath = rootRelativePath
                let demuxOp = FASTQDerivativeOperation(
                    kind: .demultiplex,
                    createdAt: Date()
                )
                let stats = FASTQDatasetStatistics.placeholder(
                    readCount: result.readCount,
                    baseCount: result.baseCount
                )
                let derivedManifest = FASTQDerivedBundleManifest(
                    name: result.baseName,
                    parentBundleRelativePath: parentRelativePath,
                    rootBundleRelativePath: rootRelativePath,
                    rootFASTQFilename: rootFASTQFilename,
                    payload: .demuxedVirtual(
                        barcodeID: result.baseName,
                        readIDListFilename: "read-ids.txt",
                        previewFilename: "preview.fastq.gz"
                    ),
                    lineage: [demuxOp],
                    operation: demuxOp,
                    cachedStatistics: stats,
                    pairingMode: nil
                )
                do {
                    try FASTQBundle.saveDerivedManifest(derivedManifest, in: result.bundleURL)
                } catch {
                    logger.error("Failed to save derived manifest for \(result.baseName): \(error)")
                }
            }

            progress(
                0.80 + Double(i + 1) * progressPerFile,
                "Created virtual bundle for \(result.baseName)"
            )
        }

        // Sort barcode results by ID
        barcodeResults.sort { $0.barcodeID.localizedStandardCompare($1.barcodeID) == .orderedAscending }

        let elapsed = Date().timeIntervalSince(startTime)

        // Build BarcodeKit for manifest
        let usesExplicitAssignments = !config.sampleAssignments.isEmpty
        let kitForManifest = BarcodeKit(
            name: config.barcodeKit.displayName,
            vendor: config.barcodeKit.vendor,
            barcodeCount: usesExplicitAssignments ? config.sampleAssignments.count : config.barcodeKit.barcodes.count,
            isDualIndexed: usesExplicitAssignments ? true : config.barcodeKit.isDualIndexed,
            barcodeType: usesExplicitAssignments
                ? .asymmetric
                : (config.barcodeKit.pairingMode == .singleEnd ? .singleEnd : .asymmetric)
        )

        // Build the cutadapt version string
        let versionResult = try? await runner.run(.cutadapt, arguments: ["--version"])
        let cutadaptVersion = versionResult?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let manifest = DemultiplexManifest(
            barcodeKit: kitForManifest,
            parameters: DemultiplexParameters(
                tool: "cutadapt",
                toolVersion: cutadaptVersion,
                maxMismatches: Int(config.errorRate * Double(config.barcodeKit.barcodes[0].i7Sequence.count)),
                requireBothEnds: config.barcodeLocation == .bothEnds || config.barcodeKit.isDualIndexed || usesExplicitAssignments,
                trimBarcodes: config.trimBarcodes,
                commandLine: "cutadapt \(args.joined(separator: " "))",
                wallClockSeconds: elapsed
            ),
            barcodes: barcodeResults,
            unassigned: UnassignedReadsSummary(
                readCount: unassignedReadCount,
                baseCount: unassignedBaseCount,
                disposition: config.unassignedDisposition,
                bundleRelativePath: unassignedBundleURL?.lastPathComponent
            ),
            outputDirectoryRelativePath: ".",
            inputReadCount: assignedReadCount + unassignedReadCount
        )

        // Save manifest to output directory
        try manifest.save(to: config.outputDirectory)

        // If input was a .lungfishfastq bundle, also save manifest to the bundle
        if FASTQBundle.isBundleURL(config.inputURL) {
            try? manifest.save(to: config.inputURL)
        }

        progress(1.0, "Demultiplexing complete: \(barcodeResults.count) barcodes, \(String(format: "%.0f%%", manifest.assignmentRate * 100)) assigned")

        logger.info("Demux complete: \(barcodeResults.count) barcodes, \(manifest.assignmentRate * 100)% assigned, \(String(format: "%.1f", elapsed))s")

        return DemultiplexResult(
            manifest: manifest,
            outputBundleURLs: bundleURLs,
            unassignedBundleURL: unassignedBundleURL,
            wallClockSeconds: elapsed
        )
    }

    // MARK: - Private Helpers

    /// Resolves the actual FASTQ file from a URL (handles .lungfishfastq bundles).
    private func resolveInputFASTQ(_ url: URL) -> URL {
        if FASTQBundle.isBundleURL(url) {
            return FASTQBundle.resolvePrimaryFASTQURL(for: url) ?? url
        }
        return url
    }

    private struct AdapterConfiguration {
        let adapterFASTA: URL
        let adapterFlag: String
    }

    private func createAdapterConfiguration(
        for config: DemultiplexConfig,
        workDirectory: URL
    ) async throws -> AdapterConfiguration {
        let adapterFASTA = workDirectory.appendingPathComponent("adapters.fasta")

        if !config.sampleAssignments.isEmpty
            && (config.barcodeKit.pairingMode == .combinatorialDual
                || config.barcodeKit.pairingMode == .fixedDual) {
            // Asymmetric/combinatorial kits with sample assignments from scout:
            // Generate linked adapter pairs (5'...3') directly. For long-read platforms,
            // reads can arrive in either orientation, so we generate BOTH orientations
            // explicitly (fwd--rev AND rev--fwd) instead of using --revcomp (which is
            // incompatible with linked adapter syntax).
            let ctx = config.resolvedAdapterContext
            var lines: [String] = []
            for assignment in config.sampleAssignments {
                guard let fwdSeq = resolveSequence(
                    explicitSequence: assignment.forwardSequence,
                    barcodeID: assignment.forwardBarcodeID,
                    kit: config.barcodeKit
                ), let revSeq = resolveSequence(
                    explicitSequence: assignment.reverseSequence,
                    barcodeID: assignment.reverseBarcodeID,
                    kit: config.barcodeKit
                ) else { continue }
                let name = sanitizedSampleIdentifier(assignment.sampleID)
                // Forward orientation: fwd barcode at 5', rev barcode (RC) at 3'
                let fwdSpec = ctx.fivePrimeSpec(barcodeSequence: fwdSeq)
                let revSpec = ctx.threePrimeSpec(barcodeSequence: revSeq)
                lines.append(">\(name)")
                lines.append("\(fwdSpec)...\(revSpec)")
                // Reverse orientation: rev barcode at 5', fwd barcode (RC) at 3'
                if fwdSeq != revSeq {
                    let revFwdSpec = ctx.fivePrimeSpec(barcodeSequence: revSeq)
                    let revRevSpec = ctx.threePrimeSpec(barcodeSequence: fwdSeq)
                    lines.append(">\(name)")
                    lines.append("\(revFwdSpec)...\(revRevSpec)")
                }
            }
            guard !lines.isEmpty else {
                throw DemultiplexError.combinatorialRequiresSampleAssignments
            }
            let content = lines.joined(separator: "\n") + "\n"
            try content.write(to: adapterFASTA, atomically: true, encoding: .utf8)
            try validateAdapterFASTA(at: adapterFASTA, kitName: config.barcodeKit.displayName)
            return AdapterConfiguration(adapterFASTA: adapterFASTA, adapterFlag: "-g")
        } else if !config.sampleAssignments.isEmpty
            && config.barcodeKit.pairingMode == .symmetric
            && config.barcodeKit.platform.readsCanBeReverseComplemented {
            // Symmetric long-read kits with sample assignments from scout:
            // Use 5'-only specs (not linked) when --revcomp is active. Linked adapter
            // syntax in FASTA files is incompatible with --revcomp, causing ~50% of
            // reverse-oriented reads to go unassigned.
            let ctx = config.resolvedAdapterContext
            let useRevcomp = config.searchReverseComplement
            var lines: [String] = []
            for assignment in config.sampleAssignments {
                guard let sequence = resolveSequence(
                    explicitSequence: assignment.forwardSequence,
                    barcodeID: assignment.forwardBarcodeID,
                    kit: config.barcodeKit
                ) else { continue }
                let spec = useRevcomp
                    ? ctx.fivePrimeSpec(barcodeSequence: sequence)
                    : ctx.linkedSpec(barcodeSequence: sequence)
                let name = sanitizedSampleIdentifier(assignment.sampleID)
                lines.append(">\(name)")
                lines.append(spec)
            }
            guard !lines.isEmpty else {
                throw DemultiplexError.combinatorialRequiresSampleAssignments
            }
            let content = lines.joined(separator: "\n") + "\n"
            try content.write(to: adapterFASTA, atomically: true, encoding: .utf8)
            try validateAdapterFASTA(at: adapterFASTA, kitName: config.barcodeKit.displayName)
            return AdapterConfiguration(adapterFASTA: adapterFASTA, adapterFlag: "-g")
        } else if !config.sampleAssignments.isEmpty {
            let entries: [(name: String, first: String, second: String)] = config.sampleAssignments.compactMap { assignment in
                guard let forward = resolveSequence(
                    explicitSequence: assignment.forwardSequence,
                    barcodeID: assignment.forwardBarcodeID,
                    kit: config.barcodeKit
                ), let reverse = resolveSequence(
                    explicitSequence: assignment.reverseSequence,
                    barcodeID: assignment.reverseBarcodeID,
                    kit: config.barcodeKit
                ) else {
                    return nil
                }

                return (
                    name: sanitizedSampleIdentifier(assignment.sampleID),
                    first: contextualizedSequence(forward, role: .i7, context: config.resolvedAdapterContext),
                    second: contextualizedSequence(reverse, role: .i5, context: config.resolvedAdapterContext)
                )
            }

            guard !entries.isEmpty else {
                throw DemultiplexError.combinatorialRequiresSampleAssignments
            }

            try writeLinkedAdapterFASTA(
                entries: entries,
                location: config.barcodeLocation,
                maxDistanceFrom5Prime: config.maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: config.maxDistanceFrom3Prime,
                to: adapterFASTA
            )
            try validateAdapterFASTA(at: adapterFASTA, kitName: config.barcodeKit.displayName)
            return AdapterConfiguration(adapterFASTA: adapterFASTA, adapterFlag: "-g")
        }

        switch config.barcodeKit.pairingMode {
        case .singleEnd, .symmetric:
            // For long-read platforms (ONT, PacBio), use 5'-only adapter specs when
            // --revcomp is active. Linked adapter syntax (5'...3') in FASTA files is
            // incompatible with --revcomp, causing ~50% of reverse-oriented reads to go
            // unassigned. The 5' spec (Y-adapter + flank + barcode) is sufficient for
            // barcode identification; --revcomp handles orientation detection.
            if config.barcodeKit.platform.readsCanBeReverseComplemented {
                let ctx = config.resolvedAdapterContext
                let useRevcomp = config.searchReverseComplement
                var lines: [String] = []
                for barcode in config.barcodeKit.barcodes {
                    let spec = useRevcomp
                        ? ctx.fivePrimeSpec(barcodeSequence: barcode.i7Sequence)
                        : ctx.linkedSpec(barcodeSequence: barcode.i7Sequence)
                    lines.append(">\(barcode.id)")
                    lines.append(spec)
                }
                let content = lines.joined(separator: "\n") + "\n"
                try content.write(to: adapterFASTA, atomically: true, encoding: .utf8)
                try validateAdapterFASTA(at: adapterFASTA, kitName: config.barcodeKit.displayName)
                return AdapterConfiguration(adapterFASTA: adapterFASTA, adapterFlag: "-g")
            }

            // For short-read platforms, use single-end adapter specs
            let entries: [(name: String, sequence: String)] = config.barcodeKit.barcodes.map { barcode in
                (
                    name: barcode.id,
                    sequence: contextualizedSequence(barcode.i7Sequence, role: .i7, context: config.resolvedAdapterContext)
                )
            }
            try writeSingleEndAdapterFASTA(
                entries: entries,
                location: config.barcodeLocation,
                maxDistanceFrom5Prime: config.maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: config.maxDistanceFrom3Prime,
                to: adapterFASTA
            )
            try validateAdapterFASTA(at: adapterFASTA, kitName: config.barcodeKit.displayName)
            return AdapterConfiguration(
                adapterFASTA: adapterFASTA,
                adapterFlag: adapterFlag(for: config.barcodeLocation)
            )

        case .fixedDual:
            let entries: [(name: String, first: String, second: String)] = config.barcodeKit.barcodes.compactMap { barcode in
                guard let i5 = barcode.i5Sequence else { return nil }
                return (
                    name: barcode.id,
                    first: contextualizedSequence(
                        barcode.i7Sequence,
                        role: .i7,
                        context: config.resolvedAdapterContext
                    ),
                    second: contextualizedSequence(
                        i5,
                        role: .i5,
                        context: config.resolvedAdapterContext
                    )
                )
            }
            guard !entries.isEmpty else { throw DemultiplexError.noBarcodes }
            try writeLinkedAdapterFASTA(
                entries: entries,
                location: config.barcodeLocation,
                maxDistanceFrom5Prime: config.maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: config.maxDistanceFrom3Prime,
                to: adapterFASTA
            )
            try validateAdapterFASTA(at: adapterFASTA, kitName: config.barcodeKit.displayName)
            return AdapterConfiguration(adapterFASTA: adapterFASTA, adapterFlag: "-g")

        case .combinatorialDual:
            throw DemultiplexError.combinatorialRequiresSampleAssignments
        }
    }

    /// Validates that an adapter FASTA file contains at least one non-empty sequence.
    private func validateAdapterFASTA(at url: URL, kitName: String) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        let sequences = content.split(separator: "\n")
            .filter { !$0.hasPrefix(">") && !$0.isEmpty }
        guard !sequences.isEmpty else {
            throw DemultiplexError.emptyAdapterSequences(kitName: kitName)
        }
        for seq in sequences {
            let trimmed = seq.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DemultiplexError.emptyAdapterSequences(kitName: kitName)
            }
        }
    }

    private enum BarcodeRole {
        case i7
        case i5
    }

    /// Wraps a barcode sequence with platform-appropriate adapter context.
    ///
    /// For ONT native barcoding, this constructs the full
    /// Y-adapter + barcode + flank sequence. For Illumina, it adds
    /// P7/P5 flanking. For PacBio HiFi, returns bare barcode (CCS
    /// already removed SMRTbell adapters).
    private func contextualizedSequence(_ sequence: String, role: BarcodeRole, context: any PlatformAdapterContext) -> String {
        switch role {
        case .i7:
            return context.fivePrimeSpec(barcodeSequence: sequence)
        case .i5:
            return context.threePrimeSpec(barcodeSequence: sequence)
        }
    }

    private func adapterFlag(for location: BarcodeLocation) -> String {
        switch location {
        case .fivePrime:
            return "-g"
        case .threePrime:
            return "-a"
        case .bothEnds:
            return "-g"
        }
    }

    private func writeSingleEndAdapterFASTA(
        entries: [(name: String, sequence: String)],
        location: BarcodeLocation,
        maxDistanceFrom5Prime: Int,
        maxDistanceFrom3Prime: Int,
        to outputURL: URL
    ) throws {
        var lines: [String] = []
        let fivePrimeOffsets = Array(0...max(0, maxDistanceFrom5Prime))
        let threePrimeOffsets = Array(0...max(0, maxDistanceFrom3Prime))
        let perEntryPatternCount: Int
        switch location {
        case .fivePrime:
            perEntryPatternCount = fivePrimeOffsets.count
        case .threePrime:
            perEntryPatternCount = threePrimeOffsets.count
        case .bothEnds:
            // Single-end kits are matched as 5' barcodes by convention.
            perEntryPatternCount = fivePrimeOffsets.count
        }
        lines.reserveCapacity(max(1, entries.count * perEntryPatternCount * 2))

        for entry in entries {
            let sequence = entry.sequence.uppercased()
            switch location {
            case .fivePrime:
                for offset in fivePrimeOffsets {
                    lines.append(">\(entry.name)")
                    lines.append("^\(wildcardExact(offset))\(sequence)")
                }
            case .threePrime:
                for offset in threePrimeOffsets {
                    lines.append(">\(entry.name)")
                    lines.append("\(sequence)\(wildcardExact(offset))$")
                }
            case .bothEnds:
                for offset in fivePrimeOffsets {
                    lines.append(">\(entry.name)")
                    lines.append("^\(wildcardExact(offset))\(sequence)")
                }
            }
        }

        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private func writeLinkedAdapterFASTA(
        entries: [(name: String, first: String, second: String)],
        location: BarcodeLocation,
        maxDistanceFrom5Prime: Int,
        maxDistanceFrom3Prime: Int,
        to outputURL: URL
    ) throws {
        var lines: [String] = []
        let fivePrimeOffsets = Array(0...max(0, maxDistanceFrom5Prime))
        let threePrimeOffsets = Array(0...max(0, maxDistanceFrom3Prime))
        let perOrientationPatternCount: Int
        switch location {
        case .fivePrime:
            perOrientationPatternCount = fivePrimeOffsets.count
        case .threePrime:
            perOrientationPatternCount = threePrimeOffsets.count
        case .bothEnds:
            perOrientationPatternCount = fivePrimeOffsets.count * threePrimeOffsets.count
        }
        lines.reserveCapacity(max(1, entries.count * perOrientationPatternCount * 4))

        for entry in entries {
            let first = entry.first.uppercased()
            let second = entry.second.uppercased()
            let forwardPatterns = linkedAdapterPatterns(
                first: first,
                second: second,
                location: location,
                fivePrimeOffsets: fivePrimeOffsets,
                threePrimeOffsets: threePrimeOffsets
            )
            for pattern in forwardPatterns {
                lines.append(">\(entry.name)")
                lines.append(pattern)
            }

            if first != second {
                let reversePatterns = linkedAdapterPatterns(
                    first: second,
                    second: first,
                    location: location,
                    fivePrimeOffsets: fivePrimeOffsets,
                    threePrimeOffsets: threePrimeOffsets
                )
                for pattern in reversePatterns {
                    lines.append(">\(entry.name)")
                    lines.append(pattern)
                }
            }
        }

        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private func linkedAdapterPatterns(
        first: String,
        second: String,
        location: BarcodeLocation,
        fivePrimeOffsets: [Int],
        threePrimeOffsets: [Int]
    ) -> [String] {
        var patterns: [String] = []
        switch location {
        case .fivePrime:
            patterns.reserveCapacity(fivePrimeOffsets.count)
            for offset in fivePrimeOffsets {
                patterns.append("^\(wildcardExact(offset))\(first)...\(second)")
            }
        case .threePrime:
            patterns.reserveCapacity(threePrimeOffsets.count)
            for offset in threePrimeOffsets {
                patterns.append("\(first)...\(second)\(wildcardExact(offset))$")
            }
        case .bothEnds:
            patterns.reserveCapacity(fivePrimeOffsets.count * threePrimeOffsets.count)
            for offset5 in fivePrimeOffsets {
                for offset3 in threePrimeOffsets {
                    patterns.append("^\(wildcardExact(offset5))\(first)...\(second)\(wildcardExact(offset3))$")
                }
            }
        }
        return patterns
    }

    private func wildcardExact(_ offset: Int) -> String {
        let distance = max(0, offset)
        guard distance > 0 else { return "" }
        return "N{\(distance)}"
    }

    private func resolveSequence(
        explicitSequence: String?,
        barcodeID: String?,
        kit: BarcodeKitDefinition
    ) -> String? {
        if let explicitSequence, !explicitSequence.isEmpty {
            return explicitSequence.uppercased()
        }
        guard let barcodeID else { return nil }
        guard let barcode = kit.barcodes.first(where: { $0.id.caseInsensitiveCompare(barcodeID) == .orderedSame }) else {
            return nil
        }
        return barcode.i7Sequence.uppercased()
    }

    private func sanitizedSampleIdentifier(_ sampleID: String) -> String {
        let trimmed = sampleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return sanitized.isEmpty ? "sample" : sanitized
    }

    private func canonicalSampleID(_ value: String) -> String {
        sanitizedSampleIdentifier(value).lowercased()
    }

    private func sampleAssignmentLookup(
        _ assignments: [FASTQSampleBarcodeAssignment]
    ) -> [String: FASTQSampleBarcodeAssignment] {
        var lookup: [String: FASTQSampleBarcodeAssignment] = [:]
        for assignment in assignments {
            lookup[canonicalSampleID(assignment.sampleID)] = assignment
        }
        return lookup
    }

    private func sampleAssignment(
        for outputName: String,
        assignments: [FASTQSampleBarcodeAssignment]
    ) -> FASTQSampleBarcodeAssignment? {
        let lookup = sampleAssignmentLookup(assignments)
        return lookup[canonicalSampleID(outputName)]
    }

    private func assignmentSequence(_ explicit: String?, id: String?, kit: BarcodeKitDefinition) -> String? {
        resolveSequence(explicitSequence: explicit, barcodeID: id, kit: kit)
    }

    private func barcodeSequenceInfo(
        for outputName: String,
        kit: BarcodeKitDefinition,
        sampleAssignments: [FASTQSampleBarcodeAssignment]
    ) -> (sampleName: String?, forward: String?, reverse: String?) {
        if let assignment = sampleAssignment(for: outputName, assignments: sampleAssignments) {
            let sampleLabel = assignment.sampleName ?? assignment.sampleID
            let forward = assignmentSequence(assignment.forwardSequence, id: assignment.forwardBarcodeID, kit: kit)
            let reverse = assignmentSequence(assignment.reverseSequence, id: assignment.reverseBarcodeID, kit: kit)
            return (sampleLabel, forward, reverse)
        }

        switch kit.pairingMode {
        case .singleEnd, .symmetric, .fixedDual:
            if let barcode = kit.barcodes.first(where: { $0.id == outputName }) {
                return (barcode.sampleName, barcode.i7Sequence, barcode.i5Sequence)
            }
            return (nil, nil, nil)

        case .combinatorialDual:
            let parts = outputName.components(separatedBy: "--")
            if parts.count == 2,
               let first = kit.barcodes.first(where: { $0.id == parts[0] }),
               let second = kit.barcodes.first(where: { $0.id == parts[1] }) {
                return (nil, first.i7Sequence, second.i7Sequence)
            }
            if let barcode = kit.barcodes.first(where: { $0.id == outputName }) {
                return (barcode.sampleName, barcode.i7Sequence, nil)
            }
            return (nil, nil, nil)
        }
    }

    /// Builds the cutadapt argument array.
    private func buildCutadaptArguments(
        config: DemultiplexConfig,
        adapterFASTA: URL,
        adapterFlag: String,
        outputPattern: String,
        unassignedPath: String,
        jsonReportPath: String
    ) -> [String] {
        var args: [String] = []

        // Adapter specification.
        args += [adapterFlag, "file:\(adapterFASTA.path)"]

        // Error rate (cross-platform aware) and overlap
        args += ["-e", String(config.effectiveErrorRate)]
        args += ["--overlap", String(config.minimumOverlap)]

        // Search both strand orientations for long-read platforms.
        // --revcomp is incompatible with linked adapter syntax (5'...3'), so skip it
        // for combinatorial/fixedDual kits that use linked pair adapters.
        let isLinkedPairMode = config.barcodeKit.pairingMode == .combinatorialDual
            || config.barcodeKit.pairingMode == .fixedDual
        if config.searchReverseComplement && !isLinkedPairMode {
            args += ["--revcomp"]
        }

        // Single-end barcode mode can trim both ends from one read via repeated matching.
        if config.barcodeKit.pairingMode == .singleEnd {
            args += ["--times", "2"]
        }

        // Trim or retain barcode
        args += ["--action", config.trimBarcodes ? "trim" : "none"]

        // Output: cutadapt {name} pattern creates one file per adapter name
        args += ["-o", outputPattern]

        // Unassigned reads
        args += ["--untrimmed-output", unassignedPath]

        // Poly-G trimming for two-color chemistry platforms (NextSeq, Element AVITI)
        if let polyGQuality = config.polyGTrimQuality {
            args += ["--nextseq-trim=\(polyGQuality)"]
        }

        // JSON report
        args += ["--json", jsonReportPath]

        // Threading
        args += ["--cores", String(max(1, config.threads))]

        return args
    }

    /// Returns file size in bytes.
    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// Counts reads in a FASTQ file (gzipped or plain).
    private func countReadsInFASTQ(url: URL) -> Int {
        let isGzipped = url.pathExtension.lowercased() == "gz"

        let process = Process()
        if isGzipped {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzcat")
            process.arguments = [url.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/cat")
            process.arguments = [url.path]
        }

        let countProcess = Process()
        countProcess.executableURL = URL(fileURLWithPath: "/usr/bin/wc")
        countProcess.arguments = ["-l"]

        let pipe = Pipe()
        process.standardOutput = pipe
        countProcess.standardInput = pipe

        let outputPipe = Pipe()
        countProcess.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        countProcess.standardError = FileHandle.nullDevice

        do {
            try process.run()
            try countProcess.run()

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            countProcess.waitUntilExit()

            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let lineCount = Int(str) {
                return lineCount / 4  // 4 lines per FASTQ record
            }
        } catch {
            logger.warning("Failed to count reads in \(url.lastPathComponent): \(error)")
        }

        return 0
    }

    // MARK: - Barcode Scouting

    /// Scans a subset of reads to detect which barcodes are present.
    ///
    /// Runs cutadapt against the first `readLimit` reads with all barcodes
    /// in the specified kit. Results include per-barcode hit counts and
    /// automatic disposition thresholds.
    ///
    /// - Parameters:
    ///   - inputURL: Input FASTQ file or bundle URL.
    ///   - kit: Barcode kit to scout against.
    ///   - readLimit: Maximum number of reads to scan (default 10,000).
    ///   - acceptThreshold: Minimum hits to auto-accept a barcode (default 10).
    ///   - rejectThreshold: Maximum hits to auto-reject a barcode (default 3).
    ///   - progress: Progress callback.
    /// - Returns: Scout result with per-barcode detections.
    public func scout(
        inputURL: URL,
        kit: BarcodeKitDefinition,
        adapterContext: (any PlatformAdapterContext)? = nil,
        readLimit: Int = 10_000,
        acceptThreshold: Int = 10,
        rejectThreshold: Int = 3,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> BarcodeScoutResult {
        let startTime = Date()

        let inputFASTQ = resolveInputFASTQ(inputURL)
        guard FileManager.default.fileExists(atPath: inputFASTQ.path) else {
            throw DemultiplexError.inputFileNotFound(inputFASTQ)
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("lungfish-scout-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // Step 1: Extract first N reads to a temp file
        progress(0.0, "Extracting first \(readLimit) reads for scouting...")
        let subsetFile = workDir.appendingPathComponent("scout-subset.fastq.gz")
        let headResult = try await runner.run(
            .seqkit,
            arguments: ["head", "-n", String(readLimit), "-o", subsetFile.path, inputFASTQ.path],
            workingDirectory: workDir,
            timeout: 120
        )
        guard headResult.isSuccess else {
            throw DemultiplexError.cutadaptFailed(exitCode: headResult.exitCode, stderr: headResult.stderr)
        }

        // Step 2: Generate adapter FASTA for all barcodes in kit
        progress(0.2, "Preparing barcode adapters...")
        let adapterFASTA = workDir.appendingPathComponent("scout-adapters.fasta")

        let ctx = adapterContext ?? kit.adapterContext
        let useRevcomp = kit.platform.readsCanBeReverseComplemented

        // For combinatorial kits, use a two-phase scout:
        //   Phase 1: Individual barcodes (N entries) to find which barcodes are present
        //   Phase 2: Linked pairs for detected barcodes only (M×M << N×N)
        // This avoids the N×N explosion (96×96 = 9,216 entries) that overwhelms cutadapt.
        if kit.pairingMode == .combinatorialDual {
            return try await scoutCombinatorial(
                kit: kit,
                ctx: ctx,
                subsetFile: subsetFile,
                workDir: workDir,
                acceptThreshold: acceptThreshold,
                rejectThreshold: rejectThreshold,
                startTime: startTime,
                progress: progress
            )
        }

        var lines: [String] = []
        if kit.pairingMode == .fixedDual {
            // fixedDual: use explicit i7/i5 pairs from each barcode entry.
            // Generate both orientations for long-read platforms.
            for barcode in kit.barcodes {
                guard let i5 = barcode.i5Sequence else { continue }
                let fwdSpec = ctx.fivePrimeSpec(barcodeSequence: barcode.i7Sequence)
                let revSpec = ctx.threePrimeSpec(barcodeSequence: i5)
                lines.append(">\(barcode.id)")
                lines.append("\(fwdSpec)...\(revSpec)")
                // Reverse orientation for long-read platforms
                if barcode.i7Sequence != i5 {
                    let revFwdSpec = ctx.fivePrimeSpec(barcodeSequence: i5)
                    let revRevSpec = ctx.threePrimeSpec(barcodeSequence: barcode.i7Sequence)
                    lines.append(">\(barcode.id)")
                    lines.append("\(revFwdSpec)...\(revRevSpec)")
                }
            }
        } else {
            // Symmetric/single-end kits: use 5'-only specs with --revcomp for orientation.
            // Linked adapter syntax is incompatible with --revcomp.
            for barcode in kit.barcodes {
                let spec = useRevcomp
                    ? ctx.fivePrimeSpec(barcodeSequence: barcode.i7Sequence)
                    : ctx.linkedSpec(barcodeSequence: barcode.i7Sequence)
                lines.append(">\(barcode.id)")
                lines.append(spec)
            }
        }
        let adapterContent = lines.joined(separator: "\n") + "\n"
        try adapterContent.write(to: adapterFASTA, atomically: true, encoding: .utf8)
        try validateAdapterFASTA(at: adapterFASTA, kitName: kit.displayName)

        // Step 3: Run cutadapt
        progress(0.3, "Running cutadapt scout scan...")
        let isLinkedPairMode = kit.pairingMode == .fixedDual
        let scoutResult = try await runScoutCutadapt(
            adapterFASTA: adapterFASTA,
            subsetFile: subsetFile,
            workDir: workDir,
            kit: kit,
            useRevcomp: useRevcomp && !isLinkedPairMode
        )

        progress(0.8, "Analyzing scout results...")

        let (detections, totalScanned, unassignedCount) = try collectScoutDetections(
            outputDir: scoutResult.outputDir,
            kit: kit,
            acceptThreshold: acceptThreshold,
            rejectThreshold: rejectThreshold
        )

        let elapsed = Date().timeIntervalSince(startTime)
        progress(1.0, "Scout complete: \(detections.count) barcodes detected")

        return BarcodeScoutResult(
            readsScanned: totalScanned,
            detections: detections,
            unassignedCount: unassignedCount,
            scoutedKitIDs: [kit.id],
            elapsedSeconds: elapsed
        )
    }

    // MARK: - Combinatorial Scout (Two-Phase)

    /// Two-phase scout for combinatorial kits.
    /// Phase 1: Scout individual barcodes to find which are present (N entries).
    /// Phase 2: Generate linked pairs for detected barcodes only (M×M entries, where M << N).
    private func scoutCombinatorial(
        kit: BarcodeKitDefinition,
        ctx: any PlatformAdapterContext,
        subsetFile: URL,
        workDir: URL,
        acceptThreshold: Int,
        rejectThreshold: Int,
        startTime: Date,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> BarcodeScoutResult {
        let fm = FileManager.default

        // Phase 1: Scout individual barcodes with --revcomp (5'-only specs, N entries)
        progress(0.25, "Phase 1: Detecting individual barcodes...")
        let phase1FASTA = workDir.appendingPathComponent("scout-phase1-adapters.fasta")
        var phase1Lines: [String] = []
        for barcode in kit.barcodes {
            let spec = ctx.fivePrimeSpec(barcodeSequence: barcode.i7Sequence)
            phase1Lines.append(">\(barcode.id)")
            phase1Lines.append(spec)
        }
        let phase1Content = phase1Lines.joined(separator: "\n") + "\n"
        try phase1Content.write(to: phase1FASTA, atomically: true, encoding: .utf8)
        try validateAdapterFASTA(at: phase1FASTA, kitName: kit.displayName)

        let phase1Result = try await runScoutCutadapt(
            adapterFASTA: phase1FASTA,
            subsetFile: subsetFile,
            workDir: workDir,
            kit: kit,
            useRevcomp: kit.platform.readsCanBeReverseComplemented,
            outputSubdir: "scout-phase1-output"
        )

        // Identify which barcodes were detected (>= rejectThreshold hits)
        let (phase1Detections, _, _) = try collectScoutDetections(
            outputDir: phase1Result.outputDir,
            kit: kit,
            acceptThreshold: 1,
            rejectThreshold: 0
        )
        let detectedIDs = Set(phase1Detections.filter { $0.hitCount >= rejectThreshold }.map(\.barcodeID))
        let detectedBarcodes = kit.barcodes.filter { detectedIDs.contains($0.id) }

        guard !detectedBarcodes.isEmpty else {
            let elapsed = Date().timeIntervalSince(startTime)
            progress(1.0, "Scout complete: no barcodes detected")
            return BarcodeScoutResult(
                readsScanned: phase1Detections.reduce(0) { $0 + $1.hitCount },
                detections: [],
                unassignedCount: phase1Detections.reduce(0) { $0 + $1.hitCount },
                scoutedKitIDs: [kit.id],
                elapsedSeconds: elapsed
            )
        }

        // Phase 2: Generate linked pairs for detected barcodes only (M×M entries)
        let pairCount = detectedBarcodes.count * detectedBarcodes.count
        progress(0.50, "Phase 2: Testing \(detectedBarcodes.count) barcodes (\(pairCount) pairs)...")
        let phase2FASTA = workDir.appendingPathComponent("scout-phase2-adapters.fasta")
        var phase2Lines: [String] = []
        for fwd in detectedBarcodes {
            for rev in detectedBarcodes {
                let canonicalName = fwd.id <= rev.id
                    ? "\(fwd.id)--\(rev.id)"
                    : "\(rev.id)--\(fwd.id)"
                let fwdSpec = ctx.fivePrimeSpec(barcodeSequence: fwd.i7Sequence)
                let revSpec = ctx.threePrimeSpec(barcodeSequence: rev.i7Sequence)
                phase2Lines.append(">\(canonicalName)")
                phase2Lines.append("\(fwdSpec)...\(revSpec)")
            }
        }
        let phase2Content = phase2Lines.joined(separator: "\n") + "\n"
        try phase2Content.write(to: phase2FASTA, atomically: true, encoding: .utf8)
        try validateAdapterFASTA(at: phase2FASTA, kitName: kit.displayName)

        // Run phase 2 without --revcomp (linked adapters cover both orientations)
        let phase2Result = try await runScoutCutadapt(
            adapterFASTA: phase2FASTA,
            subsetFile: subsetFile,
            workDir: workDir,
            kit: kit,
            useRevcomp: false,
            outputSubdir: "scout-phase2-output"
        )

        progress(0.85, "Analyzing barcode pair results...")

        let (detections, totalScanned, unassignedCount) = try collectScoutDetections(
            outputDir: phase2Result.outputDir,
            kit: kit,
            acceptThreshold: acceptThreshold,
            rejectThreshold: rejectThreshold
        )

        let elapsed = Date().timeIntervalSince(startTime)
        progress(1.0, "Scout complete: \(detections.count) barcode pairs detected")

        return BarcodeScoutResult(
            readsScanned: totalScanned,
            detections: detections,
            unassignedCount: unassignedCount,
            scoutedKitIDs: [kit.id],
            elapsedSeconds: elapsed
        )
    }

    // MARK: - Scout Helpers

    private struct ScoutCutadaptResult {
        let outputDir: URL
    }

    /// Runs cutadapt for scouting purposes and returns the output directory.
    private func runScoutCutadapt(
        adapterFASTA: URL,
        subsetFile: URL,
        workDir: URL,
        kit: BarcodeKitDefinition,
        useRevcomp: Bool,
        outputSubdir: String = "scout-output"
    ) async throws -> ScoutCutadaptResult {
        let fm = FileManager.default
        let demuxOutputDir = workDir.appendingPathComponent(outputSubdir, isDirectory: true)
        try fm.createDirectory(at: demuxOutputDir, withIntermediateDirectories: true)

        let outputPattern = demuxOutputDir.appendingPathComponent("{name}.fastq.gz").path
        let unassignedPath = demuxOutputDir.appendingPathComponent("unassigned.fastq.gz").path
        let jsonReportPath = workDir.appendingPathComponent("\(outputSubdir)-report.json").path

        var args: [String] = []
        args += ["-g", "file:\(adapterFASTA.path)"]
        args += ["-e", String(kit.platform.recommendedErrorRate)]
        args += ["--overlap", String(kit.platform.recommendedMinimumOverlap)]
        if useRevcomp {
            args += ["--revcomp"]
        }
        args += ["--action", "trim"]
        args += ["-o", outputPattern]
        args += ["--untrimmed-output", unassignedPath]
        args += ["--json", jsonReportPath]
        // Use single core to avoid multiprocessing overhead/issues on scout subset
        args += ["--cores", "1"]
        args += [subsetFile.path]

        let cutadaptResult = try await runner.run(
            .cutadapt,
            arguments: args,
            workingDirectory: workDir,
            timeout: 300
        )

        guard cutadaptResult.isSuccess else {
            throw DemultiplexError.cutadaptFailed(
                exitCode: cutadaptResult.exitCode,
                stderr: cutadaptResult.stderr
            )
        }

        return ScoutCutadaptResult(outputDir: demuxOutputDir)
    }

    /// Collects barcode detections from cutadapt scout output files.
    private func collectScoutDetections(
        outputDir: URL,
        kit: BarcodeKitDefinition,
        acceptThreshold: Int,
        rejectThreshold: Int
    ) throws -> (detections: [BarcodeDetection], totalScanned: Int, unassignedCount: Int) {
        let fm = FileManager.default
        let outputFiles = (try? fm.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var detections: [BarcodeDetection] = []
        var totalScanned = 0
        var unassignedCount = 0

        for outputFile in outputFiles {
            let baseName = outputFile.deletingPathExtension().deletingPathExtension().lastPathComponent
            let fileBytes = fileSize(outputFile)
            guard fileBytes > 20 else { continue }
            let count = countReadsInFASTQ(url: outputFile)

            if baseName == "unassigned" {
                unassignedCount = count
            } else {
                detections.append(BarcodeDetection(
                    barcodeID: baseName,
                    kitID: kit.id,
                    hitCount: count,
                    hitPercentage: 0
                ))
            }
            totalScanned += count
        }

        for i in detections.indices {
            if totalScanned > 0 {
                detections[i].hitPercentage = Double(detections[i].hitCount) / Double(totalScanned) * 100
            }
            if detections[i].hitCount >= acceptThreshold {
                detections[i].disposition = .accepted
            } else if detections[i].hitCount <= rejectThreshold {
                detections[i].disposition = .rejected
            }
        }

        detections.sort { $0.hitCount > $1.hitCount }
        return (detections, totalScanned, unassignedCount)
    }

    // MARK: - Multi-Step Demultiplexing

    /// Runs a multi-step demultiplexing pipeline.
    ///
    /// Step 0 demultiplexes the raw input into outer bins.
    /// Subsequent steps demultiplex each output bin from the previous step.
    ///
    /// - Parameters:
    ///   - plan: The multi-step demultiplexing plan.
    ///   - inputURL: Input FASTQ file or bundle URL.
    ///   - outputDirectory: Root output directory.
    ///   - progress: Progress callback.
    /// - Returns: Combined result with all output bundles.
    /// Maximum number of bins to process concurrently in inner steps.
    private static let maxConcurrentBins = 4

    public func runMultiStep(
        plan: DemultiplexPlan,
        inputURL: URL,
        outputDirectory: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> MultiStepDemultiplexResult {
        try plan.validate()
        let startTime = Date()

        let sortedSteps = plan.steps.sorted { $0.ordinal < $1.ordinal }
        var stepResults: [MultiStepDemultiplexResult.StepResult] = []
        var currentInputURLs = [inputURL]
        let progressPerStep = 1.0 / Double(sortedSteps.count)

        for (stepIndex, step) in sortedSteps.enumerated() {
            let stepStartTime = Date()
            let stepBaseProgress = Double(stepIndex) * progressPerStep

            guard let kit = BarcodeKitRegistry.kit(byID: step.barcodeKitID) else {
                throw DemultiplexPlanError.missingKit(step: step.label)
            }

            let binCount = currentInputURLs.count
            let progressPerBin = progressPerStep / Double(max(1, binCount))

            // Step 0 (single input) runs sequentially; inner steps run bins concurrently
            let perBinResults: [DemultiplexResult]
            if stepIndex == 0 || binCount <= 1 {
                var results: [DemultiplexResult] = []
                for (binIndex, binInputURL) in currentInputURLs.enumerated() {
                    let binBaseProgress = stepBaseProgress + Double(binIndex) * progressPerBin
                    let config = buildStepConfig(
                        step: step, kit: kit, binInputURL: binInputURL,
                        outputDirectory: outputDirectory
                    )
                    let result = try await run(config: config) { fraction, message in
                        progress(binBaseProgress + fraction * progressPerBin, "Step \(stepIndex + 1): \(message)")
                    }
                    results.append(result)
                }
                perBinResults = results
            } else {
                // Process inner bins concurrently with bounded parallelism
                perBinResults = try await withThrowingTaskGroup(of: (Int, DemultiplexResult).self) { group in
                    var results = [DemultiplexResult?](repeating: nil, count: binCount)
                    var nextBinIndex = 0

                    // Launch initial batch
                    for _ in 0..<min(Self.maxConcurrentBins, binCount) {
                        let idx = nextBinIndex
                        let binInputURL = currentInputURLs[idx]
                        let binBaseProgress = stepBaseProgress + Double(idx) * progressPerBin
                        let config = buildStepConfig(
                            step: step, kit: kit, binInputURL: binInputURL,
                            outputDirectory: outputDirectory
                        )
                        nextBinIndex += 1
                        group.addTask { [self] in
                            let result = try await self.run(config: config) { fraction, message in
                                progress(binBaseProgress + fraction * progressPerBin, "Step \(stepIndex + 1) [\(idx + 1)/\(binCount)]: \(message)")
                            }
                            return (idx, result)
                        }
                    }

                    // As each completes, launch the next
                    for try await (idx, result) in group {
                        results[idx] = result
                        if nextBinIndex < binCount {
                            let nextIdx = nextBinIndex
                            let binInputURL = currentInputURLs[nextIdx]
                            let binBaseProgress = stepBaseProgress + Double(nextIdx) * progressPerBin
                            let config = buildStepConfig(
                                step: step, kit: kit, binInputURL: binInputURL,
                                outputDirectory: outputDirectory
                            )
                            nextBinIndex += 1
                            group.addTask { [self] in
                                let result = try await self.run(config: config) { fraction, message in
                                    progress(binBaseProgress + fraction * progressPerBin, "Step \(stepIndex + 1) [\(nextIdx + 1)/\(binCount)]: \(message)")
                                }
                                return (nextIdx, result)
                            }
                        }
                    }

                    let collected = results.compactMap { $0 }
                    assert(collected.count == binCount, "Expected \(binCount) bin results, got \(collected.count)")
                    return collected
                }
            }

            let stepElapsed = Date().timeIntervalSince(stepStartTime)
            stepResults.append(.init(step: step, perBinResults: perBinResults, wallClockSeconds: stepElapsed))

            // Next step's inputs are the output bundles from this step
            currentInputURLs = perBinResults.flatMap(\.outputBundleURLs)
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let finalBundles = stepResults.last?.perBinResults.flatMap(\.outputBundleURLs) ?? []

        guard !stepResults.isEmpty,
              stepResults[0].perBinResults.first?.manifest != nil else {
            throw DemultiplexError.noOutputResults
        }

        // Build composite manifest with multi-step provenance
        let provenance = buildProvenance(
            plan: plan, sortedSteps: sortedSteps,
            stepResults: stepResults, elapsed: elapsed
        )

        // Use last step's kit/parameters for the composite (barcodes array comes from last step)
        let finalManifests = stepResults.last?.perBinResults.map(\.manifest) ?? []
        guard let lastStepManifest = finalManifests.first else {
            throw DemultiplexError.noOutputResults
        }

        let allBarcodes = finalManifests.flatMap(\.barcodes)
        let totalUnassignedReads = finalManifests.reduce(0) { $0 + $1.unassigned.readCount }
        let totalUnassignedBases = finalManifests.reduce(0) { $0 + $1.unassigned.baseCount }

        let compositeManifest = DemultiplexManifest(
            version: 2,
            barcodeKit: lastStepManifest.barcodeKit,
            parameters: lastStepManifest.parameters,
            barcodes: allBarcodes,
            unassigned: UnassignedReadsSummary(
                readCount: totalUnassignedReads,
                baseCount: totalUnassignedBases,
                disposition: lastStepManifest.unassigned.disposition
            ),
            outputDirectoryRelativePath: lastStepManifest.outputDirectoryRelativePath,
            inputReadCount: stepResults[0].perBinResults.reduce(0) { $0 + $1.manifest.inputReadCount },
            multiStepProvenance: provenance
        )

        progress(1.0, "Multi-step demultiplexing complete")

        return MultiStepDemultiplexResult(
            stepResults: stepResults,
            outputBundleURLs: finalBundles,
            manifest: compositeManifest,
            wallClockSeconds: elapsed
        )
    }

    /// Builds a `DemultiplexConfig` from a step definition and a specific input bin.
    private func buildStepConfig(
        step: DemultiplexStep,
        kit: BarcodeKitDefinition,
        binInputURL: URL,
        outputDirectory: URL
    ) -> DemultiplexConfig {
        let binName = binInputURL.deletingPathExtension().lastPathComponent
        let stepOutputDir = outputDirectory
            .appendingPathComponent(binName, isDirectory: true)

        return DemultiplexConfig(
            inputURL: binInputURL,
            barcodeKit: kit,
            outputDirectory: stepOutputDir,
            barcodeLocation: step.barcodeLocation,
            symmetryMode: step.symmetryMode,
            errorRate: step.errorRate,
            minimumOverlap: step.minimumOverlap,
            trimBarcodes: step.trimBarcodes,
            searchReverseComplement: step.searchReverseComplement,
            unassignedDisposition: step.unassignedDisposition,
            sampleAssignments: step.sampleAssignments
        )
    }

    /// Builds multi-step provenance from completed step results.
    private func buildProvenance(
        plan: DemultiplexPlan,
        sortedSteps: [DemultiplexStep],
        stepResults: [MultiStepDemultiplexResult.StepResult],
        elapsed: Double
    ) -> MultiStepProvenance {
        let summaries = zip(sortedSteps, stepResults).map { step, result in
            MultiStepProvenance.StepSummary(
                label: step.label,
                barcodeKitID: step.barcodeKitID,
                symmetryMode: step.symmetryMode,
                errorRate: step.errorRate,
                inputBinCount: result.perBinResults.count,
                outputBundleCount: result.perBinResults.reduce(0) { $0 + $1.outputBundleURLs.count },
                totalReadsProcessed: result.perBinResults.reduce(0) { $0 + $1.manifest.inputReadCount },
                wallClockSeconds: result.wallClockSeconds
            )
        }

        return MultiStepProvenance(
            totalSteps: sortedSteps.count,
            stepSummaries: summaries,
            compositeSampleNames: plan.compositeSampleNames,
            totalWallClockSeconds: elapsed
        )
    }

    // MARK: - Helpers

    /// Compute a relative path from one URL to another (e.g. "../../parent-bundle.fastqbundle").
    private func relativePath(from baseURL: URL, to targetURL: URL) -> String {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents

        var common = 0
        while common < min(baseComponents.count, targetComponents.count),
              baseComponents[common] == targetComponents[common] {
            common += 1
        }

        let up = Array(repeating: "..", count: max(0, baseComponents.count - common))
        let down = Array(targetComponents.dropFirst(common))
        let parts = up + down
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
