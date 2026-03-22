// DemultiplexingPipeline.swift - Cutadapt-based barcode demultiplexing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "DemultiplexingPipeline")

// MARK: - Demultiplex Configuration

/// Configuration for a cutadapt-based demultiplexing run.
public struct DemultiplexConfig: Sendable {
    /// Input FASTQ file URL (may be inside a .lungfishfastq bundle or standalone).
    public let inputURL: URL

    /// Logical source bundle for lineage propagation and parent-manifest links.
    ///
    /// This may differ from `inputURL` when demultiplexing operates on a temporary
    /// materialized FASTQ derived from an existing bundle.
    public let sourceBundleURL: URL?

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

    /// Pairing mode of the logical input dataset.
    ///
    /// When nil, the pipeline infers pairing from `sourceBundleURL`/`inputURL`.
    public let inputPairingMode: IngestionMetadata.PairingMode?

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

    /// Effective minimum overlap accounting for cross-platform scenarios.
    ///
    /// For long-read platforms with short barcodes (e.g., 16bp PacBio barcodes on ONT),
    /// a high overlap threshold relative to barcode length is overly strict.
    /// Caps overlap at barcode_length - 4 to allow partial boundary matches.
    public var effectiveMinimumOverlap: Int {
        let minBarcodeLen = barcodeKit.barcodes.reduce(Int.max) { currentMin, barcode in
            let i7Len = barcode.i7Sequence.count
            let i5Len = barcode.i5Sequence?.count ?? i7Len
            return min(currentMin, min(i7Len, i5Len))
        }
        let barcodeLen = minBarcodeLen == Int.max ? 16 : minBarcodeLen
        // Don't require more than barcode_length - 4 overlap
        return min(minimumOverlap, max(3, barcodeLen - 4))
    }

    /// Minimum insert length (bp) between left and right barcode hits.
    /// Used by the exact barcode demux engine for asymmetric kits.
    /// Default: 2000.
    public let minimumInsert: Int

    /// Whether to disallow indels in barcode matching (cutadapt --no-indels).
    ///
    /// Defaults to `false` (indels allowed). ONT reads have significant indel
    /// rates even in barcode regions — benchmarking showed that allowing indels
    /// improved detection by 18% (50→59 both-end reads on 100-read test set).
    /// See `docs/research/cutadapt-demux-pipeline-spec.md`.
    public let useNoIndels: Bool

    /// When true, capture per-read trim positions even in full mode so that
    /// downstream inner steps can chain trim offsets back to the root FASTQ.
    /// Set by multi-step pipelines for non-final steps.
    public let captureTrimsForChaining: Bool

