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
    public let barcodeKit: IlluminaBarcodeDefinition

    /// Output directory for per-barcode .lungfishfastq bundles.
    public let outputDirectory: URL

    /// Where barcodes are located in the reads.
    public let barcodeLocation: BarcodeLocation

    /// Maximum error rate for barcode matching (cutadapt -e). Default 0.15.
    public let errorRate: Double

    /// Minimum overlap between barcode and read (cutadapt --overlap). Default 3.
    public let minimumOverlap: Int

    /// Whether to trim barcode sequences from output reads.
    public let trimBarcodes: Bool

    /// What to do with reads that don't match any barcode.
    public let unassignedDisposition: UnassignedDisposition

    /// Number of threads for cutadapt (--cores).
    public let threads: Int

    public init(
        inputURL: URL,
        barcodeKit: IlluminaBarcodeDefinition,
        outputDirectory: URL,
        barcodeLocation: BarcodeLocation = .anywhere,
        errorRate: Double = 0.15,
        minimumOverlap: Int = 3,
        trimBarcodes: Bool = true,
        unassignedDisposition: UnassignedDisposition = .keep,
        threads: Int = 4
    ) {
        self.inputURL = inputURL
        self.barcodeKit = barcodeKit
        self.outputDirectory = outputDirectory
        self.barcodeLocation = barcodeLocation
        self.errorRate = errorRate
        self.minimumOverlap = minimumOverlap
        self.trimBarcodes = trimBarcodes
        self.unassignedDisposition = unassignedDisposition
        self.threads = threads
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

public enum DemultiplexError: Error, LocalizedError {
    case inputFileNotFound(URL)
    case cutadaptFailed(exitCode: Int32, stderr: String)
    case noBarcodes
    case automaticBarcodeDiscoveryDisabled
    case outputParsingFailed(String)
    case bundleCreationFailed(barcode: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .inputFileNotFound(let url):
            return "Input FASTQ not found: \(url.lastPathComponent)"
        case .cutadaptFailed(let code, let stderr):
            return "cutadapt failed (exit \(code)): \(String(stderr.suffix(500)))"
        case .noBarcodes:
            return "Barcode kit has no barcodes defined"
        case .automaticBarcodeDiscoveryDisabled:
            return "Automatic barcode discovery is temporarily disabled. Select a known fixed barcode kit."
        case .outputParsingFailed(let msg):
            return "Failed to parse cutadapt output: \(msg)"
        case .bundleCreationFailed(let barcode, let error):
            return "Failed to create bundle for \(barcode): \(error)"
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
/// Supports both single-indexed and dual-indexed Illumina kits, and
/// handles barcodes at 5' (anchored), 3' (anchored), or anywhere in the read.
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
                let sequenceInfo = barcodeSequenceInfo(for: baseName, kit: config.barcodeKit)
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
        let kitForManifest = BarcodeKit(
            name: config.barcodeKit.displayName,
            vendor: config.barcodeKit.vendor,
            barcodeCount: config.barcodeKit.barcodes.count,
            isDualIndexed: config.barcodeKit.isDualIndexed,
            barcodeType: config.barcodeKit.pairingMode == .singleEnd ? .singleEnd : .asymmetric
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
                requireBothEnds: config.barcodeKit.isDualIndexed,
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

        switch config.barcodeKit.pairingMode {
        case .singleEnd:
            _ = try IlluminaBarcodeKitRegistry.generateCutadaptFASTA(
                for: config.barcodeKit,
                to: adapterFASTA,
                location: config.barcodeLocation,
                includeAdapterContext: config.barcodeKit.vendor.lowercased() == "illumina"
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
                        vendor: config.barcodeKit.vendor
                    ),
                    second: contextualizedSequence(
                        i5,
                        role: .i5,
                        vendor: config.barcodeKit.vendor
                    )
                )
            }
            guard !entries.isEmpty else { throw DemultiplexError.noBarcodes }
            try writeLinkedAdapterFASTA(entries: entries, location: config.barcodeLocation, to: adapterFASTA)
            return AdapterConfiguration(adapterFASTA: adapterFASTA, adapterFlag: "-g")

        case .combinatorialDual:
            throw DemultiplexError.automaticBarcodeDiscoveryDisabled
        }
    }

    private enum BarcodeRole {
        case i7
        case i5
    }

    private func contextualizedSequence(_ sequence: String, role: BarcodeRole, vendor: String) -> String {
        guard vendor.lowercased() == "illumina" else { return sequence.uppercased() }
        switch role {
        case .i7:
            return IlluminaAdapterContext.withContext(
                sequence: sequence.uppercased(),
                upstream: IlluminaAdapterContext.i7Upstream,
                downstream: IlluminaAdapterContext.i7Downstream
            )
        case .i5:
            return IlluminaAdapterContext.withContext(
                sequence: sequence.uppercased(),
                upstream: IlluminaAdapterContext.i5Upstream,
                downstream: IlluminaAdapterContext.i5Downstream
            )
        }
    }

    private func adapterFlag(for location: BarcodeLocation) -> String {
        switch location {
        case .fivePrime:
            return "-g"
        case .threePrime:
            return "-a"
        case .anywhere:
            return "-b"
        }
    }

    private func writeLinkedAdapterFASTA(
        entries: [(name: String, first: String, second: String)],
        location: BarcodeLocation,
        to outputURL: URL
    ) throws {
        var lines: [String] = []
        lines.reserveCapacity(max(1, entries.count * 4))

        for entry in entries {
            let first = entry.first.uppercased()
            let second = entry.second.uppercased()
            let forwardPattern = linkedAdapterPattern(first: first, second: second, location: location)
            lines.append(">\(entry.name)")
            lines.append(forwardPattern)

            if first != second {
                let reversePattern = linkedAdapterPattern(first: second, second: first, location: location)
                lines.append(">\(entry.name)")
                lines.append(reversePattern)
            }
        }

        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private func linkedAdapterPattern(first: String, second: String, location: BarcodeLocation) -> String {
        switch location {
        case .fivePrime:
            return "^\(first)...\(second)"
        case .threePrime:
            return "\(first)...\(second)$"
        case .anywhere:
            return "\(first)...\(second)"
        }
    }

    private func barcodeSequenceInfo(
        for outputName: String,
        kit: IlluminaBarcodeDefinition
    ) -> (sampleName: String?, forward: String?, reverse: String?) {
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

        // Search both strand orientations (ONT reads can be in either direction)
        args += ["--revcomp"]

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
}
