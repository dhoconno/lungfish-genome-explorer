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

    /// Resolved adapter context (uses override if set, otherwise derives from kit).
    public var resolvedAdapterContext: any PlatformAdapterContext {
        adapterContext ?? barcodeKit.adapterContext
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
        threads: Int = 4,
        adapterContext: (any PlatformAdapterContext)? = nil,
        sampleAssignments: [FASTQSampleBarcodeAssignment] = []
    ) {
        self.inputURL = inputURL
        self.barcodeKit = barcodeKit
        self.outputDirectory = outputDirectory
        self.barcodeLocation = barcodeLocation

        // Default symmetry from kit pairing mode
        self.symmetryMode = symmetryMode ?? {
            switch barcodeKit.pairingMode {
            case .singleEnd: return .singleEnd
            case .fixedDual: return .symmetric
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
        self.threads = threads
        self.sampleAssignments = sampleAssignments
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

        // Step 4: Create per-barcode .lungfishfastq bundles (15% progress)
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

        for (i, outputFile) in demuxOutputContents.enumerated() {
            try Task.checkCancellation()

            let baseName = outputFile.deletingPathExtension().deletingPathExtension().lastPathComponent
            let isUnassigned = baseName == "unassigned"
            let fileBytes = fileSize(outputFile)

            // Skip empty output files (0 bytes or just gzip header)
            if fileBytes <= 20 { continue }

            let bundleName = "\(baseName).\(FASTQBundle.directoryExtension)"
            let bundleURL = config.outputDirectory
                .appendingPathComponent(bundleName, isDirectory: true)
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            let destFASTQ = bundleURL.appendingPathComponent("reads.fastq.gz")
            // Use replaceItemAt for idempotent re-runs
            if fm.fileExists(atPath: destFASTQ.path) {
                _ = try fm.replaceItemAt(destFASTQ, withItemAt: outputFile)
            } else {
                try fm.moveItem(at: outputFile, to: destFASTQ)
            }

            // Count reads
            let readCount = countReadsInFASTQ(url: destFASTQ)

            // Estimate base count (compressed bytes × ~1.5 for FASTQ overhead in decompressed)
            let baseCount = Int64(Double(fileBytes) * 1.5)

            if isUnassigned {
                unassignedReadCount = readCount
                unassignedBaseCount = baseCount
                if config.unassignedDisposition == .keep {
                    unassignedBundleURL = bundleURL
                } else {
                    try? fm.removeItem(at: bundleURL)
                }
            } else {
                assignedReadCount += readCount
                let sequenceInfo = barcodeSequenceInfo(
                    for: baseName,
                    kit: config.barcodeKit,
                    sampleAssignments: config.sampleAssignments
                )
                barcodeResults.append(BarcodeResult(
                    barcodeID: baseName,
                    sampleName: sequenceInfo.sampleName,
                    forwardSequence: sequenceInfo.forward,
                    reverseSequence: sequenceInfo.reverse,
                    readCount: readCount,
                    baseCount: baseCount,
                    bundleRelativePath: bundleName
                ))
                bundleURLs.append(bundleURL)
            }

            progress(
                0.80 + Double(i + 1) * progressPerFile,
                "Created bundle for \(baseName)"
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

        if !config.sampleAssignments.isEmpty {
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
                    first: contextualizedSequence(forward, role: .i7, kit: config.barcodeKit),
                    second: contextualizedSequence(reverse, role: .i5, kit: config.barcodeKit)
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
            return AdapterConfiguration(adapterFASTA: adapterFASTA, adapterFlag: "-g")
        }

        switch config.barcodeKit.pairingMode {
        case .singleEnd:
            // For long-read platforms (ONT, PacBio), use linked adapter specs that match
            // both 5' and 3' barcode constructs. This provides better discrimination and
            // prevents false positives (e.g., barcode05 matching ONT flank sequences).
            if config.barcodeKit.platform.readsCanBeReverseComplemented {
                let ctx = config.resolvedAdapterContext
                var lines: [String] = []
                for barcode in config.barcodeKit.barcodes {
                    let spec = ctx.linkedSpec(barcodeSequence: barcode.i7Sequence)
                    lines.append(">\(barcode.id)")
                    lines.append(spec)
                }
                let content = lines.joined(separator: "\n") + "\n"
                try content.write(to: adapterFASTA, atomically: true, encoding: .utf8)
                return AdapterConfiguration(adapterFASTA: adapterFASTA, adapterFlag: "-g")
            }

            // For short-read platforms, use single-end adapter specs
            let entries: [(name: String, sequence: String)] = config.barcodeKit.barcodes.map { barcode in
                (
                    name: barcode.id,
                    sequence: contextualizedSequence(barcode.i7Sequence, role: .i7, kit: config.barcodeKit)
                )
            }
            try writeSingleEndAdapterFASTA(
                entries: entries,
                location: config.barcodeLocation,
                maxDistanceFrom5Prime: config.maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: config.maxDistanceFrom3Prime,
                to: adapterFASTA
            )
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
                        kit: config.barcodeKit
                    ),
                    second: contextualizedSequence(
                        i5,
                        role: .i5,
                        kit: config.barcodeKit
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
            return AdapterConfiguration(adapterFASTA: adapterFASTA, adapterFlag: "-g")

        case .combinatorialDual:
            throw DemultiplexError.combinatorialRequiresSampleAssignments
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
    private func contextualizedSequence(_ sequence: String, role: BarcodeRole, kit: BarcodeKitDefinition) -> String {
        let ctx = kit.adapterContext
        switch role {
        case .i7:
            return ctx.fivePrimeSpec(barcodeSequence: sequence)
        case .i5:
            return ctx.threePrimeSpec(barcodeSequence: sequence)
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
        case .singleEnd, .fixedDual:
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

        // Error rate and overlap
        args += ["-e", String(config.errorRate)]
        args += ["--overlap", String(config.minimumOverlap)]

        // Search both strand orientations for long-read platforms
        if config.searchReverseComplement {
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
        if config.barcodeKit.platform.mayNeedPolyGTrimming {
            args += ["--nextseq-trim=20"]
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

        // Build single-end adapter specs using platform context
        let ctx = kit.adapterContext
        var lines: [String] = []
        for barcode in kit.barcodes {
            let spec = ctx.linkedSpec(barcodeSequence: barcode.i7Sequence)
            lines.append(">\(barcode.id)")
            lines.append(spec)
        }
        let adapterContent = lines.joined(separator: "\n") + "\n"
        try adapterContent.write(to: adapterFASTA, atomically: true, encoding: .utf8)

        // Step 3: Run cutadapt
        progress(0.3, "Running cutadapt scout scan...")
        let demuxOutputDir = workDir.appendingPathComponent("scout-output", isDirectory: true)
        try fm.createDirectory(at: demuxOutputDir, withIntermediateDirectories: true)

        let outputPattern = demuxOutputDir.appendingPathComponent("{name}.fastq.gz").path
        let unassignedPath = demuxOutputDir.appendingPathComponent("unassigned.fastq.gz").path
        let jsonReportPath = workDir.appendingPathComponent("scout-report.json").path

        var args: [String] = []
        args += ["-g", "file:\(adapterFASTA.path)"]
        args += ["-e", String(kit.platform.recommendedErrorRate)]
        args += ["--overlap", String(kit.platform.recommendedMinimumOverlap)]
        if kit.platform.readsCanBeReverseComplemented {
            args += ["--revcomp"]
        }
        args += ["--action", "trim"]
        args += ["-o", outputPattern]
        args += ["--untrimmed-output", unassignedPath]
        args += ["--json", jsonReportPath]
        args += ["--cores", "4"]
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

        progress(0.8, "Analyzing scout results...")

        // Step 4: Count reads per barcode output file
        let outputFiles = (try? fm.contentsOfDirectory(
            at: demuxOutputDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var detections: [BarcodeDetection] = []
        var totalScanned = 0
        var unassignedCount = 0

        for outputFile in outputFiles {
            let baseName = outputFile.deletingPathExtension().deletingPathExtension().lastPathComponent
            let fileBytes = fileSize(outputFile)

            // Skip empty files
            guard fileBytes > 20 else { continue }

            let count = countReadsInFASTQ(url: outputFile)

            if baseName == "unassigned" {
                unassignedCount = count
            } else {
                detections.append(BarcodeDetection(
                    barcodeID: baseName,
                    kitID: kit.id,
                    hitCount: count,
                    hitPercentage: 0 // calculated below
                ))
            }
            totalScanned += count
        }

        // Calculate percentages and set dispositions
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

        // Sort by hit count descending
        detections.sort { $0.hitCount > $1.hitCount }

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
            let stepBaseProgress = Double(stepIndex) * progressPerStep

            guard let kit = BarcodeKitRegistry.kit(byID: step.barcodeKitID) else {
                throw DemultiplexPlanError.missingKit(step: step.label)
            }

            var perBinResults: [DemultiplexResult] = []
            let progressPerBin = progressPerStep / Double(max(1, currentInputURLs.count))

            for (binIndex, binInputURL) in currentInputURLs.enumerated() {
                let binBaseProgress = stepBaseProgress + Double(binIndex) * progressPerBin
                let binName = binInputURL.deletingPathExtension().lastPathComponent
                let stepOutputDir = outputDirectory
                    .appendingPathComponent(binName, isDirectory: true)

                let config = DemultiplexConfig(
                    inputURL: binInputURL,
                    barcodeKit: kit,
                    outputDirectory: stepOutputDir,
                    barcodeLocation: step.barcodeLocation,
                    symmetryMode: step.symmetryMode,
                    errorRate: step.errorRate,
                    minimumOverlap: step.minimumOverlap,
                    searchReverseComplement: step.searchReverseComplement,
                    sampleAssignments: step.sampleAssignments
                )

                let result = try await run(config: config) { fraction, message in
                    progress(binBaseProgress + fraction * progressPerBin, "Step \(stepIndex + 1): \(message)")
                }
                perBinResults.append(result)
            }

            stepResults.append(.init(step: step, perBinResults: perBinResults))

            // Next step's inputs are the output bundles from this step
            currentInputURLs = perBinResults.flatMap(\.outputBundleURLs)
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let finalBundles = stepResults.last?.perBinResults.flatMap(\.outputBundleURLs) ?? []
        guard let finalManifest = stepResults.last?.perBinResults.first?.manifest
            ?? stepResults.first?.perBinResults.first?.manifest else {
            throw DemultiplexError.noOutputResults
        }

        progress(1.0, "Multi-step demultiplexing complete")

        return MultiStepDemultiplexResult(
            stepResults: stepResults,
            outputBundleURLs: finalBundles,
            manifest: finalManifest,
            wallClockSeconds: elapsed
        )
    }
}