    public init(
        inputURL: URL,
        sourceBundleURL: URL? = nil,
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
        rootFASTQFilename: String? = nil,
        inputPairingMode: IngestionMetadata.PairingMode? = nil,
        minimumInsert: Int = 2000,
        useNoIndels: Bool = false,
        captureTrimsForChaining: Bool = false
    ) {
        self.inputURL = inputURL
        if let sourceBundleURL {
            self.sourceBundleURL = sourceBundleURL
        } else if FASTQBundle.isBundleURL(inputURL) {
            self.sourceBundleURL = inputURL
        } else {
            self.sourceBundleURL = nil
        }
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
        self.inputPairingMode = inputPairingMode
        self.minimumInsert = minimumInsert
        self.useNoIndels = useNoIndels
        self.captureTrimsForChaining = captureTrimsForChaining
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
    case binCountExceeded(count: Int, limit: Int)

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
        case .binCountExceeded(let count, let limit):
            return "Bin count (\(count)) exceeds maximum (\(limit)). Reduce the number of barcode combinations or use fewer demux steps."
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

    let runner = NativeToolRunner.shared

    private struct DemuxTrimEntry: Sendable {
        let readID: String
        let mate: Int
        let trim5p: Int
        let trim3p: Int
        let rootReadLength: Int?
    }

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

        // Asymmetric kits with sample assignments: use Swift-native exact barcode demux
        // instead of cutadapt. This handles internal barcode search, 4 orientation patterns,
        // minimum insert distance, and exact matching required for PacBio barcodes on ONT.
        if config.symmetryMode == .asymmetric && !config.sampleAssignments.isEmpty {
            return try await runExactBarcodeDemux(
                config: config,
                inputFASTQ: inputFASTQ,
                startTime: startTime,
                progress: progress
            )
        }

        // Create working directories
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("lungfish-demux-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        // Fetch cutadapt version for provenance recording
        let cutadaptVersion = await runner.getToolVersion(.cutadapt)

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

        // Final outputs can be virtual when root lineage is known. Intermediate multi-step
        // outputs must stay materialized so the next cutadapt stage consumes full FASTQ,
        // not a preview/read-ID pointer bundle.
        let isVirtualMode = config.rootBundleURL != nil && !config.captureTrimsForChaining
        let needsTrimCapture = isVirtualMode || config.captureTrimsForChaining
        let infoFilePath = needsTrimCapture
            ? workDir.appendingPathComponent("cutadapt-info.tsv").path
            : nil

        let isSymmetricLongRead = config.symmetryMode == .symmetric
            && config.barcodeKit.platform.readsCanBeReverseComplemented
            && config.searchReverseComplement

        var args = buildCutadaptArguments(
            config: config,
            adapterFASTA: adapterConfig.adapterFASTA,
            adapterFlag: adapterConfig.adapterFlag,
            outputPattern: outputPattern,
            unassignedPath: unassignedPath,
            jsonReportPath: jsonReportPath,
            infoFilePath: infoFilePath
        )

        // Symmetric long-read mode requires pass 2a 5' trimming before 3' validation.
        // Keep pass 1 as detection-only so the 5' barcode remains available for pass 2a.
        if isSymmetricLongRead,
           let actionIndex = args.firstIndex(of: "--action"),
           actionIndex + 1 < args.count {
            args[actionIndex + 1] = "none"
        }

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

        progress(0.75, "cutadapt complete, processing trim info...")

        // Step 4: Parse per-read trim positions from info file (if captured)
        // Key = barcode name, Value = array of (readID, trim5prime, trim3prime) tuples
        var trimPositionsByBarcode: [String: [DemuxTrimEntry]] = [:]
        if let infoFilePath, fm.fileExists(atPath: infoFilePath) {
            trimPositionsByBarcode = parseCutadaptInfoFile(URL(fileURLWithPath: infoFilePath))
        }

        // Step 4a: For inner steps of multi-step pipelines, chain trim positions from the
        // parent bundle. The parent's trim-positions.tsv records how much the outer step
        // trimmed each read relative to the root FASTQ. The inner step's trims are relative
        // to the parent's output. Cumulative = parent + inner.
        // Key: "readID\tmate" → (trim5p, trim3p)
        var parentTrimMap: [String: (trim5p: Int, trim3p: Int)] = [:]
        let lineageBundleURL = config.sourceBundleURL
        let needsLineagePropagation = (isVirtualMode || config.captureTrimsForChaining) && lineageBundleURL != nil
        if needsLineagePropagation, let lineageBundleURL {
            let parentTrimURL = lineageBundleURL.appendingPathComponent(FASTQBundle.trimPositionFilename)
            if let parentContent = try? String(contentsOf: parentTrimURL, encoding: .utf8) {
                for line in parentContent.split(separator: "\n") {
                    // Skip format headers and column headers
                    if line.hasPrefix("#") || line.hasPrefix("read_id") { continue }
                    let cols = line.split(separator: "\t")
                    if cols.count >= 4, let mate = Int(cols[1]),
                       let t5 = Int(cols[2]), let t3 = Int(cols[3]) {
                        // 4-column format: read_id, mate, trim_5p, trim_3p
                        parentTrimMap["\(cols[0])\t\(mate)"] = (t5, t3)
                    } else if cols.count >= 3, let t5 = Int(cols[1]), let t3 = Int(cols[2]) {
                        // Legacy 3-column format: read_id, trim_5p, trim_3p (mate=0)
                        parentTrimMap["\(cols[0])\t0"] = (t5, t3)
                    }
                }
                if !parentTrimMap.isEmpty {
                    logger.info("Loaded \(parentTrimMap.count) parent trim positions for chaining")
                }
            }
        }

        // Step 4b: If the input bundle has an orient map (parent was an orient step),
        // adjust trim positions so they are relative to the ROOT FASTQ orientation.
        // Cutadapt computed trims on oriented reads, but materialization reads from root.
        // For RC'd reads: swap trim_5p ↔ trim_3p to correct for the orientation flip.
        var parentOrientMap: [String: String] = [:]
        if needsLineagePropagation, let lineageBundleURL {
            let orientMapURL = lineageBundleURL.appendingPathComponent("orient-map.tsv")
            if let loaded = try? FASTQOrientMapFile.load(from: orientMapURL) {
                parentOrientMap = loaded
                logger.info("Loaded orient map with \(loaded.count) entries for trim adjustment")
            }
            // Note: If the orient map is not directly in config.inputURL, it means
            // the orient step is further up the lineage chain. In that case, the
            // intermediate bundle should have already propagated the orient map
            // to its per-barcode bundles. Multi-hop orient map resolution is not
            // yet implemented — the orient map must be in the immediate parent.
        }

        // Step 4c: For symmetric long-read kits, enforce both-end matching.
        // Pass 1 (above) used 5'-only specs with --revcomp, which assigns reads where
        // the barcode appears on ANY end. Pass 1 also normalizes all output reads to
        // forward orientation (cutadapt outputs RC'd reads in their matched orientation).
        // For symmetric mode, we filter each per-barcode file to keep only reads that
        // ALSO have the 3' adapter — i.e., both ends present.
        // Pass 2a trims/normalizes 5' with --revcomp first to avoid false positives
        // in pass 2b where RC(5') could mimic a 3' adapter hit.
        // Pass 2b then checks 3' with no --revcomp.
        if isSymmetricLongRead {
            progress(0.78, "Enforcing both-end barcode matching...")
            let ctx = config.resolvedAdapterContext
            let pass2Dir = workDir.appendingPathComponent("symmetric-pass2", isDirectory: true)
            try fm.createDirectory(at: pass2Dir, withIntermediateDirectories: true)

            let barcodeOutputFiles = try fm.contentsOfDirectory(
                at: demuxOutputDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "gz" || $0.pathExtension == "fastq" }

            for outputFile in barcodeOutputFiles {
                let baseName = outputFile.deletingPathExtension().deletingPathExtension().lastPathComponent
                guard baseName != "unassigned" else { continue }
                guard fileSize(outputFile) > 20 else { continue }

                // Find the barcode sequence for this output file
                let barcodeSeq: String?
                if let barcode = config.barcodeKit.barcodes.first(where: { $0.id == baseName }) {
                    barcodeSeq = barcode.i7Sequence
                } else if let assignment = config.sampleAssignments.first(where: {
                    sanitizedSampleIdentifier($0.sampleID) == baseName
                }) {
                    barcodeSeq = resolveSequence(
                        explicitSequence: assignment.forwardSequence,
                        barcodeID: assignment.forwardBarcodeID,
                        kit: config.barcodeKit
                    )
                } else {
                    barcodeSeq = nil
                }
                guard let seq = barcodeSeq else { continue }

                let barcodeDir = pass2Dir.appendingPathComponent(baseName, isDirectory: true)
                try fm.createDirectory(at: barcodeDir, withIntermediateDirectories: true)

                // Pass 2a: Trim the 5' adapter with --revcomp to normalize orientation.
                // This prevents RC(5') from being misinterpreted as a 3' hit in pass 2b.
                let fivePrimeFASTA = barcodeDir.appendingPathComponent("5prime.fasta")
                try ">\(baseName)\n\(ctx.fivePrimeSpec(barcodeSequence: seq))\n"
                    .write(to: fivePrimeFASTA, atomically: true, encoding: .utf8)

                let trimmedFile = barcodeDir.appendingPathComponent("trimmed.fastq.gz")
                var pass2aArgs: [String] = [
                    "-g", "file:\(fivePrimeFASTA.path)",
                    "-e", String(config.effectiveErrorRate),
                    "--overlap", String(config.effectiveMinimumOverlap),
                    "--revcomp",
                    "--action", "trim",
                    "--discard-untrimmed",
                    "-o", trimmedFile.path,
                    "--cores", "1",
                    outputFile.path
                ]
                if config.useNoIndels { pass2aArgs.insert("--no-indels", at: 6) }

                let p2aResult = try await runner.run(
                    .cutadapt, arguments: pass2aArgs, workingDirectory: workDir, timeout: 300
                )
                guard p2aResult.isSuccess, fm.fileExists(atPath: trimmedFile.path) else { continue }

                // Pass 2b: Check for 3' adapter to keep only both-end reads.
                let threePrimeFASTA = barcodeDir.appendingPathComponent("3prime.fasta")
                try ">\(baseName)\n\(ctx.threePrimeSpec(barcodeSequence: seq))\n"
                    .write(to: threePrimeFASTA, atomically: true, encoding: .utf8)

                let bothEndFile = barcodeDir.appendingPathComponent("both-end.fastq.gz")
                var pass2bArgs: [String] = [
                    "-a", "file:\(threePrimeFASTA.path)",
                    "-e", String(config.effectiveErrorRate),
                    "--overlap", String(config.effectiveMinimumOverlap),
                    "--action", "none", "--discard-untrimmed",
                    "-o", bothEndFile.path, "--cores", "1", trimmedFile.path
                ]
                if config.useNoIndels { pass2bArgs.insert("--no-indels", at: 6) }

                let p2bResult = try await runner.run(
                    .cutadapt, arguments: pass2bArgs, workingDirectory: workDir, timeout: 300
                )
                guard p2bResult.isSuccess else { continue }

                // Replace the original per-barcode output with only both-end reads.
                try fm.removeItem(at: outputFile)
                if fm.fileExists(atPath: bothEndFile.path), fileSize(bothEndFile) > 20 {
                    try fm.moveItem(at: bothEndFile, to: outputFile)
                }
            }
        }

        progress(0.80, "Creating bundles...")

        // Step 5: Create virtual per-barcode .lungfishfastq bundles (15% progress)
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

        // Process files with bounded concurrency (8 at a time)
        struct VirtualBundleResult: Sendable {
            let baseName: String
            let isUnassigned: Bool
            let bundleURL: URL
            let bundleName: String
            let statistics: FASTQDatasetStatistics
        }

        // Virtual mode: extract read IDs + preview (default for single-step and final multi-step)
        // Full mode: move entire cutadapt output into bundle (intermediate multi-step)

        let bundleResults: [VirtualBundleResult] = try await withThrowingTaskGroup(
            of: VirtualBundleResult?.self,
            returning: [VirtualBundleResult].self
        ) { group in
            var results: [VirtualBundleResult] = []
            var inFlight = 0

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
                let capturedIsVirtual = isVirtualMode
                let capturedTrimPositions = trimPositionsByBarcode[file.baseName]
                let capturedParentTrimMap = parentTrimMap
                let capturedParentOrientMap = parentOrientMap
                let capturedLineageBundleURL = lineageBundleURL
                let capturedInputFASTQ = inputFASTQ
                let capturedTrimBarcodes = config.trimBarcodes
                let capturedRootFASTQURL = config.rootBundleURL.flatMap { rootBundleURL in
                    config.rootFASTQFilename.map { rootBundleURL.appendingPathComponent($0) }
                }
                group.addTask { [self] in
                    try Task.checkCancellation()

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

                    let readIDContent = try String(contentsOf: readIDsURL, encoding: .utf8)
                    let orderedReadIDs = readIDContent.split(separator: "\n").map(String.init)

                    let cutadaptOrientMap = try await self.readCutadaptOrientations(from: file.url)
                    let finalOrientMap = self.composeFinalOrientMap(
                        parentOrientMap: capturedParentOrientMap,
                        cutadaptOrientMap: cutadaptOrientMap,
                        readIDs: orderedReadIDs
                    )

                    var allTrimEntries = self.rebaseTrimEntriesToRoot(
                        self.normalizeTrimEntriesToInputOrientation(
                            capturedTrimPositions ?? [],
                            cutadaptOrientMap: cutadaptOrientMap
                        ),
                        parentTrimMap: capturedParentTrimMap,
                        parentOrientMap: capturedParentOrientMap
                    )
                    var innerTrimKeys = Set(allTrimEntries.map { "\($0.readID)\t\($0.mate)" })

                    if capturedTrimBarcodes, orderedReadIDs.count > allTrimEntries.count {
                        let derivedTrimEntries = try await self.deriveTrimEntriesByDiff(
                            originalFASTQ: capturedInputFASTQ,
                            trimmedFASTQ: file.url,
                            cutadaptOrientMap: cutadaptOrientMap
                        )
                        let rebasedTrimEntries = self.rebaseTrimEntriesToRoot(
                            derivedTrimEntries,
                            parentTrimMap: capturedParentTrimMap,
                            parentOrientMap: capturedParentOrientMap
                        )
                        for entry in rebasedTrimEntries {
                            let key = "\(entry.readID)\t\(entry.mate)"
                            if innerTrimKeys.insert(key).inserted {
                                allTrimEntries.append(entry)
                            }
                        }
                    }

                    // Add parent-only trims for reads in this barcode's output
                    // that weren't trimmed by the inner step's cutadapt
                    if !capturedParentTrimMap.isEmpty {
                        for readID in orderedReadIDs {
                            // Try mate=0 (single-end) first, then mate 1 and 2 for PE
                            for mate in [0, 1, 2] {
                                let key = "\(readID)\t\(mate)"
                                if innerTrimKeys.insert(key).inserted,
                                   let parentTrim = capturedParentTrimMap[key] {
                                    allTrimEntries.append(DemuxTrimEntry(
                                        readID: readID,
                                        mate: mate,
                                        trim5p: parentTrim.trim5p,
                                        trim3p: parentTrim.trim3p,
                                        rootReadLength: nil
                                    ))
                                }
                            }
                        }
                    }

                    if capturedIsVirtual {
                        // Virtual mode: create a small preview alongside the read ID list

                        let previewURL = bundleURL.appendingPathComponent("preview.fastq")
                        if let capturedRootFASTQURL,
                           FileManager.default.fileExists(atPath: capturedRootFASTQURL.path) {
                            try await self.writeVirtualPreviewFASTQ(
                                fromRootFASTQ: capturedRootFASTQURL,
                                orderedReadIDs: Array(orderedReadIDs.prefix(1000)),
                                trimEntries: allTrimEntries,
                                orientMap: finalOrientMap,
                                outputURL: previewURL
                            )
                        } else {
                            let previewResult = try await capturedRunner.run(
                                .seqkit,
                                arguments: ["head", "-n", "1000", file.url.path, "-o", previewURL.path],
                                timeout: 120
                            )
                            guard previewResult.isSuccess else {
                                logger.error("seqkit head failed for \(file.baseName): \(previewResult.stderr)")
                                return nil
                            }
                        }

                        try self.writeTrimPositions(allTrimEntries, to: bundleURL)
                        try self.writeOrientMap(finalOrientMap: finalOrientMap, orderedReadIDs: orderedReadIDs, to: bundleURL)

                        // Generate read-level annotations for barcode matches
                        var annotations: [ReadAnnotationFile.Annotation] = []
                        for entry in allTrimEntries {
                            if entry.trim5p > 0 {
                                annotations.append(ReadAnnotationFile.Annotation(
                                    readID: entry.readID,
                                    mate: entry.mate,
                                    annotationType: "barcode_5p",
                                    start: 0,
                                    end: entry.trim5p,
                                    label: file.baseName
                                ))
                            }
                            if entry.trim3p > 0, let rootReadLength = entry.rootReadLength {
                                let start = max(0, rootReadLength - entry.trim3p)
                                annotations.append(ReadAnnotationFile.Annotation(
                                    readID: entry.readID,
                                    mate: entry.mate,
                                    annotationType: "barcode_3p",
                                    start: start,
                                    end: rootReadLength,
                                    label: file.baseName
                                ))
                            }
                        }

                        // Propagate parent annotations and write combined file
                        if !annotations.isEmpty || finalOrientMap.isEmpty == false {
                            let parentAnnotURL: URL? = {
                                guard let capturedLineageBundleURL else { return nil }
                                let url = capturedLineageBundleURL.appendingPathComponent(ReadAnnotationFile.filename)
                                return FileManager.default.fileExists(atPath: url.path) ? url : nil
                            }()
                            let readIDsForBarcode: Set<String> = Set(orderedReadIDs)
                            let merged = try ReadAnnotationFile.mergeAndFilter(
                                parentURL: parentAnnotURL,
                                newAnnotations: annotations,
                                readIDs: readIDsForBarcode
                            )
                            if !merged.isEmpty {
                                let annotURL = bundleURL.appendingPathComponent(ReadAnnotationFile.filename)
                                try ReadAnnotationFile.write(merged, to: annotURL)
                            }
                        }
                    } else {
                        // Full mode: move cutadapt output file into bundle for downstream steps
                        let destFilename = file.url.lastPathComponent
                        let destURL = bundleURL.appendingPathComponent(destFilename)
                        try FileManager.default.moveItem(at: file.url, to: destURL)

                        try self.writeTrimPositions(allTrimEntries, to: bundleURL)
                        try self.writeOrientMap(finalOrientMap: finalOrientMap, orderedReadIDs: orderedReadIDs, to: bundleURL)
                    }

                    // Compute full statistics (histograms, quality, GC) via native Swift scanner.
                    // Virtual bundles must scan the canonical root-based reconstruction, otherwise
                    // cached lengths can disagree with the preview/materialized sequence when trim
                    // positions have been rebased to the root FASTQ.
                    let statsSource: URL
                    var temporaryStatsURL: URL?
                    if capturedIsVirtual,
                       let capturedRootFASTQURL,
                       FileManager.default.fileExists(atPath: capturedRootFASTQURL.path) {
                        let tempStatsURL = workDir.appendingPathComponent(
                            "stats-\(file.baseName)-\(UUID().uuidString).fastq"
                        )
                        try await self.writeVirtualStatisticsFASTQ(
                            fromRootFASTQ: capturedRootFASTQURL,
                            orderedReadIDs: orderedReadIDs,
                            trimEntries: allTrimEntries,
                            orientMap: finalOrientMap,
                            outputURL: tempStatsURL
                        )
                        statsSource = tempStatsURL
                        temporaryStatsURL = tempStatsURL
                    } else {
                        statsSource = capturedIsVirtual ? file.url : bundleURL.appendingPathComponent(file.url.lastPathComponent)
                    }
                    defer {
                        if let temporaryStatsURL {
                            try? FileManager.default.removeItem(at: temporaryStatsURL)
                        }
                    }
                    let reader = FASTQReader(validateSequence: false)
                    let (statistics, _) = try await reader.computeStatistics(from: statsSource, sampleLimit: 0)

                    return VirtualBundleResult(
                        baseName: file.baseName,
                        isUnassigned: file.isUnassigned,
                        bundleURL: bundleURL,
                        bundleName: bundleName,
                        statistics: statistics
                    )
                }
                inFlight += 1
            }

            // Collect remaining results
            for try await result in group {
                if let r = result { results.append(r) }
            }
            return results
        }

        // Process results and write derived manifests
        for (i, result) in bundleResults.enumerated() {
            let stats = result.statistics
            if result.isUnassigned {
                unassignedReadCount = stats.readCount
                unassignedBaseCount = stats.baseCount
                if config.unassignedDisposition == .keep {
                    unassignedBundleURL = result.bundleURL
                } else {
                    try? fm.removeItem(at: result.bundleURL)
                    continue
                }
            } else {
                assignedReadCount += stats.readCount
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
                    readCount: stats.readCount,
                    baseCount: stats.baseCount,
                    bundleRelativePath: result.bundleName
                ))
                bundleURLs.append(result.bundleURL)
            }

            // Write derived manifest if root bundle info is available
            if let rootBundleURL = config.rootBundleURL,
               let rootFASTQFilename = config.rootFASTQFilename {
                let rootRelativePath = FASTQBundle.projectRelativePath(for: rootBundleURL, from: result.bundleURL)
                    ?? relativePath(from: result.bundleURL, to: rootBundleURL)
                let parentBundleURL = config.sourceBundleURL
                let parentRelativePath = parentBundleURL.flatMap {
                    FASTQBundle.projectRelativePath(for: $0, from: result.bundleURL)
                        ?? relativePath(from: result.bundleURL, to: $0)
                } ?? rootRelativePath
                let demuxOp = FASTQDerivativeOperation(
                    kind: .demultiplex,
                    toolUsed: "cutadapt",
                    toolVersion: cutadaptVersion
                )
                let derivedManifest = FASTQDerivedBundleManifest(
                    name: result.baseName,
                    parentBundleRelativePath: parentRelativePath,
                    rootBundleRelativePath: rootRelativePath,
                    rootFASTQFilename: rootFASTQFilename,
                    payload: .demuxedVirtual(
                        barcodeID: result.baseName,
                        readIDListFilename: "read-ids.txt",
                        previewFilename: "preview.fastq",
                        trimPositionsFilename: hasTrimPositionsFile(in: result.bundleURL) ? "trim-positions.tsv" : nil,
                        orientMapFilename: hasOrientMapFile(in: result.bundleURL) ? "orient-map.tsv" : nil
                    ),
                    lineage: [demuxOp],
                    operation: demuxOp,
                    cachedStatistics: stats,
                    pairingMode: config.inputPairingMode ?? inferredPairingMode(from: parentBundleURL ?? config.inputURL)
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
            isDualIndexed: config.symmetryMode == .singleEnd ? false : (usesExplicitAssignments ? true : config.barcodeKit.isDualIndexed),
            barcodeType: config.symmetryMode == .singleEnd ? .singleEnd : .asymmetric
        )

        let requireBothEnds: Bool
        switch config.symmetryMode {
        case .singleEnd:
            requireBothEnds = false
        case .symmetric:
            requireBothEnds = config.barcodeLocation == .bothEnds
        case .asymmetric:
            requireBothEnds = config.barcodeKit.isDualIndexed || config.barcodeLocation == .bothEnds
        }

        let manifest = DemultiplexManifest(
            barcodeKit: kitForManifest,
            parameters: DemultiplexParameters(
                tool: "cutadapt",
                toolVersion: cutadaptVersion,
                maxMismatches: Int(config.errorRate * Double(config.barcodeKit.barcodes[0].i7Sequence.count)),
                requireBothEnds: requireBothEnds,
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

    // MARK: - Exact Barcode Demux (Asymmetric)

    /// Runs the Swift-native exact barcode demux engine for asymmetric kits.
    ///
    /// Produces virtual bundles directly (read ID lists + previews) without
    /// writing intermediate FASTQ files. Used for PacBio asymmetric barcodes
    /// that require exact matching with internal barcode search.
    private func runExactBarcodeDemux(
        config: DemultiplexConfig,
        inputFASTQ: URL,
        startTime: Date,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> DemultiplexResult {
        let fm = FileManager.default
        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        // Build sample barcode pairs from assignments
        var sampleBarcodes: [ExactBarcodeDemuxConfig.SampleBarcodePair] = []
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
            sampleBarcodes.append(ExactBarcodeDemuxConfig.SampleBarcodePair(
                sampleName: name,
                forwardSequence: fwdSeq,
                reverseSequence: revSeq
            ))
        }

        guard !sampleBarcodes.isEmpty else {
            throw DemultiplexError.combinatorialRequiresSampleAssignments
        }

        // Resolve input FASTQ(s) — multi-file bundles have source-files.json
        let inputURLs: [URL]
        if let bundleURL = config.sourceBundleURL ?? (FASTQBundle.isBundleURL(config.inputURL) ? config.inputURL : nil),
           let allURLs = FASTQBundle.resolveAllFASTQURLs(for: bundleURL), allURLs.count > 1 {
            inputURLs = allURLs
        } else {
            inputURLs = [inputFASTQ]
        }

        // Run the exact barcode demux engine
        let demuxConfig = ExactBarcodeDemuxConfig(
            inputURLs: inputURLs,
            sampleBarcodes: sampleBarcodes,
            minimumInsert: config.minimumInsert
        )

        let demuxResult = try await ExactBarcodeDemux.run(
            config: demuxConfig,
            progress: progress
        )

        progress(0.80, "Creating virtual bundles...")

        // Create virtual bundles directly from demux results
        var barcodeResults: [BarcodeResult] = []
        var bundleURLs: [URL] = []
        var unassignedBundleURL: URL?
        var assignedReadCount = 0

        // Process each sample result
        for (i, sampleResult) in demuxResult.sampleResults.enumerated() {
            let bundleName = "\(sampleResult.sampleName).\(FASTQBundle.directoryExtension)"
            let bundleURL = config.outputDirectory
                .appendingPathComponent(bundleName, isDirectory: true)
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            // Write read-ids.txt
            let readIDsURL = bundleURL.appendingPathComponent("read-ids.txt")
            let readIDContent = sampleResult.readIDs.joined(separator: "\n") + "\n"
            try readIDContent.write(to: readIDsURL, atomically: true, encoding: .utf8)

            // Write preview.fastq
            let previewURL = bundleURL.appendingPathComponent("preview.fastq")
            let previewContent = sampleResult.previewRecords.map(\.fastqString).joined()
            try previewContent.write(to: previewURL, atomically: true, encoding: .utf8)

            // Write derived manifest if root bundle info is available
            if let rootBundleURL = config.rootBundleURL,
               let rootFASTQFilename = config.rootFASTQFilename {
                let rootRelativePath = FASTQBundle.projectRelativePath(for: rootBundleURL, from: bundleURL)
                    ?? relativePath(from: bundleURL, to: rootBundleURL)
                let parentBundleURL = config.sourceBundleURL
                let parentRelativePath = parentBundleURL.flatMap {
                    FASTQBundle.projectRelativePath(for: $0, from: bundleURL)
                        ?? relativePath(from: bundleURL, to: $0)
                } ?? rootRelativePath
                let demuxOp = FASTQDerivativeOperation(
                    kind: .demultiplex,
                    toolUsed: "exact-barcode-demux",
                    toolVersion: nil
                )
                let stats = ExactBarcodeDemux.computeStatistics(
                    readCount: sampleResult.readCount,
                    baseCount: sampleResult.baseCount,
                    minReadLength: sampleResult.minReadLength,
                    maxReadLength: sampleResult.maxReadLength,
                    readLengthHistogram: sampleResult.readLengthHistogram
                )
                let derivedManifest = FASTQDerivedBundleManifest(
                    name: sampleResult.sampleName,
                    parentBundleRelativePath: parentRelativePath,
                    rootBundleRelativePath: rootRelativePath,
                    rootFASTQFilename: rootFASTQFilename,
                    payload: .demuxedVirtual(
                        barcodeID: sampleResult.sampleName,
                        readIDListFilename: "read-ids.txt",
                        previewFilename: "preview.fastq",
                        trimPositionsFilename: nil,
                        orientMapFilename: nil
                    ),
                    lineage: [demuxOp],
                    operation: demuxOp,
                    cachedStatistics: stats,
                    pairingMode: config.inputPairingMode ?? inferredPairingMode(from: config.sourceBundleURL ?? config.inputURL)
                )
                do {
                    try FASTQBundle.saveDerivedManifest(derivedManifest, in: bundleURL)
                } catch {
                    logger.error("Failed to save derived manifest for \(sampleResult.sampleName): \(error)")
                }
            }

            // Look up sample assignment for sequence info
            let sequenceInfo = barcodeSequenceInfo(
                for: sampleResult.sampleName,
                kit: config.barcodeKit,
                sampleAssignments: config.sampleAssignments
            )
            barcodeResults.append(BarcodeResult(
                barcodeID: sampleResult.sampleName,
                sampleName: sequenceInfo.sampleName,
                forwardSequence: sampleResult.forwardBarcodeSeq,
                reverseSequence: sampleResult.reverseBarcodeSeq,
                readCount: sampleResult.readCount,
                baseCount: sampleResult.baseCount,
                bundleRelativePath: bundleName
            ))
            bundleURLs.append(bundleURL)
            assignedReadCount += sampleResult.readCount

            progress(
                0.80 + 0.15 * Double(i + 1) / Double(demuxResult.sampleResults.count),
                "Created virtual bundle for \(sampleResult.sampleName)"
            )
        }

        // Handle unassigned reads
        if config.unassignedDisposition == .keep && demuxResult.unassignedReadCount > 0 {
            let unassignedBundleName = "unassigned.\(FASTQBundle.directoryExtension)"
            let bundleURL = config.outputDirectory
                .appendingPathComponent(unassignedBundleName, isDirectory: true)
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            let readIDsURL = bundleURL.appendingPathComponent("read-ids.txt")
            let readIDContent = demuxResult.unassignedReadIDs.joined(separator: "\n") + "\n"
            try readIDContent.write(to: readIDsURL, atomically: true, encoding: .utf8)

            let previewURL = bundleURL.appendingPathComponent("preview.fastq")
            let previewContent = demuxResult.unassignedPreview.map(\.fastqString).joined()
            try previewContent.write(to: previewURL, atomically: true, encoding: .utf8)

            if let rootBundleURL = config.rootBundleURL,
               let rootFASTQFilename = config.rootFASTQFilename {
                let rootRelativePath = FASTQBundle.projectRelativePath(for: rootBundleURL, from: bundleURL)
                    ?? relativePath(from: bundleURL, to: rootBundleURL)
                let parentRelativePath = config.sourceBundleURL.flatMap {
                    FASTQBundle.projectRelativePath(for: $0, from: bundleURL)
                        ?? relativePath(from: bundleURL, to: $0)
                } ?? rootRelativePath
                let demuxOp = FASTQDerivativeOperation(
                    kind: .demultiplex,
                    toolUsed: "exact-barcode-demux",
                    toolVersion: nil
                )
                let stats = ExactBarcodeDemux.computeStatistics(
                    readCount: demuxResult.unassignedReadCount,
                    baseCount: demuxResult.unassignedBaseCount,
                    minReadLength: demuxResult.unassignedMinReadLength,
                    maxReadLength: demuxResult.unassignedMaxReadLength,
                    readLengthHistogram: [:]
                )
                let derivedManifest = FASTQDerivedBundleManifest(
                    name: "unassigned",
                    parentBundleRelativePath: parentRelativePath,
                    rootBundleRelativePath: rootRelativePath,
                    rootFASTQFilename: rootFASTQFilename,
                    payload: .demuxedVirtual(
                        barcodeID: "unassigned",
                        readIDListFilename: "read-ids.txt",
                        previewFilename: "preview.fastq",
                        trimPositionsFilename: nil,
                        orientMapFilename: nil
                    ),
                    lineage: [demuxOp],
                    operation: demuxOp,
                    cachedStatistics: stats,
                    pairingMode: config.inputPairingMode ?? inferredPairingMode(from: config.sourceBundleURL ?? config.inputURL)
                )
                do {
                    try FASTQBundle.saveDerivedManifest(derivedManifest, in: bundleURL)
                } catch {
                    logger.error("Failed to save derived manifest for unassigned: \(error)")
                }
            }

            unassignedBundleURL = bundleURL
        }

        // Sort barcode results by ID
        barcodeResults.sort { $0.barcodeID.localizedStandardCompare($1.barcodeID) == .orderedAscending }

        let elapsed = Date().timeIntervalSince(startTime)

        // Build manifest
        let kitForManifest = BarcodeKit(
            name: config.barcodeKit.displayName,
            vendor: config.barcodeKit.vendor,
            barcodeCount: config.sampleAssignments.count,
            isDualIndexed: true,
            barcodeType: .asymmetric
        )

        let manifest = DemultiplexManifest(
            barcodeKit: kitForManifest,
            parameters: DemultiplexParameters(
                tool: "exact-barcode-demux",
                toolVersion: nil,
                maxMismatches: 0,
                requireBothEnds: true,
                trimBarcodes: false,
                commandLine: "exact-barcode-demux --min-insert \(config.minimumInsert)",
                wallClockSeconds: elapsed
            ),
            barcodes: barcodeResults,
            unassigned: UnassignedReadsSummary(
                readCount: demuxResult.unassignedReadCount,
                baseCount: demuxResult.unassignedBaseCount,
                disposition: config.unassignedDisposition,
                bundleRelativePath: unassignedBundleURL?.lastPathComponent
            ),
            outputDirectoryRelativePath: ".",
            inputReadCount: demuxResult.totalReads
        )

        try manifest.save(to: config.outputDirectory)

        if FASTQBundle.isBundleURL(config.inputURL) {
            try? manifest.save(to: config.inputURL)
        }

        progress(1.0, "Demultiplexing complete: \(barcodeResults.count) samples, \(String(format: "%.0f%%", manifest.assignmentRate * 100)) assigned")

        logger.info("Exact barcode demux complete: \(barcodeResults.count) samples, \(manifest.assignmentRate * 100)% assigned, \(String(format: "%.1f", elapsed))s")

        return DemultiplexResult(
            manifest: manifest,
            outputBundleURLs: bundleURLs,
            unassignedBundleURL: unassignedBundleURL,
            wallClockSeconds: elapsed
        )
    }

    // MARK: - Private Helpers

    /// Resolves the actual FASTQ file from a URL (handles .lungfishfastq bundles).
    func resolveInputFASTQ(_ url: URL) -> URL {
        if FASTQBundle.isBundleURL(url) {
            return FASTQBundle.resolvePrimaryFASTQURL(for: url) ?? url
        }
        return url
    }

    private func inferredPairingMode(from url: URL) -> IngestionMetadata.PairingMode? {
        if FASTQBundle.isBundleURL(url) {
            if let manifest = FASTQBundle.loadDerivedManifest(in: url), let pairingMode = manifest.pairingMode {
                return pairingMode
            }
            if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: url) {
                return FASTQMetadataStore.load(for: fastqURL)?.ingestion?.pairingMode
            }
            return nil
        }
        return FASTQMetadataStore.load(for: url)?.ingestion?.pairingMode
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

        if !config.sampleAssignments.isEmpty && config.symmetryMode == .singleEnd {
            let ctx = config.resolvedAdapterContext
            let useRevcomp = config.searchReverseComplement
            var lines: [String] = []
            for assignment in config.sampleAssignments {
                guard let sequence = resolveSequence(
                    explicitSequence: assignment.forwardSequence,
                    barcodeID: assignment.forwardBarcodeID,
                    kit: config.barcodeKit
                ) ?? resolveSequence(
                    explicitSequence: assignment.reverseSequence,
                    barcodeID: assignment.reverseBarcodeID,
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
        } else if !config.sampleAssignments.isEmpty
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
            // Use 5'-only specs with --revcomp for pass 1 (barcode identity detection).
            // The actual demux enforces both-end matching via a second pass with 3' adapter.
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
            // For long-read platforms, use 5'-only adapter specs with --revcomp.
            // Pass 1 detects barcode identity; for symmetric mode, the demux pipeline
            // runs a second pass with 3' adapter to enforce both-end matching.
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
    func validateAdapterFASTA(at url: URL, kitName: String) throws {
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
        jsonReportPath: String,
        infoFilePath: String? = nil
    ) -> [String] {
        var args: [String] = []

        // Adapter specification.
        args += [adapterFlag, "file:\(adapterFASTA.path)"]

        // Error rate (cross-platform aware) and overlap
        args += ["-e", String(config.effectiveErrorRate)]
        args += ["--overlap", String(config.effectiveMinimumOverlap)]
        if config.useNoIndels {
            args += ["--no-indels"]
        }

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

        // Per-read adapter match info (for trim position capture)
        if let infoFilePath {
            args += ["--info-file", infoFilePath]
        }

        // Threading
        args += ["--cores", String(max(1, config.threads))]

        return args
    }

    /// Parses cutadapt's `--info-file` output to extract per-read trim positions.
    ///
    /// The info file is tab-separated with columns:
    /// 0: read_name, 1: errors, 2: adapter_start, 3: adapter_end,
    /// 4: sequence_before, 5: matched_sequence, 6: sequence_after,
    /// 7: adapter_name, 8: quality_before, 9: quality_of_match, 10: quality_after
    ///
    /// For linked adapters (5'...3'), each read produces two lines (one per arm).
    /// Returns: dictionary keyed by barcode name → array of (readID, trim5p, trim3p).
    /// trim5p = number of bases to trim from 5' end (adapter match end position).
    /// trim3p = number of bases to trim from 3' end (read length - adapter match start).
    ///
    /// Direction detection uses adapter_start/adapter_end positions (columns 2-3) rather
    /// than sequence length comparison, which is unreliable for symmetric barcodes or
    /// adapters near the read midpoint.
    private func parseCutadaptInfoFile(_ url: URL) -> [String: [DemuxTrimEntry]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }

        // Accumulate per-read match info: (readID, mate) → (barcode, 5p trim end, 3p trim start)
        struct ReadTrimInfo {
            var barcode: String = ""
            var trim5p: Int = 0
            var trim3p: Int = 0  // stored as offset from read start where 3' adapter begins
            var readLength: Int = 0
        }

        // Key: "readID\tmate" to distinguish R1/R2 in interleaved PE data
        var readInfos: [String: ReadTrimInfo] = [:]

        // Stream line-by-line using a chunked buffer to avoid loading entire file into memory
        let chunkSize = 65536
        var buffer = Data()

        func processLine(_ line: String) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 8 else { return }

            let rawReadName = String(cols[0])
            let errors = Int(cols[1]) ?? -1
            guard errors >= 0 else { return }  // -1 means no match

            let (readID, mate) = detectMate(rawReadName: rawReadName)

            let adapterStart = Int(cols[2]) ?? 0
            let adapterEnd = Int(cols[3]) ?? 0
            let adapterName = canonicalAdapterName(String(cols[7]))
            let seqBefore = cols[4]
            let matchedSeq = cols[5]
            let seqAfter = cols[6]

            let totalLen = seqBefore.count + matchedSeq.count + seqAfter.count

            let compositeKey = "\(readID)\t\(mate)"
            var info = readInfos[compositeKey] ?? ReadTrimInfo()
            info.barcode = adapterName
            info.readLength = max(info.readLength, totalLen)

            // Use adapter position to determine direction:
            // 5' adapter: starts near position 0, trim everything up to adapter_end
            // 3' adapter: starts in the second half, trim from adapter_start onward
            // For linked adapters, cutadapt reports two info lines per read — one for
            // each arm. The adapter_start position reliably distinguishes 5' from 3'.
            let readMidpoint = totalLen / 2
            if adapterStart < readMidpoint {
                info.trim5p = max(info.trim5p, adapterEnd)
            } else {
                if info.trim3p == 0 || adapterStart < info.trim3p {
                    info.trim3p = adapterStart
                }
            }
            readInfos[compositeKey] = info
        }

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                // Process any remaining data in buffer
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
                    processLine(line)
                }
                break
            }
            buffer.append(chunk)

            // Process complete lines from buffer
            while let newlineRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    processLine(line)
                }
                buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)
            }
        }

        // Group by barcode and compute final trim positions
        var result: [String: [DemuxTrimEntry]] = [:]
        for (compositeKey, info) in readInfos {
            let parts = compositeKey.split(separator: "\t")
            let readID = String(parts[0])
            let mate = Int(parts[1]) ?? 0
            let finalTrim3p = info.trim3p > 0 ? info.readLength - info.trim3p : 0
            result[info.barcode, default: []].append(DemuxTrimEntry(
                readID: readID,
                mate: mate,
                trim5p: info.trim5p,
                trim3p: finalTrim3p,
                rootReadLength: info.readLength
            ))
        }

        return result
    }

    private func readCutadaptOrientations(from outputFASTQ: URL) async throws -> [String: String] {
        let reader = FASTQReader(validateSequence: false)
        var orientations: [String: String] = [:]

        for try await record in reader.records(from: outputFASTQ) {
            let rawReadName = record.description.map { "\(record.identifier) \($0)" } ?? record.identifier
            let (readID, _) = detectMate(rawReadName: rawReadName)
            let orientation = isReverseComplementDescription(record.description) ? "-" : "+"
            orientations[readID] = orientation
        }

        return orientations
    }

    private func composeFinalOrientMap(
        parentOrientMap: [String: String],
        cutadaptOrientMap: [String: String],
        readIDs: [String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for readID in readIDs {
            let parentOrientation = parentOrientMap[readID] ?? "+"
            let cutadaptOrientation = cutadaptOrientMap[readID] ?? "+"
            let finalOrientation: String = if cutadaptOrientation == "-" {
                parentOrientation == "-" ? "+" : "-"
            } else {
                parentOrientation
            }
            result[readID] = finalOrientation
        }
        return result
    }

    private func normalizeTrimEntriesToInputOrientation(
        _ entries: [DemuxTrimEntry],
        cutadaptOrientMap: [String: String]
    ) -> [DemuxTrimEntry] {
        entries.map { entry in
            guard cutadaptOrientMap[entry.readID] == "-" else { return entry }
            return DemuxTrimEntry(
                readID: entry.readID,
                mate: entry.mate,
                trim5p: entry.trim3p,
                trim3p: entry.trim5p,
                rootReadLength: entry.rootReadLength
            )
        }
    }

    private func rebaseTrimEntriesToRoot(
        _ entries: [DemuxTrimEntry],
        parentTrimMap: [String: (trim5p: Int, trim3p: Int)],
        parentOrientMap: [String: String]
    ) -> [DemuxTrimEntry] {
        entries.map { entry in
            let key = "\(entry.readID)\t\(entry.mate)"
            let parentTrim = parentTrimMap[key]
            let rebased = DemuxTrimEntry(
                readID: entry.readID,
                mate: entry.mate,
                trim5p: entry.trim5p + (parentTrim?.trim5p ?? 0),
                trim3p: entry.trim3p + (parentTrim?.trim3p ?? 0),
                rootReadLength: entry.rootReadLength.map {
                    $0 + (parentTrim?.trim5p ?? 0) + (parentTrim?.trim3p ?? 0)
                }
            )
            guard parentOrientMap[entry.readID] == "-" else { return rebased }
            return DemuxTrimEntry(
                readID: rebased.readID,
                mate: rebased.mate,
                trim5p: rebased.trim3p,
                trim3p: rebased.trim5p,
                rootReadLength: rebased.rootReadLength
            )
        }
    }

    private func deriveTrimEntriesByDiff(
        originalFASTQ: URL,
        trimmedFASTQ: URL,
        cutadaptOrientMap: [String: String]
    ) async throws -> [DemuxTrimEntry] {
        let trimmedReader = FASTQReader(validateSequence: false)
        var trimmedByKey: [String: FASTQRecord] = [:]

        for try await record in trimmedReader.records(from: trimmedFASTQ) {
            let rawReadName = record.description.map { "\(record.identifier) \($0)" } ?? record.identifier
            let (readID, mate) = detectMate(rawReadName: rawReadName)
            trimmedByKey["\(readID)\t\(mate)"] = record
        }

        let originalReader = FASTQReader(validateSequence: false)
        var entries: [DemuxTrimEntry] = []

        for try await record in originalReader.records(from: originalFASTQ) {
            let rawReadName = record.description.map { "\(record.identifier) \($0)" } ?? record.identifier
            let (readID, mate) = detectMate(rawReadName: rawReadName)
            let key = "\(readID)\t\(mate)"
            guard let trimmedRecord = trimmedByKey[key], !trimmedRecord.sequence.isEmpty else { continue }

            let searchSequence = cutadaptOrientMap[readID] == "-"
                ? trimmedRecord.reverseComplement().sequence
                : trimmedRecord.sequence
            guard let range = record.sequence.range(of: searchSequence) else { continue }

            let trim5p = record.sequence.distance(from: record.sequence.startIndex, to: range.lowerBound)
            let trim3p = record.sequence.distance(from: range.upperBound, to: record.sequence.endIndex)
            entries.append(DemuxTrimEntry(
                readID: readID,
                mate: mate,
                trim5p: trim5p,
                trim3p: trim3p,
                rootReadLength: record.sequence.count
            ))
        }

        return entries
    }

    private func writeVirtualPreviewFASTQ(
        fromRootFASTQ rootFASTQ: URL,
        orderedReadIDs: [String],
        trimEntries: [DemuxTrimEntry],
        orientMap: [String: String],
        outputURL: URL
    ) async throws {
        guard !orderedReadIDs.isEmpty else { return }

        var trimMap: [String: DemuxTrimEntry] = [:]
        for entry in trimEntries {
            trimMap["\(entry.readID)\t\(entry.mate)"] = entry
        }

        let selectedReadIDs = Set(orderedReadIDs)
        var transformedRecords: [String: FASTQRecord] = [:]
        let reader = FASTQReader(validateSequence: false)

        for try await record in reader.records(from: rootFASTQ) {
            let rawReadName = record.description.map { "\(record.identifier) \($0)" } ?? record.identifier
            let (readID, mate) = detectMate(rawReadName: rawReadName)
            guard selectedReadIDs.contains(readID) else { continue }

            var outputRecord = record
            if let trim = trimMap["\(readID)\t\(mate)"] ?? trimMap["\(readID)\t0"] {
                let trimEnd = max(trim.trim5p, outputRecord.length - trim.trim3p)
                outputRecord = outputRecord.trimmed(from: trim.trim5p, to: trimEnd)
            }
            if orientMap[readID] == "-" {
                outputRecord = outputRecord.reverseComplement()
            }
            transformedRecords[readID] = outputRecord

            if transformedRecords.count == selectedReadIDs.count {
                break
            }
        }

        let writer = FASTQWriter(url: outputURL)
        try writer.open()
        defer { try? writer.close() }

        for readID in orderedReadIDs {
            if let record = transformedRecords[readID] {
                try writer.write(record)
            }
        }
    }

    private func writeVirtualStatisticsFASTQ(
        fromRootFASTQ rootFASTQ: URL,
        orderedReadIDs: [String],
        trimEntries: [DemuxTrimEntry],
        orientMap: [String: String],
        outputURL: URL
    ) async throws {
        guard !orderedReadIDs.isEmpty else { return }

        var trimMap: [String: DemuxTrimEntry] = [:]
        for entry in trimEntries {
            trimMap["\(entry.readID)\t\(entry.mate)"] = entry
        }

        let selectedReadIDs = Set(orderedReadIDs)
        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputURL)
        try writer.open()
        defer { try? writer.close() }

        for try await record in reader.records(from: rootFASTQ) {
            let rawReadName = record.description.map { "\(record.identifier) \($0)" } ?? record.identifier
            let (readID, mate) = detectMate(rawReadName: rawReadName)
            guard selectedReadIDs.contains(readID) else { continue }

            var outputRecord = record
            if let trim = trimMap["\(readID)\t\(mate)"] ?? trimMap["\(readID)\t0"] {
                let trimEnd = max(trim.trim5p, outputRecord.length - trim.trim3p)
                outputRecord = outputRecord.trimmed(from: trim.trim5p, to: trimEnd)
            }
            if orientMap[readID] == "-" {
                outputRecord = outputRecord.reverseComplement()
            }
            try writer.write(outputRecord)
        }
    }

    /// Detects mate number from a read name.
    /// Returns (baseReadID, mate) where mate is 0 (single), 1 (R1), or 2 (R2).
    /// Handles both /1 /2 suffix format and Illumina " 1:N:0" " 2:N:0" format.
    private func detectMate(rawReadName: String) -> (readID: String, mate: Int) {
        let parts = rawReadName.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let identifier = parts.first.map(String.init) ?? rawReadName

        // Check for /1 or /2 suffix
        if identifier.hasSuffix("/1") {
            return (String(identifier.dropLast(2)), 1)
        }
        if identifier.hasSuffix("/2") {
            return (String(identifier.dropLast(2)), 2)
        }
        // Check for Illumina format: "READID 1:N:0:BARCODE" or "READID 2:N:0:BARCODE"
        if parts.count > 1 {
            let description = String(parts[1])
            if description.hasPrefix("1:") {
                return (identifier, 1)
            }
            if description.hasPrefix("2:") {
                return (identifier, 2)
            }
        }
        return (identifier, 0)
    }

    func canonicalAdapterName(_ adapterName: String) -> String {
        guard let semicolonIndex = adapterName.lastIndex(of: ";") else {
            return adapterName
        }
        let suffix = adapterName[adapterName.index(after: semicolonIndex)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else {
            return adapterName
        }
        return String(adapterName[..<semicolonIndex])
    }

    private func isReverseComplementDescription(_ description: String?) -> Bool {
        guard let description else { return false }
        if description == "rc" {
            return true
        }
        return description.split(separator: " ").last == "rc"
    }

    /// Returns true when a bundle has a trim-positions.tsv file.
    func hasTrimPositionsFile(in bundleURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent(FASTQBundle.trimPositionFilename).path
        )
    }

    func hasOrientMapFile(in bundleURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("orient-map.tsv").path
        )
    }

    /// Returns file size in bytes.
    func fileSize(_ url: URL) -> Int64 {
        url.fileSizeBytes
    }

    /// Writes demux trim positions to a TSV file in the bundle.
    private func writeTrimPositions(_ entries: [DemuxTrimEntry], to bundleURL: URL) throws {
        guard !entries.isEmpty else { return }
        let trimURL = bundleURL.appendingPathComponent("trim-positions.tsv")
        var trimContent = "#format lungfish-demux-trim-v1\nread_id\tmate\ttrim_5p\ttrim_3p\n"
        for entry in entries {
            trimContent += "\(entry.readID)\t\(entry.mate)\t\(entry.trim5p)\t\(entry.trim3p)\n"
        }
        try trimContent.write(to: trimURL, atomically: true, encoding: .utf8)
    }

    /// Writes orient map entries for a barcode bundle, filtering to only the read IDs present.
    private func writeOrientMap(
        finalOrientMap: [String: String],
        orderedReadIDs: [String],
        to bundleURL: URL
    ) throws {
        guard !finalOrientMap.isEmpty else { return }
        var barcodeOrientRecords: [(readID: String, orientation: String)] = []
        for readID in orderedReadIDs {
            if let orient = finalOrientMap[readID] {
                barcodeOrientRecords.append((readID, orient))
            }
        }
        guard !barcodeOrientRecords.isEmpty else { return }
        let orientURL = bundleURL.appendingPathComponent("orient-map.tsv")
        try FASTQOrientMapFile.write(barcodeOrientRecords, to: orientURL)
    }

    /// Counts reads in a FASTQ file (gzipped or plain).
    func countReadsInFASTQ(url: URL) -> Int {
        let isGzipped = url.pathExtension.lowercased() == "gz"

        let process = Process()
        if isGzipped {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzcat")
            process.arguments = [url.path]
            logger.info("Running count helper: /usr/bin/gzcat \(url.path, privacy: .public)")
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/cat")
            process.arguments = [url.path]
            logger.info("Running count helper: /bin/cat \(url.path, privacy: .public)")
        }

        let countProcess = Process()
        countProcess.executableURL = URL(fileURLWithPath: "/usr/bin/wc")
        countProcess.arguments = ["-l"]
        logger.info("Running count helper: /usr/bin/wc -l")

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

}
